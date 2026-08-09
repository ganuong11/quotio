//
//  QoderCompletionAggregatorTests.swift
//  QuotioTests
//
//  Tests for the non-streaming aggregation path (issue #9).
//  `QoderCompletionAggregator` consumes the OpenAI-shape SSE chunks that
//  `QoderSSEReparser` emits and folds them into a single
//  `chat.completion` JSON object. The aggregator is a pure value type, so
//  these tests feed it constructed SSE frames directly — no I/O, no actor.
//

import XCTest
@testable import Quotio

final class QoderCompletionAggregatorTests: XCTestCase {

    // MARK: - Helpers

    /// Build one OpenAI streaming chunk (`chat.completion.chunk`) wrapped in an
    /// SSE `data:` frame. Mirrors what `QoderSSEReparser.emitChunk` produces,
    /// so the aggregator sees the same bytes ProxyBridge would feed it.
    private func sseFrame(_ chunk: [String: Any]) -> Data {
        let json = try! JSONSerialization.data(withJSONObject: chunk)
        return Data("data: ".utf8) + json + Data("\n\n".utf8)
    }

    /// Build a `chat.completion.chunk` content delta.
    private func contentChunk(_ text: String, id: String = "chatcmpl-x", model: String = "auto", created: Int = 1700) -> [String: Any] {
        [
            "id": id,
            "object": "chat.completion.chunk",
            "created": created,
            "model": model,
            "choices": [["index": 0, "delta": ["content": text]]],
        ]
    }

    /// Build a finish chunk (no delta).
    private func finishChunk(_ reason: String) -> [String: Any] {
        [
            "id": "chatcmpl-x",
            "object": "chat.completion.chunk",
            "created": 1700,
            "model": "auto",
            "choices": [["index": 0, "finish_reason": reason]],
        ]
    }

    /// Build a trailing usage-only chunk (empty choices, like the reparser's
    /// `finish()` trailing usage chunk).
    private func usageChunk(_ usage: [String: Any]) -> [String: Any] {
        [
            "id": "chatcmpl-x",
            "object": "chat.completion.chunk",
            "created": 1700,
            "model": "auto",
            "choices": [],
            "usage": usage,
        ]
    }

    // MARK: - Content aggregation

    func testAggregatesSingleContentDelta() throws {
        var agg = QoderCompletionAggregator()
        try agg.ingest(sseFrame(contentChunk("hello")))
        try agg.ingest(sseFrame(finishChunk("stop")))

        let json = agg.completionJSON(requestModel: "qoder/auto")
        XCTAssertEqual(json["object"] as? String, "chat.completion")
        XCTAssertEqual(json["id"] as? String, "chatcmpl-x")
        XCTAssertEqual(json["model"] as? String, "qoder/auto")
        XCTAssertEqual(json["created"] as? Int, 1700)

        let choice = try XCTUnwrap((json["choices"] as? [Any])?.first as? [String: Any])
        XCTAssertEqual(choice["index"] as? Int, 0)
        XCTAssertEqual(choice["finish_reason"] as? String, "stop")
        let message = try XCTUnwrap(choice["message"] as? [String: Any])
        XCTAssertEqual(message["role"] as? String, "assistant")
        XCTAssertEqual(message["content"] as? String, "hello")
    }

    func testConcatenatesContentAcrossFrames() throws {
        var agg = QoderCompletionAggregator()
        // Two SSE frames in one feed call (a single TCP buffer often carries
        // multiple frames — the aggregator must peel them).
        let twoFrames = sseFrame(contentChunk("Hel")) + sseFrame(contentChunk("lo"))
        try agg.ingest(twoFrames)
        try agg.ingest(sseFrame(contentChunk(" world")))
        try agg.ingest(sseFrame(finishChunk("stop")))

        let json = agg.completionJSON(requestModel: "qoder/auto")
        let choice = try XCTUnwrap((json["choices"] as? [Any])?.first as? [String: Any])
        let message = try XCTUnwrap(choice["message"] as? [String: Any])
        XCTAssertEqual(message["content"] as? String, "Hello world")
    }

    // MARK: - finish_reason

