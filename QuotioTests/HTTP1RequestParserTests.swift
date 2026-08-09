//
//  HTTP1RequestParserTests.swift
//  QuotioTests
//
//  Tests for the byte-wise HTTP/1.1 request parser (issue #15, ADR 0015).
//  `HTTP1RequestParser` is a pure value type — no I/O, no actor — so these
//  tests feed it constructed request bytes directly and assert on the
//  `ParseProgress` it returns. Coverage:
//
//    - Plain Content-Length request (single feed and incremental).
//    - Chunked request with multiple chunks.
//    - Chunked with extensions (`;name=value`).
//    - Chunked empty body (just `0\r\n\r\n`).
//    - Chunked + Content-Length both present (chunked wins per RFC 9112 §6.3).
//    - Partial data split across multiple `feed` calls (byte-at-a-time).
//    - Malformed chunk size → error.
//    - Header cap exceeded → error.
//    - Body cap exceeded → error.
//    - Case-insensitive header lookup.
//    - Body preserved byte-exact including non-UTF8 bytes.
//    - Repeated header names preserved.
//

import XCTest
@testable import Quotio

final class HTTP1RequestParserTests: XCTestCase {

    // MARK: - Helpers

    /// UTF-8-safe helper to build request bytes from a Swift string.
    private func data(_ s: String) -> Data { Data(s.utf8) }

    /// Drive a parser through a sequence of byte chunks; assert the final
    /// progress is `.complete` and return the request. Fails the test if the
    /// parser errors or stalls on `needsMoreData` after all feeds.
    private func expectComplete(chunks: [Data], file: StaticString = #filePath, line: UInt = #line) throws -> HTTP1Request {
        var parser = HTTP1RequestParser()
        var lastProgress: HTTP1RequestParser.ParseProgress = .needsMoreData
        for chunk in chunks {
            lastProgress = parser.feed(chunk)
            if case .error = lastProgress {
                XCTFail("Parser errored mid-feed: \(lastProgress)", file: file, line: line)
                throw lastProgress.asError()!
            }
        }
        guard case .complete(let req) = lastProgress else {
            XCTFail("Parser did not complete after all feeds: \(lastProgress)", file: file, line: line)
            throw HTTP1RequestParserError.invalidEncoding
        }
        return req
    }

    /// Drive a parser through chunks and assert it ends in `.error` of the
    /// given kind.
    private func expectError(_ expected: HTTP1RequestParserError,
                             chunks: [Data],
                             file: StaticString = #filePath, line: UInt = #line) {
        var parser = HTTP1RequestParser()
        var lastProgress: HTTP1RequestParser.ParseProgress = .needsMoreData
        for chunk in chunks {
            lastProgress = parser.feed(chunk)
            if case .error = lastProgress { break }
        }
        guard case .error(let actual) = lastProgress else {
            XCTFail("Expected error \(expected), got \(lastProgress)", file: file, line: line)
            return
        }
        XCTAssertEqual(actual, expected, file: file, line: line)
    }

    // MARK: - Plain Content-Length

    func testContentLengthRequest_singleFeed() throws {
        let body = #"{"model":"qoder/x","prompt":"hi"}"#
        let raw = "POST /v1/chat/completions HTTP/1.1\r\n" +
            "Host: localhost:8080\r\n" +
            "Content-Type: application/json\r\n" +
            "Content-Length: \(body.utf8.count)\r\n" +
            "\r\n" +
            body
        let req = try expectComplete(chunks: [data(raw)])
        XCTAssertEqual(req.method, "POST")
        XCTAssertEqual(req.path, "/v1/chat/completions")
        XCTAssertEqual(req.version, "HTTP/1.1")
        XCTAssertEqual(req.firstHeader(named: "Content-Type"), "application/json")
        XCTAssertEqual(req.firstHeader(named: "content-type"), "application/json") // case-insensitive
        XCTAssertEqual(req.firstHeader(named: "CONTENT-LENGTH"), String(body.utf8.count))
        XCTAssertEqual(req.body, data(body))
    }

    func testContentLengthRequest_bodyArrivesSeparately() throws {
        let body = #"{"model":"qoder/x"}"#
        let head = "POST /v1/chat/completions HTTP/1.1\r\n" +
            "Content-Length: \(body.utf8.count)\r\n" +
            "\r\n"
        // Header-only first feed, then body in a second feed.
        let req = try expectComplete(chunks: [data(head), data(body)])
        XCTAssertEqual(req.body, data(body))
    }

