//
//  HTTP1RequestParser.swift
//  Quotio
//
//  Byte-wise HTTP/1.1 request parser for ProxyBridge.receiveRequest
//  (issue #15, ADR 0015). Replaces the prior String-based scan that converted
//  the whole request accumulation to a Swift `String` on every NWConnection
//  receive callback (memory doubling + UTF-8 decode cost on the hot path).
//
//  This parser scans the accumulated `Data` buffer directly for the `\r\n\r\n`
//  header terminator, decodes ONLY the header section to `String` (bounded by
//  `maxHeaderBytes`), and frames the body by either Content-Length (existing
//  behavior) or Transfer-Encoding: chunked (RFC 9112 §7.1, supported for the
//  first time). Chunked takes precedence over Content-Length when both are
//  present (RFC 9112 §6.3).
//
//  Pure value type — no I/O, no actor state — mirroring `QoderSSEReparser` /
//  `QoderCompletionAggregator`: `nonisolated struct` so it opts out of the
//  project's MainActor default isolation, `mutating func feed` for
//  testability and single-domain ownership. ProxyBridge holds it as a
//  per-request `var` inside `receiveRequest` (the NWConnection callback runs
//  off the MainActor); tests construct one and feed bytes directly.
//
//  ADR 0013 Tier 1 receive-path caps (`maxHeaderBytes`, `maxBodyBytes`) are
//  enforced HERE — the single seam both the Qoder and CPA routing branches
//  flow through — so a body-exhaustion vector cannot pick the loose path.
//

import Foundation

/// Errors thrown while parsing an HTTP/1.1 request. None of these carry
/// token/secret content — only byte counts and short header snippets.
/// `ProxyBridge.receiveRequest` maps each to HTTP 400 or 413 via the ADR 0010
/// envelope.
nonisolated enum HTTP1RequestParserError: Error, LocalizedError, Equatable {
    /// The header section exceeded `maxHeaderBytes` without a `\r\n\r\n`
    /// terminator. ADR 0013 Tier 1 cap → HTTP 413.
    case headerTooLarge(maxBytes: Int)
    /// The request body exceeded `maxBodyBytes` before framing completed.
    /// Applies to both Content-Length and chunked framing (ADR 0013 Tier 1).
    /// → HTTP 413.
    case bodyTooLarge(maxBytes: Int)
    /// The request line was missing or malformed (not the expected
    /// `METHOD SP PATH SP VERSION` triple). → HTTP 400.
    case malformedRequestLine(snippet: String)
    /// A header line was malformed (no `:` separating name and value). The
    /// prior String-based parser silently `continue`d past these; we surface
    /// them so a malformed request is not silently forwarded. → HTTP 400.
    case malformedHeaderLine(snippet: String)
    /// `Content-Length` carried a value that was not a non-negative integer.
    /// → HTTP 400.
    case invalidContentLength(snippet: String)
    /// Two `Content-Length` headers carried disagreeing values, or a single
    /// `Content-Length` header carried a comma-list of differing values
    /// (RFC 9110 §8.6). → HTTP 400.
    case conflictingContentLength(values: [String])
    /// A header name was empty, or a header name or value contained a control
    /// character that is forbidden by RFC 9110 §5.5 / §5.6
    /// (`field-name = 1*tchar`, `field-value = *( HTAB / SP / VCHAR /
    /// obs-text )`; NUL and bare CR/LF are always rejected because they can
    /// act as line terminators to lenient upstream parsers — request
    /// splitting). → HTTP 400.
    case invalidHeaderCharacter(snippet: String)
    /// A chunk-size line was not valid hex (RFC 9112 §7.1). → HTTP 400.
    case invalidChunkSize(snippet: String)
    /// The request did not begin with a valid HTTP/1.x request line, or a
    /// terminal parser was fed extra bytes. → HTTP 400.
    case invalidEncoding

    var errorDescription: String? {
        switch self {
        case .headerTooLarge(let max):
            return "Request header exceeded \(max) bytes."
        case .bodyTooLarge(let max):
            return "Request body exceeded \(max) bytes."
        case .malformedRequestLine(let snippet):
            return "Malformed request line: \(String(snippet.prefix(120)))."
        case .malformedHeaderLine(let snippet):
            return "Malformed header line: \(String(snippet.prefix(120)))."
        case .invalidContentLength(let snippet):
            return "Invalid Content-Length value: \(String(snippet.prefix(60)))."
        case .conflictingContentLength(let values):
            return "Conflicting Content-Length values: \(values.prefix(4))."
        case .invalidHeaderCharacter(let snippet):
            return "Invalid character in header name or value: \(String(snippet.prefix(60)))."
        case .invalidChunkSize(let snippet):
            return "Invalid chunk size: \(String(snippet.prefix(60)))."
        case .invalidEncoding:
            return "Request bytes were not a valid HTTP/1.1 request."
        }
    }
}