    func testDefaultsFinishReasonToStopWhenAbsent() throws {
        var agg = QoderCompletionAggregator()
        try agg.ingest(sseFrame(contentChunk("hi")))
        // No finish chunk at all (upstream truncated). Should default to "stop".
        let json = agg.completionJSON(requestModel: "qoder/auto")
        let choice = try XCTUnwrap((json["choices"] as? [Any])?.first as? [String: Any])
        XCTAssertEqual(choice["finish_reason"] as? String, "stop")
    }

    func testPreservesNonStopFinishReason() throws {
        var agg = QoderCompletionAggregator()
        try agg.ingest(sseFrame(contentChunk("...")))
        try agg.ingest(sseFrame(finishChunk("length")))
        let json = agg.completionJSON(requestModel: "qoder/auto")
        let choice = try XCTUnwrap((json["choices"] as? [Any])?.first as? [String: Any])
        XCTAssertEqual(choice["finish_reason"] as? String, "length")
    }

    // MARK: - Reasoning content (ingested, not surfaced per ADR 0014)

    func testReasoningContentIngestedButOmitted() throws {
        var agg = QoderCompletionAggregator()
        let reasoningChunk: [String: Any] = [
            "id": "chatcmpl-x", "object": "chat.completion.chunk", "created": 1700, "model": "auto",
            "choices": [["index": 0, "delta": ["reasoning_content": "thinking..."]]],
        ]
        try agg.ingest(sseFrame(reasoningChunk))
        try agg.ingest(sseFrame(contentChunk("answer")))
        try agg.ingest(sseFrame(finishChunk("stop")))

        let json = agg.completionJSON(requestModel: "qoder/auto")
        let choice = try XCTUnwrap((json["choices"] as? [Any])?.first as? [String: Any])
        let message = try XCTUnwrap(choice["message"] as? [String: Any])
        // Content present, reasoning absent from the message object.
        XCTAssertEqual(message["content"] as? String, "answer")
        XCTAssertNil(message["reasoning_content"])
    }

    // MARK: - Tool calls

    func testAggregatesToolCallsAcrossFragments() throws {
        var agg = QoderCompletionAggregator()
        // Opening frame: id/type/name ride together.
        let opener: [String: Any] = [
            "id": "chatcmpl-x", "object": "chat.completion.chunk", "created": 1700, "model": "auto",
            "choices": [["index": 0, "delta": ["tool_calls": [[
                "index": 0, "id": "call_1", "type": "function",
                "function": ["name": "get_weather", "arguments": "{\"loc\":\""],
            ]]]]],
        ]
        // Argument fragment.
        let fragment: [String: Any] = [
            "id": "chatcmpl-x", "object": "chat.completion.chunk", "created": 1700, "model": "auto",
            "choices": [["index": 0, "delta": ["tool_calls": [[
                "index": 0, "function": ["arguments": "SF\"}"],
            ]]]]],
        ]
        try agg.ingest(sseFrame(opener))
        try agg.ingest(sseFrame(fragment))
        try agg.ingest(sseFrame(finishChunk("tool_calls")))

        let json = agg.completionJSON(requestModel: "qoder/auto")
        let choice = try XCTUnwrap((json["choices"] as? [Any])?.first as? [String: Any])
        XCTAssertEqual(choice["finish_reason"] as? String, "tool_calls")
        let message = try XCTUnwrap(choice["message"] as? [String: Any])
        let toolCalls = try XCTUnwrap(message["tool_calls"] as? [Any])
        XCTAssertEqual(toolCalls.count, 1)
        let tc = try XCTUnwrap(toolCalls[0] as? [String: Any])
        XCTAssertEqual(tc["id"] as? String, "call_1")
        XCTAssertEqual(tc["type"] as? String, "function")
        let fn = try XCTUnwrap(tc["function"] as? [String: Any])
        XCTAssertEqual(fn["name"] as? String, "get_weather")
        XCTAssertEqual(fn["arguments"] as? String, "{\"loc\":\"SF\"}")
    }

