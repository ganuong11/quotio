//
//  OpencodeResponsesAggregatorTests.swift
//  QuotioTests
//
//  Fixture tests for the responses-native non-streaming fold (ADR 0021):
//  terminal-event capture (the primary strategy) and delta-fold fallback,
//  plus the raw-upstream seam contract the translated streaming arm relies
//  on (`QoderResponsesAdapter` consuming raw chat SSE incl. [DONE]).
//

import Foundation
import XCTest
@testable import QuotioDomain

final class OpencodeResponsesAggregatorTests: XCTestCase {

    private func event(_ type: String, _ payload: [String: Any]) -> Data {
        var frame = "event: \(type)\ndata: ".utf8
        let json = try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return Data(frame) + json + Data("\n\n".utf8)
    }

    // MARK: - Terminal-event capture (primary)

    func testCompletedEventCapturedVerbatimWithModelEcho() {
        var aggregator = OpencodeResponsesAggregator()
        aggregator.ingest(event("response.created", [
            "type": "response.created",
            "response": ["id": "resp_9", "object": "response", "created_at": 1792000000,
                         "model": "muse-spark-1.3-contributor-free", "status": "in_progress"],
        ]))
        aggregator.ingest(event("response.output_text.delta", [
            "type": "response.output_text.delta", "delta": "ignored-when-completed-present",
        ]))
        aggregator.ingest(event("response.completed", [
            "type": "response.completed",
            "response": [
                "id": "resp_9", "object": "response", "status": "completed",
                "created_at": 1792000000, "model": "muse-spark-1.3-contributor-free",
                "output": [["id": "msg_1", "type": "message", "role": "assistant",
                            "content": [["type": "output_text", "text": "hello"]]]],
                "usage": ["input_tokens": 5, "output_tokens": 2, "total_tokens": 7],
            ],
        ]))

        let object = aggregator.responseObject(requestModel: "opencode/muse-spark-1.3-contributor-free")
        // Captured response wins verbatim, except the model echo.
        XCTAssertEqual(object["id"] as? String, "resp_9")
        XCTAssertEqual(object["status"] as? String, "completed")
        XCTAssertEqual(object["model"] as? String, "opencode/muse-spark-1.3-contributor-free")
        XCTAssertEqual((object["usage"] as? [String: Any])?["total_tokens"] as? Int, 7)
        let output = try! XCTUnwrap(object["output"] as? [[String: Any]])
        XCTAssertEqual(output.first?["type"] as? String, "message")
    }

    func testFailedEventCaptured() {
        var aggregator = OpencodeResponsesAggregator()
        aggregator.ingest(event("response.failed", [
            "type": "response.failed",
            "response": ["id": "resp_e", "object": "response", "status": "failed",
                         "error": ["code": "x", "message": "boom"]],
        ]))
        let object = aggregator.responseObject(requestModel: "opencode/m")
        XCTAssertEqual(object["status"] as? String, "failed")
        XCTAssertEqual((object["error"] as? [String: Any])?["message"] as? String, "boom")
    }

    // MARK: - Delta-fold fallback

    func testDeltaFoldWhenNoTerminalArrives() {
        var aggregator = OpencodeResponsesAggregator()
        aggregator.ingest(event("response.created", [
            "type": "response.created",
            "response": ["id": "resp_2", "created_at": 1792000050],
        ]))
        aggregator.ingest(event("response.output_text.delta", ["type": "response.output_text.delta", "delta": "hel"]))
        aggregator.ingest(event("response.output_text.delta", ["type": "response.output_text.delta", "delta": "lo"]))
        aggregator.ingest(event("response.output_item.done", [
            "type": "response.output_item.done",
            "item": ["type": "function_call", "call_id": "call_1", "name": "read",
                     "arguments": #"{"filePath":"/x"}"#],
        ]))

        let object = aggregator.responseObject(requestModel: "opencode/m")
        XCTAssertEqual(object["object"] as? String, "response")
        XCTAssertEqual(object["status"] as? String, "completed")
        XCTAssertEqual(object["usage"] as? NSNull, NSNull())
        let output = try! XCTUnwrap(object["output"] as? [[String: Any]])
        XCTAssertEqual(output.count, 2)
        let message = output[0]
        XCTAssertEqual(message["type"] as? String, "message")
        let content = try! XCTUnwrap(message["content"] as? [[String: Any]])
        XCTAssertEqual(content.first?["text"] as? String, "hello")
        XCTAssertEqual(content.first?["type"] as? String, "output_text")
        let call = output[1]
        XCTAssertEqual(call["type"] as? String, "function_call")
        XCTAssertEqual(call["call_id"] as? String, "call_1")
        XCTAssertEqual(call["name"] as? String, "read")
    }

    func testFramesMaySplitAcrossIngestCalls() {
        var aggregator = OpencodeResponsesAggregator()
        let whole = event("response.completed", [
            "type": "response.completed",
            "response": ["id": "resp_s", "status": "completed", "output": []],
        ])
        // Split mid-JSON — the buffer holds the partial frame until \n\n.
        let split = whole.count / 2
        aggregator.ingest(whole.prefix(split))
        aggregator.ingest(whole.suffix(whole.count - split))
        let object = aggregator.responseObject(requestModel: "opencode/m")
        XCTAssertEqual(object["id"] as? String, "resp_s")
    }

    func testMalformedFramesSkipped() {
        var aggregator = OpencodeResponsesAggregator()
        aggregator.ingest(Data("data: not-json\n\n".utf8))
        aggregator.ingest(Data("data: [DONE]\n\n".utf8))
        let object = aggregator.responseObject(requestModel: "opencode/m")
        XCTAssertEqual(object["status"] as? String, "completed")   // fallback, no crash
    }
}

/// The translated streaming arm (ADR 0021 2a) feeds RAW upstream Chat
/// Completions SSE — including the `data: [DONE]` sentinel the Qoder path's
/// reparser used to consume — straight into `QoderResponsesAdapter`. This
/// pins that seam: the sentinel is skipped and normal chunks translate.
final class OpencodeRawChatSSEAdapterSeamTests: XCTestCase {

    func testAdapterConsumesRawUpstreamChatSSEWithDoneSentinel() throws {
        var adapter = QoderResponsesAdapter(model: "opencode/mimo-x")
        func chunk(_ delta: [String: Any]) -> Data {
            let json = try! JSONSerialization.data(withJSONObject: [
                "id": "chatcmpl-1", "object": "chat.completion.chunk",
                "created": 1792000000, "model": "mimo-v2.6-flash-free",
                "choices": [["index": 0, "delta": delta]],
            ])
            return Data("data: ".utf8) + json + Data("\n\n".utf8)
        }
        var out = try adapter.ingest(chunk(["role": "assistant"]))
        out += try adapter.ingest(chunk(["content": "hi"]))
        out += try adapter.ingest(Data("data: [DONE]\n\n".utf8))   // raw sentinel
        out += try adapter.finish()

        let text = String(data: out, encoding: .utf8) ?? ""
        XCTAssertTrue(text.contains("response.created"), "expected response.created, got: \(text)")
        XCTAssertTrue(text.contains("response.output_text.delta"))
        XCTAssertTrue(text.contains("response.completed"))
        XCTAssertFalse(text.contains("[DONE]"), "chat sentinel must not leak onto the Responses stream")
    }
}