    func testContentLengthRequest_byteAtATime() throws {
        // Stress: feed one byte at a time. Verifies the incremental state
        // machine never over-consumes or stalls.
        let body = "hello body world"
        let raw = "POST /p HTTP/1.1\r\nContent-Length: \(body.utf8.count)\r\n\r\n" + body
        let bytes = data(raw)
        var chunks: [Data] = []
        for i in 0..<bytes.count {
            let byte = bytes[bytes.startIndex.advanced(by: i)]
            chunks.append(Data([byte]))
        }
        let req = try expectComplete(chunks: chunks)
        XCTAssertEqual(req.body, data(body))
    }

    func testNoBodyRequest_contentLengthZero() throws {
        let raw = "GET /healthz HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\n\r\n"
        let req = try expectComplete(chunks: [data(raw)])
        XCTAssertEqual(req.body, Data())
    }

    func testNoBodyRequest_noContentLengthHeader() throws {
        // No body framing at all → treated as Content-Length: 0.
        let raw = "GET /healthz HTTP/1.1\r\nHost: x\r\n\r\n"
        let req = try expectComplete(chunks: [data(raw)])
        XCTAssertEqual(req.body, Data())
    }

    // MARK: - Chunked

    func testChunkedRequest_multipleChunks() throws {
        let body = "Hello, chunked world!"
        // Split the body into two chunks: "Hello, " (7) and "chunked world!" (14).
        let part1 = "Hello, "
        let part2 = "chunked world!"
        let raw = "POST /v1/chat/completions HTTP/1.1\r\n" +
            "Transfer-Encoding: chunked\r\n" +
            "\r\n" +
            String(part1.count, radix: 16) + "\r\n" + part1 + "\r\n" +
            String(part2.count, radix: 16) + "\r\n" + part2 + "\r\n" +
            "0\r\n\r\n"
        let req = try expectComplete(chunks: [data(raw)])
        XCTAssertEqual(req.body, data(body))
        // Transfer-Encoding header preserved on the parsed request (the CPA
        // pass-through strips it; the parser just reflects what arrived).
        XCTAssertEqual(req.firstHeader(named: "Transfer-Encoding"), "chunked")
    }

    func testChunkedRequest_withExtensions() throws {
        // Chunk extensions (RFC 9112 §7.1.1) after `;` are discarded.
        let raw = "POST /p HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n" +
            "5;name=value\r\nHello\r\n" +
            "6;foo=bar\r\n World\r\n" +
            "0\r\n\r\n"
        let req = try expectComplete(chunks: [data(raw)])
        XCTAssertEqual(req.body, data("Hello World"))
    }

    func testChunkedRequest_emptyBody() throws {
        // Just the terminator: `0\r\n\r\n`.
        let raw = "POST /p HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n"
        let req = try expectComplete(chunks: [data(raw)])
        XCTAssertEqual(req.body, Data())
    }

    func testChunkedRequest_withTrailerFields() throws {
        // Trailer fields after the final zero chunk are accepted and discarded.
        let raw = "POST /p HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n" +
            "5\r\nHello\r\n" +
            "0\r\n" +
            "X-Trailer: discarded\r\n" +
            "\r\n"
        let req = try expectComplete(chunks: [data(raw)])
        XCTAssertEqual(req.body, data("Hello"))
    }

    func testChunkedRequest_byteAtATime() throws {
        let raw = "POST /p HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n" +
            "5\r\nHello\r\n" +
            "1\r\n!\r\n" +
            "0\r\n\r\n"
        let bytes = data(raw)
        var chunks: [Data] = []
        for i in 0..<bytes.count {
            let byte = bytes[bytes.startIndex.advanced(by: i)]
            chunks.append(Data([byte]))
        }
        let req = try expectComplete(chunks: chunks)
        XCTAssertEqual(req.body, data("Hello!"))
    }

    // MARK: - Chunked + Content-Length precedence