/// A parsed HTTP/1.1 request. The body is raw bytes (byte-exact — for chunked
/// input this is the *decoded* body, chunk framing stripped). Headers preserve
/// arrival order and support case-insensitive lookup AND repeated names
/// (matching the prior parser's behavior; the CPA pass-through joins them as
/// `name: value` per occurrence).
nonisolated struct HTTP1Request: Sendable {
    let method: String
    let path: String
    let version: String
    /// Headers in arrival order. Each tuple is `(name, value)` with original
    /// name casing preserved. Repeated header names are kept as separate
    /// entries (RFC 9112 §5.2 allows this).
    let headers: [(name: String, value: String)]
    /// Raw body bytes. For chunked input this is the concatenation of the
    /// chunk data fields with the chunk framing removed. Byte-exact — may
    /// contain non-UTF8 bytes (binary payloads); consumers must NOT round-trip
    /// through String.
    let body: Data
    /// Byte length of the consumed wire header section: request line + headers
    /// + the trailing `\r\n\r\n` terminator. Surfaced so callers can compute
    /// a wire-accurate `requestSize = headerBytes + body.count` for advisory
    /// metrics (the parser otherwise discards the raw header bytes after
    /// decoding them).
    let headerBytes: Int

    /// First value for a header name (case-insensitive), or nil. Mirrors the
    /// lookup shape the prior parser's callers used.
    func firstHeader(named name: String) -> String? {
        let needle = name.lowercased()
        return headers.first(where: { $0.name.lowercased() == needle })?.value
    }
}

extension HTTP1Request: Equatable {
    /// Manual equality (synthesized Equatable doesn't cover arrays of named
    /// tuples). Compares method/path/version, every header pair in order,
    /// headerBytes, and the body bytes. `nonisolated` so it stays outside the
    /// project's MainActor default isolation — required so the `Equatable`
    /// conformance is callable from the parser's nonisolated context.
    nonisolated static func == (lhs: HTTP1Request, rhs: HTTP1Request) -> Bool {
        guard lhs.method == rhs.method,
              lhs.path == rhs.path,
              lhs.version == rhs.version,
              lhs.headers.count == rhs.headers.count,
              lhs.headerBytes == rhs.headerBytes,
              lhs.body == rhs.body else { return false }
        for (l, r) in zip(lhs.headers, rhs.headers) {
            guard l.name == r.name, l.value == r.value else { return false }
        }
        return true
    }
}