    func testAggregatesMultipleToolCallIndices() throws {
        var agg = QoderCompletionAggregator()
        let a: [String: Any] = [
            "id": "x", "object": "chat.completion.chunk", "created": 1, "model": "m",
            "choices": [["index": 0, "delta": ["tool_calls": [[
                "index": 0, "id": "call_0", "type": "function",
                "function": ["name": "a", "arguments": "1"],
            ]]]]],
        ]
        let b: [String: Any] = [
            "id": "x", "object": "chat.completion.chunk", "created": 1, "model": "m",
            "choices": [["index": 0, "delta": ["tool_calls": [[
                "index": 1, "id": "call_1", "type": "function",
                "function": ["name": "b", "arguments": "2"],
            ]]]]],
        ]
        try agg.ingest(sseFrame(a))
        try agg.ingest(sseFrame(b))
        try agg.ingest(sseFrame(finishChunk("tool_calls")))

        let json = agg.completionJSON(requestModel: "m")
        let choice = try XCTUnwrap((json["choices"] as? [Any])?.first as? [String: Any])
        let message = try XCTUnwrap(choice["message"] as? [String: Any])
        let toolCalls = try XCTUnwrap(message["tool_calls"] as? [Any])
        XCTAssertEqual(toolCalls.count, 2)
        // Tool calls surface in ascending index order (stable regardless of
        // arrival order in the stream).
        let names = toolCalls.compactMap { ($0 as? [String: Any])?["function"] as? [String: Any] }
            .compactMap { $0["name"] as? String }
        XCTAssertEqual(names, ["a", "b"])
    }

    // MARK: - Usage

    func testCapturesUsageFromTrailingChunk() throws {
        var agg = QoderCompletionAggregator()
        try agg.ingest(sseFrame(contentChunk("hi")))
        try agg.ingest(sseFrame(finishChunk("stop")))
        try agg.ingest(sseFrame(usageChunk([
            "prompt_tokens": 10,
            "completion_tokens": 5,
            "total_tokens": 15,
        ])))

        // capturedUsage surfaces for ProxyBridge's RequestMetadata path.
        let captured = agg.capturedUsage
        XCTAssertEqual(captured?["prompt_tokens"] as? Int, 10)
        XCTAssertEqual(captured?["completion_tokens"] as? Int, 5)

        let json = agg.completionJSON(requestModel: "qoder/auto")
        let usage = try XCTUnwrap(json["usage"] as? [String: Any])
        XCTAssertEqual(usage["prompt_tokens"] as? Int, 10)
        XCTAssertEqual(usage["total_tokens"] as? Int, 15)
    }

    // MARK: - Robustness

    func testIgnoresDoneMarkerAndNonDataLines() throws {
        var agg = QoderCompletionAggregator()
        let mixed = Data("event: ping\n\ndata: [DONE]\n\n".utf8)
            + sseFrame(contentChunk("ok"))
            + Data(": keepalive\n\n".utf8)
        try agg.ingest(mixed)
        try agg.ingest(sseFrame(finishChunk("stop")))

        let json = agg.completionJSON(requestModel: "qoder/auto")
        let choice = try XCTUnwrap((json["choices"] as? [Any])?.first as? [String: Any])
        let message = try XCTUnwrap(choice["message"] as? [String: Any])
        XCTAssertEqual(message["content"] as? String, "ok")
    }

    func testHandlesSplitFrameAcrossFeeds() throws {
        // A single `data: {...}\n\n` frame split across two feed calls (TCP
        // segmentation). The aggregator must buffer until the frame boundary.
        var agg = QoderCompletionAggregator()
        let full = sseFrame(contentChunk("split"))
        let mid = full.count / 2
        try agg.ingest(full.prefix(mid))
        try agg.ingest(full.suffix(full.count - mid))
        try agg.ingest(sseFrame(finishChunk("stop")))

        let json = agg.completionJSON(requestModel: "qoder/auto")
        let choice = try XCTUnwrap((json["choices"] as? [Any])?.first as? [String: Any])
        let message = try XCTUnwrap(choice["message"] as? [String: Any])
        XCTAssertEqual(message["content"] as? String, "split")
    }

    func testStampsFirstSeenIdAndModel() throws {
        var agg = QoderCompletionAggregator()
        try agg.ingest(sseFrame(contentChunk("a", id: "chatcmpl-1", model: "auto", created: 99)))
        // Later chunks with different id/model do NOT override (OpenAI: id is
        // stable for a completion).
        try agg.ingest(sseFrame(contentChunk("b", id: "chatcmpl-2", model: "other", created: 100)))
        try agg.ingest(sseFrame(finishChunk("stop")))

        let json = agg.completionJSON(requestModel: "qoder/auto")
        XCTAssertEqual(json["id"] as? String, "chatcmpl-1")
        // `model` in the response reflects the request model (passed in), not
        // the chunk's model field — matching OpenAI's echo-back behavior.
        XCTAssertEqual(json["model"] as? String, "qoder/auto")
        XCTAssertEqual(json["created"] as? Int, 99)
    }

