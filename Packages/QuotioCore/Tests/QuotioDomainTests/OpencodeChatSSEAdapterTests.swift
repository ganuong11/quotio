//
//  OpencodeChatSSEAdapterTests.swift
//  QuotioTests
//
//  Fixture tests for the ADR 0021 Phase 2b stream translator
//  (`OpencodeChatSSEAdapter`): Responses SSE events → Chat Completions
//  chunks. Mirrors QoderResponsesAdapterTests' seam (feed `data:` frames,
//  peel emitted `data:` frames), including TCP-split ingestion.
//

import Foundation
import XCTest
@testable import QuotioDomain

final class OpencodeChatSSEAdapterTests: XCTestCase {

    /// Feed each event string as one SSE frame; return parsed emitted chunks.
    private func run(_ events: [String], model: String = "opencode/muse-spark-1.3-contributor-free") throws -> [[String: Any]] {
        var adapter = OpencodeChatSSEAdapter(model: model)
        var bytes = Data()
        for event in events {
            bytes.append(Data("event: x\ndata: \(event)\n\n".utf8))
        }
        let out = try adapter.ingest(bytes)
        return try Self.parseChunks(out)
    }

    /// Peel `data: {...}` frames from emitted bytes into parsed JSON objects.
    private static func parseChunks(_ data: Data) throws -> [[String: Any]] {
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        return text.split(separator: "\n\n").compactMap { frame in
            for line in frame.split(separator: "\n") {
                guard line.hasPrefix("data: ") else { continue }
                let payload = String(line.dropFirst("data: ".count))
                if payload == "[DONE]" { continue }
                if let lineData = payload.data(using: .utf8) {
                    return try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
                }
            }
            return nil
        }
    }

    private func choices(_ chunk: [String: Any]) throws -> [[String: Any]] {
        try XCTUnwrap(chunk["choices"] as? [[String: Any]])
    }

    // MARK: - Content

    func testCreatedAndTextDeltaEmitChatChunks() throws {
        let chunks = try run([
            #"{"type":"response.created","response":{"id":"resp_1","created_at":756000000}}"#,
            #"{"type":"response.output_text.delta","delta":"hel"}"#,
            #"{"type":"response.output_text.delta","delta":"lo"}"#,
        ])
        XCTAssertEqual(chunks.count, 3)

        // Opener carries the assistant role (ADR 0011 chunk template).
        let opener = chunks[0]
        XCTAssertEqual(opener["object"] as? String, "chat.completion.chunk")
        XCTAssertEqual(opener["id"] as? String, "chatcmpl-resp_1")
        XCTAssertEqual(opener["created"] as? Int, 756000000)
        XCTAssertEqual(opener["model"] as? String, "opencode/muse-spark-1.3-contributor-free")
        let openerDelta = try XCTUnwrap((try choices(opener)[0])["delta"] as? [String: Any])
        XCTAssertEqual(openerDelta["role"] as? String, "assistant")

        // Content deltas carry delta.content; id stays stable across chunks.
        for chunk in chunks.dropFirst(0) {
            XCTAssertEqual(chunk["id"] as? String, "chatcmpl-resp_1")
            XCTAssertEqual(chunk["object"] as? String, "chat.completion.chunk")
        }
        let d1 = try XCTUnwrap((try choices(chunks[1])[0])["delta"] as? [String: Any])
        XCTAssertEqual(d1["content"] as? String, "hel")
        let d2 = try XCTUnwrap((try choices(chunks[2])[0])["delta"] as? [String: Any])
        XCTAssertEqual(d2["content"] as? String, "lo")
    }

    func testReasoningSummaryDeltaBecomesReasoningContent() throws {
        // The repo's established chat-dialect for reasoning is
        // `delta.reasoning_content` (QoderThinkingTagParser mapping) — not
        // think tags in content.
        let chunks = try run([
            #"{"type":"response.created","response":{"id":"resp_1","created_at":756000000}}"#,
            #"{"type":"response.reasoning_summary_text.delta","delta":"thinking..."}"#,
            #"{"type":"response.reasoning_text.delta","delta":" deeply"}"#,
        ])
        let reasoning1 = try XCTUnwrap((try choices(chunks[1])[0])["delta"] as? [String: Any])
        XCTAssertEqual(reasoning1["reasoning_content"] as? String, "thinking...")
        XCTAssertNil(reasoning1["content"])
        let reasoning2 = try XCTUnwrap((try choices(chunks[2])[0])["delta"] as? [String: Any])
        XCTAssertEqual(reasoning2["reasoning_content"] as? String, " deeply")
    }

    // MARK: - Tool calls

