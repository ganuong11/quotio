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
    /// Phase 2b: content wraps in `.text` (the golden vectors are text-only).
    private func qmsg(_ role: String, _ content: String?) -> QoderMessage {
        QoderMessage(role: role, content: content.map { .text($0) }, toolCalls: [], toolCallID: nil)
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
        XCTAssertEqual(out[0].content, .text("Be terse."))
        XCTAssertEqual(out[1].role, "user")
        XCTAssertEqual(out[1].content, .text("Hi"))
    }

    /// Multipart text-only content flattens to plain text (no image part →
    /// pi's fast path, transform.ts ~102-104).
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
        XCTAssertEqual(out[0].content, .text("a b c"))
    }

    /// Assistant with tool calls but no text gets a single-space placeholder
    /// (Qoder gateway otherwise drops the message and orphans the tool_result).
    /// Phase 2b: assistant tool calls now reach this branch (gate 1 lifted).
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
        XCTAssertEqual(out[0].content, .text(" "))
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
        XCTAssertEqual(out[0].content, .text("result"))
        XCTAssertEqual(out[0].toolCallID, "tc1")
    }

    /// A tool result carrying an image is forwarded: the text note rides the
    /// `tool` message (string content, as the gateway requires) and the image
    /// follows as a separate `user` message with a leading label. Without this
    /// the image was dropped by `contentText` and the model saw only the note,
    /// then reported it could not see images. (pi-provider-qoder PR #14.)
    func testTransformForwardsToolResultImages() {
        let msgs = [
            OpenAIChatMessage(
                role: "tool",
                content: .parts([
                    .text("Read image file [image/png]"),
                    .imageURL(URL(string: "data:image/png;base64,abc123")!),
                ]),
                toolCalls: nil,
                toolCallID: "call_1"
            ),
        ]
        let out = QoderChatTranslator.transformMessagesForQoder(msgs)
        XCTAssertEqual(out.count, 2)
        // First: the tool message, string-only content.
        XCTAssertEqual(out[0].role, "tool")
        XCTAssertEqual(out[0].content, .text("Read image file [image/png]"))
        XCTAssertEqual(out[0].toolCallID, "call_1")
        // Second: a user message with the label + the image.
        XCTAssertEqual(out[1].role, "user")
        guard let content = out[1].content, case .parts(let parts) = content else {
            return XCTFail("expected parts content on the follow-up user message")
        }
        XCTAssertEqual(parts.count, 2)
        guard case .text(let label) = parts[0] else {
            return XCTFail("first part must be the text label")
        }
        XCTAssertEqual(label, "[1 image returned by the previous tool call]")
        XCTAssertEqual(parts[1], .imageURL("data:image/png;base64,abc123"))
    }

    /// Several images from one tool call share one follow-up `user` message;
    /// the label counts them.
    func testTransformForwardsMultipleToolResultImages() {
        let msgs = [
            OpenAIChatMessage(
                role: "tool",
                content: .parts([
                    .text("two shots"),
                    .imageURL(URL(string: "data:image/png;base64,one")!),
                    .imageURL(URL(string: "data:image/jpeg;base64,two")!),
                ]),
                toolCalls: nil,
                toolCallID: "call_1"
            ),
        ]
        let out = QoderChatTranslator.transformMessagesForQoder(msgs)
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out[1].role, "user")
        guard let content = out[1].content, case .parts(let parts) = content else {
            return XCTFail("expected parts content on the follow-up user message")
        }
        XCTAssertEqual(parts.count, 3)
        guard case .text(let label) = parts[0] else {
            return XCTFail("first part must be the text label")
        }
        XCTAssertEqual(label, "[2 images returned by the previous tool call]")
        XCTAssertEqual(parts[1], .imageURL("data:image/png;base64,one"))
        XCTAssertEqual(parts[2], .imageURL("data:image/jpeg;base64,two"))
    }

    /// A text-only tool result stays a single `tool` message — the common case
    /// must not gain a spurious follow-up.
    func testTransformToolResultWithoutImagesIsSingleMessage() {
        let msgs = [
            OpenAIChatMessage(role: "tool", content: .text("plain text result"), toolCalls: nil, toolCallID: "call_1"),
        ]
        let out = QoderChatTranslator.transformMessagesForQoder(msgs)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].role, "tool")
    }

    /// The OpenAI `developer` role folds into Qoder's `system` semantics —
    /// it's the newer instruction role that replaces `system` for newer models.
    /// Content is preserved; only the role is normalized.
    func testTransformMapsDeveloperToSystem() {
        let msgs = [
            OpenAIChatMessage(role: "developer", content: .text("x"), toolCalls: nil, toolCallID: nil),
        ]
        let out = QoderChatTranslator.transformMessagesForQoder(msgs)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].role, "system")
        XCTAssertEqual(out[0].content, .text("x"))
    }

    /// Relative order among `system`/`developer`/`user` is preserved, with
    /// `developer` normalized to `system`: the sequence system, developer, user
    /// becomes system, system, user.
    func testTransformPreservesInstructionOrder() {
        let msgs = [
            OpenAIChatMessage(role: "system", content: .text("s"), toolCalls: nil, toolCallID: nil),
            OpenAIChatMessage(role: "developer", content: .text("d"), toolCalls: nil, toolCallID: nil),
            OpenAIChatMessage(role: "user", content: .text("u"), toolCalls: nil, toolCallID: nil),
        ]
        let out = QoderChatTranslator.transformMessagesForQoder(msgs)
        XCTAssertEqual(out.count, 3)
        XCTAssertEqual(out[0].role, "system")
        XCTAssertEqual(out[0].content, .text("s"))
        XCTAssertEqual(out[1].role, "system")
        XCTAssertEqual(out[1].content, .text("d"))
        XCTAssertEqual(out[2].role, "user")
        XCTAssertEqual(out[2].content, .text("u"))
    }

    /// Unknown roles are skipped (pi parity). `developer` is no longer unknown
    /// — it folds into `system` — so a genuinely-unknown role exercises this path.
    func testTransformSkipsUnknownRole() {
        let msgs = [
            OpenAIChatMessage(role: "moderator", content: .text("x"), toolCalls: nil, toolCallID: nil),
            OpenAIChatMessage(role: "user", content: .text("y"), toolCalls: nil, toolCallID: nil),
        ]
        let out = QoderChatTranslator.transformMessagesForQoder(msgs)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].role, "user")
    }

    // MARK: - transformTools (Phase 2b: now wired into the envelope)

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

    // MARK: - Tools wiring (Phase 2b — gates lifted)

    /// A tools-bearing request translates successfully and the envelope carries
    /// the transformed tools (previously Phase 2a rejected this with a 400).
    func testToolsTranslateIntoEnvelope() throws {
        let request = OpenAIChatRequest(
            model: "m",
            messages: [OpenAIChatMessage(role: "user", content: .text("hi"), toolCalls: nil, toolCallID: nil)],
            tools: [OpenAITool(function: OpenAIToolDefinition(
                name: "f", description: "do f", parameters: Data("{}".utf8)
            ))],
            maxTokens: nil
        )
        let result = try translate(request)
        let env = try JSONSerialization.jsonObject(with: result.envelopeJSON) as? [String: Any]
        let tools = env?["tools"] as? [[String: Any]]
        XCTAssertEqual(tools?.count, 1)
        XCTAssertEqual(tools?[0]["type"] as? String, "function")
        XCTAssertEqual((tools?[0]["function"] as? [String: Any])?["name"] as? String, "f")
    }

    /// The tool surface feeds the recordID hash — adding a tool changes the
    /// recordID (cache affinity includes tools, stream.ts ~173). Previously
    /// Phase 2a always hashed toolsJSON="" so tool-bearing requests shared a
    /// recordID with tool-free requests, breaking cache affinity.
    func testRecordIDChangesWithTools() throws {
        let noTools = OpenAIChatRequest(
            model: "m",
            messages: [OpenAIChatMessage(role: "user", content: .text("hi"), toolCalls: nil, toolCallID: nil)],
            tools: nil, maxTokens: nil
        )
        let withTools = OpenAIChatRequest(
            model: "m",
            messages: [OpenAIChatMessage(role: "user", content: .text("hi"), toolCalls: nil, toolCallID: nil)],
            tools: [OpenAITool(function: OpenAIToolDefinition(
                name: "f", description: nil, parameters: Data("{}".utf8)
            ))],
            maxTokens: nil
        )
        let r1 = try translate(noTools)
        let r2 = try translate(withTools)
        XCTAssertNotEqual(r1.chatRecordID, r2.chatRecordID,
            "recordID must change when tools are added (cache affinity includes tools)")
    }

    /// Empty tools array is allowed (treated as "no tools" — envelope tools is
    /// empty, recordID matches a no-tools request).
    func testEmptyToolsAllowed() throws {
        let request = OpenAIChatRequest(
            model: "m",
            messages: [OpenAIChatMessage(role: "user", content: .text("hi"), toolCalls: nil, toolCallID: nil)],
            tools: [],
            maxTokens: nil
        )
        let result = try translate(request)
        let env = try JSONSerialization.jsonObject(with: result.envelopeJSON) as? [String: Any]
        XCTAssertEqual((env?["tools"] as? [Any])?.count, 0)
    }

    // MARK: - Image content parts (Phase 2b — gate lifted)

    /// A user message with an image part produces array-of-parts content in
    /// the envelope: a text part and an `image_url` part carrying the verbatim
    /// URL (Phase 2b: OpenAI input already carries a ready URL — we don't
    /// reconstruct pi's mimeType/base64 byte model).
    func testImagePartBecomesImageURLPart() throws {
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
        let result = try translate(request)
        let env = try JSONSerialization.jsonObject(with: result.envelopeJSON) as? [String: Any]
        let messages = env?["messages"] as? [[String: Any]]
        let content = messages?[0]["content"] as? [[String: Any]]
        XCTAssertEqual(content?.count, 2)
        XCTAssertEqual(content?[0]["type"] as? String, "text")
        XCTAssertEqual(content?[0]["text"] as? String, "look")
        XCTAssertEqual(content?[1]["type"] as? String, "image_url")
        let imageURL = content?[1]["image_url"] as? [String: Any]
        XCTAssertEqual(imageURL?["url"] as? String, "https://example.com/x.png")
    }

    /// A `data:` URL image part passes through verbatim (the common case for
    /// CLI agents embedding screenshots as base64 data URLs).
    func testImageDataURLPassesThrough() throws {
        let dataURL = "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII="
        let request = OpenAIChatRequest(
            model: "m",
            messages: [OpenAIChatMessage(
                role: "user",
                content: .parts([.imageURL(URL(string: dataURL)!)]),
                toolCalls: nil,
                toolCallID: nil
            )],
            tools: nil,
            maxTokens: nil
        )
        let result = try translate(request)
        let env = try JSONSerialization.jsonObject(with: result.envelopeJSON) as? [String: Any]
        let content = (env?["messages"] as? [[String: Any]])?[0]["content"] as? [[String: Any]]
        let imageURL = content?[0]["image_url"] as? [String: Any]
        XCTAssertEqual(imageURL?["url"] as? String, dataURL)
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

    // MARK: - Reasoning intent parsing (parseReasoningIntent)

    /// Drive `parseReasoningIntent` by round-tripping a JSON body through
    /// `parse(body:)`. The intent is exposed on the parsed request.
    private func parsedIntent(_ json: String) throws -> OpenAIReasoningIntent {
        let body = Data(json.utf8)
        return try QoderChatTranslator.parse(body: body).reasoningIntent
    }

    /// No reasoning fields → `.absent`. The common case.
    func testReasoningIntentAbsentWhenNoField() throws {
        let intent = try parsedIntent(#"{"model":"m","messages":[{"role":"user","content":"hi"}]}"#)
        XCTAssertEqual(intent, .absent)
    }

    /// `reasoning_effort: "high"` (OpenAI shortcut) → enabled(high).
    func testReasoningEffortShortcutString() throws {
        let intent = try parsedIntent(
            #"{"model":"m","messages":[{"role":"user","content":"hi"}],"reasoning_effort":"high"}"#
        )
        XCTAssertEqual(intent, .enabled(effort: "high"))
    }

    /// Unknown effort string clamps to a known tier rather than rejecting.
    func testReasoningEffortClampsUnknown() throws {
        let intent = try parsedIntent(
            #"{"model":"m","messages":[{"role":"user","content":"hi"}],"reasoning_effort":"ultra"}"#
        )
        XCTAssertEqual(intent, .enabled(effort: "max"))
    }

    /// `reasoning_effort: "none"` is a disable alias, not a low tier.
    func testReasoningEffortNoneAliasIsDisabled() throws {
        let intent = try parsedIntent(
            #"{"model":"m","messages":[{"role":"user","content":"hi"}],"reasoning_effort":"none"}"#
        )
        XCTAssertEqual(intent, .disabled, "\"none\" must disable thinking, not enable at low effort")
    }

    /// `reasoning: {effort: "medium"}` (OpenAI object) → enabled(medium).
    func testReasoningObjectForm() throws {
        let intent = try parsedIntent(
            #"{"model":"m","messages":[{"role":"user","content":"hi"}],"reasoning":{"effort":"medium"}}"#
        )
        XCTAssertEqual(intent, .enabled(effort: "medium"))
    }

    /// `reasoning: {exclude: true}` is NOT a thinking toggle in OpenAI semantics
    /// (it controls response content, not whether the model reasons). With no
    /// effort, it falls through to `.absent` — the model still reasons at its
    /// default. This guards against a regression where exclude mapped to disabled.
    func testReasoningExcludeIsNotAThinkingToggle() throws {
        let intent = try parsedIntent(
            #"{"model":"m","messages":[{"role":"user","content":"hi"}],"reasoning":{"exclude":true}}"#
        )
        XCTAssertEqual(intent, .absent, "exclude controls response shape, not reasoning; must stay absent")
    }

    /// `reasoning: {effort: "high", exclude: true}` — effort still wins even
    /// when exclude is present (the model reasons at high effort; exclude only
    /// affects whether the trace is returned, which is the SSE reparser's job).
    func testReasoningEffortWinsOverExclude() throws {
        let intent = try parsedIntent(
            #"{"model":"m","messages":[{"role":"user","content":"hi"}],"reasoning":{"effort":"high","exclude":true}}"#
        )
        XCTAssertEqual(intent, .enabled(effort: "high"))
    }

    /// `reasoning: {}` (empty object) → no signal → absent.
    func testReasoningEmptyObjectIsAbsent() throws {
        let intent = try parsedIntent(
            #"{"model":"m","messages":[{"role":"user","content":"hi"}],"reasoning":{}}"#
        )
        XCTAssertEqual(intent, .absent)
    }

    /// `thinking: {type: "disabled"}` (Anthropic-style) → disabled. Unlike
    /// OpenAI's exclude, this IS a true thinking toggle.
    func testThinkingTypeDisabled() throws {
        let intent = try parsedIntent(
            #"{"model":"m","messages":[{"role":"user","content":"hi"}],"thinking":{"type":"disabled"}}"#
        )
        XCTAssertEqual(intent, .disabled)
    }

    /// `thinking: {type: "enabled", budget_tokens: 8000}` → enabled with an
    /// effort tier derived from the budget.
    func testThinkingEnabledWithBudget() throws {
        let intent = try parsedIntent(
            #"{"model":"m","messages":[{"role":"user","content":"hi"}],"thinking":{"type":"enabled","budget_tokens":8000}}"#
        )
        XCTAssertEqual(intent, .enabled(effort: "medium"))
    }

    /// `thinking: {type: "enabled"}` with no budget → enabled with nil effort
    /// (gateway picks its default tier).
    func testThinkingEnabledNoBudget() throws {
        let intent = try parsedIntent(
            #"{"model":"m","messages":[{"role":"user","content":"hi"}],"thinking":{"type":"enabled"}}"#
        )
        XCTAssertEqual(intent, .enabled(effort: nil))
    }

    /// Unknown `thinking.type` falls through to absent (not a failure).
    func testThinkingUnknownTypeIsAbsent() throws {
        let intent = try parsedIntent(
            #"{"model":"m","messages":[{"role":"user","content":"hi"}],"thinking":{"type":"weird"}}"#
        )
        XCTAssertEqual(intent, .absent)
    }

    /// Precedence: `reasoning_effort` wins over `reasoning` and `thinking`.
    func testReasoningEffortPrecedence() throws {
        let intent = try parsedIntent(
            #"{"model":"m","messages":[{"role":"user","content":"hi"}],"reasoning_effort":"low","reasoning":{"effort":"high"},"thinking":{"type":"enabled","budget_tokens":999999}}"#
        )
        XCTAssertEqual(intent, .enabled(effort: "low"))
    }

    // MARK: - resolveThinking decision table

    /// Non-reasoning model → `.absent` regardless of agent intent. The gateway
    /// can't make `qoder/auto` reason.
    func testResolveThinkingNonReasoningModelAlwaysAbsent() {
        XCTAssertEqual(
            QoderChatTranslator.resolveThinking(intent: .enabled(effort: "high"), modelReasoning: false),
            .absent
        )
        XCTAssertEqual(
            QoderChatTranslator.resolveThinking(intent: .disabled, modelReasoning: false),
            .absent
        )
    }

    /// Reasoning model + absent intent → `.absent` (gateway default). THE key
    /// regression guard: this is the case the two-field struct got wrong.
    func testResolveThinkingReasoningModelAbsentIntent() {
        XCTAssertEqual(
            QoderChatTranslator.resolveThinking(intent: .absent, modelReasoning: true),
            .absent,
            "absent intent on a reasoning model must stay absent (gateway default), not become disabled"
        )
    }

    /// Reasoning model + disabled intent → `.disabled` (force off).
    func testResolveThinkingReasoningModelDisabled() {
        XCTAssertEqual(
            QoderChatTranslator.resolveThinking(intent: .disabled, modelReasoning: true),
            .disabled
        )
    }

    /// Reasoning model + enabled(effort:) → `.enabled(effort:)`.
    func testResolveThinkingReasoningModelEnabledWithEffort() {
        XCTAssertEqual(
            QoderChatTranslator.resolveThinking(intent: .enabled(effort: "xhigh"), modelReasoning: true),
            .enabled(effort: "xhigh")
        )
    }

    /// Reasoning model + enabled(effort: nil) → `.absent` (gateway picks tier).
    func testResolveThinkingReasoningModelEnabledNoEffort() {
        XCTAssertEqual(
            QoderChatTranslator.resolveThinking(intent: .enabled(effort: nil), modelReasoning: true),
            .absent
        )
    }

    // MARK: - thinking_config envelope emission

    /// Helper: parse the `model_config` block out of a translation result.
    private func modelConfigBlock(_ result: QoderTranslationResult) throws -> [String: Any]? {
        let env = try JSONSerialization.jsonObject(with: result.envelopeJSON) as? [String: Any]
        return env?["model_config"] as? [String: Any]
    }

    /// Absent selection → no `thinking_config` key in model_config. Preserves
    /// today's envelope shape for the common case.
    func testEnvelopeNoThinkingConfigWhenAbsent() throws {
        let request = OpenAIChatRequest(
            model: "ultimate",
            messages: [OpenAIChatMessage(role: "user", content: .text("hi"), toolCalls: nil, toolCallID: nil)]
        )
        let result = try QoderChatTranslator.translate(
            request: request, userID: "u", proxyAPIKey: "k",
            modelConfig: QoderModelConfig(key: "ultimate", isReasoning: true, maxOutputTokens: 32768, source: "system"),
            options: .deferringToRandom
        )
        let mc = try modelConfigBlock(result)
        XCTAssertNil(mc?["thinking_config"], "absent selection must not emit thinking_config")
    }

    /// Enabled selection → `{enabled: {effort: ...}}` in model_config.
    func testEnvelopeEmitsEnabledThinkingConfig() throws {
        let body = Data(#"{"model":"ultimate","messages":[{"role":"user","content":"hi"}],"reasoning_effort":"high"}"#.utf8)
        let request = try QoderChatTranslator.parse(body: body)
        let result = try QoderChatTranslator.translate(
            request: request, userID: "u", proxyAPIKey: "k",
            modelConfig: QoderModelConfig(key: "ultimate", isReasoning: true, maxOutputTokens: 32768, source: "system"),
            options: .deferringToRandom
        )
        let mc = try modelConfigBlock(result)
        let tc = mc?["thinking_config"] as? [String: Any]
        let enabled = tc?["enabled"] as? [String: Any]
        let expected: [String: Any] = ["effort": "high"]
        XCTAssertEqual(enabled?["effort"] as? String, expected["effort"] as? String)
    }

    /// Disabled selection → `{disabled: {}}` in model_config.
    func testEnvelopeEmitsDisabledThinkingConfig() throws {
        let body = Data(#"{"model":"ultimate","messages":[{"role":"user","content":"hi"}],"thinking":{"type":"disabled"}}"#.utf8)
        let request = try QoderChatTranslator.parse(body: body)
        let result = try QoderChatTranslator.translate(
            request: request, userID: "u", proxyAPIKey: "k",
            modelConfig: QoderModelConfig(key: "ultimate", isReasoning: true, maxOutputTokens: 32768, source: "system"),
            options: .deferringToRandom
        )
        let mc = try modelConfigBlock(result)
        let tc = mc?["thinking_config"] as? [String: Any]
        XCTAssertNotNil(tc?["disabled"], "disabled selection must emit {disabled: {}}")
    }

    /// Non-reasoning model + enabled intent → no thinking_config (model can't
    /// reason regardless of what the agent asked).
    func testEnvelopeNoThinkingConfigOnNonReasoningModel() throws {
        let body = Data(#"{"model":"auto","messages":[{"role":"user","content":"hi"}],"reasoning_effort":"high"}"#.utf8)
        let request = try QoderChatTranslator.parse(body: body)
        let result = try QoderChatTranslator.translate(
            request: request, userID: "u", proxyAPIKey: "k",
            modelConfig: QoderModelConfig(key: "auto", isReasoning: false, maxOutputTokens: 32768, source: "system"),
            options: .deferringToRandom
        )
        let mc = try modelConfigBlock(result)
        XCTAssertNil(mc?["thinking_config"], "non-reasoning model must never carry thinking_config")
    }

    // MARK: - thinking selection in the recordID cache key

    /// Absent selection hashes identically to the pre-reasoning era — guards
    /// the pi-parity golden vector and existing cache keys. Compares the
    /// four-arg call (which defaults thinking to .absent) against the explicit
    /// five-arg call with .absent.
    func testRecordIDAbsentThinkingMatchesDefault() {
        let msgs = [qmsg("user", "hi")]
        let withoutArg = QoderChatTranslator.stableChatRecordID(
            model: "m", messages: msgs, toolsJSON: "", maxTokens: 32768
        )
        let explicitAbsent = QoderChatTranslator.stableChatRecordID(
            model: "m", messages: msgs, toolsJSON: "", maxTokens: 32768, thinking: .absent
        )
        XCTAssertEqual(withoutArg, explicitAbsent)
    }

    /// Different effort tiers fork the cache key — two requests to the same
    /// reasoning model with low vs high effort get distinct recordIDs.
    func testRecordIDVariesByEffortTier() {
        let msgs = [qmsg("user", "hi")]
        let low = QoderChatTranslator.stableChatRecordID(
            model: "ultimate", messages: msgs, toolsJSON: "", maxTokens: 32768, thinking: .enabled(effort: "low")
        )
        let high = QoderChatTranslator.stableChatRecordID(
            model: "ultimate", messages: msgs, toolsJSON: "", maxTokens: 32768, thinking: .enabled(effort: "high")
        )
        XCTAssertNotEqual(low, high, "different effort tiers must fork the cache key")
    }

    /// Enabled vs disabled fork the cache key too.
    func testRecordIDVariesEnabledVsDisabled() {
        let msgs = [qmsg("user", "hi")]
        let enabled = QoderChatTranslator.stableChatRecordID(
            model: "ultimate", messages: msgs, toolsJSON: "", maxTokens: 32768, thinking: .enabled(effort: "high")
        )
        let disabled = QoderChatTranslator.stableChatRecordID(
            model: "ultimate", messages: msgs, toolsJSON: "", maxTokens: 32768, thinking: .disabled
        )
        XCTAssertNotEqual(enabled, disabled)
    }

    // MARK: - Tier 2 semantic caps (issue #14)

    /// Tight limits used by the cap tests so each boundary is exact and the
    /// tests don't depend on the (much larger) production defaults.
    private static let tightLimits = QoderTranslatorLimits(
        maxMessages: 3,
        maxImageBytes: 100,
        maxTools: 2,
        maxToolSchemaBytes: 50
    )

    /// Convenience: translate with the tight test limits + throwaway defaults.
    private func translateWithTightLimits(_ request: OpenAIChatRequest) throws -> QoderTranslationResult {
        try QoderChatTranslator.translate(
            request: request,
            userID: "u",
            proxyAPIKey: "k",
            modelConfig: QoderModelConfig(key: "m", isReasoning: false, maxOutputTokens: 32768, source: "system"),
            options: .deferringToRandom,
            limits: Self.tightLimits
        )
    }

    /// Asserts the thrown error is the expected limit kind + maps to the
    /// expected HTTP status. Centralizes the throw-shape assertion so each cap
    /// test reads as one line.
    private func assertLimitError(
        _ block: () throws -> QoderTranslationResult,
        expectedStatus: Int,
        kindDescriptionContains needle: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        do {
            _ = try block()
            XCTFail("expected limit error, request was accepted", file: file, line: line)
        } catch let error as QoderTranslatorError {
            XCTAssertEqual(error.httpStatus, expectedStatus, "status mismatch: \(error)", file: file, line: line)
            XCTAssertTrue(
                error.localizedDescription.contains(needle),
                "error message should name '\(needle)': got \(error.localizedDescription)",
                file: file, line: line
            )
        } catch {
            XCTFail("expected QoderTranslatorError, got \(error)", file: file, line: line)
        }
    }

    // -- Message count cap ---------------------------------------------------

    /// At-limit message count is accepted (tight limit = 3, send exactly 3).
    func testMessageCountAtLimitAccepted() throws {
        let msgs = (0..<3).map {
            OpenAIChatMessage(role: "user", content: .text("m\($0)"), toolCalls: nil, toolCallID: nil)
        }
        let request = OpenAIChatRequest(model: "m", messages: msgs, tools: nil, maxTokens: nil)
        _ = try translateWithTightLimits(request)  // does not throw
    }

    /// Over-limit message count is rejected with 400 + the message-count error.
    func testMessageCountOverLimitRejected() {
        let msgs = (0..<4).map {
            OpenAIChatMessage(role: "user", content: .text("m\($0)"), toolCalls: nil, toolCallID: nil)
        }
        let request = OpenAIChatRequest(model: "m", messages: msgs, tools: nil, maxTokens: nil)
        assertLimitError(
            { try translateWithTightLimits(request) },
            expectedStatus: 400,
            kindDescriptionContains: "messages"
        )
    }

    /// The error reports the actual count and the limit, but not message content.
    func testMessageCountErrorNamesLimitAndActualNotContent() {
        let msgs = (0..<5).map { _ in
            OpenAIChatMessage(role: "user", content: .text("SECRET"), toolCalls: nil, toolCallID: nil)
        }
        let request = OpenAIChatRequest(model: "m", messages: msgs, tools: nil, maxTokens: nil)
        do {
            _ = try translateWithTightLimits(request)
            XCTFail("expected throw")
        } catch let error as QoderTranslatorError {
            let msg = error.localizedDescription
            XCTAssertTrue(msg.contains("5"), "should report actual count 5: \(msg)")
            XCTAssertTrue(msg.contains("3"), "should report limit 3: \(msg)")
            XCTAssertFalse(msg.contains("SECRET"), "error must not echo request content: \(msg)")
        } catch {
            XCTFail("expected QoderTranslatorError, got \(error)")
        }
    }

    // -- Image size cap ------------------------------------------------------

    /// Helper: an OpenAIChatRequest with a single user message carrying one
    /// image_url part with the given URL string.
    private func requestWithImageURL(_ urlString: String) -> OpenAIChatRequest {
        OpenAIChatRequest(
            model: "m",
            messages: [OpenAIChatMessage(
                role: "user",
                content: .parts([.imageURL(URL(string: urlString)!)]),
                toolCalls: nil,
                toolCallID: nil
            )],
            tools: nil,
            maxTokens: nil
        )
    }

    /// At-limit image size (base64 decoded) is accepted. Tight cap = 100 bytes;
    /// 100 bytes of base64-decoded payload = ~134 base64 chars.
    func testImageSizeAtLimitAccepted() throws {
        // 100 zero bytes → base64 "AAAA..." (134 chars including padding).
        let payload = Data(repeating: 0x41, count: 100).base64EncodedString()
        let url = "data:image/png;base64,\(payload)"
        // Sanity: the decoded size really is 100.
        XCTAssertEqual(Data(base64Encoded: payload)?.count, 100)
        _ = try translateWithTightLimits(requestWithImageURL(url))
    }

    /// Over-limit image size (base64 decoded) is rejected with 413.
    func testImageSizeOverLimitRejected() {
        // 101 bytes → just over the 100-byte cap.
        let payload = Data(repeating: 0x41, count: 101).base64EncodedString()
        let url = "data:image/png;base64,\(payload)"
        assertLimitError(
            { try translateWithTightLimits(requestWithImageURL(url)) },
            expectedStatus: 413,
            kindDescriptionContains: "image_url"
        )
    }

    /// The image cap measures the DECODED byte length, not the on-wire base64
    /// length — a 4/3 inflation must not sneak a too-large image past the cap.
    /// Tight cap = 100 bytes; 80 raw bytes encode to ~108 base64 chars (under
    /// 100 if measured as chars, over 100 only when decoded). This guards that
    /// we decode rather than string-counting the data URL.
    func testImageSizeMeasuresDecodedBase64NotWireLength() {
        // 200 raw bytes → 268 base64 chars. Decoded = 200 > 100 cap. If we were
        // measuring wire length we'd still reject (268 > 100), so to truly test
        // the decode path use a size that's over-cap when decoded but whose
        // base64 substring is longer than the cap either way. The point of this
        // test is that the decoded count appears in the error message.
        let raw = Data(repeating: 0x42, count: 150)
        let payload = raw.base64EncodedString()
        let url = "data:image/png;base64,\(payload)"
        do {
            _ = try translateWithTightLimits(requestWithImageURL(url))
            XCTFail("expected throw")
        } catch let error as QoderTranslatorError {
            XCTAssertEqual(error.httpStatus, 413)
            // The actual decoded size (150) must be reported, proving we decoded.
            XCTAssertTrue(error.localizedDescription.contains("150"), "got \(error.localizedDescription)")
        } catch {
            XCTFail("expected QoderTranslatorError, got \(error)")
        }
    }

    /// A plain http(s) URL image is capped by URL string length (proxy for
    /// payload size — real URLs are tiny). Tight cap = 100 bytes; a 101-char
    /// URL is over.
    func testImageSizeHTTPSURLCappedByStringLength() {
        let longURL = "https://example.com/" + String(repeating: "x", count: 90)  // > 100 chars total
        XCTAssertTrue(longURL.utf8.count > 100)
        assertLimitError(
            { try translateWithTightLimits(requestWithImageURL(longURL)) },
            expectedStatus: 413,
            kindDescriptionContains: "image_url"
        )
    }

    /// A small plain https URL image is accepted.
    func testImageSizeSmallHTTPSURLAccepted() throws {
        _ = try translateWithTightLimits(requestWithImageURL("https://e.co/x.png"))
    }

    /// A small data URL image is accepted (the common case — inline screenshots).
    func testImageSizeSmallDataURLAccepted() throws {
        let payload = Data(repeating: 0x41, count: 10).base64EncodedString()
        _ = try translateWithTightLimits(requestWithImageURL("data:image/png;base64,\(payload)"))
    }

    /// Image cap applies to tool-result messages too (a screenshot-returning
    /// tool includes image_url parts in a role:tool message). Over-limit there
    /// is also rejected.
    func testImageSizeCapAppliesToToolResultMessages() {
        let payload = Data(repeating: 0x41, count: 101).base64EncodedString()
        let url = "data:image/png;base64,\(payload)"
        let request = OpenAIChatRequest(
            model: "m",
            messages: [OpenAIChatMessage(
                role: "tool",
                content: .parts([.text("note"), .imageURL(URL(string: url)!)]),
                toolCalls: nil,
                toolCallID: "tc1"
            )],
            tools: nil,
            maxTokens: nil
        )
        assertLimitError(
            { try translateWithTightLimits(request) },
            expectedStatus: 413,
            kindDescriptionContains: "image_url"
        )
    }

    // -- Tools count cap -----------------------------------------------------

    private func requestWithTools(_ count: Int) -> OpenAIChatRequest {
        let tools = (0..<count).map { i in
            OpenAITool(function: OpenAIToolDefinition(
                name: "t\(i)", description: nil, parameters: Data("{}".utf8)
            ))
        }
        return OpenAIChatRequest(
            model: "m",
            messages: [OpenAIChatMessage(role: "user", content: .text("hi"), toolCalls: nil, toolCallID: nil)],
            tools: tools,
            maxTokens: nil
        )
    }

    /// At-limit tool count is accepted (tight cap = 2).
    func testToolCountAtLimitAccepted() throws {
        _ = try translateWithTightLimits(requestWithTools(2))
    }

    /// Over-limit tool count is rejected with 400.
    func testToolCountOverLimitRejected() {
        assertLimitError(
            { try translateWithTightLimits(requestWithTools(3)) },
            expectedStatus: 400,
            kindDescriptionContains: "tools"
        )
    }

    // -- Per-tool schema size cap -------------------------------------------

    /// Helper: a request with one tool whose `parameters` JSON Schema serializes
    /// to *exactly* `targetBytes` (within JSON's determinism for this shape).
    /// Builds `{"description":"<pad>"}` and grows the pad until the serialized
    /// form hits the target. The parser round-trips the schema through
    /// JSONSerialization, so the byte length is stable for this key/value shape.
    /// `targetBytes` must be ≥ the skeleton `{"description":""}` length (19).
    private func requestWithToolSchemaSize(_ targetBytes: Int) -> OpenAIChatRequest {
        // Grow the pad until the serialized form equals the target. Tolerates
        // JSON escape differences by measuring the real output each iteration.
        var padLen = 0
        var schemaData: Data
        repeat {
            let pad = String(repeating: "x", count: padLen)
            schemaData = (try! JSONSerialization.data(withJSONObject: ["description": pad]))
            if schemaData.count == targetBytes { break }
            padLen += 1
        } while schemaData.count < targetBytes
        // The at-limit test relies on exactness; assert it here so a future
        // Foundation change that shifts serialization surfaces loudly.
        XCTAssertEqual(schemaData.count, targetBytes, "schema must serialize to exactly \(targetBytes) bytes")
        let tool = OpenAITool(function: OpenAIToolDefinition(
            name: "big", description: nil, parameters: schemaData
        ))
        return OpenAIChatRequest(
            model: "m",
            messages: [OpenAIChatMessage(role: "user", content: .text("hi"), toolCalls: nil, toolCallID: nil)],
            tools: [tool],
            maxTokens: nil
        )
    }

    /// At-limit tool schema size is accepted. Tight cap = 50 bytes; build a
    /// schema that serializes to *exactly* 50 bytes so the `>` boundary is
    /// genuinely pinned (cap+1 would reject; cap must not).
    func testToolSchemaSizeAtLimitAccepted() throws {
        let request = requestWithToolSchemaSize(50)  // exactly the cap
        _ = try translateWithTightLimits(request)
    }

    /// Over-limit tool schema size is rejected with 413. Cap+1 byte.
    func testToolSchemaSizeOverLimitRejected() {
        let request = requestWithToolSchemaSize(51)  // 51 = cap + 1
        assertLimitError(
            { try translateWithTightLimits(request) },
            expectedStatus: 413,
            kindDescriptionContains: "tool schema"
        )
    }

    /// The schema-size error names the byte count + limit, not the schema.
    func testToolSchemaSizeErrorNamesBytesNotContent() {
        let request = requestWithToolSchemaSize(51)
        do {
            _ = try translateWithTightLimits(request)
            XCTFail("expected throw")
        } catch let error as QoderTranslatorError {
            let msg = error.localizedDescription
            XCTAssertTrue(msg.contains("50"), "should report limit 50: \(msg)")
            XCTAssertFalse(msg.contains("xxx"), "error must not echo schema content: \(msg)")
        } catch {
            XCTFail("expected QoderTranslatorError, got \(error)")
        }
    }

    // -- Production defaults sanity -----------------------------------------

    /// Production defaults are the values documented in the issue and ADR 0013.
    /// Pins them so a future edit can't silently shrink them.
    /// (Raised in the "raise translator default limits" change: 999 messages /
    /// 90 MiB images / 999 tools / 5 MiB tool schemas.)
    func testProductionDefaultsMatchIssue14() {
        let d = QoderTranslatorLimits.default
        XCTAssertEqual(d.maxMessages, 999)
        XCTAssertEqual(d.maxImageBytes, 90 * 1024 * 1024)
        XCTAssertEqual(d.maxTools, 999)
        XCTAssertEqual(d.maxToolSchemaBytes, 5 * 1024 * 1024)
    }

    /// Defaults are injectable and a request that's over the tight limit but
    /// under the production limit is accepted under `.default` — proving the
    /// tight-limit rejections above are about the injected limits, not a hard
    /// structural cap.
    func testDefaultsAreInjectableAndMorePermissive() throws {
        // 4 messages: rejected by tightLimits (cap 3), accepted by .default.
        let msgs = (0..<4).map {
            OpenAIChatMessage(role: "user", content: .text("m\($0)"), toolCalls: nil, toolCallID: nil)
        }
        let request = OpenAIChatRequest(model: "m", messages: msgs, tools: nil, maxTokens: nil)
        XCTAssertThrowsError(try translateWithTightLimits(request))
        _ = try QoderChatTranslator.translate(
            request: request,
            userID: "u", proxyAPIKey: "k",
            modelConfig: QoderModelConfig(key: "m", isReasoning: false, maxOutputTokens: 32768, source: "system"),
            options: .deferringToRandom,
            limits: .default
        )
    }

    // -- Status code propagation through QoderFailoverError -----------------

    /// The translator error's httpStatus flows through QoderFailoverError so
    /// that a size overage surfaces as 413 (not the historical hard-coded 400).
    /// This is the contract ProxyBridge relies on to send the right status.
    func testFailoverErrorSurfacesTranslatorStatusForSizeCap() {
        // 413 path: image size overage.
        let payload = Data(repeating: 0x41, count: 101).base64EncodedString()
        let url = "data:image/png;base64,\(payload)"
        let request = requestWithImageURL(url)
        do {
            _ = try translateWithTightLimits(request)
            XCTFail("expected throw")
        } catch let error as QoderTranslatorError {
            let failover = QoderFailoverError.requestRejected(
                error.localizedDescription, status: error.httpStatus
            )
            XCTAssertEqual(failover.httpStatus, 413)
        } catch {
            XCTFail("expected QoderTranslatorError, got \(error)")
        }
    }

    func testFailoverErrorDefaultsTo400ForMalformed() {
        // The default status (used by missing-model, gateway HTTP errors, etc.)
        // is 400 — guards the backward-compatible shape for non-translator
        // rejections.
        let e = QoderFailoverError.requestRejected("missing model")
        XCTAssertEqual(e.httpStatus, 400)
    }
}