    // MARK: - Responses object (issue #26)

    /// Fold a content stream into the non-streaming Responses object and pin
    /// the full required shape: `id`, `object`, `created_at`, `status`,
    /// `model`, `output` (one message item with an `output_text` part +
    /// `annotations: []`), and the usage mapping to Responses vocabulary.
    func testResponsesObjectBasicShape() throws {
        var agg = QoderCompletionAggregator()
        try agg.ingest(sseFrame(contentChunk("Hello ", id: "chatcmpl-1", created: 1700)))
        try agg.ingest(sseFrame(contentChunk("world", id: "chatcmpl-1", created: 1700)))
        try agg.ingest(sseFrame(finishChunk("stop")))
        try agg.ingest(sseFrame(usageChunk([
            "prompt_tokens": 11, "completion_tokens": 5, "total_tokens": 16,
        ])))

        let resp = agg.responsesObject(requestModel: "qoder/auto")

        XCTAssertEqual(resp["id"] as? String, "chatcmpl-1")
        XCTAssertEqual(resp["object"] as? String, "response")
        XCTAssertEqual(resp["created_at"] as? Int, 1700)
        XCTAssertEqual(resp["status"] as? String, "completed")
        XCTAssertEqual(resp["model"] as? String, "qoder/auto")

        let output = try XCTUnwrap(resp["output"] as? [[String: Any]])
        XCTAssertEqual(output.count, 1)
        let message = output[0]
        XCTAssertEqual(message["id"] as? String, "msg_chatcmpl-1")
        XCTAssertEqual(message["type"] as? String, "message")
        XCTAssertEqual(message["status"] as? String, "completed")
        XCTAssertEqual(message["role"] as? String, "assistant")
        let content = try XCTUnwrap(message["content"] as? [[String: Any]])
        XCTAssertEqual(content.count, 1)
        XCTAssertEqual(content[0]["type"] as? String, "output_text")
        XCTAssertEqual(content[0]["text"] as? String, "Hello world")
        XCTAssertEqual((content[0]["annotations"] as? [Any])?.isEmpty, true)

        // Usage mapped to Responses vocabulary (issue #26 acceptance):
        // prompt_tokens→input_tokens, completion_tokens→output_tokens.
        let usage = try XCTUnwrap(resp["usage"] as? [String: Any])
        XCTAssertEqual(usage["input_tokens"] as? Int, 11)
        XCTAssertEqual(usage["output_tokens"] as? Int, 5)
        XCTAssertEqual(usage["total_tokens"] as? Int, 16)
        XCTAssertNil(usage["prompt_tokens"])
        XCTAssertNil(usage["completion_tokens"])
    }

    /// A pure tool-call stream (no content) has NO message item — matching the
    /// streaming adapter's `response.completed` (message item only when content
    /// streamed). Function_call ids start at `fc_0` when the message item is
    /// absent.
    func testResponsesObjectPureToolCallHasNoMessageItem() throws {
        var agg = QoderCompletionAggregator()
        let opener: [String: Any] = [
            "id": "chatcmpl-t", "object": "chat.completion.chunk", "created": 1700, "model": "auto",
            "choices": [["index": 0, "delta": ["tool_calls": [[
                "index": 0, "id": "call_1", "type": "function",
                "function": ["name": "get_weather", "arguments": "{\"loc\":\"SF\"}"],
            ]]]]],
        ]
        try agg.ingest(sseFrame(opener))
        try agg.ingest(sseFrame(finishChunk("tool_calls")))

        let resp = agg.responsesObject(requestModel: "qoder/auto")
        let output = try XCTUnwrap(resp["output"] as? [[String: Any]])
        XCTAssertEqual(output.count, 1)
        let item = output[0]
        XCTAssertEqual(item["id"] as? String, "fc_0")
        XCTAssertEqual(item["type"] as? String, "function_call")
        XCTAssertEqual(item["status"] as? String, "completed")
        XCTAssertEqual(item["call_id"] as? String, "call_1")
        XCTAssertEqual(item["name"] as? String, "get_weather")
        XCTAssertEqual(item["arguments"] as? String, "{\"loc\":\"SF\"}")
    }

