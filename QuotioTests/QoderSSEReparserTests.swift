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
    /// OpenAI-shape chunk with the same text. ADR 0011 §4: a synthesized
    /// `delta.role:"assistant"` opener fires first, so a one-line content feed
    /// produces two chunks (opener + content).
    func testEmitsContentDelta() throws {
        var reparser = QoderSSEReparser(created: 1)
        let line = qoderLine([
            "id": "chatcmpl-abc",
            "model": "qoder-model-x",
            "choices": [["index": 0, "delta": ["content": "Hello"]]],
        ])
        let out = try reparser.feed(Data(line.utf8))
        let chunks = openAIChunks(out)
        // ADR 0011: opener + content = 2 chunks.
        XCTAssertEqual(chunks.count, 2)
        XCTAssertEqual(chunks[0]["id"] as? String, "chatcmpl-abc")
        XCTAssertEqual(chunks[0]["model"] as? String, "qoder-model-x")
        XCTAssertEqual(chunks[0]["object"] as? String, "chat.completion.chunk")
        XCTAssertEqual(chunks[0]["created"] as? Int, 1)
        // chunks[0] is the role opener; chunks[1] carries the content.
        let choices = try XCTUnwrap(chunks[1]["choices"] as? [[String: Any]])
        XCTAssertEqual(choices[0]["index"] as? Int, 0)
        let delta = try XCTUnwrap(choices[0]["delta"] as? [String: Any])
        XCTAssertEqual(delta["content"] as? String, "Hello")
    }

    /// Multiple content deltas across multiple frames each produce their own
    /// OpenAI chunk. Response ID + model are stamped once and reused. ADR 0011
    /// §4: the synthesized role opener fires once on the first content line.
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
        // ADR 0011: opener + "Hel" + "lo" = 3 chunks.
        XCTAssertEqual(chunks.count, 3)
        XCTAssertEqual(chunks[0]["id"] as? String, "chatcmpl-x")
        XCTAssertEqual(chunks[1]["id"] as? String, "chatcmpl-x")  // stable ID
        // chunks[0] = role opener; chunks[1] = "Hel"; chunks[2] = "lo".
        let c1 = (chunks[1]["choices"] as? [[String: Any]])?[0]
        let c2 = (chunks[2]["choices"] as? [[String: Any]])?[0]
        XCTAssertEqual((c1?["delta"] as? [String: Any])?["content"] as? String, "Hel")
        XCTAssertEqual((c2?["delta"] as? [String: Any])?["content"] as? String, "lo")
    }

    /// An empty content delta (role-only opener or usage-only chunk) emits
    /// nothing — no spurious empty chunks.
    ///
    /// ADR 0011 §4: this test still passes unchanged after the role-opener
    /// synthesis. The opener is gated on a content/reasoning/tool payload
    /// (`producedAssistantPayloadThisLine`), and an upstream role-only delta
    /// carries none of those — so `out` stays empty and the opener does NOT
    /// fire. The reparser synthesizes its OWN opener lazily on the first real
    /// payload; it does not echo an upstream role-only delta.
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
    /// lines across feed calls" watch-item. ADR 0011 §4: opener + content = 2.
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
        // ADR 0011: opener + content = 2 chunks.
        XCTAssertEqual(chunks.count, 2)
        // chunks[0] is the role opener; chunks[1] carries the content.
        XCTAssertEqual(((chunks[1]["choices"] as? [[String: Any]])?[0]["delta"] as? [String: Any])?["content"] as? String, "Hello")
    }

    /// `\r\n` line endings are tolerated (SSE spec allows them). ADR 0011 §4:
    /// opener + content = 2 chunks.
    func testHandlesCRLFLineEndings() throws {
        var reparser = QoderSSEReparser()
        let line = qoderLine([
            "id": "x", "model": "m",
            "choices": [["delta": ["content": "hi"]]],
        ]).replacingOccurrences(of: "\n", with: "\r\n")
        let out = try reparser.feed(Data(line.utf8))
        XCTAssertEqual(openAIChunks(out).count, 2)
    }

    // MARK: - Usage pass-through (ADR 0005 §2)

    /// Usage from the final chunk is emitted as a trailing usage-only chunk
    /// (OpenAI's `stream_options.include_usage` convention), passed through
    /// verbatim — no cached_tokens subtraction. Issue #19: the trailing
    /// usage chunk is gated on `include_usage`; this test pins the opt-in
    /// path by constructing the reparser with `includeUsage: true`.
    func testUsagePassedThroughVerbatim() throws {
        var reparser = QoderSSEReparser(includeUsage: true)
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

    // MARK: - Reasoning content (Phase 2b)

    /// `delta.reasoning_content` is stripped of thinking-tag artifacts then
    /// re-emitted as OpenAI `delta.reasoning_content`. ADR 0011 §4: opener +
    /// reasoning = 2 chunks.
    func testReasoningContentEmitted() throws {
        var reparser = QoderSSEReparser(created: 1)
        let line = qoderLine([
            "id": "x", "model": "m",
            "choices": [["delta": ["reasoning_content": "thinking..."]]],
        ])
        let out = try reparser.feed(Data(line.utf8))
        let chunks = openAIChunks(out)
        // ADR 0011: opener + reasoning = 2 chunks.
        XCTAssertEqual(chunks.count, 2)
        // chunks[0] is the role opener; chunks[1] carries reasoning.
        let delta = chunks[1]["choices"] as? [[String: Any]]
        let deltaDict = (delta?[0]["delta"] as? [String: Any])
        XCTAssertEqual(deltaDict?["reasoning_content"] as? String, "thinking...")
        XCTAssertNil(deltaDict?["content"], "reasoning chunk must not carry content")
    }

    /// A literal `<thinking>` opener routed into reasoning_content is stripped
    /// (Qoder's backend sometimes splits a tag pair across reasoning + content
    /// channels — pi strips the artifacts in stream.ts ~354-355). ADR 0011 §4:
    /// opener + reasoning = 2 chunks.
    func testReasoningContentStripsThinkingTags() throws {
        var reparser = QoderSSEReparser(created: 1)
        let line = qoderLine([
            "id": "x", "model": "m",
            "choices": [["delta": ["reasoning_content": "<thinking>real reasoning"]]],
        ])
        let out = try reparser.feed(Data(line.utf8))
        let chunks = openAIChunks(out)
        // ADR 0011: opener + reasoning = 2 chunks.
        XCTAssertEqual(chunks.count, 2)
        let delta = (chunks[1]["choices"] as? [[String: Any]])?[0]["delta"] as? [String: Any]
        XCTAssertEqual(delta?["reasoning_content"] as? String, "real reasoning")
    }

    /// An empty reasoning_content after stripping emits nothing (the artifact
    /// was the whole payload — e.g. a lone `<thinking>` opener).
    func testEmptyReasoningAfterStripEmitsNothing() throws {
        var reparser = QoderSSEReparser(created: 1)
        let line = qoderLine([
            "id": "x", "model": "m",
            "choices": [["delta": ["reasoning_content": "<thinking>"]]],
        ])
        let out = try reparser.feed(Data(line.utf8))
        XCTAssertTrue(openAIChunks(out).isEmpty)
    }

    // MARK: - Content with embedded thinking tags (Phase 2b)

    /// A `<thinking>...</thinking>` pair embedded in `delta.content` splits
    /// into a reasoning delta (the thinking text) and text deltas (the parts
    /// before and after the pair). Cross-checks the thinking parser wiring.
    /// ADR 0011 §4: opener + text + reasoning + text = 4 chunks.
    func testContentWithThinkingTagSplits() throws {
        var reparser = QoderSSEReparser(created: 1)
        let line = qoderLine([
            "id": "x", "model": "m",
            "choices": [["delta": ["content": "before <thinking>mid</thinking> after"]]],
        ])
        let out = try reparser.feed(Data(line.utf8))
        let chunks = openAIChunks(out)
        // ADR 0011: opener + text "before " + reasoning "mid" + text " after" = 4.
        XCTAssertEqual(chunks.count, 4)
        // chunks[0] = role opener. Then: text, reasoning, text.
        let d1 = (chunks[1]["choices"] as? [[String: Any]])?[0]["delta"] as? [String: Any]
        let d2 = (chunks[2]["choices"] as? [[String: Any]])?[0]["delta"] as? [String: Any]
        let d3 = (chunks[3]["choices"] as? [[String: Any]])?[0]["delta"] as? [String: Any]
        XCTAssertEqual(d1?["content"] as? String, "before ")
        XCTAssertEqual(d2?["reasoning_content"] as? String, "mid")
        XCTAssertEqual(d3?["content"] as? String, " after")
    }

    /// A thinking tag split across content deltas (cross-delta buffering)
    /// resolves correctly: the partial opener is held back until the next
    /// chunk completes it.
    func testContentThinkingTagSplitAcrossDeltas() throws {
        var reparser = QoderSSEReparser(created: 1)
        let line1 = qoderLine([
            "id": "x", "model": "m",
            "choices": [["delta": ["content": "Hello <thin"]]],
        ])
        let line2 = qoderLine([
            "choices": [["delta": ["content": "king>part</thinking> world"]]],
        ])
        var out = try reparser.feed(Data(line1.utf8))
        out.append(try reparser.feed(Data(line2.utf8)))
        out.append(try reparser.finish())
        let chunks = openAIChunks(out)
        // Concatenate content + reasoning separately.
        let text = chunks.compactMap { (($0["choices"] as? [[String: Any]])?[0]["delta"] as? [String: Any])?["content"] as? String }.joined()
        let reasoning = chunks.compactMap { (($0["choices"] as? [[String: Any]])?[0]["delta"] as? [String: Any])?["reasoning_content"] as? String }.joined()
        XCTAssertEqual(text, "Hello  world")
        XCTAssertEqual(reasoning, "part")
    }

    // MARK: - Tool calls (Phase 2b)

    /// Helper: build an inner chunk dict with a tool_calls delta.
    private func innerWithToolCalls(_ toolCalls: [[String: Any]]) -> [String: Any] {
        [
            "id": "x", "model": "m",
            "choices": [["delta": ["tool_calls": toolCalls]]],
        ]
    }

    /// A tool_calls delta is re-emitted as OpenAI `delta.tool_calls`, preserving
    /// the index, id, type, and function name. ADR 0011 §4: opener + tool = 2.
    func testToolCallFirstDeltaEmitted() throws {
        var reparser = QoderSSEReparser(created: 1)
        let line = qoderLine(innerWithToolCalls([[
            "index": 0,
            "id": "call_1",
            "type": "function",
            "function": ["name": "get_weather", "arguments": ""],
        ]]))
        let out = try reparser.feed(Data(line.utf8))
        let chunks = openAIChunks(out)
        // ADR 0011: opener + tool = 2 chunks.
        XCTAssertEqual(chunks.count, 2)
        // chunks[0] = role opener; chunks[1] = tool_calls.
        let tcArray = ((chunks[1]["choices"] as? [[String: Any]])?[0]["delta"] as? [String: Any])?["tool_calls"] as? [[String: Any]]
        XCTAssertEqual(tcArray?.count, 1)
        XCTAssertEqual(tcArray?[0]["index"] as? Int, 0)
        XCTAssertEqual(tcArray?[0]["id"] as? String, "call_1")
        XCTAssertEqual(tcArray?[0]["type"] as? String, "function")
        let fn = tcArray?[0]["function"] as? [String: Any]
        XCTAssertEqual(fn?["name"] as? String, "get_weather")
    }

    /// Argument fragments stream across deltas (true OpenAI streaming). Two
    /// deltas with the SAME index but fragmented `function.arguments` produce
    /// two chunks; the agent concatenates them. ADR 0011 §4: opener + tool +
    /// fragment = 3 chunks.
    func testToolCallArgumentsStreamFragmented() throws {
        var reparser = QoderSSEReparser(created: 1)
        let first = qoderLine(innerWithToolCalls([[
            "index": 0, "id": "call_1", "type": "function",
            "function": ["name": "get_weather", "arguments": "{\"city\":"],
        ]]))
        let frag = qoderLine(innerWithToolCalls([[
            "index": 0,
            "function": ["arguments": " \"Paris\"}"],
        ]]))
        var out = try reparser.feed(Data(first.utf8))
        out.append(try reparser.feed(Data(frag.utf8)))
        let chunks = openAIChunks(out)
        // ADR 0011: opener + first tool + fragment = 3 chunks.
        XCTAssertEqual(chunks.count, 3)
        // chunks[0] = opener; chunks[1] = id/type/name + first arg; chunks[2] = sparse fragment.
        let fn1 = (((chunks[1]["choices"] as? [[String: Any]])?[0]["delta"] as? [String: Any])?["tool_calls"] as? [[String: Any]])?[0]["function"] as? [String: Any]
        XCTAssertEqual(fn1?["arguments"] as? String, "{\"city\":")
        // Second tool chunk (chunks[2]) carries only the argument fragment (sparse delta).
        let tc2 = ((chunks[2]["choices"] as? [[String: Any]])?[0]["delta"] as? [String: Any])?["tool_calls"] as? [[String: Any]]
        XCTAssertEqual(tc2?[0]["index"] as? Int, 0)
        let fn2 = tc2?[0]["function"] as? [String: Any]
        XCTAssertEqual(fn2?["arguments"] as? String, " \"Paris\"}")
        XCTAssertNil(tc2?[0]["id"], "second fragment must not repeat id")
    }

    /// Multiple tool-call indices interleave correctly — each index gets its
    /// own id on first sighting. Each entry in the upstream `tool_calls` array
    /// is re-emitted as its own OpenAI chunk (one tool_call per delta). ADR
    /// 0011 §4: opener + tool_a + tool_b = 3 chunks.
    func testMultipleToolCallIndices() throws {
        var reparser = QoderSSEReparser(created: 1)
        let line = qoderLine(innerWithToolCalls([
            ["index": 0, "id": "call_a", "type": "function", "function": ["name": "f1", "arguments": ""]],
            ["index": 1, "id": "call_b", "type": "function", "function": ["name": "f2", "arguments": ""]],
        ]))
        let out = try reparser.feed(Data(line.utf8))
        let chunks = openAIChunks(out)
        // ADR 0011: opener + tool_a + tool_b = 3 chunks.
        XCTAssertEqual(chunks.count, 3)
        // chunks[0] = opener; chunks[1] = tool_a; chunks[2] = tool_b.
        let tc1 = ((chunks[1]["choices"] as? [[String: Any]])?[0]["delta"] as? [String: Any])?["tool_calls"] as? [[String: Any]]
        let tc2 = ((chunks[2]["choices"] as? [[String: Any]])?[0]["delta"] as? [String: Any])?["tool_calls"] as? [[String: Any]]
        XCTAssertEqual(tc1?[0]["id"] as? String, "call_a")
        XCTAssertEqual(tc1?[0]["index"] as? Int, 0)
        XCTAssertEqual(tc2?[0]["id"] as? String, "call_b")
        XCTAssertEqual(tc2?[0]["index"] as? Int, 1)
    }

    /// `index` defaults to 0 when absent (pi: `tc.index ?? 0`). ADR 0011 §4:
    /// opener + tool = 2 chunks; the tool is chunks[1].
    func testToolCallIndexDefaultsToZero() throws {
        var reparser = QoderSSEReparser(created: 1)
        let line = qoderLine(innerWithToolCalls([[
            "id": "call_1", "type": "function",
            "function": ["name": "f", "arguments": ""],
        ]]))
        let out = try reparser.feed(Data(line.utf8))
        // chunks[0] is the role opener; the tool is chunks[1].
        let tcArray = ((openAIChunks(out)[1]["choices"] as? [[String: Any]])?[0]["delta"] as? [String: Any])?["tool_calls"] as? [[String: Any]]
        XCTAssertEqual(tcArray?[0]["index"] as? Int, 0)
    }

    /// Phase 2b: when tool_calls streamed and the upstream sends a generic
    /// `finish_reason: "stop"`, the reparser overrides it to OpenAI's
    /// `"tool_calls"` so the agent knows to execute the calls (pi forces
    /// "toolUse" in stream.ts ~496-498). A meaningful upstream finish_reason
    /// ("length", "content_filter") is preserved. ADR 0011: every choice now
    /// carries a `finish_reason` key (null on non-terminal chunks), so the
    /// find filter must distinguish a real string reason from null.
    func testToolCallsOverrideFinishReasonToToolCalls() throws {
        var reparser = QoderSSEReparser(created: 1)
        let toolLine = qoderLine(innerWithToolCalls([[
            "index": 0, "id": "call_1", "type": "function",
            "function": ["name": "f", "arguments": "{}"],
        ]]))
        // Upstream sends the generic "stop" after tool_calls streamed.
        let stopLine = qoderLine([
            "choices": [["delta": [:], "finish_reason": "stop"]],
        ])
        var out = try reparser.feed(Data(toolLine.utf8))
        out.append(try reparser.feed(Data(stopLine.utf8)))
        let chunks = openAIChunks(out)
        // The finish chunk carries "tool_calls", not "stop". Filter on a real
        // string finish_reason (ADR 0011: other chunks carry NSNull now).
        let finishChunk = chunks.first {
            ($0["choices"] as? [[String: Any]])?[0]["finish_reason"] as? String != nil
        }
        XCTAssertEqual(
            (finishChunk?["choices"] as? [[String: Any]])?[0]["finish_reason"] as? String,
            "tool_calls"
        )
    }

    /// Regression: an upstream `tool_calls` delta that carries `id`/`type`/
    /// `index` but NO `function` object (the first frame of a tool stream —
    /// Qoder sometimes opens with `{"type":"function","index":0}` before the
    /// name/arguments arrive) MUST NOT be re-emitted as-is. OpenAI's streaming
    /// schema requires `choices[].delta.tool_calls[].function` to be an object
    /// whenever the entry is present, so emitting `{"type":"function","index":0}`
    /// makes strict clients (the ZCode agent's zod validator) reject the whole
    /// turn with `invalid_union / function: expected object, received undefined`.
    ///
    /// The id/type are buffered server-side; the first chunk the agent sees for
    /// a tool_call must carry a non-empty `function` (name, arguments, or both).
    /// See `Turn execution failed ... Type validation failed` (qoder/qmodel_38max).
    func testToolCallDeltaWithoutFunctionIsNotEmitted() throws {
        var reparser = QoderSSEReparser(created: 1)
        // First upstream delta: id/type/index only — no function payload yet.
        let headerOnly = qoderLine(innerWithToolCalls([[
            "index": 0, "id": "call_1", "type": "function",
        ]]))
        // Second upstream delta: function.name + arguments fragment.
        let nameAndArgs = qoderLine(innerWithToolCalls([[
            "index": 0,
            "function": ["name": "get_weather", "arguments": "{\"city\":\"Paris\"}"],
        ]]))
        var out = try reparser.feed(Data(headerOnly.utf8))
        out.append(try reparser.feed(Data(nameAndArgs.utf8)))
        let chunks = openAIChunks(out)

        // The first (function-less) delta MUST NOT produce an OpenAI chunk.
        // Find the first chunk that carries a tool_calls delta.
        let toolChunks = chunks.filter {
            (($0["choices"] as? [[String: Any]])?[0]["delta"] as? [String: Any])?["tool_calls"] != nil
        }
        XCTAssertEqual(toolChunks.count, 1, "only the function-bearing delta should be emitted")
        let entry = ((toolChunks[0]["choices"] as? [[String: Any]])?[0]["delta"] as? [String: Any])?["tool_calls"] as? [[String: Any]]
        XCTAssertEqual(entry?.count, 1)
        // The emitted entry MUST carry a non-empty `function` object — the
        // field the zod validator complained was missing.
        let fn = entry?[0]["function"] as? [String: Any]
        XCTAssertNotNil(fn, "emitted tool_call entry must carry a function object")
        XCTAssertFalse((fn ?? [:]).isEmpty, "function object must not be empty")
        // The buffered id/type from the header-only delta ride this chunk.
        XCTAssertEqual(entry?[0]["id"] as? String, "call_1")
        XCTAssertEqual(entry?[0]["type"] as? String, "function")
        XCTAssertEqual(fn?["name"] as? String, "get_weather")
        XCTAssertEqual(fn?["arguments"] as? String, "{\"city\":\"Paris\"}")
    }

    /// Regression companion: the `finish_reason: "tool_calls"` override must
    /// still fire when tool_calls were seen, even if the only emitted chunk
    /// carried the buffered-then-merged payload (i.e. the header-only delta
    /// contributed to `toolCallsState` even though it produced no chunk).
    func testToolCallHeaderOnlyStillDrivesFinishOverride() throws {
        var reparser = QoderSSEReparser(created: 1)
        let headerOnly = qoderLine(innerWithToolCalls([[
            "index": 0, "id": "call_1", "type": "function",
        ]]))
        let args = qoderLine(innerWithToolCalls([[
            "index": 0, "function": ["arguments": "{}"],
        ]]))
        let stop = qoderLine([
            "choices": [["delta": [:], "finish_reason": "stop"]],
        ])
        var out = try reparser.feed(Data(headerOnly.utf8))
        out.append(try reparser.feed(Data(args.utf8)))
        out.append(try reparser.feed(Data(stop.utf8)))
        let chunks = openAIChunks(out)
        let finishChunk = chunks.first { ($0["choices"] as? [[String: Any]])?[0]["finish_reason"] as? String != nil }
        XCTAssertEqual(
            (finishChunk?["choices"] as? [[String: Any]])?[0]["finish_reason"] as? String,
            "tool_calls"
        )
    }

    /// A name-only delta after a suppressed header becomes the opening frame;
    /// the following arguments delta remains sparse and uses the same index.
    /// This mirrors a valid incremental Chat Completions tool-call sequence:
    /// clients concatenate `function.arguments` across emitted chunks.
    func testToolCallNameAndArgumentsArriveInSeparateDeltas() throws {
        var reparser = QoderSSEReparser(created: 1)
        let headerOnly = qoderLine(innerWithToolCalls([[
            "index": 0, "id": "call_1", "type": "function",
        ]]))
        let nameOnly = qoderLine(innerWithToolCalls([[
            "index": 0,
            "function": ["name": "get_weather"],
        ]]))
        let arguments = qoderLine(innerWithToolCalls([[
            "index": 0,
            "function": ["arguments": "{\"city\":\"Paris\"}"],
        ]]))
        let stop = qoderLine([
            "choices": [["delta": [:], "finish_reason": "stop"]],
        ])

        var out = try reparser.feed(Data(headerOnly.utf8))
        out.append(try reparser.feed(Data(nameOnly.utf8)))
        out.append(try reparser.feed(Data(arguments.utf8)))
        out.append(try reparser.feed(Data(stop.utf8)))
        out.append(try reparser.finish())
        let chunks = openAIChunks(out)
        let toolChunks = chunks.filter {
            (($0["choices"] as? [[String: Any]])?[0]["delta"] as? [String: Any])?["tool_calls"] != nil
        }

        // The header-only delta is suppressed for strict downstream clients.
        XCTAssertEqual(toolChunks.count, 2)

        let first = ((toolChunks[0]["choices"] as? [[String: Any]])?[0]["delta"] as? [String: Any])?["tool_calls"] as? [[String: Any]]
        XCTAssertEqual(first?[0]["index"] as? Int, 0)
        XCTAssertEqual(first?[0]["id"] as? String, "call_1")
        XCTAssertEqual(first?[0]["type"] as? String, "function")
        let firstFunction = first?[0]["function"] as? [String: Any]
        XCTAssertEqual(firstFunction?["name"] as? String, "get_weather")
        XCTAssertNil(firstFunction?["arguments"])

        let second = ((toolChunks[1]["choices"] as? [[String: Any]])?[0]["delta"] as? [String: Any])?["tool_calls"] as? [[String: Any]]
        XCTAssertEqual(second?[0]["index"] as? Int, 0)
        XCTAssertNil(second?[0]["id"])
        XCTAssertNil(second?[0]["type"])
        let secondFunction = second?[0]["function"] as? [String: Any]
        XCTAssertEqual(secondFunction?["arguments"] as? String, "{\"city\":\"Paris\"}")

        let finishChunk = chunks.first { ($0["choices"] as? [[String: Any]])?[0]["finish_reason"] as? String != nil }
        XCTAssertEqual(
            (finishChunk?["choices"] as? [[String: Any]])?[0]["finish_reason"] as? String,
            "tool_calls"
        )
        XCTAssertTrue(String(data: out, encoding: .utf8)?.hasSuffix("data: [DONE]\n\n") == true)
    }

    /// A meaningful upstream finish_reason ("length") is preserved even when
    /// tool_calls streamed — only a generic "stop" is overridden.
    func testToolCallsPreserveMeaningfulFinishReason() throws {
        var reparser = QoderSSEReparser(created: 1)
        let toolLine = qoderLine(innerWithToolCalls([[
            "index": 0, "id": "call_1", "type": "function",
            "function": ["name": "f", "arguments": "{}"],
        ]]))
        let lengthLine = qoderLine([
            "choices": [["delta": [:], "finish_reason": "length"]],
        ])
        var out = try reparser.feed(Data(toolLine.utf8))
        out.append(try reparser.feed(Data(lengthLine.utf8)))
        let chunks = openAIChunks(out)
        let finishChunk = chunks.first { ($0["choices"] as? [[String: Any]])?[0]["finish_reason"] as? String != nil }
        XCTAssertEqual(
            (finishChunk?["choices"] as? [[String: Any]])?[0]["finish_reason"] as? String,
            "length"
        )
    }

    /// Regression (pi-provider-qoder PR #14): a tool_calls delta that carries
    /// neither id, name, nor arguments (`{function:{}}`) must NOT trigger the
    /// `finish_reason` override. It populates `toolCallsState` but emits no
    /// chunk the agent can act on; claiming "tool_calls" with nothing to run
    /// dead-ends the turn. The override fires only when a chunk actually
    /// reached the agent (`emittedHeader`).
    func testEmptyToolCallDeltaDoesNotClaimToolUse() throws {
        var reparser = QoderSSEReparser(created: 1)
        let malformed = qoderLine(innerWithToolCalls([[
            "index": 0,
            "function": [:] as [String: Any],
        ]]))
        let stop = qoderLine([
            "choices": [["delta": [:], "finish_reason": "stop"]],
        ])
        var out = try reparser.feed(Data(malformed.utf8))
        out.append(try reparser.feed(Data(stop.utf8)))
        let chunks = openAIChunks(out)
        // No tool_calls chunk should have been emitted.
        let toolChunks = chunks.filter {
            (($0["choices"] as? [[String: Any]])?[0]["delta"] as? [String: Any])?["tool_calls"] != nil
        }
        XCTAssertTrue(toolChunks.isEmpty, "a function-less delta must emit no tool_calls chunk")
        // finish_reason stays "stop" — not overridden to "tool_calls".
        let finishChunk = chunks.first { ($0["choices"] as? [[String: Any]])?[0]["finish_reason"] as? String != nil }
        XCTAssertEqual(
            (finishChunk?["choices"] as? [[String: Any]])?[0]["finish_reason"] as? String,
            "stop",
            "no emitted tool call → finish_reason must stay \"stop\", not \"tool_calls\""
        )
    }

    // MARK: - finish_reason + [DONE]

    /// finish_reason on its own chunk emits a chunk carrying finish_reason,
    /// then finish() emits the usage chunk (if any) + [DONE]. ADR 0011 §4:
    /// opener + content + finish = 3 chunks (was 2).
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
        // ADR 0011: opener + content + finish = 3 chunks (was 2).
        XCTAssertEqual(chunks.count, 3)
        // chunks[2] is the finish chunk (chunks[0] = opener, chunks[1] = content).
        let finishChunk = chunks[2]
        let choices = (finishChunk["choices"] as? [[String: Any]])?[0]
        XCTAssertEqual(choices?["finish_reason"] as? String, "stop")
    }

    /// Issue #18 regression: when one upstream frame carries BOTH
    /// `delta.content` AND `finish_reason` in the same choice, `processLine`
    /// stashes the finish reason (the immediate-emit path is skipped because
    /// `producedContentThisLine` is true) and `finish()` must emit it before
    /// `[DONE]` — else strict OpenAI clients see an unterminated response.
    /// Contract: a content chunk followed by a finish chunk (real reason),
    /// then `[DONE]`.
    ///
    /// ADR 0011 §4: the count grew from 2 → 3 because the role opener now
    /// synthesizes on the first content emission. This is a sanctioned
    /// ADR-0011 update, NOT a #18 regression — the finish chunk still carries
    /// the real `finish_reason` (pinned by `testFinishChunkCarriesDeltaAndFinishReason`).
    /// Chunk layout: chunks[0] = role opener, chunks[1] = content,
    /// chunks[2] = finish.
    func testCombinedContentAndFinishReasonEmittedInFinish() throws {
        var reparser = QoderSSEReparser()
        let line = qoderLine([
            "id": "x", "model": "m",
            "choices": [["delta": ["content": "done"], "finish_reason": "stop"]],
        ])
        var out = try reparser.feed(Data(line.utf8))
        out.append(try reparser.finish())
        let text = String(data: out, encoding: .utf8) ?? ""
        XCTAssertTrue(text.hasSuffix("data: [DONE]\n\n"))
        let chunks = openAIChunks(out)
        // ADR 0011: opener (§4) + content + finish = 3 chunks (was 2 pre-0011).
        XCTAssertEqual(chunks.count, 3)
        // Chunk 0: the synthesized role opener.
        let c0 = (chunks[0]["choices"] as? [[String: Any]])?[0]
        let d0 = c0?["delta"] as? [String: Any]
        XCTAssertEqual(d0?["role"] as? String, "assistant", "ADR 0011 §4: opener fires first")
        // Chunk 1: the content delta.
        let c1 = (chunks[1]["choices"] as? [[String: Any]])?[0]
        let d1 = c1?["delta"] as? [String: Any]
        XCTAssertEqual(d1?["content"] as? String, "done")
        // Chunk 2: the finish chunk carrying the real finish_reason.
        let c2 = (chunks[2]["choices"] as? [[String: Any]])?[0]
        XCTAssertEqual(c2?["finish_reason"] as? String, "stop")
    }

    /// Issue #18 contract lock: a frame with `delta.reasoning_content` AND
    /// `finish_reason` in the same choice still emits the finish reason before
    /// `[DONE]`. This passes BEFORE the fix too (reasoning doesn't set
    /// `producedContentThisLine`, so the immediate-emit path fires and the
    /// stash stays nil) — it pins the contract so a future change to the
    /// reasoning branch can't silently regress combined frames.
    func testCombinedReasoningAndFinishReason() throws {
        var reparser = QoderSSEReparser()
        let line = qoderLine([
            "id": "x", "model": "m",
            "choices": [["delta": ["reasoning_content": "thinking..."], "finish_reason": "stop"]],
        ])
        var out = try reparser.feed(Data(line.utf8))
        out.append(try reparser.finish())
        let chunks = openAIChunks(out)
        let finishChunk = chunks.first { ($0["choices"] as? [[String: Any]])?[0]["finish_reason"] as? String != nil }
        XCTAssertEqual(
            (finishChunk?["choices"] as? [[String: Any]])?[0]["finish_reason"] as? String,
            "stop"
        )
    }

    /// Issue #18 contract lock: a frame with a function-bearing
    /// `delta.tool_calls` AND `finish_reason: "stop"` in the same choice must
    /// surface `finish_reason: "tool_calls"` (the override flips "stop" once
    /// `emittedHeader` is true). Like the reasoning variant, this passes before
    /// AND after the fix (tool_calls don't set `producedContentThisLine`, so
    /// the immediate-emit path fires) — it pins the contract so the tool-call
    /// branch can't silently regress combined frames later.
    func testCombinedToolCallAndFinishReason() throws {
        var reparser = QoderSSEReparser()
        let line = qoderLine([
            "id": "x", "model": "m",
            "choices": [[
                "delta": ["tool_calls": [[
                    "index": 0, "id": "call_1", "type": "function",
                    "function": ["name": "f", "arguments": "{}"],
                ]]],
                "finish_reason": "stop",
            ]],
        ])
        var out = try reparser.feed(Data(line.utf8))
        out.append(try reparser.finish())
        let chunks = openAIChunks(out)
        let finishChunk = chunks.first { ($0["choices"] as? [[String: Any]])?[0]["finish_reason"] as? String != nil }
        XCTAssertEqual(
            (finishChunk?["choices"] as? [[String: Any]])?[0]["finish_reason"] as? String,
            "tool_calls"
        )
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
    /// ADR 0011 §4: opener + content = 2 chunks.
    func testIgnoresNonDataLines() throws {
        var reparser = QoderSSEReparser()
        let cleanLine = qoderLine([
            "id": "x", "model": "m",
            "choices": [["delta": ["content": "ok"]]],
        ])
        let raw = ": comment\n\nevent: ping\n\n" + cleanLine
        let out = try reparser.feed(Data(raw.utf8))
        let chunks = openAIChunks(out)
        // ADR 0011: opener + content = 2.
        XCTAssertEqual(chunks.count, 2)
    }

    /// A malformed `data:` line is skipped (pi parity), not fatal. ADR 0011 §4:
    /// opener + content = 2 chunks.
    func testSkipsMalformedDataLine() throws {
        var reparser = QoderSSEReparser()
        let bad = "data: {not json}\n\n"
        let good = qoderLine([
            "id": "x", "model": "m",
            "choices": [["delta": ["content": "ok"]]],
        ])
        let out = try reparser.feed(Data((bad + good).utf8))
        let chunks = openAIChunks(out)
        // ADR 0011: opener + content = 2.
        XCTAssertEqual(chunks.count, 2, "malformed line should be skipped, not fatal")
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

    // MARK: - ADR 0011 streaming chunk template

    /// ADR 0011: every choice on every chunk carries BOTH `delta` (default `{}`)
    /// and `finish_reason` (default null — present, null on non-terminal chunks).
    /// Strict SDK schemas (zod, pydantic with `required`) reject the key being
    /// absent. The content chunk is the populated case for `delta` and the
    /// null case for `finish_reason`.
    func testEveryChoiceCarriesDeltaAndFinishReason() throws {
        var reparser = QoderSSEReparser()
        // Content chunk: delta populated, finish_reason must be present and null.
        let contentLine = qoderLine([
            "id": "x", "model": "m",
            "choices": [["delta": ["content": "hi"]]],
        ])
        var out = try reparser.feed(Data(contentLine.utf8))
        out.append(try reparser.finish())
        let chunks = openAIChunks(out)
        // The role opener fires first (ADR 0011 §3), so the content chunk is
        // not necessarily chunks[0]. Find it by payload.
        let contentChunk = try XCTUnwrap(chunks.first {
            (($0["choices"] as? [[String: Any]])?[0]["delta"] as? [String: Any])?["content"] != nil
        })
        let contentChoice = try XCTUnwrap((contentChunk["choices"] as? [[String: Any]])?[0])
        // delta present and carries the content.
        let contentDelta = try XCTUnwrap(contentChoice["delta"] as? [String: Any])
        XCTAssertEqual(contentDelta["content"] as? String, "hi")
        // finish_reason key present and null (NSNull round-trips to NSNull).
        XCTAssertNotNil(contentChoice["finish_reason"], "finish_reason key must be present (ADR 0011)")
        XCTAssertTrue(contentChoice["finish_reason"] is NSNull, "finish_reason must be null on non-terminal chunk")

        // Finish-only chunk: delta must be {} (present, empty), finish_reason populated.
        var reparser2 = QoderSSEReparser()
        let finishLine = qoderLine([
            "id": "y", "model": "m2",
            "choices": [["delta": [:], "finish_reason": "stop"]],
        ])
        var out2 = try reparser2.feed(Data(finishLine.utf8))
        out2.append(try reparser2.finish())
        let chunks2 = openAIChunks(out2)
        let finishChunk = try XCTUnwrap(chunks2.first {
            ($0["choices"] as? [[String: Any]])?[0]["finish_reason"] != nil
            && !((($0["choices"] as? [[String: Any]])?[0]["finish_reason"] is NSNull))
        })
        let finishChoice = try XCTUnwrap((finishChunk["choices"] as? [[String: Any]])?[0])
        XCTAssertEqual(finishChoice["finish_reason"] as? String, "stop")
        // delta must be present (an empty object), not omitted.
        XCTAssertNotNil(finishChoice["delta"], "delta key must be present (ADR 0011)")
        let finishDelta = try XCTUnwrap(finishChoice["delta"] as? [String: Any])
        XCTAssertTrue(finishDelta.isEmpty, "finish chunk delta must be {} when no content")
    }

    /// ADR 0011 §3: the trailing usage chunk is built by a dedicated
    /// `buildUsageChunk` and carries `choices: []` (empty array), matching
    /// OpenAI's `stream_options.include_usage` spec. NOT `choices:[{index:0}]`.
    /// Issue #19: opt into the trailing usage chunk via `includeUsage: true`
    /// (the default is now false per the OpenAI streaming contract).
    func testUsageChunkHasEmptyChoices() throws {
        var reparser = QoderSSEReparser(includeUsage: true)
        let line = qoderLine([
            "id": "x", "model": "m",
            "choices": [["delta": [:], "finish_reason": "stop"]],
            "usage": ["prompt_tokens": 10, "completion_tokens": 5, "total_tokens": 15] as [String: Any],
        ])
        var out = try reparser.feed(Data(line.utf8))
        out.append(try reparser.finish())
        let chunks = openAIChunks(out)
        // The usage chunk is the only chunk carrying top-level `usage`.
        let usageChunks = chunks.filter { ($0["usage"] as? [String: Any]) != nil }
        XCTAssertEqual(usageChunks.count, 1, "exactly one trailing usage chunk")
        let usageChunk = usageChunks[0]
        // CRITICAL: spec-mandated empty choices array, not [{index:0,...}].
        let choices = try XCTUnwrap(usageChunk["choices"] as? [Any])
        XCTAssertEqual(choices.count, 0, "usage chunk must carry choices: [] (OpenAI spec, ADR 0011)")
    }

    /// ADR 0011 §4: a synthesized `delta.role: "assistant"` opener fires exactly
    /// once per stream — on the first content/reasoning/tool emission. Mirrors
    /// CPA's `message_start`. Two content lines → exactly one opener, and it
    /// precedes both content chunks.
    func testRoleOpenerFiresOncePerStream() throws {
        var reparser = QoderSSEReparser()
        let line1 = qoderLine([
            "id": "x", "model": "m",
            "choices": [["delta": ["content": "Hel"]]],
        ])
        let line2 = qoderLine([
            "choices": [["delta": ["content": "lo"]]],
        ])
        var out = try reparser.feed(Data(line1.utf8))
        out.append(try reparser.feed(Data(line2.utf8)))
        let chunks = openAIChunks(out)
        // Exactly one chunk carries delta.role == "assistant".
        let openers = chunks.filter {
            (($0["choices"] as? [[String: Any]])?[0]["delta"] as? [String: Any])?["role"] as? String == "assistant"
        }
        XCTAssertEqual(openers.count, 1, "role opener must fire exactly once per stream")
        // And the opener is the FIRST chunk in the stream.
        let firstDelta = (chunks[0]["choices"] as? [[String: Any]])?[0]["delta"] as? [String: Any]
        XCTAssertEqual(firstDelta?["role"] as? String, "assistant", "opener must precede content")
    }

    /// Issue #18 cross-concern pin (ADR 0011): the finish chunk emitted in
    /// `finish()` via the #18 stashed-finish path inherits the template — it
    /// carries `delta: {}` (present, empty) AND `finish_reason: <reason>`.
    /// This explicitly pins that #18's late finish chunk satisfies the strict
    /// schema (both keys present), not just the finish_reason half.
    func testFinishChunkCarriesDeltaAndFinishReason() throws {
        var reparser = QoderSSEReparser()
        // The #18 scenario: a single frame carries BOTH content and finish_reason.
        // processLine stashes the reason (producedContentThisLine suppressed the
        // immediate emit); finish() then emits it via the #18 path.
        let line = qoderLine([
            "id": "x", "model": "m",
            "choices": [["delta": ["content": "done"], "finish_reason": "stop"]],
        ])
        var out = try reparser.feed(Data(line.utf8))
        out.append(try reparser.finish())
        let chunks = openAIChunks(out)
        // The finish chunk is the one with finish_reason == "stop" (a real
        // string, not NSNull).
        let finishChunks = chunks.filter {
            let fr = ($0["choices"] as? [[String: Any]])?[0]["finish_reason"]
            return fr is String && (fr as? String) == "stop"
        }
        XCTAssertEqual(finishChunks.count, 1)
        let finishChoice = (finishChunks[0]["choices"] as? [[String: Any]])?[0]
        // CRITICAL #18 pin: the finish chunk inherits ADR 0011's template —
        // delta is present (empty {}), finish_reason carries the real reason.
        XCTAssertNotNil(finishChoice?["delta"], "#18 finish chunk must carry delta (ADR 0011 template)")
        let finishDelta = finishChoice?["delta"] as? [String: Any]
        XCTAssertTrue(finishDelta?.isEmpty == true, "#18 finish chunk delta must be {} (no content)")
        XCTAssertEqual(finishChoice?["finish_reason"] as? String, "stop")
    }

    /// ADR 0011 §4 edge case: a finish-only stream (no content/reasoning/tool
    /// emission) does NOT get a synthesized role opener. The opener is about
    /// announcing the assistant role, which only matters if there's assistant
    /// output. A bare finish (e.g. a `length` truncation with no content) has
    /// nothing to open. This pins the chosen interpretation: gate the opener on
    /// a content/reasoning/tool emission, NOT on any non-empty `out`.
    func testFinishOnlyStreamDoesNotEmitOpener() throws {
        var reparser = QoderSSEReparser()
        // A single finish-only frame — no content/reasoning/tool delta.
        let line = qoderLine([
            "id": "x", "model": "m",
            "choices": [["delta": [:], "finish_reason": "stop"]],
        ])
        var out = try reparser.feed(Data(line.utf8))
        out.append(try reparser.finish())
        let chunks = openAIChunks(out)
        let openers = chunks.filter {
            (($0["choices"] as? [[String: Any]])?[0]["delta"] as? [String: Any])?["role"] as? String == "assistant"
        }
        XCTAssertEqual(openers.count, 0, "finish-only stream must not synthesize a role opener (ADR 0011 §4 edge case)")
    }

    // MARK: - Issue #19: stream_options.include_usage gating

    /// Issue #19: when the reparser is constructed WITHOUT `includeUsage`
    /// (the default — mirrors a client that did not send
    /// `stream_options.include_usage: true`), the trailing usage chunk is
    /// SUPPRESSED even though the upstream carried usage. The OpenAI
    /// streaming contract emits the trailing usage-only chunk ONLY when the
    /// client opted in; Quotio today emits it unconditionally (the bug).
    func testUsageChunkSuppressedWhenIncludeUsageFalse() throws {
        // Default init → includeUsage == false.
        var reparser = QoderSSEReparser()
        let line = qoderLine([
            "id": "x", "model": "m",
            "choices": [["delta": [:], "finish_reason": "stop"]],
            "usage": ["prompt_tokens": 10, "completion_tokens": 5, "total_tokens": 15] as [String: Any],
        ])
        var out = try reparser.feed(Data(line.utf8))
        out.append(try reparser.finish())
        let chunks = openAIChunks(out)
        // No chunk should carry a top-level `usage` field — the trailing
        // usage-only chunk is gated off. The finish chunk (and any content)
        // still emit; only the usage chunk is suppressed.
        let usageChunks = chunks.filter { ($0["usage"] as? [String: Any]) != nil }
        XCTAssertEqual(usageChunks.count, 0, "includeUsage=false must suppress the trailing usage chunk (issue #19)")
    }

    /// Issue #19: when the reparser is constructed WITH `includeUsage: true`
    /// (mirrors a client that sent `stream_options.include_usage: true`), the
    /// trailing usage chunk is emitted as before. Pin the opt-in path.
    func testUsageChunkEmittedWhenIncludeUsageTrue() throws {
        var reparser = QoderSSEReparser(includeUsage: true)
        let line = qoderLine([
            "id": "x", "model": "m",
            "choices": [["delta": [:], "finish_reason": "stop"]],
            "usage": ["prompt_tokens": 10, "completion_tokens": 5, "total_tokens": 15] as [String: Any],
        ])
        var out = try reparser.feed(Data(line.utf8))
        out.append(try reparser.finish())
        let chunks = openAIChunks(out)
        let usageChunks = chunks.filter { ($0["usage"] as? [String: Any]) != nil }
        XCTAssertEqual(usageChunks.count, 1, "includeUsage=true must emit exactly one trailing usage chunk")
        // Built via buildUsageChunk → choices: [].
        let choices = try XCTUnwrap(usageChunks[0]["choices"] as? [Any])
        XCTAssertEqual(choices.count, 0, "usage chunk must carry choices: [] (ADR 0011 §3)")
    }

    /// Issue #19 acceptance: the internal `capturedUsage` MUST stay populated
    /// when `includeUsage == false`. Quotio's own ADR 0005 §2 token accounting
    /// reads `capturedUsage` independently of whether the client-facing chunk
    /// was emitted — the whole point of the gate is to stop leaking token
    /// counts to a client that opted out without breaking internal capture.
    func testCapturedUsagePopulatedEvenWhenChunkSuppressed() throws {
        var reparser = QoderSSEReparser()   // includeUsage == false
        let line = qoderLine([
            "id": "x", "model": "m",
            "choices": [["delta": [:], "finish_reason": "stop"]],
            "usage": ["prompt_tokens": 100, "completion_tokens": 50, "total_tokens": 150] as [String: Any],
        ])
        _ = try reparser.feed(Data(line.utf8))
        _ = try reparser.finish()
        // Internal capture UNCHANGED — the stash is read independently of the
        // client-facing emission gate.
        let captured = try XCTUnwrap(reparser.capturedUsage)
        XCTAssertEqual(captured["prompt_tokens"] as? Int, 100)
        XCTAssertEqual(captured["completion_tokens"] as? Int, 50)
        XCTAssertEqual(captured["total_tokens"] as? Int, 150)
    }

    /// Issue #19: when `includeUsage == false`, the trailing usage chunk is
    /// suppressed BUT the finish_reason chunk + `[DONE]` still emit. The gate
    /// touches only the usage chunk; the rest of the terminal sequence is
    /// unaffected. Regression-pin against an over-broad gate.
    func testFinishReasonAndDoneStillEmitWhenUsageSuppressed() throws {
        var reparser = QoderSSEReparser()   // includeUsage == false
        let finishLine = qoderLine([
            "id": "x", "model": "m",
            "choices": [["delta": [:], "finish_reason": "stop"]],
            "usage": ["prompt_tokens": 7] as [String: Any],
        ])
        var out = try reparser.feed(Data(finishLine.utf8))
        out.append(try reparser.finish())
        let text = String(data: out, encoding: .utf8) ?? ""
        // [DONE] still terminates the stream.
        XCTAssertTrue(text.hasSuffix("data: [DONE]\n\n"))
        let chunks = openAIChunks(out)
        // The finish chunk still carries the real finish_reason.
        let finishChunk = try XCTUnwrap(chunks.first {
            ($0["choices"] as? [[String: Any]])?[0]["finish_reason"] as? String != nil
        })
        let choice = try XCTUnwrap((finishChunk["choices"] as? [[String: Any]])?[0])
        XCTAssertEqual(choice["finish_reason"] as? String, "stop")
    }

    /// Issue #19 boundary: the default-constructed reparser (no params) and
    /// the `includeUsage: false` reparser behave identically — pin that the
    /// default argument matches the explicit false. Guards against a future
    /// refactor accidentally flipping the default.
    func testDefaultInitEqualsExplicitIncludeUsageFalse() throws {
        let usage: [String: Any] = ["prompt_tokens": 1, "total_tokens": 1]
        func emit(using make: () -> QoderSSEReparser) -> Int {
            var r = make()
            let line = qoderLine([
                "id": "x", "model": "m",
                "choices": [["delta": [:], "finish_reason": "stop"]],
                "usage": usage,
            ])
            var out = try! r.feed(Data(line.utf8))
            out.append(try! r.finish())
            return openAIChunks(out).filter { ($0["usage"] as? [String: Any]) != nil }.count
        }
        XCTAssertEqual(emit { QoderSSEReparser() }, 0, "default init must suppress usage chunk")
        XCTAssertEqual(emit { QoderSSEReparser(includeUsage: false) }, 0, "explicit false must suppress usage chunk")
        XCTAssertEqual(emit { QoderSSEReparser(created: 1) }, 0, "created-pinned default must suppress usage chunk")
        XCTAssertEqual(emit { QoderSSEReparser(created: 1, includeUsage: false) }, 0, "created-pinned explicit false must suppress usage chunk")
    }

    /// Issue #19 S3 regression pin: a full content + finish + usage stream with
    /// `includeUsage == false` must still stream the content delta and emit the
    /// finish chunk, while suppressing ONLY the trailing usage chunk. The most
    /// direct pin against an over-broad gate — if the gate accidentally swallowed
    /// the content delta, finish chunk, or [DONE], this test fails. Includes a
    /// role opener (ADR 0011 §4) on the first content line, so the content
    /// assertion uses a `contains` predicate rather than a positional index.
    func testContentStillStreamsWhenUsageSuppressed() throws {
        var reparser = QoderSSEReparser()   // includeUsage == false
        var out = try reparser.feed(Data(qoderLine([
            "id": "x", "model": "m",
            "choices": [["delta": ["content": "Hi"]]],
        ]).utf8))
        out.append(try reparser.feed(Data(qoderLine([
            "id": "x", "model": "m",
            "choices": [["delta": [:], "finish_reason": "stop"]],
            "usage": ["prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2] as [String: Any],
        ]).utf8)))
        out.append(try reparser.finish())
        let chunks = openAIChunks(out)
        // Content delta still reaches the client.
        XCTAssertTrue(chunks.contains {
            (($0["choices"] as? [[String: Any]])?[0]["delta"] as? [String: Any])?["content"] as? String == "Hi"
        }, "content delta must still stream when usage is suppressed")
        // Finish chunk still reaches the client.
        XCTAssertTrue(chunks.contains {
            (($0["choices"] as? [[String: Any]])?[0]["finish_reason"] as? String) == "stop"
        }, "finish_reason chunk must still emit when usage is suppressed")
        // [DONE] still terminates the stream.
        XCTAssertTrue(String(data: out, encoding: .utf8)?.hasSuffix("data: [DONE]\n\n") == true)
        // And the usage chunk is the ONLY thing suppressed.
        XCTAssertEqual(chunks.filter { ($0["usage"] as? [String: Any]) != nil }.count, 0,
                       "includeUsage=false must suppress the trailing usage chunk")
    }

    // MARK: - ADR 0013 Tier 1 SSE line cap (issue #23)

    /// A line exactly AT the cap terminates fine on its `\n`; the cap fires
    /// only when the partial-line buffer EXCEEDS it with no terminator in
    /// sight. Boundary: at-cap → no throw.
    func testLineExactlyAtCapDoesNotThrow() throws {
        var reparser = QoderSSEReparser(created: 1700, maxLineBytes: 64)
        // 64 bytes of `x` followed by `\n` — the line hits the cap exactly.
        let line = String(repeating: "x", count: 64) + "\n"
        // Malformed (not a `data:` JSON line) is skipped per pi-parity — the
        // point is the LINE-CAP path did not fire.
        _ = try reparser.feed(Data(line.utf8))
    }

    /// An oversized line (no `\n` terminator) throws `.lineTooLarge` once the
    /// partial-line buffer exceeds the cap — the ADR 0013 structured
    /// termination signal ProxyBridge turns into a mid-stream error frame.
    func testOversizedLineThrowsLineTooLarge() throws {
        var reparser = QoderSSEReparser(created: 1700, maxLineBytes: 64)
        // 65 bytes with no `\n` — one over the cap.
        do {
            _ = try reparser.feed(Data(String(repeating: "x", count: 65).utf8))
            XCTFail("expected lineTooLarge")
        } catch let err as QoderSSEReparserError {
            guard case .lineTooLarge(let max) = err else {
                return XCTFail("wrong error: \(err)")
            }
            XCTAssertEqual(max, 64)
        }
    }

    /// The cap applies to the ACCUMULATED partial line across feeds — a
    /// misbehaving upstream trickling bytes with no `\n` must still trip it,
    /// not grow the buffer unbounded.
    func testOversizedLineAcrossFeedsThrows() throws {
        var reparser = QoderSSEReparser(created: 1700, maxLineBytes: 64)
        // Two feeds of 40 bytes each (80 > 64), neither carrying `\n`.
        _ = try reparser.feed(Data(String(repeating: "a", count: 40).utf8))
        do {
            _ = try reparser.feed(Data(String(repeating: "a", count: 40).utf8))
            XCTFail("expected lineTooLarge on the second feed")
        } catch let err as QoderSSEReparserError {
            guard case .lineTooLarge = err else { return XCTFail("wrong error: \(err)") }
        }
    }

    /// A legitimately huge line under the cap passes through — the default
    /// 1 MiB cap must not truncate real payloads. Feeds a 100 KiB line under
    /// a 1 MiB-equivalent cap and asserts it survives.
    func testLargeLegitimateLinePasses() throws {
        var reparser = QoderSSEReparser(created: 1700, maxLineBytes: 200_000)
        // A 100 KiB `data:` line (well under cap) with a proper terminator.
        let payload = String(repeating: "y", count: 100_000)
        let line = "data: " + payload + "\n\n"
        // Malformed JSON → skipped per pi-parity; the assertion is that no
        // lineTooLarge fired (the line is legitimately large but under cap).
        _ = try reparser.feed(Data(line.utf8))
    }
}
