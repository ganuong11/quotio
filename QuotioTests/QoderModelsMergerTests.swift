//
//  QoderModelsMergerTests.swift
//  QuotioTests
//
//  Issue #10 / ADR 0016: pin the pure merge + body-extraction helpers for the
//  `/v1/models` intercept. The network half (ProxyBridge.serveModelsList,
//  NWConnection accumulation, raw-passthrough degradation) is exercised by
//  inspection of `serveModelsList` — these tests cover the deterministic,
//  side-effect-free surface that the network path delegates to.
//

import XCTest
@testable import Quotio

final class QoderModelsMergerTests: XCTestCase {

    // MARK: - catalogKeys / catalogEpoch sanity

    func testCatalogKeysMatchesKnownIDsAndCount() {
        // `catalogKeys` is the ORDERED enumeration source for the merge (issue
        // #10). It must cover exactly the same IDs as `knownIDs` (the unordered
        // set used for membership tests), and the count is the current seed
        // size — pinning it makes a future seed change deliberate (the merge
        // output count assertion below depends on this number).
        let keys = QoderModelRegistry.catalogKeys
        XCTAssertEqual(Set(keys), QoderModelRegistry.knownIDs,
                       "catalogKeys and knownIDs must describe the same catalog")
        XCTAssertEqual(keys.count, 15,
                       "seed size — update this when QoderModelRegistry.entries changes")
        XCTAssertEqual(QoderModelRegistry.knownIDs.count, 15)
    }

    func testCatalogKeysIsStableAcrossCalls() {
        // Set ordering in Swift is not stable, so `catalogKeys` MUST source
        // from the ordered `entries` array — not `knownIDs`. Two calls must
        // return the same sequence (the merge is deterministic).
        XCTAssertEqual(QoderModelRegistry.catalogKeys, QoderModelRegistry.catalogKeys)
        // Pin the exact seed order (auto, ultimate, performance, efficient,
        // lite, qmodel, qmodel_latest, qmodel_38max, dmodel, dfmodel, gm51model,
        // kmodel, kmodel_latest, mmodel, cmodel) so a reorder is deliberate.
        let expected = [
            "auto", "ultimate", "performance", "efficient", "lite",
            "qmodel", "qmodel_latest", "qmodel_38max",
            "dmodel", "dfmodel",
            "gm51model",
            "kmodel", "kmodel_latest",
            "mmodel",
            "cmodel",
        ]
        XCTAssertEqual(QoderModelRegistry.catalogKeys, expected)
    }

