//
//  QoderChatTranslatorTests.swift
//  QuotioTests
//
//  Phase 2a tests for the Qoder chat request-envelope builder (ticket #6).
//  Golden hash vectors were captured by running pi-provider-qoder's
//  `stableHash` and `stableChatRecordID` (src/stream.ts ~30-75) on the same
//  inputs, so a passing suite means the Swift port's hashing is byte-identical
//  to the TypeScript reference.
//

import XCTest
@testable import Quotio

final class QoderChatTranslatorTests: XCTestCase {

    // MARK: - stableHash golden vectors (captured from pi)

    /// (prefix, inputs, expected) tuples. Captured by invoking pi's
    /// `stableHash` directly with the same arguments.
    private static let stableHashVectors: [(String, [String], String)] = [
        ("qoder-session", ["u1", "m1"], "35882b7941113d04"),
        ("qoder-client", ["key-a"], "06d34f70aa118d60"),
        ("qoder-session", ["", ""], "33246292d38c4d99"),
        ("p", ["x"], "89a1db2113864175"),
        ("p", ["x", "y"], "6d027690d3ae5a21"),
        ("p", [], "148de9c5a7a44d19"),
    ]

    func testStableHashMatchesReference() {
        for (prefix, inputs, expected) in Self.stableHashVectors {
            let actual = QoderChatTranslator.stableHash(prefix, inputs)
            XCTAssertEqual(
                actual, expected,
                "stableHash(\"\(prefix)\", \(inputs)) diverged from pi: got \(actual)"
            )
        }
    }

    /// The variadic and array overloads must agree.
    func testStableHashVariadicMatchesArray() {
        XCTAssertEqual(
            QoderChatTranslator.stableHash("qoder-session", "u1", "m1"),
            QoderChatTranslator.stableHash("qoder-session", ["u1", "m1"])
        )
    }

    /// Determinism: same inputs → same output across calls.
    func testStableHashDeterministic() {
        let a = QoderChatTranslator.stableHash("p", ["a", "b"])
        let b = QoderChatTranslator.stableHash("p", ["a", "b"])
        XCTAssertEqual(a, b)
    }

    // MARK: - stableChatRecordID golden vectors (captured from pi)

    /// Helper: build a QoderMessage the way the translator does. content nil
    /// for "no content" cases mirrors pi's `if (msg.content)` JS-truthiness
    /// skip — both empty-string content and nil content must hash the same.
    private func qmsg(_ role: String, _ content: String?) -> QoderMessage {
        QoderMessage(role: role, content: content, toolCalls: [], toolCallID: nil)
    }

    func testStableChatRecordIDMatchesReference() {
        // (model, messages, toolsJSON, maxTokens, expected) — captured from pi.
        let cases: [(String, [QoderMessage], String, Int, String)] = [
            ("m1", [qmsg("user", "hi")], "", 32768, "b22bd82cd142a53f"),
            ("m1", [qmsg("system", "be nice"), qmsg("user", "hi")], "", 32768, "2e17fb4d67372a0c"),
            ("m1", [qmsg("user", "hi"), qmsg("assistant", "yo")], "", 32768, "8c2ace27735bfdf1"),
            ("m1", [qmsg("user", "")], "", 32768, "a68b06981b82a675"),
            ("m1", [qmsg("user", nil)], "", 32768, "a68b06981b82a675"),
            ("m1", [], "", 32768, "8a5862567bc2c5bf"),
            ("m2", [qmsg("user", "hi")], "", 1024, "6128e7a1eaceb1d5"),
        ]
        for (model, messages, tools, maxTokens, expected) in cases {
            let actual = QoderChatTranslator.stableChatRecordID(
                model: model, messages: messages, toolsJSON: tools, maxTokens: maxTokens
            )
            XCTAssertEqual(
                actual, expected,
                "stableChatRecordID(\(model), …) diverged from pi: got \(actual)"
            )
        }
    }

