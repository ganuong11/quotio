//
//  QoderResponsesAdapterTests.swift
//  QuotioTests
//
//  Tests for the output translator on the Responses API path (issue #11 Task A).
//  `QoderResponsesAdapter` consumes the OpenAI Chat Completions SSE chunks that
//  `QoderSSEReparser` emits and re-encodes them as Responses API streaming
//  events. The adapter is a pure value type, so these tests feed it constructed
//  Chat chunks (no Qoder envelope — the adapter consumes reparser output, same
//  seam `QoderCompletionAggregator` uses) and parse the emitted Responses events
//  back to assert the event sequence.
//

import XCTest
@testable import Quotio

final class QoderResponsesAdapterTests: XCTestCase {

    // MARK: - Helpers

    /// Build one OpenAI Chat Completions streaming chunk wrapped in an SSE
    /// `data:` frame. Mirrors what `QoderSSEReparser.emitChunk` produces, so
    /// the adapter sees the same bytes ProxyBridge would feed it (post-reparser,
    /// pre-adapter — there is no Qoder envelope at this seam).
    private func chatChunk(_ inner: [String: Any]) -> Data {
        let json = try! JSONSerialization.data(withJSONObject: inner)
        return Data("data: ".utf8) + json + Data("\n\n".utf8)
    }

    /// Build a content-delta Chat chunk.
    private func contentDelta(_ text: String, id: String = "resp_1", model: String = "qoder/x", created: Int = 1700) -> [String: Any] {
        [
            "id": id,
            "object": "chat.completion.chunk",
            "created": created,
            "model": model,
            "choices": [["index": 0, "delta": ["content": text]]],
        ]
    }

    /// Build a reasoning-delta Chat chunk.
    private func reasoningDelta(_ text: String) -> [String: Any] {
        [
            "id": "resp_1",
            "object": "chat.completion.chunk",
            "created": 1700,
            "model": "qoder/x",
            "choices": [["index": 0, "delta": ["reasoning_content": text]]],
        ]
    }

    /// Build a tool-call-delta Chat chunk.
    private func toolCallDelta(index: Int, id: String? = nil, name: String? = nil, arguments: String) -> [String: Any] {
        var tc: [String: Any] = ["index": index]
        if let id { tc["id"] = id }
        if let name {
            tc["type"] = "function"
            tc["function"] = ["name": name]
        } else {
            tc["function"] = ["arguments": arguments]
        }
        // For the opener (name set), carry name + an initial (possibly empty)
        // argument fragment so the adapter sees both fields.
        if let name {
            var fn = (tc["function"] as? [String: Any]) ?? [:]
            fn["arguments"] = arguments
            tc["function"] = fn
        }
        return [
            "id": "resp_1",
            "object": "chat.completion.chunk",
            "created": 1700,
            "model": "qoder/x",
            "choices": [["index": 0, "delta": ["tool_calls": [tc]]]],
        ]
    }