    func testChunkedWinsOverContentLength() throws {
        // RFC 9112 §6.3: when both are present, chunked wins and Content-Length
        // is ignored. The decoded body is the chunk data, NOT the (wrong)
        // Content-Length framing.
        let raw = "POST /p HTTP/1.1\r\n" +
            "Content-Length: 999\r\n" +   // deliberately wrong
            "Transfer-Encoding: chunked\r\n" +
            "\r\n" +
            "5\r\nHello\r\n" +
            "0\r\n\r\n"
        let req = try expectComplete(chunks: [data(raw)])
        XCTAssertEqual(req.body, data("Hello"), "chunked body should win over Content-Length")
    }

    func testTransferEncodingListContainingChunked() throws {
        // RFC 9112 §6.2 — `chunked` may appear alongside other transfer codings.
        // We treat any list containing `chunked` as chunked.
        let raw = "POST /p HTTP/1.1\r\n" +
            "Transfer-Encoding: gzip, chunked\r\n" +
            "\r\n" +
            "5\r\nHello\r\n" +
            "0\r\n\r\n"
        let req = try expectComplete(chunks: [data(raw)])
        XCTAssertEqual(req.body, data("Hello"))
    }

    // MARK: - Errors

    func testMalformedChunkSize_returnsError() {
        let raw = "POST /p HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n" +
            "NOT-HEX\r\nHello\r\n" +
            "0\r\n\r\n"
        expectError(.invalidChunkSize(snippet: "NOT-HEX"), chunks: [data(raw)])
    }

    func testHeaderCapExceeded_returnsError() {
        // Build a header section with no `\r\n\r\n` terminator that exceeds
        // the configured header cap. Use a small cap so the test is fast.
        let huge = String(repeating: "X", count: 200)
        let raw = "POST /p HTTP/1.1\r\nX-Junk: \(huge)\r\n"
        var parser = HTTP1RequestParser(maxHeaderBytes: 100, maxBodyBytes: 1024)
        let progress = parser.feed(data(raw))
        guard case .error(let err) = progress else {
            XCTFail("Expected headerTooLarge, got \(progress)")
            return
        }
        XCTAssertEqual(err, .headerTooLarge(maxBytes: 100))
    }

    func testBodyCapExceeded_contentLength_returnsError() {
        // Content-Length declares more than the cap allows.
        let raw = "POST /p HTTP/1.1\r\nContent-Length: 1024\r\n\r\n"
        var parser = HTTP1RequestParser(maxHeaderBytes: 4096, maxBodyBytes: 16)
        let progress = parser.feed(data(raw))
        guard case .error(let err) = progress else {
            XCTFail("Expected bodyTooLarge, got \(progress)")
            return
        }
        XCTAssertEqual(err, .bodyTooLarge(maxBytes: 16))
    }

    func testBodyCapExceeded_chunked_returnsError() {
        // A chunked body whose accumulated data exceeds the cap.
        let raw = "POST /p HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n" +
            "20\r\n" + String(repeating: "A", count: 32) + "\r\n" +
            "0\r\n\r\n"
        var parser = HTTP1RequestParser(maxHeaderBytes: 4096, maxBodyBytes: 16)
        let progress = parser.feed(data(raw))
        guard case .error(let err) = progress else {
            XCTFail("Expected bodyTooLarge, got \(progress)")
            return
        }
        XCTAssertEqual(err, .bodyTooLarge(maxBytes: 16))
    }

    /// Tier 1's body cap must stay above the Tier 2 image cap's *wire*
    /// footprint. `QoderTranslatorLimits.maxImageBytes` measures decoded image
    /// bytes, but inline images travel as base64 data URLs (~4/3x on the
    /// wire). If the body cap dips below `maxImageBytes * 4/3` (+ the largest
    /// tool schema + JSON overhead), a request that Tier 2 would legitimately
    /// accept gets 413'd at the parser before the translator's own cap is
    /// ever consulted. Pins the tier ordering.
    func testBodyCapStaysAboveImageCapWireFootprint() {
        let limits = QoderTranslatorLimits.default
        let imageWireFootprint = limits.maxImageBytes * 4 / 3
        let worstCaseBody = imageWireFootprint + limits.maxToolSchemaBytes + 1024 * 1024
        XCTAssertGreaterThan(HTTP1RequestParser.defaultMaxBodyBytes, worstCaseBody)
    }