    func testFunctionCallItemDoneBecomesToolCallsDelta() throws {
        let chunks = try run([
            #"{"type":"response.created","response":{"id":"resp_1","created_at":756000000}}"#,
            #"{"type":"response.output_item.done","item":{"type":"function_call","id":"fc_0","call_id":"call_9","name":"read","arguments":"{\"filePath\":\"/x\"}"}}"#,
        ])
        let toolChunk = chunks.last!
        let delta = try XCTUnwrap((try choices(toolChunk)[0])["delta"] as? [String: Any])
        let calls = try XCTUnwrap(delta["tool_calls"] as? [[String: Any]])
        XCTAssertEqual(calls[0]["index"] as? Int, 0)
        XCTAssertEqual(calls[0]["id"] as? String, "call_9")
        XCTAssertEqual(calls[0]["type"] as? String, "function")
        let fn = try XCTUnwrap(calls[0]["function"] as? [String: Any])
        XCTAssertEqual(fn["name"] as? String, "read")
        XCTAssertEqual(fn["arguments"] as? String, #"{"filePath":"/x"}"#)
    }

    // MARK: - Terminals

    func testCompletedEmitsFinishUsageAndDone() throws {
        var adapter = OpencodeChatSSEAdapter(model: "m")
        var out = try adapter.ingest(Data(
            ("event: x\ndata: " + #"{"type":"response.created","response":{"id":"resp_1","created_at":756000000}}"# + "\n\n"
                + "event: x\ndata: " + #"{"type":"response.output_text.delta","delta":"hi"}"# + "\n\n"
                + "event: x\ndata: "
                + #"{"type":"response.completed","response":{"id":"resp_1","usage":{"input_tokens":7,"output_tokens":3,"total_tokens":10}}}"#
                + "\n\n").utf8))

        // Terminal already emitted everything — finish() is idempotent empty.
        let finished = try adapter.finish()
        XCTAssertTrue(finished.isEmpty)
        out.append(finished)

        let text = try XCTUnwrap(String(data: out, encoding: .utf8))
        XCTAssertTrue(text.hasSuffix("data: [DONE]\n\n"), "chat stream must end with [DONE]")

        let chunks = try Self.parseChunks(out)
        let finishChunk = try XCTUnwrap(chunks.last { c in
            !((c["choices"] as? [[String: Any]])?.isEmpty ?? true)
        })
        let choice = try choices(finishChunk)[0]
        XCTAssertEqual(choice["finish_reason"] as? String, "stop")
        // Usage is reverse-mapped to the chat vocabulary and rides its own
        // choices:[] chunk (OpenAI include_usage convention).
        let usageChunk = try XCTUnwrap(chunks.last { c in
            ((c["choices"] as? [[String: Any]])?.isEmpty ?? false) && c["usage"] != nil
        })
        let usage = try XCTUnwrap(usageChunk["usage"] as? [String: Any])
        XCTAssertEqual(usage["prompt_tokens"] as? Int, 7)
        XCTAssertEqual(usage["completion_tokens"] as? Int, 3)
        XCTAssertEqual(usage["total_tokens"] as? Int, 10)
    }

    func testCompletedAfterToolCallsFinishesWithToolCallsReason() throws {
        let chunks = try run([
            #"{"type":"response.created","response":{"id":"resp_1","created_at":756000000}}"#,
            #"{"type":"response.output_item.done","item":{"type":"function_call","call_id":"call_9","name":"read","arguments":"{}"}}"#,
            #"{"type":"response.completed","response":{"id":"resp_1","usage":null}}"#,
        ])
        let finishChunk = try XCTUnwrap(chunks.last { c in
            !((c["choices"] as? [[String: Any]])?.isEmpty ?? true)
        })
        XCTAssertEqual(try choices(finishChunk)[0]["finish_reason"] as? String, "tool_calls")
    }

    func testIncompleteMaxOutputTokensMapsToLength() throws {
        let chunks = try run([
            #"{"type":"response.created","response":{"id":"resp_1","created_at":756000000}}"#,
            #"{"type":"response.output_text.delta","delta":"hi"}"#,
            #"{"type":"response.incomplete","response":{"id":"resp_1","incomplete_details":{"reason":"max_output_tokens"}}}"#,
        ])
        let finishChunk = try XCTUnwrap(chunks.last { c in
            !((c["choices"] as? [[String: Any]])?.isEmpty ?? true)
        })
        XCTAssertEqual(try choices(finishChunk)[0]["finish_reason"] as? String, "length")
    }

    func testFailedEmitsChatErrorFrameThenDone() throws {
        let chunks = try run([
            #"{"type":"response.created","response":{"id":"resp_1","created_at":756000000}}"#,
            #"{"type":"response.failed","response":{"id":"resp_1","error":{"code":"server_error","message":"upstream blew up"}}}"#,
        ])
        let errorChunk = try XCTUnwrap(chunks.last)
        let error = try XCTUnwrap(errorChunk["error"] as? [String: Any])
        XCTAssertEqual(error["message"] as? String, "upstream blew up")
        // No finish_reason chunk after a failure — the error frame terminates.
        XCTAssertNil(errorChunk["choices"])
    }

    // MARK: - EOF synthesis + segmentation

    func testCleanEOFSynthesizesStopTerminal() throws {
        // ADR 0018 precedent: clean EOF without a terminal event synthesizes
        // the `stop` terminal instead of truncating the chat stream.
        var adapter = OpencodeChatSSEAdapter(model: "m")
        _ = try adapter.ingest(Data(
            ("event: x\ndata: " + #"{"type":"response.created","response":{"id":"resp_1","created_at":756000000}}"# + "\n\n"
                + "event: x\ndata: " + #"{"type":"response.output_text.delta","delta":"hi"}"# + "\n\n").utf8))
        let finished = try adapter.finish()
        let text = try XCTUnwrap(String(data: finished, encoding: .utf8))
        XCTAssertTrue(text.hasSuffix("data: [DONE]\n\n"))
        let chunks = try Self.parseChunks(finished)
        let finishChunk = try XCTUnwrap(chunks.last { c in
            !((c["choices"] as? [[String: Any]])?.isEmpty ?? true)
        })
        XCTAssertEqual(try choices(finishChunk)[0]["finish_reason"] as? String, "stop")
    }

    func testFramesSplitAcrossIngestCalls() throws {
        let whole = ("event: x\ndata: "
            + #"{"type":"response.created","response":{"id":"resp_1","created_at":756000000}}"# + "\n\n"
            + "event: x\ndata: " + #"{"type":"response.output_text.delta","delta":"hello"}"# + "\n\n").utf8
        var adapter = OpencodeChatSSEAdapter(model: "m")
        var out = Data()
        for byte in whole {
            out.append(try adapter.ingest(Data([byte])))
        }
        let chunks = try Self.parseChunks(out)
        XCTAssertEqual(chunks.count, 2)
        let content = try XCTUnwrap((try choices(chunks[1])[0])["delta"] as? [String: Any])
        XCTAssertEqual(content["content"] as? String, "hello")
    }

    // MARK: - Transport failure (adapter-owned error frame)

    func testErrorEventIsChatShapedTerminal() throws {
        var adapter = OpencodeChatSSEAdapter(model: "m")
        let frame = adapter.errorEvent(message: "opencode upstream stream ended before completion.")
        let text = try XCTUnwrap(String(data: frame, encoding: .utf8))
        XCTAssertTrue(text.hasSuffix("data: [DONE]\n\n"))
        let chunks = try Self.parseChunks(frame)
        let error = try XCTUnwrap((chunks.last?["error"] as? [String: Any]))
        XCTAssertNotNil(error["message"])
    }

    // MARK: - Aggregation seam (non-streaming fold reuses the chat aggregator)

    func testEmittedChunksFoldThroughQoderAggregator() throws {
        var adapter = OpencodeChatSSEAdapter(model: "m")
        var aggregator = QoderCompletionAggregator()
        let upstream = Data(
            ("event: x\ndata: " + #"{"type":"response.created","response":{"id":"resp_1","created_at":756000000}}"# + "\n\n"
                + "event: x\ndata: " + #"{"type":"response.output_text.delta","delta":"hel"}"# + "\n\n"
                + "event: x\ndata: " + #"{"type":"response.output_text.delta","delta":"lo"}"# + "\n\n"
                + "event: x\ndata: "
                + #"{"type":"response.completed","response":{"id":"resp_1","usage":{"input_tokens":7,"output_tokens":3,"total_tokens":10}}}"#
                + "\n\n").utf8)
        try aggregator.ingest(try adapter.ingest(upstream))
        let json = aggregator.completionJSON(requestModel: "opencode/muse-spark-1.3-contributor-free")
        XCTAssertEqual(json["object"] as? String, "chat.completion")
        XCTAssertEqual(json["model"] as? String, "opencode/muse-spark-1.3-contributor-free")
        let choice = try XCTUnwrap((json["choices"] as? [[String: Any]])?.first)
        XCTAssertEqual((choice["message"] as? [String: Any])?["content"] as? String, "hello")
        XCTAssertEqual(choice["finish_reason"] as? String, "stop")
        let usage = try XCTUnwrap(json["usage"] as? [String: Any])
        XCTAssertEqual(usage["prompt_tokens"] as? Int, 7)
    }

    // MARK: - Failure surfacing (review pass)

    func testFailedStreamMarksAdapterFailedNotCleanCompletion() throws {
        // The non-streaming fold's contract: an upstream-reported failure is
        // a true HTTP error (the bridge checks adapter.failed) — NOT a
        // choices-less error frame folded into an empty-but-200 completion.
        var adapter = OpencodeChatSSEAdapter(model: "m")
        var aggregator = QoderCompletionAggregator()
        let upstream = Data(
            ("event: x\ndata: " + #"{"type":"response.created","response":{"id":"resp_1","created_at":756000000}}"# + "\n\n"
                + "event: x\ndata: " + #"{"type":"response.output_text.delta","delta":"par"}"# + "\n\n"
                + "event: x\ndata: "
                + #"{"type":"response.failed","response":{"id":"resp_1","error":{"code":"server_error","message":"overloaded"}}}"#
                + "\n\n").utf8)
        try aggregator.ingest(try adapter.ingest(upstream))
        XCTAssertTrue(adapter.failed)
        XCTAssertEqual(adapter.failureMessage, "overloaded")
        // What the aggregator alone would (wrongly) fold — documents why the
        // bridge must check the adapter, not just the aggregate:
        let json = aggregator.completionJSON(requestModel: "m")
        XCTAssertEqual(((json["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any])?["content"] as? String, "par")
    }

    func testTopLevelErrorEventIsErrorFrame() throws {
        var adapter = OpencodeChatSSEAdapter(model: "m")
        let out = try adapter.ingest(Data(
            ("event: x\ndata: " + #"{"type":"response.created","response":{"id":"resp_1","created_at":756000000}}"# + "\n\n"
                + "event: x\ndata: " + #"{"type":"error","error":{"code":"rate_limit","message":"slow down"}}"# + "\n\n").utf8))
        XCTAssertTrue(adapter.failed)
        XCTAssertEqual(adapter.failureMessage, "slow down")
        let text = try XCTUnwrap(String(data: out, encoding: .utf8))
        XCTAssertTrue(text.hasSuffix("data: [DONE]\n\n"))
        let chunks = try Self.parseChunks(out)
        let error = try XCTUnwrap((chunks.last?["error"] as? [String: Any]))
        XCTAssertEqual(error["message"] as? String, "slow down")
    }

    func testMultipleFunctionCallsGetDistinctIndices() throws {
        let chunks = try run([
            #"{"type":"response.created","response":{"id":"resp_1","created_at":756000000}}"#,
            #"{"type":"response.output_item.done","item":{"type":"function_call","call_id":"call_a","name":"read","arguments":"{}"}}"#,
            #"{"type":"response.output_item.done","item":{"type":"function_call","call_id":"call_b","name":"grep","arguments":"{}"}}"#,
            #"{"type":"response.completed","response":{"id":"resp_1","usage":null}}"#,
        ])
        let toolChunks = chunks.filter { c in
            !((c["choices"] as? [[String: Any]])?.isEmpty ?? true)
                && ((c["choices"] as? [[String: Any]])?.first?["delta"] as? [String: Any])?["tool_calls"] != nil
        }
        XCTAssertEqual(toolChunks.count, 2)
        let indices = try toolChunks.compactMap { chunk -> Int? in
            let delta = try XCTUnwrap(((try choices(chunk)[0])["delta"] as? [String: Any]))
            let calls = try XCTUnwrap(delta["tool_calls"] as? [[String: Any]])
            return calls[0]["index"] as? Int
        }
        XCTAssertEqual(indices, [0, 1])
    }

    func testFinishIsIdempotentAfterSynthesis() throws {
        var adapter = OpencodeChatSSEAdapter(model: "m")
        _ = try adapter.ingest(Data(
            ("event: x\ndata: " + #"{"type":"response.created","response":{"id":"resp_1","created_at":756000000}}"# + "\n\n").utf8))
        let first = try adapter.finish()
        XCTAssertFalse(first.isEmpty)
        let second = try adapter.finish()
        XCTAssertTrue(second.isEmpty)
    }

    func testSecondTerminalAfterDoneIsDropped() throws {
        // One [DONE] per stream — a duplicated terminal must not emit a
        // second finish sequence (nor may stray deltas follow the sentinel).
        var adapter = OpencodeChatSSEAdapter(model: "m")
        let out = try adapter.ingest(Data(
            ("event: x\ndata: " + #"{"type":"response.created","response":{"id":"resp_1","created_at":756000000}}"# + "\n\n"
                + "event: x\ndata: " + #"{"type":"response.completed","response":{"id":"resp_1","usage":null}}"# + "\n\n"
                + "event: x\ndata: " + #"{"type":"response.completed","response":{"id":"resp_1","usage":null}}"# + "\n\n"
                + "event: x\ndata: " + #"{"type":"response.output_text.delta","delta":"stray"}"# + "\n\n").utf8))
        let text = try XCTUnwrap(String(data: out, encoding: .utf8))
        XCTAssertEqual(text.components(separatedBy: "data: [DONE]").count - 1, 1)
        XCTAssertFalse(text.contains("stray"))
    }
}
