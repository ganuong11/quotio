//
//  QoderSSEReparserTests.swift
//  QuotioTests
//
//  Phase 2a tests for the Qoder SSE → OpenAI SSE re-parser (ticket #6).
//  The reparser's job is mechanical (Qoder envelope unwrap → OpenAI chunk
//  re-encode), so these tests pin behavior with constructed frames rather than
//  golden vectors captured from a live Qoder stream.
//

import XCTest
@testable import Quotio

final class QoderSSEReparserTests: XCTestCase {

    /// Build a single Qoder envelope SSE line: `data: {outer}\n\n`.
    /// `inner` is the OpenAI-shape body that Qoder wraps as a JSON string.
    private func qoderLine(_ inner: [String: Any], statusCodeValue: Int = 200) -> String {
        let innerData = try! JSONSerialization.data(withJSONObject: inner)
        let innerStr = String(data: innerData, encoding: .utf8)!
        let envelope: [String: Any] = [
            "statusCodeValue": statusCodeValue,
            "body": innerStr,
        ]
        let envelopeData = try! JSONSerialization.data(withJSONObject: envelope)
        return "data: " + String(data: envelopeData, encoding: .utf8)! + "\n\n"
    }

    /// Parse all `data:` lines out of an OpenAI-shape SSE byte stream. Helper
    /// for assertions: returns the JSON object carried by each `data:` line.
    private func openAIChunks(_ data: Data) -> [[String: Any]] {
        var chunks: [[String: Any]] = []
        let text = String(data: data, encoding: .utf8) ?? ""
        for line in text.components(separatedBy: "\n") {
            guard line.hasPrefix("data: ") else { continue }
            let payload = String(line.dropFirst("data: ".count))
            if payload == "[DONE]" { continue }
            if let d = payload.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                chunks.append(obj)
            }
        }
        return chunks
    }

    // MARK: - Content extraction

    /// A content delta in the inner OpenAI-shape chunk is re-emitted as an
    /// OpenAI-shape chunk with the same text.
    func testEmitsContentDelta() throws {
        var reparser = QoderSSEReparser(created: 1)
        let line = qoderLine([
            "id": "chatcmpl-abc",
            "model": "qoder-model-x",
            "choices": [["index": 0, "delta": ["content": "Hello"]]],
        ])
        let out = try reparser.feed(Data(line.utf8))
        let chunks = openAIChunks(out)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0]["id"] as? String, "chatcmpl-abc")
        XCTAssertEqual(chunks[0]["model"] as? String, "qoder-model-x")
        XCTAssertEqual(chunks[0]["object"] as? String, "chat.completion.chunk")
        XCTAssertEqual(chunks[0]["created"] as? Int, 1)
        let choices = try XCTUnwrap(chunks[0]["choices"] as? [[String: Any]])
        XCTAssertEqual(choices[0]["index"] as? Int, 0)
        let delta = try XCTUnwrap(choices[0]["delta"] as? [String: Any])
        XCTAssertEqual(delta["content"] as? String, "Hello")
    }

    /// Multiple content deltas across multiple frames each produce their own
    /// OpenAI chunk. Response ID + model are stamped once and reused.
    func testEmitsMultipleContentDeltas() throws {
        var reparser = QoderSSEReparser()
        let line1 = qoderLine([
            "id": "chatcmpl-x", "model": "m",
            "choices": [["delta": ["content": "Hel"]]],
        ])
        let line2 = qoderLine([
            "choices": [["delta": ["content": "lo"]]],
        ])
        var out = try reparser.feed(Data((line1 + line2).utf8))
        out.append(try reparser.finish())
        let chunks = openAIChunks(out)
        XCTAssertEqual(chunks.count, 2)
        XCTAssertEqual(chunks[0]["id"] as? String, "chatcmpl-x")
        XCTAssertEqual(chunks[1]["id"] as? String, "chatcmpl-x")  // stable ID
        let c0 = (chunks[0]["choices"] as? [[String: Any]])?[0]
        let c1 = (chunks[1]["choices"] as? [[String: Any]])?[0]
        XCTAssertEqual((c0?["delta"] as? [String: Any])?["content"] as? String, "Hel")
        XCTAssertEqual((c1?["delta"] as? [String: Any])?["content"] as? String, "lo")
    }

    /// An empty content delta (role-only opener or usage-only chunk) emits
    /// nothing — no spurious empty chunks.
    func testEmptyContentDeltaEmitsNothing() throws {
        var reparser = QoderSSEReparser()
        let line = qoderLine([
            "id": "x", "model": "m",
            "choices": [["delta": ["role": "assistant"]]],  // no content
        ])
        let out = try reparser.feed(Data(line.utf8))
        XCTAssertTrue(out.isEmpty)
    }

    // MARK: - Frame buffering (partial lines across feeds)

    /// A frame split across two `feed` calls (TCP segment boundary) is
    /// reassembled before parsing — the advisor's "retain partial trailing
    /// lines across feed calls" watch-item.
    func testHandlesFrameSplitAcrossFeeds() throws {
        var reparser = QoderSSEReparser()
        let line = qoderLine([
            "id": "x", "model": "m",
            "choices": [["delta": ["content": "Hello"]]],
        ])
        let bytes = Array(line.utf8)
        let split = bytes.count / 2
        let out1 = try reparser.feed(Data(bytes[0..<split]))
        let out2 = try reparser.feed(Data(bytes[split..<bytes.count]))
        XCTAssertTrue(out1.isEmpty, "first half should buffer, not emit")
        let chunks = openAIChunks(out2)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(((chunks[0]["choices"] as? [[String: Any]])?[0]["delta"] as? [String: Any])?["content"] as? String, "Hello")
    }

    /// `\r\n` line endings are tolerated (SSE spec allows them).
    func testHandlesCRLFLineEndings() throws {
        var reparser = QoderSSEReparser()
        let line = qoderLine([
            "id": "x", "model": "m",
            "choices": [["delta": ["content": "hi"]]],
        ]).replacingOccurrences(of: "\n", with: "\r\n")
        let out = try reparser.feed(Data(line.utf8))
        XCTAssertEqual(openAIChunks(out).count, 1)
    }

    // MARK: - Usage pass-through (ADR 0005 §2)

    /// Usage from the final chunk is emitted as a trailing usage-only chunk
    /// (OpenAI's `stream_options.include_usage` convention), passed through
    /// verbatim — no cached_tokens subtraction.
    func testUsagePassedThroughVerbatim() throws {
        var reparser = QoderSSEReparser()
        let usage: [String: Any] = [
            "prompt_tokens": 100,
            "completion_tokens": 50,
            "total_tokens": 150,
            "prompt_tokens_details": [
                "cached_tokens": 30,         // included in prompt_tokens (OpenAI semantics)
                "cacheable_tokens": 80,
            ] as [String: Any],
            "completion_tokens_details": [
                "reasoning_tokens": 5,
            ] as [String: Any],
        ]
        let line = qoderLine([
            "id": "x", "model": "m",
            "choices": [["delta": [:], "finish_reason": "stop"]],
            "usage": usage,
        ])
        var out = try reparser.feed(Data(line.utf8))
        out.append(try reparser.finish())
        let chunks = openAIChunks(out)
        // finish_reason chunk + usage chunk.
        XCTAssertEqual(chunks.count, 2)
        let usageChunk = chunks[1]
        let u = try XCTUnwrap(usageChunk["usage"] as? [String: Any])
        XCTAssertEqual(u["prompt_tokens"] as? Int, 100)
        XCTAssertEqual(u["completion_tokens"] as? Int, 50)
        XCTAssertEqual(u["total_tokens"] as? Int, 150)
        // cached_tokens preserved untouched (no subtraction).
        let details = try XCTUnwrap(u["prompt_tokens_details"] as? [String: Any])
        XCTAssertEqual(details["cached_tokens"] as? Int, 30)
    }

    // MARK: - Upstream status gate

    /// `statusCodeValue != 200` throws upstreamStatus with a redacted snippet.
    func testNon200StatusThrows() {
        var reparser = QoderSSEReparser()
        let envelope: [String: Any] = [
            "statusCodeValue": 429,
            "body": #"{"error":"rate limited, pt-ABCD1234 leaked"}"#,
        ]
        let envelopeData = try! JSONSerialization.data(withJSONObject: envelope)
        let line = "data: " + String(data: envelopeData, encoding: .utf8)! + "\n\n"
        XCTAssertThrowsError(try reparser.feed(Data(line.utf8))) { error in
            guard case .upstreamStatus(let status, let snippet) = error as? QoderSSEReparserError else {
                return XCTFail("expected .upstreamStatus, got \(error)")
            }
            XCTAssertEqual(status, 429)
            XCTAssertFalse(snippet.contains("pt-ABCD1234"), "token must be redacted: \(snippet)")
            XCTAssertTrue(snippet.contains("pt-REDACTED"))
        }
    }

    // MARK: - Reasoning / tool_calls text-path gates

    /// `delta.reasoning_content` throws — Phase 2b (ticket #8) handles it.
    func testReasoningContentThrows() {
        var reparser = QoderSSEReparser()
        let line = qoderLine([
            "id": "x", "model": "m",
            "choices": [["delta": ["reasoning_content": "thinking..."]]],
        ])
        XCTAssertThrowsError(try reparser.feed(Data(line.utf8))) { error in
            guard case .reasoningContentNotSupported = error as? QoderSSEReparserError else {
                return XCTFail("expected .reasoningContentNotSupported, got \(error)")
            }
        }
    }

    /// `delta.tool_calls` throws — tools were already rejected at the request
    /// boundary; this is defensive.
    func testToolCallsThrow() {
        var reparser = QoderSSEReparser()
        let line = qoderLine([
            "id": "x", "model": "m",
            "choices": [["delta": ["tool_calls": [["index": 0]]]]],
        ])
        XCTAssertThrowsError(try reparser.feed(Data(line.utf8))) { error in
            guard case .toolCallsNotSupported = error as? QoderSSEReparserError else {
                return XCTFail("expected .toolCallsNotSupported, got \(error)")
            }
        }
    }

    // MARK: - finish_reason + [DONE]

    /// finish_reason on its own chunk emits a chunk carrying finish_reason,
    /// then finish() emits the usage chunk (if any) + [DONE].
    func testFinishReasonEmittedAndDone() throws {
        var reparser = QoderSSEReparser()
        let contentLine = qoderLine([
            "id": "x", "model": "m",
            "choices": [["delta": ["content": "done"]]],
        ])
        let finishLine = qoderLine([
            "choices": [["delta": [:], "finish_reason": "stop"]],
        ])
        var out = try reparser.feed(Data((contentLine + finishLine).utf8))
        out.append(try reparser.finish())
        let text = String(data: out, encoding: .utf8) ?? ""
        XCTAssertTrue(text.hasSuffix("data: [DONE]\n\n"))
        let chunks = openAIChunks(out)
        // content + finish_reason.
        XCTAssertEqual(chunks.count, 2)
        let finishChunk = chunks[1]
        let choices = (finishChunk["choices"] as? [[String: Any]])?[0]
        XCTAssertEqual(choices?["finish_reason"] as? String, "stop")
    }

    /// finish() is idempotent — calling it twice emits [DONE] once.
    func testFinishIdempotent() throws {
        var reparser = QoderSSEReparser()
        _ = try reparser.feed(Data(qoderLine([
            "id": "x", "model": "m",
            "choices": [["delta": ["content": "hi"]]],
        ]).utf8))
        let first = try reparser.finish()
        let second = try reparser.finish()
        XCTAssertFalse(first.isEmpty, "first finish() should emit the terminal [DONE]")
        XCTAssertTrue(second.isEmpty, "second finish() should emit nothing")
    }

    // MARK: - Robustness

    /// A non-`data:` line (SSE comment, event line) is ignored, not fatal.
    func testIgnoresNonDataLines() throws {
        var reparser = QoderSSEReparser()
        let cleanLine = qoderLine([
            "id": "x", "model": "m",
            "choices": [["delta": ["content": "ok"]]],
        ])
        let raw = ": comment\n\nevent: ping\n\n" + cleanLine
        let out = try reparser.feed(Data(raw.utf8))
        let chunks = openAIChunks(out)
        XCTAssertEqual(chunks.count, 1)
    }

    /// A malformed `data:` line is skipped (pi parity), not fatal.
    func testSkipsMalformedDataLine() throws {
        var reparser = QoderSSEReparser()
        let bad = "data: {not json}\n\n"
        let good = qoderLine([
            "id": "x", "model": "m",
            "choices": [["delta": ["content": "ok"]]],
        ])
        let out = try reparser.feed(Data((bad + good).utf8))
        let chunks = openAIChunks(out)
        XCTAssertEqual(chunks.count, 1, "malformed line should be skipped, not fatal")
    }

    /// Upstream `[DONE]` in an inner body is ignored; finish() owns the
    /// terminal [DONE] (advisor watch-item: don't double-emit).
    func testInnerDoneIgnored() throws {
        var reparser = QoderSSEReparser()
        let envelope: [String: Any] = ["statusCodeValue": 200, "body": "[DONE]"]
        let envelopeData = try! JSONSerialization.data(withJSONObject: envelope)
        let line = "data: " + String(data: envelopeData, encoding: .utf8)! + "\n\n"
        let out1 = try reparser.feed(Data(line.utf8))
        XCTAssertTrue(out1.isEmpty)
        let out2 = try reparser.finish()
        let text = String(data: out2, encoding: .utf8) ?? ""
        XCTAssertEqual(text, "data: [DONE]\n\n", "exactly one terminal [DONE]")
    }
}