    func testMalformedRequestLine_returnsError() {
        let raw = "NOT-A-VALID-REQUEST-LINE\r\n\r\n"
        expectError(.malformedRequestLine(snippet: "NOT-A-VALID-REQUEST-LINE"), chunks: [data(raw)])
    }

    func testMalformedHeaderLine_returnsError() {
        // Header line without `:` after the request line.
        let raw = "GET /p HTTP/1.1\r\nNoColon Here Just Text\r\n\r\n"
        var parser = HTTP1RequestParser()
        let progress = parser.feed(data(raw))
        guard case .error(let err) = progress else {
            XCTFail("Expected malformedHeaderLine, got \(progress)")
            return
        }
        if case .malformedHeaderLine = err {
            // ok
        } else {
            XCTFail("Expected malformedHeaderLine, got \(err)")
        }
    }

    func testInvalidContentLength_returnsError() {
        let raw = "POST /p HTTP/1.1\r\nContent-Length: not-a-number\r\n\r\n"
        expectError(.invalidContentLength(snippet: "not-a-number"), chunks: [data(raw)])
    }

    // MARK: - W1: unbounded size-line / trailer accumulation

    func testChunkedUnterminatedSizeLine_boundedByHeaderCap() {
        // Regression (W1): a client streaming bytes with no CRLF in the
        // chunk-size line used to grow `pending` unbounded (the body cap only
        // fires once a size parses). Now the sizeLine phase enforces the same
        // header cap as the request header section.
        let header = "POST /p HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n"
        var parser = HTTP1RequestParser(maxHeaderBytes: 100, maxBodyBytes: 1024)
        _ = parser.feed(data(header))
        // Feed a size line with NO CRLF — just hex-ish bytes that grow.
        let flood = String(repeating: "A", count: 200)
        let progress = parser.feed(data(flood))
        guard case .error(let err) = progress else {
            XCTFail("Expected headerTooLarge, got \(progress)")
            return
        }
        XCTAssertEqual(err, .headerTooLarge(maxBytes: 100))
    }

    func testChunkedUnterminatedTrailer_boundedByHeaderCap() {
        // Regression (W1): same vector via a trailer field line after the
        // final `0\r\n` that never gets its terminating CRLF.
        let header = "POST /p HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n" +
            "5\r\nHello\r\n0\r\n"
        var parser = HTTP1RequestParser(maxHeaderBytes: 100, maxBodyBytes: 1024)
        _ = parser.feed(data(header))
        // Trailer line with no CRLF terminator, growing past the cap.
        let flood = "X-Trailer: " + String(repeating: "z", count: 200)
        let progress = parser.feed(data(flood))
        guard case .error(let err) = progress else {
            XCTFail("Expected headerTooLarge, got \(progress)")
            return
        }
        XCTAssertEqual(err, .headerTooLarge(maxBytes: 100))
    }

    // MARK: - W3: control-character / forbidden-byte rejection

    func testHeaderRejectsNULInValue() {
        // NUL in a header value can act as a string terminator to some
        // upstream parsers; reject it.
        var raw = Data("POST /p HTTP/1.1\r\nX-Bad: hello".utf8)
        raw.append(0x00)
        raw.append(data(" world\r\nContent-Length: 0\r\n\r\n"))
        var parser = HTTP1RequestParser()
        let progress = parser.feed(raw)
        guard case .error(let err) = progress else {
            XCTFail("Expected invalidHeaderCharacter, got \(progress)")
            return
        }
        if case .invalidHeaderCharacter = err {
            // ok
        } else {
            XCTFail("Expected invalidHeaderCharacter, got \(err)")
        }
    }

    func testHeaderRejectsBareCRInValue() {
        // Bare CR in a header value can act as a line terminator to a lenient
        // upstream parser (request splitting); reject it.
        let raw = "POST /p HTTP/1.1\r\nX-Bad: hello\rworld\r\nContent-Length: 0\r\n\r\n"
        var parser = HTTP1RequestParser()
        let progress = parser.feed(data(raw))
        guard case .error(let err) = progress else {
            XCTFail("Expected invalidHeaderCharacter, got \(progress)")
            return
        }
        if case .invalidHeaderCharacter = err {
            // ok
        } else {
            XCTFail("Expected invalidHeaderCharacter, got \(err)")
        }
    }