    /// Empty-string content and nil content hash identically — JS truthiness
    /// (`if (msg.content)`) skips both. This is the parity-sensitive edge that
    /// would break prompt-cache affinity if the Swift port diverged.
    func testStableChatRecordIDEmptyContentEqualsNilContent() {
        let nilID = QoderChatTranslator.stableChatRecordID(
            model: "m", messages: [qmsg("user", nil)], toolsJSON: "", maxTokens: 32768
        )
        let emptyID = QoderChatTranslator.stableChatRecordID(
            model: "m", messages: [qmsg("user", "")], toolsJSON: "", maxTokens: 32768
        )
        XCTAssertEqual(nilID, emptyID)
    }

    // MARK: - Message transform

    /// System role passes through as role:system (OpenAI input carries system
    /// as a message; pi had no system branch). This is the documented
    /// ADR 0004 deviation.
    func testTransformPassesSystemMessageThrough() {
        let msgs = [
            OpenAIChatMessage(role: "system", content: .text("Be terse."), toolCalls: nil, toolCallID: nil),
            OpenAIChatMessage(role: "user", content: .text("Hi"), toolCalls: nil, toolCallID: nil),
        ]
        let out = QoderChatTranslator.transformMessagesForQoder(msgs)
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out[0].role, "system")
        XCTAssertEqual(out[0].content, "Be terse.")
        XCTAssertEqual(out[1].role, "user")
        XCTAssertEqual(out[1].content, "Hi")
    }

    /// Multipart text content flattens to plain text. (Image parts are
    /// rejected at the gate before transform runs.)
    func testTransformFlattensMultipartText() {
        let msgs = [
            OpenAIChatMessage(
                role: "user",
                content: .parts([.text("a "), .text("b"), .text(" c")]),
                toolCalls: nil,
                toolCallID: nil
            ),
        ]
        let out = QoderChatTranslator.transformMessagesForQoder(msgs)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].content, "a b c")
    }

    /// Assistant with tool calls but no text gets a single-space placeholder
    /// (Qoder gateway otherwise drops the message and orphans the tool_result).
    /// Tool calls are unreachable on the text path (gate 1), but the branch is
    /// asserted here for ticket #8 correctness.
    func testTransformAssistantToolCallPlaceholder() {
        let msgs = [
            OpenAIChatMessage(
                role: "assistant",
                content: nil,
                toolCalls: [OpenAIToolCall(id: "tc1", function: OpenAIToolFunction(name: "f", arguments: "{}"))],
                toolCallID: nil
            ),
        ]
        let out = QoderChatTranslator.transformMessagesForQoder(msgs)
        XCTAssertEqual(out[0].content, " ")
        XCTAssertEqual(out[0].toolCalls.count, 1)
        XCTAssertEqual(out[0].toolCalls[0].function.name, "f")
    }

    /// tool-role message carries tool_call_id forward.
    func testTransformToolRoleMessage() {
        let msgs = [
            OpenAIChatMessage(role: "tool", content: .text("result"), toolCalls: nil, toolCallID: "tc1"),
        ]
        let out = QoderChatTranslator.transformMessagesForQoder(msgs)
        XCTAssertEqual(out[0].role, "tool")
        XCTAssertEqual(out[0].content, "result")
        XCTAssertEqual(out[0].toolCallID, "tc1")
    }

    /// Unknown roles are skipped (pi parity).
    func testTransformSkipsUnknownRole() {
        let msgs = [
            OpenAIChatMessage(role: "developer", content: .text("x"), toolCalls: nil, toolCallID: nil),
            OpenAIChatMessage(role: "user", content: .text("y"), toolCalls: nil, toolCallID: nil),
        ]
        let out = QoderChatTranslator.transformMessagesForQoder(msgs)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].role, "user")
    }

    // MARK: - transformTools (ported but unused on text path)

    /// transformTools round-trips a JSON-Schema parameter blob faithfully.
    func testTransformToolsRoundTripsParameters() throws {
        let schemaJSON = #"{"type":"object","properties":{"x":{"type":"number"}},"required":["x"]}"#
        let tool = OpenAITool(
            function: OpenAIToolDefinition(
                name: "get_weather",
                description: "Get weather",
                parameters: Data(schemaJSON.utf8)
            )
        )
        let out = QoderChatTranslator.transformTools([tool])
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0]["type"] as? String, "function")
        let fn = out[0]["function"] as? [String: Any]
        XCTAssertEqual(fn?["name"] as? String, "get_weather")
        XCTAssertEqual(fn?["description"] as? String, "Get weather")
        let params = fn?["parameters"] as? [String: Any]
        XCTAssertEqual(params?["type"] as? String, "object")
        // Round-trips back to the same bytes.
        let reencoded = try JSONSerialization.data(withJSONObject: params as Any)
        let redecoded = try JSONSerialization.jsonObject(with: reencoded) as? [String: Any]
        XCTAssertEqual(redecoded?["required"] as? [String], ["x"])
    }

    // MARK: - Fail-fast gates

    /// Non-empty tools → toolsNotSupported (Phase 2a text path).
    func testGateRejectsTools() {
        let request = OpenAIChatRequest(
            model: "m",
            messages: [OpenAIChatMessage(role: "user", content: .text("hi"), toolCalls: nil, toolCallID: nil)],
            tools: [OpenAITool(function: OpenAIToolDefinition(
                name: "f", description: nil, parameters: Data("{}".utf8)
            ))],
            maxTokens: nil
        )
        XCTAssertThrowsError(try translate(request)) { error in
            guard case .toolsNotSupported = error as? QoderTranslatorError else {
                return XCTFail("expected .toolsNotSupported, got \(error)")
            }
        }
    }

    /// Empty tools array is allowed (treated as "no tools").
    func testGateAllowsEmptyTools() throws {
        let request = OpenAIChatRequest(
            model: "m",
            messages: [OpenAIChatMessage(role: "user", content: .text("hi"), toolCalls: nil, toolCallID: nil)],
            tools: [],
            maxTokens: nil
        )
        _ = try translate(request)
    }

    /// Image content part in any message → imageContentNotSupported.
    func testGateRejectsImageContent() {
        let request = OpenAIChatRequest(
            model: "m",
            messages: [OpenAIChatMessage(
                role: "user",
                content: .parts([
                    .text("look"),
                    .imageURL(URL(string: "https://example.com/x.png")!),
                ]),
                toolCalls: nil,
                toolCallID: nil
            )],
            tools: nil,
            maxTokens: nil
        )
        XCTAssertThrowsError(try translate(request)) { error in
            guard case .imageContentNotSupported = error as? QoderTranslatorError else {
                return XCTFail("expected .imageContentNotSupported, got \(error)")
            }
        }
    }

    // MARK: - Envelope structure + determinism (pinned options)

    /// With pinned options, the translator produces the same recordID,
    /// sessionID, and requestID as an equivalent pi-shaped build. The envelope
    /// is compared structurally (re-serialized through a stable formatter)
    /// rather than byte-equal, since `JSONSerialization` may reorder keys
    /// across calls — the gateway parses JSON, so order is irrelevant.
    func testEnvelopeStructureAndDeterministicIDs() throws {
        let result = try translateEnvelopeFixture()
        XCTAssertEqual(result.requestID, "req-fixed-uuid")
        XCTAssertEqual(result.requestSetID, "f30d6ad1d789f9d4")
        XCTAssertEqual(result.chatRecordID, "f30d6ad1d789f9d4")
        XCTAssertEqual(result.sessionID, "28b730efa32f4e9e-5b79d08086ab20c4")

        // Re-running with the same pinned options produces the same envelope
        // tree (deep-equal), even if `JSONSerialization` reorders keys.
        let result2 = try translateEnvelopeFixture()
        let tree1 = try JSONSerialization.jsonObject(with: result.envelopeJSON)
        let tree2 = try JSONSerialization.jsonObject(with: result2.envelopeJSON)
        XCTAssertEqual(
            String(describing: NSDictionary(dictionary: tree1 as? [AnyHashable: Any] ?? [:])),
            String(describing: NSDictionary(dictionary: tree2 as? [AnyHashable: Any] ?? [:]))
        )
    }

    /// Assert the envelope's full field set, captured from the pi-shaped build.
    func testEnvelopeFieldSet() throws {
        let result = try translateEnvelopeFixture()
        let envelope = try JSONSerialization.jsonObject(with: result.envelopeJSON) as? [String: Any]
        let env = try XCTUnwrap(envelope)

        // Top-level fixed fields (verbatim from stream.ts). Compare by
        // re-encoding each side through JSON so Bool/Int/NSNumber all normalize
        // to the same textual form (JSONSerialization round-trips Bool as
        // NSNumber, whose String(describing:) is "1"/"0", not "true"/"false").
        let fixedFields: [String: Any] = [
            "request_id": "req-fixed-uuid",
            "request_set_id": "f30d6ad1d789f9d4",
            "chat_record_id": "f30d6ad1d789f9d4",
            "session_id": "28b730efa32f4e9e-5b79d08086ab20c4",
            "stream": true,
            "chat_task": "FREE_INPUT",
            "is_reply": true,
            "is_retry": false,
            "source": 1,
            "version": "3",
            "session_type": "qodercli",
            "agent_id": "agent_common",
            "task_id": "common",
            "code_language": "",
            "chat_prompt": "",
            "aliyun_user_type": "",
            "system": "",
        ]
        for (k, v) in fixedFields {
            let actualNorm = try String(data: JSONSerialization.data(withJSONObject: [k: env[k] ?? NSNull()], options: [.sortedKeys]), encoding: .utf8)
            let expectedNorm = try String(data: JSONSerialization.data(withJSONObject: [k: v], options: [.sortedKeys]), encoding: .utf8)
            XCTAssertEqual(actualNorm, expectedNorm, "envelope field '\(k)' mismatch")
        }
        // image_urls is null.
        XCTAssertEqual(env["image_urls"] as? NSNull, NSNull())

        // messages: system + user + assistant(null) + assistant(text).
        let messages = try XCTUnwrap(env["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 4)
        XCTAssertEqual(messages[0]["role"] as? String, "system")
        XCTAssertEqual(messages[0]["content"] as? String, "Be terse.")
        XCTAssertEqual(messages[2]["role"] as? String, "assistant")
        XCTAssertEqual(messages[2]["content"] as? NSNull, NSNull())

        // tools is empty array.
        XCTAssertEqual((env["tools"] as? [Any])?.count, 0)

        // parameters.max_tokens.
        let params = try XCTUnwrap(env["parameters"] as? [String: Any])
        XCTAssertEqual(params["max_tokens"] as? Int, 4096)

        // chat_context.extra.originalContent + text = last user message.
        let chatContext = try XCTUnwrap(env["chat_context"] as? [String: Any])
        let extra = try XCTUnwrap(chatContext["extra"] as? [String: Any])
        XCTAssertEqual(extra["originalContent"] as? String, "Hello")
        XCTAssertEqual(chatContext["text"] as? String, "Hello")
        let modelCfg = try XCTUnwrap(extra["modelConfig"] as? [String: Any])
        XCTAssertEqual(modelCfg["key"] as? String, "qoder-model-x")
        XCTAssertEqual(modelCfg["is_reasoning"] as? Bool, false)

        // top-level model_config carries the full descriptor.
        let topModelCfg = try XCTUnwrap(env["model_config"] as? [String: Any])
        XCTAssertEqual(topModelCfg["key"] as? String, "qoder-model-x")
        XCTAssertEqual(topModelCfg["is_reasoning"] as? Bool, false)
        XCTAssertEqual(topModelCfg["max_output_tokens"] as? Int, 4096)
        XCTAssertEqual(topModelCfg["source"] as? String, "system")

        // business.name is truncated to 30 chars; begin_at is the pinned ms.
        let business = try XCTUnwrap(env["business"] as? [String: Any])
        XCTAssertEqual(business["id"] as? String, "biz-fixed-uuid")
        XCTAssertEqual(business["name"] as? String, "Hello")
        XCTAssertEqual(business["begin_at"] as? Int, 1700000000000)
    }

    /// business.name truncates to 30 chars when the last user message is long.
    func testBusinessNameTruncates() throws {
        let longText = String(repeating: "x", count: 50)
        let request = OpenAIChatRequest(
            model: "m",
            messages: [OpenAIChatMessage(role: "user", content: .text(longText), toolCalls: nil, toolCallID: nil)],
            tools: nil,
            maxTokens: nil
        )
        let result = try QoderChatTranslator.translate(
            request: request,
            userID: "u",
            proxyAPIKey: "k",
            modelConfig: QoderModelConfig(key: "m", isReasoning: false, maxOutputTokens: 32768, source: "system"),
            options: QoderChatTranslatorOptions(
                requestID: "r", businessID: "b", businessBeginAtMS: 1
            )
        )
        let env = try JSONSerialization.jsonObject(with: result.envelopeJSON) as? [String: Any]
        let business = env?["business"] as? [String: Any]
        XCTAssertEqual((business?["name"] as? String)?.count, 30)
    }

    // MARK: - Body parsing

    /// Round-trip: parse a JSON body, translate, re-parse the envelope — the
    /// user's text survives the parse + transform + serialize pipeline.
    func testParseAndTranslateFromJSONBody() throws {
        let bodyJSON = #"""
        {"model":"m","messages":[{"role":"user","content":"hello world"}],"max_tokens":128}
        """#
        let result = try QoderChatTranslator.translate(
            body: Data(bodyJSON.utf8),
            userID: "u",
            proxyAPIKey: "k",
            modelConfig: QoderModelConfig(key: "m", isReasoning: false, maxOutputTokens: 32768, source: "system"),
            options: QoderChatTranslatorOptions(requestID: "r", businessID: "b", businessBeginAtMS: 1)
        )
        let env = try JSONSerialization.jsonObject(with: result.envelopeJSON) as? [String: Any]
        let params = env?["parameters"] as? [String: Any]
        XCTAssertEqual(params?["max_tokens"] as? Int, 128)   // request max respected
    }

    /// max_tokens > model cap is clamped to the model cap.
    func testMaxTokensClampsToModelCap() throws {
        let bodyJSON = #"{"model":"m","messages":[{"role":"user","content":"x"}],"max_tokens":999999}"#
        let result = try QoderChatTranslator.translate(
            body: Data(bodyJSON.utf8),
            userID: "u",
            proxyAPIKey: "k",
            modelConfig: QoderModelConfig(key: "m", isReasoning: false, maxOutputTokens: 8192, source: "system"),
            options: QoderChatTranslatorOptions(requestID: "r", businessID: "b", businessBeginAtMS: 1)
        )
        let env = try JSONSerialization.jsonObject(with: result.envelopeJSON) as? [String: Any]
        let params = env?["parameters"] as? [String: Any]
        XCTAssertEqual(params?["max_tokens"] as? Int, 8192)
    }

    /// Malformed JSON → malformedRequest.
    func testParseRejectsMalformedJSON() {
        XCTAssertThrowsError(try QoderChatTranslator.parse(body: Data("not json".utf8))) { error in
            guard case .malformedRequest = error as? QoderTranslatorError else {
                return XCTFail("expected .malformedRequest, got \(error)")
            }
        }
    }

    /// Missing model → malformedRequest.
    func testParseRejectsMissingModel() {
        let body = Data(#"{"messages":[{"role":"user","content":"x"}]}"#.utf8)
        XCTAssertThrowsError(try QoderChatTranslator.parse(body: body)) { error in
            guard case .malformedRequest = error as? QoderTranslatorError else {
                return XCTFail("expected .malformedRequest, got \(error)")
            }
        }
    }

    // MARK: - Session ID (ADR 0005 §1)

    /// Same user + same model + same proxy key → same session ID. This is the
    /// cache-affinity invariant: across turns, the same CLI agent collapses to
    /// one Qoder session.
    func testSessionIDStableAcrossCalls() throws {
        let request = OpenAIChatRequest(
            model: "m",
            messages: [OpenAIChatMessage(role: "user", content: .text("turn 1"), toolCalls: nil, toolCallID: nil)],
            tools: nil,
            maxTokens: nil
        )
        let a = try QoderChatTranslator.translate(
            request: request, userID: "u1", proxyAPIKey: "key-A",
            modelConfig: QoderModelConfig(key: "m", isReasoning: false, maxOutputTokens: 32768, source: "system"),
            options: QoderChatTranslatorOptions(requestID: "r1", businessID: "b1", businessBeginAtMS: 1)
        )
        let b = try QoderChatTranslator.translate(
            request: request, userID: "u1", proxyAPIKey: "key-A",
            modelConfig: QoderModelConfig(key: "m", isReasoning: false, maxOutputTokens: 32768, source: "system"),
            options: QoderChatTranslatorOptions(requestID: "r2", businessID: "b2", businessBeginAtMS: 2)
        )
        XCTAssertEqual(a.sessionID, b.sessionID)
    }

    /// Different proxy key (different CLI agent) → different session ID.
    func testSessionIDVariesByProxyKey() throws {
        let request = OpenAIChatRequest(
            model: "m",
            messages: [OpenAIChatMessage(role: "user", content: .text("x"), toolCalls: nil, toolCallID: nil)],
            tools: nil,
            maxTokens: nil
        )
        let a = try QoderChatTranslator.translate(
            request: request, userID: "u", proxyAPIKey: "key-A",
            modelConfig: QoderModelConfig(key: "m", isReasoning: false, maxOutputTokens: 32768, source: "system"),
            options: .deferringToRandom
        )
        let b = try QoderChatTranslator.translate(
            request: request, userID: "u", proxyAPIKey: "key-B",
            modelConfig: QoderModelConfig(key: "m", isReasoning: false, maxOutputTokens: 32768, source: "system"),
            options: .deferringToRandom
        )
        XCTAssertNotEqual(a.sessionID, b.sessionID)
    }

    /// Different model → different session ID (model is part of the stable hash).
    func testSessionIDVariesByModel() throws {
        let requestA = OpenAIChatRequest(
            model: "m1",
            messages: [OpenAIChatMessage(role: "user", content: .text("x"), toolCalls: nil, toolCallID: nil)],
            tools: nil, maxTokens: nil
        )
        let requestB = OpenAIChatRequest(
            model: "m2",
            messages: [OpenAIChatMessage(role: "user", content: .text("x"), toolCalls: nil, toolCallID: nil)],
            tools: nil, maxTokens: nil
        )
        let a = try QoderChatTranslator.translate(
            request: requestA, userID: "u", proxyAPIKey: "k",
            modelConfig: QoderModelConfig(key: "m1", isReasoning: false, maxOutputTokens: 32768, source: "system"),
            options: .deferringToRandom
        )
        let b = try QoderChatTranslator.translate(
            request: requestB, userID: "u", proxyAPIKey: "k",
            modelConfig: QoderModelConfig(key: "m2", isReasoning: false, maxOutputTokens: 32768, source: "system"),
            options: .deferringToRandom
        )
        XCTAssertNotEqual(a.sessionID, b.sessionID)
    }

    // MARK: - Helpers

    /// Drive the typed-translate entry with the same inputs as the pi-shaped
    /// envelope fixture captured above, with all random inputs pinned.
    private func translateEnvelopeFixture() throws -> QoderTranslationResult {
        let request = OpenAIChatRequest(
            model: "qoder-model-x",
            messages: [
                OpenAIChatMessage(role: "system", content: .text("Be terse."), toolCalls: nil, toolCallID: nil),
                OpenAIChatMessage(role: "user", content: .text("Hello"), toolCalls: nil, toolCallID: nil),
                OpenAIChatMessage(role: "assistant", content: nil, toolCalls: [], toolCallID: nil),
                OpenAIChatMessage(role: "assistant", content: .text("Hi there"), toolCalls: nil, toolCallID: nil),
            ],
            tools: [],
            maxTokens: 4096
        )
        return try QoderChatTranslator.translate(
            request: request,
            userID: "u1",
            proxyAPIKey: "key-A",
            modelConfig: QoderModelConfig(
                key: "qoder-model-x", isReasoning: false, maxOutputTokens: 4096, source: "system"
            ),
            options: QoderChatTranslatorOptions(
                requestID: "req-fixed-uuid",
                businessID: "biz-fixed-uuid",
                businessBeginAtMS: 1700000000000
            )
        )
    }

    /// Shorthand for the gate tests: translate with throwaway defaults.
    private func translate(_ request: OpenAIChatRequest) throws -> QoderTranslationResult {
        try QoderChatTranslator.translate(
            request: request,
            userID: "u",
            proxyAPIKey: "k",
            modelConfig: QoderModelConfig(key: "m", isReasoning: false, maxOutputTokens: 32768, source: "system"),
            options: .deferringToRandom
        )
    }
}