/// Incremental HTTP/1.1 request parser. Feed bytes as they arrive from
/// `NWConnection.receive`; each `feed` call attempts to advance the parse
/// state and reports whether more bytes are needed, the request is complete,
/// or an error occurred.
///
/// State machine:
///
///     readingHeader → readingBody(contentLength: N)
///                   → readingBody(chunked: <chunk reader state>)
///                   → complete(HTTP1Request)
///                   → failed(error)
///
/// The parser owns one `Data` accumulation buffer (`pending`). On the hot
/// path only the header section is decoded to `String` (after the `\r\n\r\n`
/// boundary is found); the body is sliced as `Data` and never Stringified.
nonisolated struct HTTP1RequestParser {

    /// ADR 0013 Tier 1 cap on the request header section. Headers are never
    /// legitimately large; if the `\r\n\r\n` boundary has not been found by
    /// the time the header accumulation reaches this size, the parser errors
    /// with `.headerTooLarge`. Sized with generous headroom over any
    /// plausible CLI-agent request.
    static let defaultMaxHeaderBytes: Int = 64 * 1024

    /// ADR 0013 Tier 1 cap on the request body. Applies identically to
    /// Content-Length framing and to accumulated chunked body bytes — the
    /// body-exhaustion vector does not care which framing the client chose
    /// (ADR 0013 §Decision). Sized to cover large multimodal / tool payloads
    /// with headroom.
    static let defaultMaxBodyBytes: Int = 64 * 1024 * 1024

    private let maxHeaderBytes: Int
    private let maxBodyBytes: Int

    /// Bytes received but not yet consumed by the framing loop. During the
    /// header phase this is the header accumulation; during the body phase
    /// this is body bytes received but not yet folded into `bodyAccumulated`.
    private var pending: Data = Data()

    /// Body bytes accumulated so far (across both framing modes). For
    /// Content-Length mode this is the in-progress body; for chunked mode
    /// this is the concatenation of completed chunk-data fields.
    private var bodyAccumulated: Data = Data()

    /// Parsed header components, kept on the parser so the body phase can
    /// read framing headers without re-parsing.
    private var parsedMethod: String = ""
    private var parsedPath: String = ""
    private var parsedVersion: String = ""
    private var parsedHeaders: [(name: String, value: String)] = []

    /// Byte length of the consumed wire header section (request line +
    /// headers + the trailing `\r\n\r\n` terminator). Set when the header
    /// phase completes; surfaced on `HTTP1Request.headerBytes` so callers can
    /// compute a wire-accurate `requestSize = headerBytes + body.count`.
    private var parsedHeaderBytes: Int = 0

    /// Parse state. `.complete` and `.failed` are terminal — a terminal
    /// parser is sticky and rejects further feeds.
    private var state: State = .readingHeader

    private enum State {
        /// Still scanning for `\r\n\r\n`.
        case readingHeader
        /// Body framed by Content-Length. `remaining` is the byte count still
        /// expected.
        case readingContentLength(remaining: Int)
        /// Body framed by Transfer-Encoding: chunked. The ChunkReader owns the
        /// per-chunk state machine (size line → data → next size line → ...).
        case readingChunked(ChunkReader)
        /// Terminal success.
        case complete(HTTP1Request)
        /// Terminal failure.
        case failed(HTTP1RequestParserError)
    }

    /// Chunked transfer-encoding reader state. RFC 9112 §7.1: each chunk is
    /// `<hex-size>[;ext] CRLF <chunk-data> CRLF`, terminated by a final
    /// zero-size chunk `0 CRLF CRLF` (optionally with trailer header fields
    /// between the final `0 CRLF` and the terminating `CRLF`).
    private struct ChunkReader: Sendable {
        enum Phase { case sizeLine, data(remaining: Int), trailersOrEnd }
        var phase: Phase = .sizeLine
    }

    /// Construct a parser with explicit caps (tests). Production callers use
    /// `HTTP1RequestParser()` for the ADR 0013 defaults.
    init(maxHeaderBytes: Int = HTTP1RequestParser.defaultMaxHeaderBytes,
         maxBodyBytes: Int = HTTP1RequestParser.defaultMaxBodyBytes) {
        self.maxHeaderBytes = maxHeaderBytes
        self.maxBodyBytes = maxBodyBytes
    }

    /// Result of one `feed` call.
    enum ParseProgress: Equatable {
        /// The parser needs more bytes to advance. The bridge should keep
        /// reading from the socket.
        case needsMoreData
        /// The request is fully parsed; the body bytes are in `request.body`.
        case complete(HTTP1Request)
        /// An error occurred (size cap exceeded, malformed framing, etc.).
        /// The bridge surfaces this as the corresponding HTTP error (400/413).
        case error(HTTP1RequestParserError)
    }

    /// Append `chunk` to the accumulation and attempt to advance the parse.
    ///
    /// Terminal-state handling (defensive — the bridge stops feeding once
    /// terminal): a `.failed` parser re-returns its stored error on every
    /// subsequent feed; a `.complete` parser returns `.error(.invalidEncoding)`
    /// so a stray late feed surfaces as a logic bug rather than masking as
    /// progress. See `testTerminalParserIsSticky`.
    mutating func feed(_ chunk: Data) -> ParseProgress {
        switch state {
        case .complete(let req):
            // Sticky success — a stray late feed is a logic bug at the
            // bridge; surface as an error so it doesn't look like progress.
            _ = req
            return .error(.invalidEncoding)
        case .failed(let err):
            return .error(err)
        case .readingHeader, .readingContentLength, .readingChunked:
            break
        }

        pending.append(chunk)
        return drive()
    }

    /// Drive the state machine as far as the current buffer allows.
    private mutating func drive() -> ParseProgress {
        while true {
            switch state {
            case .readingHeader:
                let r = tryAdvanceHeader()
                switch r {
                case .needsMoreData:
                    return .needsMoreData
                case .error(let err):
                    state = .failed(err)
                    return .error(err)
                case .advanced:
                    continue    // header phase done; loop into body phase
                }

            case .readingContentLength(let remaining):
                // Fold whatever is in `pending` into the body.
                if !pending.isEmpty {
                    bodyAccumulated.append(pending)
                    pending = Data()
                }
                let have = bodyAccumulated.count

                // Lazy body-cap enforcement (also enforced at advanceHeader
                // for the pre-declared Content-Length case).
                if have > maxBodyBytes {
                    let err = HTTP1RequestParserError.bodyTooLarge(maxBytes: maxBodyBytes)
                    state = .failed(err)
                    return .error(err)
                }

                if have >= remaining {
                    // Body complete. Slice exactly `remaining` bytes; any
                    // surplus (pipelined next request) is intentionally
                    // dropped — ProxyBridge forces Connection: close on the
                    // upstream, so pipelining past the first request is not
                    // supported here. (Matches the prior parser's behavior.)
                    let body = bodyAccumulated.prefix(remaining)
                    let request = HTTP1Request(
                        method: parsedMethod,
                        path: parsedPath,
                        version: parsedVersion,
                        headers: parsedHeaders,
                        body: Data(body),
                        headerBytes: parsedHeaderBytes
                    )
                    state = .complete(request)
                    return .complete(request)
                }
                return .needsMoreData

            case .readingChunked(var reader):
                let r = tryAdvanceChunked(reader: &reader)
                switch r {
                case .needsMoreData:
                    state = .readingChunked(reader)
                    return .needsMoreData
                case .error(let err):
                    state = .failed(err)
                    return .error(err)
                case .complete(let request):
                    state = .complete(request)
                    return .complete(request)
                }

            case .complete(let req):
                return .complete(req)
            case .failed(let err):
                return .error(err)
            }
        }
    }

    // MARK: - Header phase

    private enum AdvanceResult {
        case needsMoreData
        case error(HTTP1RequestParserError)
        case advanced
    }

    private mutating func tryAdvanceHeader() -> AdvanceResult {
        // Find `\r\n\r\n` directly in the byte buffer — no whole-buffer
        // String conversion. `Data.firstRange(of:)` is a byte scan.
        guard let endRange = pending.firstRange(of: Self.headerTerminator) else {
            // Cap check: header section alone. If `\r\n\r\n` has not been
            // found by `maxHeaderBytes` of accumulation, it's never going to
            // be a legitimate header.
            if pending.count > maxHeaderBytes {
                return .error(.headerTooLarge(maxBytes: maxHeaderBytes))
            }
            return .needsMoreData
        }

        let headerEnd = endRange.lowerBound
        let bodyStart = endRange.upperBound

        // Record the consumed wire header-section byte count (request line +
        // headers + the `\r\n\r\n` terminator) so callers can compute a
        // wire-accurate `requestSize = headerBytes + body.count`.
        parsedHeaderBytes = bodyStart

        // Decode ONLY the header section to String. This is the small,
        // bounded String decode ADR 0015 §Decision sanctions.
        let headerBytes = pending[..<headerEnd]
        guard let headerString = String(data: Data(headerBytes), encoding: .utf8) else {
            return .error(.invalidEncoding)
        }

        // Parse request line + headers. Match the prior parser's tolerance:
        // request line must split into ≥3 SP-separated tokens; header lines
        // without `:` are malformed (the prior code `continue`d silently — we
        // surface so a malformed header is not silently forwarded; tests
        // document this stricter behavior).
        let lines = headerString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            return .error(.malformedRequestLine(snippet: headerString))
        }

        let requestLineParts = requestLine.components(separatedBy: " ")
        guard requestLineParts.count >= 3 else {
            return .error(.malformedRequestLine(snippet: requestLine))
        }
        parsedMethod = requestLineParts[0]
        parsedPath = requestLineParts[1]
        parsedVersion = requestLineParts[2]

        parsedHeaders.removeAll(keepingCapacity: true)
        for line in lines.dropFirst() {
            if line.isEmpty { break }   // shouldn't happen before terminator
            guard let colonIndex = line.firstIndex(of: ":") else {
                return .error(.malformedHeaderLine(snippet: line))
            }
            let name = String(line[..<colonIndex]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)

            // W3: reject forbidden control characters. RFC 9110 §5.5/§5.6:
            //   field-name  = 1*tchar          (tchar excludes SP and CTL)
            //   field-value = *( HTAB / SP / VCHAR / obs-text )
            // A NUL or bare CR/LF in a value can act as a line terminator to a
            // lenient upstream parser (request splitting) — reject outright
            // rather than forward verbatim on the CPA path. obs-text (>=0x80)
            // is permitted by the grammar; we keep it (some clients send
            // Latin-1 in User-Agent etc.).
            if let bad = Self.firstInvalidHeaderCharacter(name: name, value: value) {
                // Surface the offending component as the snippet (name or
                // value) so the error message points at the right field.
                let snippet = bad.kind == .name ? name : value
                return .error(.invalidHeaderCharacter(snippet: snippet))
            }

            parsedHeaders.append((name, value))
        }

        // Move the trailing body bytes into `pending` (they will be folded
        // into `bodyAccumulated` by the body phase). Select the body framing
        // based on the parsed headers.
        let trailing = Data(pending[bodyStart...])
        pending = trailing

        // Select framing. Transfer-Encoding: chunked wins over Content-Length
        // per RFC 9112 §6.3 (a sender MUST NOT send both; when both arrive,
        // Content-Length is ignored — RFC 9110 §8.6). Combine ALL
        // Transfer-Encoding field-values into one list before checking for
        // chunked: multiple TE header lines are valid (RFC 9112 §5.2), and a
        // client may legitimately split `gzip, chunked` across two lines.
        let transferEncoding = combinedHeaderValues(named: "transfer-encoding")
        let isChunked = !transferEncoding.isEmpty
            && Self.headerValueContainsToken(transferEncoding, token: "chunked")

        if isChunked {
            // Chunked framing. Body bytes will be appended to
            // `bodyAccumulated` as chunk-data fields are decoded.
            bodyAccumulated = Data()
            state = .readingChunked(ChunkReader())
            return .advanced
        }

        // Content-Length framing (the default path; also used when neither
        // header is present — then Content-Length is treated as 0).
        //
        // RFC 9110 §8.6: multiple Content-Length headers with the SAME value
        // are allowed (treat as one); multiple DISAGREEING values, or a single
        // comma-list of differing values, are a 400. The prior parser took
        // first-wins; we surface conflicts so a smuggled second CL can't pick
        // a different framing on the upstream.
        let clValues = allHeaderValuesIgnoringCase("content-length")
        let contentLength: Int
        if clValues.isEmpty {
            contentLength = 0
        } else {
            // Each CL header value may itself be a comma-list (RFC 9110 §5.2).
            // Flatten to individual integer candidates and require unanimity.
            let parsed: [(raw: String, n: Int)] = clValues.compactMap { raw in
                raw.split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .compactMap { tok in
                        guard let n = Int(tok), n >= 0 else { return nil }
                        return (tok, n)
                    }
            }.flatMap { $0 }
            // Any non-integer token → invalid.
            let seenTokens = clValues.flatMap { $0.split(separator: ",") }
                .map { $0.trimmingCharacters(in: .whitespaces) }
            let invalidTokens = seenTokens.filter { Int($0) == nil }
            if !invalidTokens.isEmpty {
                return .error(.invalidContentLength(snippet: invalidTokens.first ?? ""))
            }
            let distinct = Set(parsed.map { $0.n })
            if distinct.count != 1 {
                return .error(.conflictingContentLength(values: clValues))
            }
            contentLength = distinct.first ?? 0
        }

        if contentLength > maxBodyBytes {
            return .error(.bodyTooLarge(maxBytes: maxBodyBytes))
        }

        state = .readingContentLength(remaining: contentLength)
        return .advanced
    }

    /// The 4-byte CRLF CRLF terminator.
    private static let headerTerminator = Data([0x0D, 0x0A, 0x0D, 0x0A])   // \r\n\r\n

    // MARK: - Chunked body phase (RFC 9112 §7.1)

    private enum ChunkResult {
        case needsMoreData
        case error(HTTP1RequestParserError)
        case complete(HTTP1Request)
    }

    /// RFC 9112 §7.1 chunked transfer-encoding reader. State machine:
    ///
    ///   sizeLine → parse hex (extensions after `;` discarded) → data(remaining)
    ///            → if size == 0: trailersOrEnd → expect terminating CRLF
    ///            → else: after data, expect next CRLF-terminated size line
    ///
    /// Trailer header fields after the final zero chunk (RFC 9112 §7.1.3)
    /// are accepted up to the terminating empty line and discarded — the CPA
    /// pass-through reconstructs its own headers, so forwarding trailers is
    /// not meaningful.
    private mutating func tryAdvanceChunked(reader: inout ChunkReader) -> ChunkResult {
        while true {
            switch reader.phase {
            case .sizeLine:
                // W1: a size line is never legitimately larger than a few
                // bytes (hex digits + optional `;ext`). Bound it with the
                // header cap so a client streaming bytes with no CRLF can't
                // grow `pending` unbounded (the body cap only fires once a
                // chunk size parses; an unterminated size line would otherwise
                // accumulate forever). Reuses maxHeaderBytes — a chunk-size
                // line is well under any plausible header-section bound.
                if pending.count > maxHeaderBytes {
                    return .error(.headerTooLarge(maxBytes: maxHeaderBytes))
                }
                // Read until CRLF.
                guard let (lineBytes, afterLine) = Self.readLine(from: pending) else {
                    return .needsMoreData
                }
                pending = Data(afterLine)
                let line = String(data: lineBytes, encoding: .utf8) ?? ""

                // Hex size, with optional `;` chunk extensions discarded
                // (RFC 9112 §7.1.1).
                let sizeToken: String
                if let semi = line.firstIndex(of: ";") {
                    sizeToken = String(line[..<semi]).trimmingCharacters(in: .whitespaces)
                } else {
                    sizeToken = line.trimmingCharacters(in: .whitespaces)
                }

                guard let size = Int(sizeToken, radix: 16), size >= 0 else {
                    return .error(.invalidChunkSize(snippet: line))
                }

                if size == 0 {
                    // Final chunk — trailers may follow, terminated by an
                    // empty line (the second CRLF of `0\r\n\r\n`). RFC
                    // 9112 §7.1.3.
                    reader.phase = .trailersOrEnd
                    continue
                }

                // Body cap applies to the *accumulated* chunked body — not
                // to a single chunk. Check incrementally so we don't buffer
                // an attack.
                if bodyAccumulated.count + size > maxBodyBytes {
                    return .error(.bodyTooLarge(maxBytes: maxBodyBytes))
                }

                reader.phase = .data(remaining: size)
                continue

            case .data(var remaining):
                // Consume up to `remaining` bytes of chunk data, then expect
                // a trailing CRLF (RFC 9112 §7.1: chunk-data is followed by
                // CRLF, which we discard).
                let take = min(remaining, pending.count)
                if take > 0 {
                    bodyAccumulated.append(pending.prefix(take))
                    pending = Data(pending.dropFirst(take))
                    remaining -= take
                }

                if remaining > 0 {
                    // Still need chunk-data bytes.
                    reader.phase = .data(remaining: remaining)
                    return .needsMoreData
                }

                // All chunk-data consumed — expect the trailing CRLF.
                // RFC 9112 §7.1: chunk-data is followed by CRLF.
                guard pending.count >= 2 else {
                    reader.phase = .data(remaining: 0)
                    return .needsMoreData
                }
                // Verify and skip the CRLF. Be tolerant of bare LF in the
                // separator too (matches the SSE reparser's tolerance and
                // the prior parser's behavior for malformed clients).
                if pending[0] == 0x0D, pending.count >= 2, pending[1] == 0x0A {
                    pending = Data(pending.dropFirst(2))
                } else if pending[0] == 0x0A {
                    pending = Data(pending.dropFirst(1))
                } else {
                    // Not a CRLF where one is expected — malformed chunked
                    // stream. Surface as an invalid chunk size (closest
                    // existing error; the chunk framing is broken).
                    return .error(.invalidChunkSize(snippet: "expected CRLF after chunk data"))
                }
                reader.phase = .sizeLine
                continue

            case .trailersOrEnd:
                // Standing just after the final `0\r\n`. RFC 9112 §7.1.3:
                // there may be trailer header fields, terminated by CRLF
                // (i.e. an empty line). We discard trailers; we just need to
                // find the terminating empty line.
                //
                // W1: bound `pending` here too — a client that streams trailer
                // bytes with no terminating CRLF would otherwise grow pending
                // unbounded (same vector as the sizeLine phase). Trailer field
                // lines are header-shaped; reuse the header cap.
                if pending.count > maxHeaderBytes {
                    return .error(.headerTooLarge(maxBytes: maxHeaderBytes))
                }
                guard let (lineBytes, afterLine) = Self.readLine(from: pending) else {
                    return .needsMoreData
                }
                pending = Data(afterLine)
                if lineBytes.isEmpty {
                    // Terminating empty line → chunked body complete.
                    let request = HTTP1Request(
                        method: parsedMethod,
                        path: parsedPath,
                        version: parsedVersion,
                        headers: parsedHeaders,
                        body: bodyAccumulated,
                        headerBytes: parsedHeaderBytes
                    )
                    return .complete(request)
                }
                // Trailer field — discard, continue reading lines.
                continue
            }
        }
    }

    // MARK: - Helpers

    /// Read one CRLF-terminated line from `data`. Returns the line bytes
    /// (without the CRLF) and the suffix after the CRLF, or nil if no
    /// terminator is present yet.
    ///
    /// Tolerates bare LF as a line terminator too — some HTTP clients emit
    /// size lines with bare LF, and the SSE reparser already follows the same
    /// tolerance. RFC 9112 mandates CRLF; this is a deliberate compatibility
    /// relaxation, NOT a spec deviation in our emitted bytes.
    private static func readLine(from data: Data) -> (line: Data, after: Data)? {
        let cr: UInt8 = 0x0D
        let lf: UInt8 = 0x0A
        // Find `\n`.
        guard let lfIndex = data.firstIndex(of: lf) else { return nil }
        // Determine line end (excluding the CRLF) and the suffix (after the
        // LF). If the byte before `\n` is `\r`, the line ends before the `\r`.
        let lineEnd: Int
        let afterStart: Int
        if lfIndex > data.startIndex, data[data.index(before: lfIndex)] == cr {
            lineEnd = data.index(before: lfIndex)
            afterStart = data.index(after: lfIndex)
        } else {
            // Bare LF — line ends before the `\n`.
            lineEnd = lfIndex
            afterStart = data.index(after: lfIndex)
        }
        let line = Data(data[..<lineEnd])
        let after = Data(data[afterStart...])
        return (line, after)
    }

    /// True if the header value contains the given token as one of its
    /// comma-separated transfer-codings (RFC 9112 §6.2). Case-insensitive.
    /// Used for `Transfer-Encoding: chunked` detection — also matches the
    /// trailing-token list form (`gzip, chunked`).
    private static func headerValueContainsToken(_ value: String, token: String) -> Bool {
        let lowered = value.lowercased()
        for piece in lowered.split(separator: ",") {
            let trimmed = piece.trimmingCharacters(in: .whitespaces)
            if trimmed == token { return true }
        }
        return false
    }

    /// All values for header lines matching `name` (case-insensitive), in
    /// arrival order. RFC 9112 §5.2 allows repeated header field-lines with
    /// the same name; this is how they're collected for framing-header
    /// validation (Content-Length agreement, combined Transfer-Encoding).
    private func allHeaderValuesIgnoringCase(_ name: String) -> [String] {
        let needle = name.lowercased()
        return parsedHeaders
            .filter { $0.name.lowercased() == needle }
            .map { $0.value }
    }

    /// Join all values for header lines matching `name` (case-insensitive)
    /// into one comma-separated list, per RFC 9112 §5.3 (a sender MAY split
    /// a list-valued header across multiple field-lines; the recipient
    /// equivalent is to concatenate with `, `). Used for Transfer-Encoding so
    /// `TE: gzip` + `TE: chunked` is treated identically to
    /// `TE: gzip, chunked`.
    private func combinedHeaderValues(named name: String) -> String {
        let needle = name.lowercased()
        return parsedHeaders
            .filter { $0.name.lowercased() == needle }
            .map { $0.value.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }

    /// The kind of header-field component that failed character validation.
    private enum HeaderFieldKind { case name, value }

    /// First invalid character position in a header name or value, per RFC 9110
    /// §5.5 / §5.6. Returns nil if both are clean.
    ///
    /// - Name: `field-name = 1*tchar`; `tchar` excludes SP and all control
    ///   bytes, so any byte < 0x21 (SP is 0x20) rejects, and an empty name
    ///   rejects (`1*` requires at least one).
    /// - Value: `field-value = *( HTAB / SP / VCHAR / obs-text )`. HTAB (0x09)
    ///   and SP (0x20) are allowed; NUL (0x00) and bare CR/LF (0x0D/0x0A) are
    ///   rejected outright — a bare CR or LF can act as a line terminator to a
    ///   lenient upstream parser and enable request splitting. obs-text
    ///   (>=0x80) is permitted (Latin-1 in User-Agent etc.).
    private static func firstInvalidHeaderCharacter(name: String, value: String) -> (kind: HeaderFieldKind, index: String.Index)? {
        // Name: must be non-empty, all bytes >= 0x21 (excludes SP and CTL).
        if name.isEmpty {
            return (.name, name.startIndex)
        }
        for i in name.indices {
            // Scalar arithmetic on UTF-8/UTF-16 view; ASCII fast path covers
            // all valid tchar. For multi-byte scalars (obs-text in a name is
            // already invalid per tchar), the utf8 view is the safer check —
            // but names are ASCII in practice. Use the unicodeScalars to keep
            // the check byte-accurate for the ASCII range that matters.
            let s = name[i]
            let scalar = s.unicodeScalars.first?.value ?? 0
            // Reject anything below 0x21 (covers NUL, CR, LF, HTAB, SP).
            // Names must be `tchar`, which is `!#$%&'*+-.^_`|~0-9A-Za-z-`.
            if scalar < 0x21 {
                return (.name, i)
            }
        }
        // Value: reject NUL, bare CR, bare LF. HTAB (0x09) and SP (0x20) are
        // explicit in the grammar; VCHAR (0x21-0x7E) and obs-text (0x80-0xFF)
        // are allowed.
        for i in value.indices {
            let scalar = value[i].unicodeScalars.first?.value ?? 0
            if scalar == 0x00 || scalar == 0x0D || scalar == 0x0A {
                return (.value, i)
            }
        }
        return nil
    }
}

// MARK: - Single-shot convenience

extension HTTP1RequestParser {

    /// Convenience for tests / single-shot callers: parse a complete request
    /// from one `Data` in a single call. Returns the request or throws.
    mutating func parse(_ data: Data) throws -> HTTP1Request {
        let progress = feed(data)
        switch progress {
        case .complete(let req):
            return req
        case .needsMoreData:
            throw HTTP1RequestParserError.invalidEncoding
        case .error(let err):
            throw err
        }
    }
}