    func testHeaderRejectsBareLFInValue() {
        // Bare LF in a header value — same request-splitting vector.
        let raw = "POST /p HTTP/1.1\r\nX-Bad: he\nllo\r\nContent-Length: 0\r\n\r\n"
        var parser = HTTP1RequestParser()
        let progress = parser.feed(data(raw))
        guard case .error(let err) = progress else {
            XCTFail("Expected invalidHeaderCharacter, got \(progress)")
            return
        }
        if case .invalidHeaderCharacter = err {
            // ok
        } else {
            XCTFail("Expected invalidHeaderCharacter, got \(err)")
        }
    }

    func testHeaderRejectsControlCharInName() {
        // A header name must be `1*tchar` — NUL/control bytes are forbidden.
        var raw = Data("POST /p HTTP/1.1\r\nX-B".utf8)
        raw.append(0x00)
        raw.append(data("ad: value\r\nContent-Length: 0\r\n\r\n"))
        var parser = HTTP1RequestParser()
        let progress = parser.feed(raw)
        guard case .error(let err) = progress else {
            XCTFail("Expected invalidHeaderCharacter, got \(progress)")
            return
        }
        if case .invalidHeaderCharacter = err {
            // ok
        } else {
            XCTFail("Expected invalidHeaderCharacter, got \(err)")
        }
    }

    func testHeaderAcceptsTabAndObsTextInValue() throws {
        // Sanity: HTAB (0x09) and obs-text (>=0x80, e.g. Latin-1) ARE allowed
        // in field-values per RFC 9110 §5.6. Confirms the W3 check isn't
        // over-rejecting legitimate values.
        let value = Data("café".utf8)
        let raw = Data("POST /p HTTP/1.1\r\nX-Tab: a\tb\r\n".utf8)
            + Data("X-Latin1: ".utf8)
            + value
            + Data("\r\nContent-Length: 0\r\n\r\n".utf8)
        let req = try expectComplete(chunks: [raw])
        XCTAssertEqual(req.firstHeader(named: "X-Tab"), "a\tb")
        XCTAssertEqual(req.firstHeader(named: "X-Latin1"), "café")
    }

    // MARK: - S1: conflicting Content-Length + combined Transfer-Encoding

    func testConflictingContentLengthHeaders_rejected() {
        // RFC 9110 §8.6: two Content-Length headers with disagreeing values
        // are malformed → 400. (Same value is allowed; tested below.)
        let raw = "POST /p HTTP/1.1\r\n" +
            "Content-Length: 5\r\n" +
            "Content-Length: 6\r\n" +
            "\r\nhello"
        var parser = HTTP1RequestParser()
        let progress = parser.feed(data(raw))
        guard case .error(let err) = progress else {
            XCTFail("Expected conflictingContentLength, got \(progress)")
            return
        }
        if case .conflictingContentLength = err {
            // ok
        } else {
            XCTFail("Expected conflictingContentLength, got \(err)")
        }
    }

    func testConflictingContentLengthCommaList_rejected() {
        // A single CL header with a comma-list of differing values is also
        // malformed per RFC 9110 §8.6.
        let raw = "POST /p HTTP/1.1\r\nContent-Length: 5, 6\r\n\r\nhello"
        var parser = HTTP1RequestParser()
        let progress = parser.feed(data(raw))
        guard case .error(let err) = progress else {
            XCTFail("Expected conflictingContentLength, got \(progress)")
            return
        }
        if case .conflictingContentLength = err {
            // ok
        } else {
            XCTFail("Expected conflictingContentLength, got \(err)")
        }
    }

    func testAgreementContentLengthHeaders_accepted() throws {
        // RFC 9110 §8.6: multiple Content-Length headers with the SAME value
        // are allowed (treated as one).
        let raw = "POST /p HTTP/1.1\r\n" +
            "Content-Length: 5\r\n" +
            "Content-Length: 5\r\n" +
            "\r\nhello"
        let req = try expectComplete(chunks: [data(raw)])
        XCTAssertEqual(req.body, data("hello"))
    }