    /// Parse a Responses SSE byte stream back into (type, payload) tuples.
    /// Each Responses event is a two-line frame (`event: <type>\n` +
    /// `data: {<payload>}\n\n`); this helper splits frames on `\n\n` and pairs
    /// each `event:` line with its `data:` line.
    private func responsesEvents(_ data: Data) -> [(type: String, payload: [String: Any])] {
        var events: [(String, [String: Any])] = []
        let text = String(data: data, encoding: .utf8) ?? ""
        for frame in text.components(separatedBy: "\n\n") {
            var type: String?
            var payload: [String: Any]?
            for rawLine in frame.split(separator: "\n", omittingEmptySubsequences: false) {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("event: ") {
                    type = String(line.dropFirst("event: ".count))
                } else if line.hasPrefix("data: ") {
                    let s = String(line.dropFirst("data: ".count))
                    if let d = s.data(using: .utf8),
                       let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                        payload = obj
                    }
                }
            }
            if let type, let payload {
                events.append((type, payload))
            }
        }
        return events
    }

    // MARK: - Content deltas

    /// One content chunk fires the lazy opener (created/in_progress/
    /// output_item.added/content_part.added) and then one output_text.delta.
    func testContentDeltaEmitsCreatedInProgressAddedThenDelta() throws {
        var adapter = QoderResponsesAdapter()
        let out = try adapter.ingest(chatChunk(contentDelta("hi")))
        let events = responsesEvents(out)

        let types = events.map(\.type)
        XCTAssertEqual(types, [
            "response.created",
            "response.in_progress",
            "response.output_item.added",
            "response.content_part.added",
            "response.output_text.delta",
        ])
        // The output_text.delta carries the text.
        let deltaPayload = events.last!.payload
        XCTAssertEqual(deltaPayload["delta"] as? String, "hi")
        XCTAssertEqual(deltaPayload["type"] as? String, "response.output_text.delta")
    }

    /// Two content chunks reuse the opener — it fires exactly once, then two
    /// output_text.delta events.
    func testMultipleContentDeltasReuseOpener() throws {
        var adapter = QoderResponsesAdapter()
        var out = try adapter.ingest(chatChunk(contentDelta("Hel")))
        out.append(try adapter.ingest(chatChunk(contentDelta("lo"))))
        let events = responsesEvents(out)

        let createdCount = events.filter { $0.type == "response.created" }.count
        XCTAssertEqual(createdCount, 1)
        let deltaCount = events.filter { $0.type == "response.output_text.delta" }.count
        XCTAssertEqual(deltaCount, 2)
    }

    // MARK: - Reasoning deltas

    /// A reasoning delta emits response.reasoning_summary_text.delta. The full
    /// reasoning item lifecycle is out of scope (follow-up); only the summary
    /// text delta streams.
    func testReasoningDeltaEmitsSummaryTextDelta() throws {
        var adapter = QoderResponsesAdapter()
        let out = try adapter.ingest(chatChunk(reasoningDelta("thinking...")))
        let events = responsesEvents(out)

        // The opener (message-item) must NOT fire on reasoning — reasoning
        // rides a separate item lifecycle in Responses.
        XCTAssertFalse(events.contains { $0.type == "response.created" })
        let deltas = events.filter { $0.type == "response.reasoning_summary_text.delta" }
        XCTAssertEqual(deltas.count, 1)
        XCTAssertEqual(deltas[0].payload["delta"] as? String, "thinking...")
    }

    // MARK: - Tool-call deltas

    /// A tool-call delta emits response.output_item.added (function_call item)
    /// on first sight, then response.function_call_arguments.delta.
    func testToolCallDeltaEmitsFunctionCallArgumentsDelta() throws {
        var adapter = QoderResponsesAdapter()
        var out = try adapter.ingest(chatChunk(toolCallDelta(
            index: 0, id: "call_1", name: "get_weather", arguments: "{\"loc\":\""
        )))
        out.append(try adapter.ingest(chatChunk(toolCallDelta(
            index: 0, arguments: "SF\"}"
        ))))
        let events = responsesEvents(out)

        // First sight of index 0 → output_item.added for a function_call item.
        let added = events.filter { $0.type == "response.output_item.added" }
        XCTAssertEqual(added.count, 1)
        let item = added[0].payload["item"] as? [String: Any]
        XCTAssertEqual(item?["type"] as? String, "function_call")
        XCTAssertEqual(item?["status"] as? String, "in_progress")
        XCTAssertEqual(item?["call_id"] as? String, "call_1")
        XCTAssertEqual(item?["name"] as? String, "get_weather")

        // Two argument deltas (opener + fragment) → two
        // function_call_arguments.delta events.
        let argDeltas = events.filter { $0.type == "response.function_call_arguments.delta" }
        XCTAssertEqual(argDeltas.count, 2)
        let combined = argDeltas.compactMap { $0.payload["delta"] as? String }.joined()
        XCTAssertEqual(combined, "{\"loc\":\"SF\"}")
    }

    // MARK: - finish()

    /// Content chunk then finish() emits the terminal trio
    /// (output_text.done, output_item.done, response.completed) and the
    /// completed Response object carries the accumulated text.
    func testFinishEmitsTerminalsAndCompleted() throws {
        var adapter = QoderResponsesAdapter()
        _ = try adapter.ingest(chatChunk(contentDelta("Hel")))
        _ = try adapter.ingest(chatChunk(contentDelta("lo")))
        let out = try adapter.finish()
        let events = responsesEvents(out)

        let types = events.map(\.type)
        XCTAssertEqual(types, [
            "response.output_text.done",
            "response.content_part.done",
            "response.output_item.done",
            "response.completed",
        ])

        // output_text.done carries the accumulated text.
        let textDone = events[0].payload
        XCTAssertEqual(textDone["text"] as? String, "Hello")

        // The completed Response object's output[0].content[0].text equals the
        // accumulated content.
        let completed = events.last!.payload
        let response = try XCTUnwrap(completed["response"] as? [String: Any])
        XCTAssertEqual(response["status"] as? String, "completed")
        let output = try XCTUnwrap(response["output"] as? [Any])
        XCTAssertEqual(output.count, 1)
        let item = try XCTUnwrap(output[0] as? [String: Any])
        XCTAssertEqual(item["type"] as? String, "message")
        let content = try XCTUnwrap(item["content"] as? [Any])
        let part = try XCTUnwrap(content[0] as? [String: Any])
        XCTAssertEqual(part["text"] as? String, "Hello")
    }

    /// Across the full feed+finish sequence, sequence_number strictly
    /// increases by 1.
    func testSequenceNumbersMonotonic() throws {
        var adapter = QoderResponsesAdapter()
        var out = try adapter.ingest(chatChunk(contentDelta("a")))
        out.append(try adapter.ingest(chatChunk(contentDelta("b"))))
        out.append(try adapter.finish())
        let events = responsesEvents(out)

        let seqs = events.compactMap { $0.payload["sequence_number"] as? Int }
        // Strictly increasing by 1 starting from 1.
        XCTAssertEqual(seqs.first, 1)
        for i in 1..<seqs.count {
            XCTAssertEqual(seqs[i] - seqs[i - 1], 1, "sequence_number not strictly +1 at index \(i)")
        }
    }

    /// A chunk carrying top-level `usage` maps to response.completed's
    /// `response.usage` with prompt_tokens→input_tokens,
    /// completion_tokens→output_tokens (Responses vocabulary).
    func testUsageMapsToCompleted() throws {
        var adapter = QoderResponsesAdapter()
        _ = try adapter.ingest(chatChunk(contentDelta("hi")))
        let usageChunk: [String: Any] = [
            "id": "resp_1",
            "object": "chat.completion.chunk",
            "created": 1700,
            "model": "qoder/x",
            "choices": [],
            "usage": [
                "prompt_tokens": 5,
                "completion_tokens": 7,
                "total_tokens": 12,
            ],
        ]
        _ = try adapter.ingest(chatChunk(usageChunk))
        let out = try adapter.finish()
        let events = responsesEvents(out)

        let completed = events.first { $0.type == "response.completed" }
        let response = completed?.payload["response"] as? [String: Any]
        let usage = response?["usage"] as? [String: Any]
        XCTAssertEqual(usage?["input_tokens"] as? Int, 5)
        XCTAssertEqual(usage?["output_tokens"] as? Int, 7)
        XCTAssertEqual(usage?["total_tokens"] as? Int, 12)
    }
}