    func testCatalogEpochDecodesTo2026August03UTC() {
        // `catalogEpoch` is documented as the 2026-08-03 catalog-refresh date
        // at MIDNIGHT UTC (the output of `date -j -u -f "%Y-%m-%d" ...`).
        // Pin the full instant, not just the calendar day — a day-only check
        // would silently accept an off-by-hours error (e.g. a local-timezone
        // computation leaking into the constant).
        let date = Date(timeIntervalSince1970: TimeInterval(QoderModelsMerger.catalogEpoch))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: date
        )
        XCTAssertEqual(components.year, 2026)
        XCTAssertEqual(components.month, 8)
        XCTAssertEqual(components.day, 3)
        XCTAssertEqual(components.hour, 0)
        XCTAssertEqual(components.minute, 0)
        XCTAssertEqual(components.second, 0)
    }

    // MARK: - mergeQoderModels — happy paths

    func testMergeOnRealisticCPABodyAppendsQoderEntriesInOrder() {
        // The realistic CPA body: OpenAI models-list shape with a couple of
        // provider entries. CPA does not carry qoder/<id> (ADR 0003 keeps
        // Qoder out of its registry).
        let cpaBody = """
        {
          "object": "list",
          "data": [
            {"id": "gpt-4o", "object": "model", "created": 1234567890, "owned_by": "openai"},
            {"id": "claude-3-5-sonnet", "object": "model", "created": 1234567891, "owned_by": "anthropic"}
          ]
        }
        """
        let input = Data(cpaBody.utf8)

        guard let merged = QoderModelsMerger.mergeQoderModels(into: input) else {
            return XCTFail("merge should succeed on a valid CPA body")
        }

        guard let root = try? JSONSerialization.jsonObject(with: merged) as? [String: Any],
              let data = root["data"] as? [[String: Any]] else {
            return XCTFail("merged body must be a JSON object with a data array")
        }

        // Top-level shape preserved.
        XCTAssertEqual(root["object"] as? String, "list")

        // CPA entries come through unchanged (id + owned_by). Key order in the
        // output is not pinned (JSONSerialization may reorder), so we look up
        // entries by id.
        let byID = Dictionary(uniqueKeysWithValues: data.compactMap { entry -> (String, [String: Any])? in
            guard let id = entry["id"] as? String else { return nil }
            return (id, entry)
        })

        // CPA entries preserved.
        XCTAssertEqual(byID["gpt-4o"]?["owned_by"] as? String, "openai")
        XCTAssertEqual(byID["claude-3-5-sonnet"]?["owned_by"] as? String, "anthropic")

        // Total count = CPA + catalog (15).
        XCTAssertEqual(data.count, 2 + QoderModelRegistry.catalogKeys.count)

        // One qoder entry per catalogKey, in order, with the pinned fields.
        let qoderEntries = data.filter { ($0["id"] as? String)?.hasPrefix("qoder/") ?? false }
        XCTAssertEqual(qoderEntries.count, QoderModelRegistry.catalogKeys.count)
        let qoderIDs = qoderEntries.compactMap { $0["id"] as? String }
        XCTAssertEqual(qoderIDs, QoderModelRegistry.catalogKeys.map { "qoder/" + $0 },
                       "qoder entries must appear in catalogKeys order")
        for entry in qoderEntries {
            XCTAssertEqual(entry["object"] as? String, "model")
            XCTAssertEqual(entry["created"] as? Int, QoderModelsMerger.catalogEpoch)
            XCTAssertEqual(entry["owned_by"] as? String, "qoder")
        }
    }

    func testMergeOnEmptyDataReturnsExactlyQoderCatalog() {
        // Empty CPA list — the merge should still produce a valid models-list
        // envelope containing exactly the Qoder catalog.
        let cpaBody = #"{"object":"list","data":[]}"#
        let input = Data(cpaBody.utf8)

        guard let merged = QoderModelsMerger.mergeQoderModels(into: input) else {
            return XCTFail("merge on empty data array should succeed")
        }

        guard let root = try? JSONSerialization.jsonObject(with: merged) as? [String: Any],
              let data = root["data"] as? [[String: Any]] else {
            return XCTFail("merged body must be a JSON object with a data array")
        }

        XCTAssertEqual(root["object"] as? String, "list")
        XCTAssertEqual(data.count, QoderModelRegistry.catalogKeys.count)
        let ids = data.compactMap { $0["id"] as? String }
        XCTAssertEqual(ids, QoderModelRegistry.catalogKeys.map { "qoder/" + $0 })
    }

    func testMergeIsIdempotentWhenQoderEntryAlreadyPresent() {
        // Defense in depth: if CPA's body already carries a qoder/<id> entry
        // (ADR 0003 keeps this from happening, but the dedupe must hold), the
        // merge must NOT emit a duplicate id for that key. Other keys still
        // append normally.
        let cpaBody = """
        {
          "object": "list",
          "data": [
            {"id": "qoder/auto", "object": "model", "created": 1, "owned_by": "someone-else"}
          ]
        }
        """
        let input = Data(cpaBody.utf8)

        guard let merged = QoderModelsMerger.mergeQoderModels(into: input) else {
            return XCTFail("merge should succeed")
        }

        guard let root = try? JSONSerialization.jsonObject(with: merged) as? [String: Any],
              let data = root["data"] as? [[String: Any]] else {
            return XCTFail("merged body must be a JSON object with a data array")
        }

        // Exactly one qoder/auto entry (the pre-existing one) — NOT a duplicate.
        let autoEntries = data.filter { $0["id"] as? String == "qoder/auto" }
        XCTAssertEqual(autoEntries.count, 1)
        // The pre-existing entry is preserved verbatim (we skipped appending
        // ours; we did NOT mutate the existing one).
        XCTAssertEqual(autoEntries.first?["owned_by"] as? String, "someone-else")
        XCTAssertEqual(autoEntries.first?["created"] as? Int, 1)

        // The remaining 14 catalog keys each appear exactly once.
        let expectedAppended = QoderModelRegistry.catalogKeys.filter { $0 != "auto" }.map { "qoder/" + $0 }
        let appendedIDs = data.compactMap { entry -> String? in
            guard let id = entry["id"] as? String, id != "qoder/auto" else { return nil }
            return id
        }
        XCTAssertEqual(appendedIDs, expectedAppended)
        // No duplicate ids anywhere in the output.
        let allIDs = data.compactMap { $0["id"] as? String }
        XCTAssertEqual(Set(allIDs).count, allIDs.count, "no duplicate ids allowed")
    }

    func testMergePreservesUnknownTopLevelFields() {
        // Future-proofing: if CPA adds a top-level field beyond object/data,
        // the merge must preserve it (we mutate only `data`).
        let cpaBody = #"{"object":"list","data":[],"notice":"hello"}"#
        let input = Data(cpaBody.utf8)

        guard let merged = QoderModelsMerger.mergeQoderModels(into: input) else {
            return XCTFail("merge should succeed")
        }

        guard let root = try? JSONSerialization.jsonObject(with: merged) as? [String: Any] else {
            return XCTFail("merged body must be a JSON object")
        }
        XCTAssertEqual(root["object"] as? String, "list")
        XCTAssertEqual(root["notice"] as? String, "hello")
        XCTAssertNotNil(root["data"])
    }

    // MARK: - mergeQoderModels — failure → nil (passthrough)

    func testMergeReturnsNilForUnparseableBody() {
        let input = Data("not json".utf8)
        XCTAssertNil(QoderModelsMerger.mergeQoderModels(into: input))
    }

    func testMergeReturnsNilForNonDictJSON() {
        // A bare JSON array or number is the wrong shape — the OpenAI models
        // list is always a top-level object.
        XCTAssertNil(QoderModelsMerger.mergeQoderModels(into: Data("[1,2,3]".utf8)))
        XCTAssertNil(QoderModelsMerger.mergeQoderModels(into: Data("42".utf8)))
    }

    func testMergeReturnsNilForDictWithoutData() {
        let input = Data(#"{"object":"list"}"#.utf8)
        XCTAssertNil(QoderModelsMerger.mergeQoderModels(into: input))
    }

    func testMergeReturnsNilForDataNotAnArray() {
        // `data` present but wrong-typed — wrong shape.
        let input = Data(#"{"object":"list","data":"not-an-array"}"#.utf8)
        XCTAssertNil(QoderModelsMerger.mergeQoderModels(into: input))
    }

    // MARK: - extractHTTPBody

    func testExtractHTTPBodyContentLengthExactSlice() {
        // Plain Content-Length response — body must be sliced exactly to the
        // declared length, no more, no less.
        let response = """
        HTTP/1.1 200 OK\r
        Content-Type: application/json\r
        Content-Length: 5\r
        \r
        hello
        """
        let data = Data(response.utf8)
        let body = QoderModelsMerger.extractHTTPBody(from: data)
        XCTAssertEqual(body, Data("hello".utf8))
    }

    func testExtractHTTPBodyContentLengthIgnoresTrailingBytes() {
        // If the buffer carries bytes beyond Content-Length (shouldn't happen
        // with Connection: close, but be defensive), only the declared length
        // is returned.
        let response = "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhelloEXTRA"
        let data = Data(response.utf8)
        let body = QoderModelsMerger.extractHTTPBody(from: data)
        XCTAssertEqual(body, Data("hello".utf8))
    }

    func testExtractHTTPBodyContentLengthHeaderCaseInsensitive() {
        // Header names are case-insensitive (RFC 7230 §3.2). CPA sends
        // `Content-Length` but we must also accept `content-length` etc.
        let response = "HTTP/1.1 200 OK\r\ncontent-length: 3\r\n\r\nabc"
        let data = Data(response.utf8)
        let body = QoderModelsMerger.extractHTTPBody(from: data)
        XCTAssertEqual(body, Data("abc".utf8))
    }

    func testExtractHTTPBodyChunkedTwoChunks() {
        // Chunked transfer encoding (RFC 7230 §4.1): hex size, CRLF, data,
        // CRLF, repeat; terminated by a 0-size chunk. Optional trailers follow,
        // ended by a blank line.
        let response = """
        HTTP/1.1 200 OK\r
        Transfer-Encoding: chunked\r
        \r
        5\r
        hello\r
        1\r
        !\r
        0\r
        X-Trailer: value\r
        \r

        """
        let data = Data(response.utf8)
        let body = QoderModelsMerger.extractHTTPBody(from: data)
        // 5-byte "hello" + 1-byte "!" = "hello!"
        XCTAssertEqual(body, Data("hello!".utf8))
    }

    func testExtractHTTPBodyChunkedNoTrailer() {
        // Same as above but the 0-size chunk is immediately followed by the
        // final CRLF (no trailer section). The decoder must accept both.
        let response = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n0\r\n\r\n"
        let data = Data(response.utf8)
        let body = QoderModelsMerger.extractHTTPBody(from: data)
        XCTAssertEqual(body, Data("abc".utf8))
    }

    func testExtractHTTPBodyNoLengthNoChunkedReturnsEverythingAfterHead() {
        // No Content-Length and no chunked: with `Connection: close` (which
        // ProxyBridge forces upstream), RFC 7230 §3.3.3 #7 says the body runs
        // to end-of-connection. CPA always sends Content-Length for /v1/models,
        // but this fallback is the safe behavior if it ever doesn't.
        let response = "HTTP/1.1 200 OK\r\n\r\nplain body to EOF"
        let data = Data(response.utf8)
        let body = QoderModelsMerger.extractHTTPBody(from: data)
        XCTAssertEqual(body, Data("plain body to EOF".utf8))
    }

    func testExtractHTTPBodyReturnsNilForMissingSeparator() {
        // No `\r\n\r\n` — head is malformed/incomplete.
        let response = "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n"
        let data = Data(response.utf8)
        XCTAssertNil(QoderModelsMerger.extractHTTPBody(from: data))
    }

    func testExtractHTTPBodyReturnsNilForIncompleteContentLength() {
        // Declared Content-Length > available body bytes → body is incomplete
        // (connection closed early). Return nil so the caller degrades to
        // raw passthrough instead of shipping a truncated body to the merger.
        let response = "HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\nshort"
        let data = Data(response.utf8)
        XCTAssertNil(QoderModelsMerger.extractHTTPBody(from: data))
    }

    /// Regression (code review, M1): a NEGATIVE Content-Length parses as an Int
    /// but must return nil, not trap in `subdata(in: 0..<(-1))` (Range requires
    /// lowerBound <= upperBound). The function's contract is nil-on-malformed,
    /// never a crash.
    func testExtractHTTPBodyReturnsNilForNegativeContentLength() {
        let response = "HTTP/1.1 200 OK\r\nContent-Length: -1\r\n\r\nbody"
        let data = Data(response.utf8)
        XCTAssertNil(QoderModelsMerger.extractHTTPBody(from: data))
    }

    /// Zero-length body is legal and yields an empty Data.
    func testExtractHTTPBodyZeroContentLengthIsEmpty() {
        let response = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"
        let data = Data(response.utf8)
        XCTAssertEqual(QoderModelsMerger.extractHTTPBody(from: data), Data())
    }

    /// Regression (code review, M2): a chunk size of Int.max must return nil,
    /// not wrap `pos + size` negative past an addition-based guard and trap in
    /// `subdata`. The decoder now guards with subtraction (overflow-proof).
    func testExtractHTTPBodyReturnsNilForChunkSizeOverflow() {
        let response = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n" +
            "1\r\na\r\n7fffffffffffffff\r\n"
        let data = Data(response.utf8)
        XCTAssertNil(QoderModelsMerger.extractHTTPBody(from: data))
    }

    /// Chunk extensions (`;ext=val`) are stripped from the size line per
    /// RFC 7230 §4.1.1.
    func testExtractHTTPBodyChunkedWithChunkExtension() {
        let response = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n" +
            "5;ext=1\r\nhello\r\n0\r\n\r\n"
        let data = Data(response.utf8)
        XCTAssertEqual(
            QoderModelsMerger.extractHTTPBody(from: data),
            Data("hello".utf8)
        )
    }

    /// RFC 7230 §3.3.3: when both Transfer-Encoding: chunked and Content-Length
    /// are present, chunked wins.
    func testExtractHTTPBodyChunkedWinsOverContentLength() {
        let response = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nContent-Length: 99\r\n\r\n" +
            "3\r\nabc\r\n0\r\n\r\n"
        let data = Data(response.utf8)
        XCTAssertEqual(
            QoderModelsMerger.extractHTTPBody(from: data),
            Data("abc".utf8)
        )
    }

    func testExtractHTTPBodyReturnsNilForMalformedChunkSize() {
        // A chunk-size line that isn't valid hex is a framing error.
        let response = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nzzz\r\nabc\r\n0\r\n\r\n"
        let data = Data(response.utf8)
        XCTAssertNil(QoderModelsMerger.extractHTTPBody(from: data))
    }

    func testExtractHTTPBodyReturnsNilForChunkedMissingTerminator() {
        // Chunks present but no 0-size terminator → malformed stream. Return
        // nil so the caller degrades to raw passthrough.
        let response = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n"
        let data = Data(response.utf8)
        XCTAssertNil(QoderModelsMerger.extractHTTPBody(from: data))
    }

    // MARK: - constants

    func testNamespacePrefixAndOwnedBy() {
        // Pin the public constants — they drive the merged entry shape and
        // must match the request-side prefix (QoderRouteGate.qoderPrefix).
        XCTAssertEqual(QoderModelsMerger.namespacePrefix, "qoder/")
        XCTAssertEqual(QoderModelsMerger.ownedBy, "qoder")
    }
}