    func testSplitTransferEncodingLines_combinedIntoChunked() throws {
        // RFC 9112 §5.2/§5.3: a sender may split a list-valued header across
        // multiple field-lines. `TE: gzip` + `TE: chunked` is equivalent to
        // `TE: gzip, chunked` and must be treated as chunked.
        let raw = "POST /p HTTP/1.1\r\n" +
            "Transfer-Encoding: gzip\r\n" +
            "Transfer-Encoding: chunked\r\n" +
            "\r\n" +
            "5\r\nHello\r\n" +
            "0\r\n\r\n"
        let req = try expectComplete(chunks: [data(raw)])
        XCTAssertEqual(req.body, data("Hello"))
    }

    // MARK: - W4: headerBytes accounting

    func testHeaderBytesReported_contentLength() throws {
        // W4: the parser surfaces the consumed wire header-section byte count
        // so ProxyBridge can compute a wire-accurate requestSize.
        let body = "hello"
        let head = "POST /p HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\n"
        let req = try expectComplete(chunks: [data(head + body)])
        XCTAssertEqual(req.headerBytes, head.utf8.count)
        // Sanity: the body is the remainder.
        XCTAssertEqual(req.body, data(body))
    }

    func testHeaderBytesReported_chunked() throws {
        let head = "POST /p HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n"
        let raw = head + "5\r\nHello\r\n0\r\n\r\n"
        let req = try expectComplete(chunks: [data(raw)])
        XCTAssertEqual(req.headerBytes, head.utf8.count)
    }

    // MARK: - Header semantics

    func testCaseInsensitiveHeaderLookup() throws {
        let raw = "POST /p HTTP/1.1\r\n" +
            "Content-Type: application/json\r\n" +
            "Authorization: Bearer abc-123\r\n" +
            "Content-Length: 0\r\n" +
            "\r\n"
        let req = try expectComplete(chunks: [data(raw)])
        XCTAssertEqual(req.firstHeader(named: "content-type"), "application/json")
        XCTAssertEqual(req.firstHeader(named: "CONTENT-TYPE"), "application/json")
        XCTAssertEqual(req.firstHeader(named: "AuThOrIzAtIoN"), "Bearer abc-123")
    }

    func testRepeatedHeadersPreserved() throws {
        // RFC 9112 §5.2: repeated header names are allowed. The parser keeps
        // each occurrence as a separate entry in arrival order.
        let raw = "GET /p HTTP/1.1\r\n" +
            "X-Multi: one\r\n" +
            "X-Multi: two\r\n" +
            "X-Multi: three\r\n" +
            "\r\n"
        let req = try expectComplete(chunks: [data(raw)])
        let multiValues = req.headers
            .filter { $0.name == "X-Multi" }
            .map(\.value)
        XCTAssertEqual(multiValues, ["one", "two", "three"])
        // firstHeader(named:) returns the first occurrence.
        XCTAssertEqual(req.firstHeader(named: "X-Multi"), "one")
    }

    // MARK: - Body byte-exactness (non-UTF8)

    func testBodyPreservesNonUTF8Bytes_contentLength() throws {
        // A body containing bytes that are NOT valid UTF-8 (0xFF, 0xFE, 0x00).
        // The body must round-trip byte-exact — the whole point of the
        // byte-wise parser is that consumers never Stringify the body.
        var bodyBytes = Data([0xFF, 0xFE, 0x00, 0x01, 0x02, 0x80])
        // Pad to a known length.
        bodyBytes.append(Data(repeating: 0xAB, count: 10))
        let head = "POST /upload HTTP/1.1\r\n" +
            "Content-Length: \(bodyBytes.count)\r\n" +
            "Content-Type: application/octet-stream\r\n" +
            "\r\n"
        let req = try expectComplete(chunks: [data(head), bodyBytes])
        XCTAssertEqual(req.body, bodyBytes, "body must be byte-exact including non-UTF8 bytes")
        // And String(body) must fail — proving we didn't Stringify internally.
        XCTAssertNil(String(data: req.body, encoding: .utf8),
                     "non-UTF8 body must not be representable as UTF-8")
    }