    /// Content + tool calls: the message item precedes the function_call items
    /// and the tool ids shift to the message-occupies-0 layout (`fc_1`,
    /// `fc_2`, ...), matching the streaming adapter's `nextOutputIndexForTool`
    /// allocation (base 1 once the message item exists).
    func testResponsesObjectMessageThenToolCallIdsStartAtOne() throws {
        var agg = QoderCompletionAggregator()
        try agg.ingest(sseFrame(contentChunk("checking…", id: "chatcmpl-m")))
        let a: [String: Any] = [
            "id": "chatcmpl-m", "object": "chat.completion.chunk", "created": 1700, "model": "auto",
            "choices": [["index": 0, "delta": ["tool_calls": [[
                "index": 0, "id": "call_0", "type": "function",
                "function": ["name": "a", "arguments": "1"],
            ]]]]],
        ]
        let b: [String: Any] = [
            "id": "chatcmpl-m", "object": "chat.completion.chunk", "created": 1700, "model": "auto",
            "choices": [["index": 0, "delta": ["tool_calls": [[
                "index": 1, "id": "call_1", "type": "function",
                "function": ["name": "b", "arguments": "2"],
            ]]]]],
        ]
        try agg.ingest(sseFrame(a))
        try agg.ingest(sseFrame(b))
        try agg.ingest(sseFrame(finishChunk("tool_calls")))

        let resp = agg.responsesObject(requestModel: "qoder/auto")
        let output = try XCTUnwrap(resp["output"] as? [[String: Any]])
        XCTAssertEqual(output.count, 3)
        XCTAssertEqual(output[0]["type"] as? String, "message")
        XCTAssertEqual(output[1]["id"] as? String, "fc_1")
        XCTAssertEqual(output[2]["id"] as? String, "fc_2")
        // Ascending Chat-index order regardless of arrival order.
        XCTAssertEqual(output[1]["name"] as? String, "a")
        XCTAssertEqual(output[2]["name"] as? String, "b")
    }

    /// No usage chunk arrived → `usage` is JSON null (matching the streaming
    /// adapter's `response.completed`, which emits null rather than omitting).
    func testResponsesObjectNullUsageWhenAbsent() throws {
        var agg = QoderCompletionAggregator()
        try agg.ingest(sseFrame(contentChunk("hi")))
        try agg.ingest(sseFrame(finishChunk("stop")))

        let resp = agg.responsesObject(requestModel: "qoder/auto")
        XCTAssertTrue(resp["usage"] is NSNull)
    }

    /// No id/created arrived from the stream → fallbacks (`resp_qoder`, now).
    func testResponsesObjectFallbackIdAndCreatedAt() throws {
        var agg = QoderCompletionAggregator()
        // Feed a frame carrying no id/created keys at all.
        let bare: [String: Any] = [
            "object": "chat.completion.chunk",
            "choices": [["index": 0, "delta": ["content": "x"]]],
        ]
        try agg.ingest(sseFrame(bare))
        // Bare finish frame too — `finishChunk` carries id/created and would
        // stamp them, defeating the fallback under test.
        let bareFinish: [String: Any] = [
            "object": "chat.completion.chunk",
            "choices": [["index": 0, "finish_reason": "stop"]],
        ]
        try agg.ingest(sseFrame(bareFinish))

        let resp = agg.responsesObject(requestModel: "qoder/auto")
        XCTAssertEqual(resp["id"] as? String, "resp_qoder")
        // `created_at` falls back to "now"; assert within 2s to avoid a
        // second-boundary race between the fold and the assertion.
        let createdAt = try XCTUnwrap(resp["created_at"] as? Int)
        let now = Int(Date().timeIntervalSince1970.rounded(.down))
        XCTAssertLessThanOrEqual(abs(createdAt - now), 2)
        let message = try XCTUnwrap((resp["output"] as? [[String: Any]])?.first)
        XCTAssertEqual(message["id"] as? String, "msg_resp_qoder")
    }
}