    func testBodyPreservesNonUTF8Bytes_chunked() throws {
        // Same as above but chunked: the chunk-data fields are concatenated
        // byte-exact, including non-UTF8 bytes.
        let chunk1 = Data([0xFF, 0xFE, 0x00])
        let chunk2 = Data([0x80, 0x81, 0x82])
        let raw = "POST /upload HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n" +
            "3\r\n" +
            // chunk1 bytes follow inline (cannot embed raw bytes in a Swift
            // string literal cleanly, so we build the full frame as Data).
            ""
        // Build the full frame as Data so the non-UTF8 bytes land literally.
        var frame = Data()
        frame.append(data(raw))
        frame.append(chunk1)
        frame.append(data("\r\n3\r\n"))
        frame.append(chunk2)
        frame.append(data("\r\n0\r\n\r\n"))

        let req = try expectComplete(chunks: [frame])
        let expected = chunk1 + chunk2
        XCTAssertEqual(req.body, expected)
        XCTAssertNil(String(data: req.body, encoding: .utf8))
    }

    // MARK: - Incremental / partial

    func testPartialHeaderAcrossFeeds() throws {
        // The header boundary `\r\n\r\n` arrives split across two feeds.
        let body = "x"
        let raw = "POST /p HTTP/1.1\r\nContent-Length: 1\r\n\r\n" + body
        // Split exactly at the midpoint of `\r\n\r\n`: "...Length: 1\r\n" + "\r\n..."
        let midpoint = raw.range(of: "Length: 1\r\n")!.upperBound
        let head = String(raw[..<midpoint])
        let tail = String(raw[midpoint...])
        let req = try expectComplete(chunks: [data(head), data(tail)])
        XCTAssertEqual(req.body, data(body))
    }

    func testNeedsMoreDataBeforeComplete() {
        // Feed only the header (no body yet) — parser should report
        // needsMoreData, not error.
        var parser = HTTP1RequestParser()
        let head = data("POST /p HTTP/1.1\r\nContent-Length: 5\r\n\r\n")
        let progress = parser.feed(head)
        XCTAssertEqual(progress, .needsMoreData)
    }

    func testChunkedPartialSizeLineAcrossFeeds() throws {
        // The chunk-size line itself splits across feeds.
        var parser = HTTP1RequestParser()
        _ = parser.feed(data("POST /p HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n"))
        XCTAssertEqual(parser.feed(data("5\r")), .needsMoreData)
        XCTAssertEqual(parser.feed(data("\nHel")), .needsMoreData)
        XCTAssertEqual(parser.feed(data("lo\r")), .needsMoreData)
        XCTAssertEqual(parser.feed(data("\n0\r")), .needsMoreData)
        XCTAssertEqual(parser.feed(data("\n\r")), .needsMoreData)
        let last = parser.feed(data("\n"))
        guard case .complete(let req) = last else {
            XCTFail("Expected complete, got \(last)")
            return
        }
        XCTAssertEqual(req.body, data("Hello"))
    }

    // MARK: - Single-shot parse()

    func testParseSingleShot_convenience() throws {
        let body = #"{"ok":true}"#
        let raw = "POST /p HTTP/1.1\r\nContent-Length: \(body.utf8.count)\r\n\r\n" + body
        var parser = HTTP1RequestParser()
        let req = try parser.parse(data(raw))
        XCTAssertEqual(req.body, data(body))
    }

    func testParseSingleShot_throwsOnPartial() {
        var parser = HTTP1RequestParser()
        XCTAssertThrowsError(try parser.parse(data("POST /p HTTP/1.1\r\nContent-Length: 5\r\n\r\n"))) { err in
            guard err is HTTP1RequestParserError else {
                XCTFail("Expected HTTP1RequestParserError, got \(err)")
                return
            }
        }
    }

    // MARK: - Sticky terminal

    func testTerminalParserIsSticky() {
        // After completion, feeding more bytes is a logic bug — surface as
        // an error rather than masking as success.
        var parser = HTTP1RequestParser()
        let raw = "GET /p HTTP/1.1\r\nContent-Length: 0\r\n\r\n"
        let first = parser.feed(data(raw))
        guard case .complete = first else {
            XCTFail("Expected complete on first feed, got \(first)")
            return
        }
        let second = parser.feed(data("EXTRA"))
        guard case .error = second else {
            XCTFail("Expected error on second feed of terminal parser, got \(second)")
            return
        }
    }
}

// MARK: - Test-only ParseProgress helpers

private extension HTTP1RequestParser.ParseProgress {
    /// Bridge a `.error` case to `Error?` for test ergonomics.
    func asError() -> Error? {
        switch self {
        case .error(let e): return e
        default: return nil
        }
    }
}
