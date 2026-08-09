//
//  QoderResponsesTranslator.swift
//  Quotio
//
//  Input translator for the OpenAI Responses API path (issue #11 Task A).
//
//  The OpenAI Responses API (`POST /v1/responses`) carries a different request
//  shape than Chat Completions: `input` is an array of typed items
//  (`message`, `function_call`, `function_call_output`, ...) and the top-level
//  `instructions` field is the Responses instruction channel. Qoder's gateway
//  only speaks Chat Completions, so Quotio's strategy (ADR 0014 + this issue)
//  is to synthesize the equivalent Chat Completions body and reuse the entire
//  Chat path downstream — message transform (`transformMessagesForQoder`),
//  COSY signing, failover, and the SSE reparser. This translator produces the
//  input that feeds `translate`; Task B (issue #11) wires it into the dispatch.
//
//  Reuse decision: this translator emits an `OpenAIChatRequest` — the SAME DTO
//  `QoderChatTranslator.parse(body:)` produces — by reusing the DTOs declared
//  in `QoderChatTranslator.swift` (`OpenAIChatRequest`, `OpenAIChatMessage`,
//  `OpenAIContent`, ...). It does NOT re-run `transformMessagesForQoder`; that
//  runs as part of `translate` later in the pipeline. It does NOT duplicate the
//  DTOs — one source of truth for the Chat path's input shape.
//
//  Pure value type — no I/O, no actor state, no globals. `nonisolated enum`
//  with static methods, mirroring `QoderChatTranslator`'s declaration style so
//  the translator opts out of the project's MainActor default and is callable
//  from any isolation domain (ProxyBridge is an `actor`). JSON parsing uses the
//  same `JSONSerialization` + `guard let dict as? [String: Any]` idiom as
//  `QoderChatTranslator.parse(body:)`, with the same indexed error messages.
//

import Foundation

/// Pure translator: OpenAI Responses API request body → Chat Completions
/// request DTO (`OpenAIChatRequest`). Task B (issue #11) synthesizes a Chat
/// Completions JSON body from this and hands it to
/// `QoderFailoverRouter.openStream(requestBody:proxyAPIKey:)`, reusing the
/// entire Chat path (message transform, COSY, failover, SSE reparser).
///
/// Translation rules (Responses `input` → Chat `messages`):
///   - `input: "hi"` (string shorthand) → one `role: "user"` message.
///   - `input: [{type: "message", role, content}]` → one message per item,
///     content flattened from text parts and mapped from image parts.
///   - `input: [{type: "function_call", call_id, name, arguments}]` → an
///     assistant message carrying a single tool call (id = call_id).
///   - `input: [{type: "function_call_output", call_id, output}]` → a
///     `role: "tool"` message with `toolCallID = call_id`.
///   - Unknown item types are skipped (matching the translator's existing
///     skip-unknown policy), not thrown.
///   - Top-level `instructions`, if present, PREPENDS a `role: "developer"`
///     message. The `developer`→`system` normalization is already handled by
///     `transformMessagesForQoder` (issue #17), so emit `developer` here.
///   - `max_output_tokens` (Responses spelling) → `maxTokens`.
///   - `reasoning_effort` / `reasoning` / `thinking` map to `reasoningIntent`
///     via the SAME vocabulary `QoderChatTranslator` reads (issue #17).
nonisolated enum QoderResponsesTranslator {

    // MARK: - Entry points

    /// Parse an OpenAI Responses API request body into a Chat Completions
    /// request DTO. Reuses the existing `OpenAIChatRequest` shape so downstream
    /// (translate, COSY, failover) is identical to the Chat path.
    static func parseResponses(body: Data) throws -> OpenAIChatRequest {
        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: body)
        } catch {
            throw QoderTranslatorError.malformedRequest("body is not valid JSON")
        }
        guard let dict = json as? [String: Any] else {
            throw QoderTranslatorError.malformedRequest("body is not a JSON object")
        }
        guard let model = dict["model"] as? String, !model.isEmpty else {
            throw QoderTranslatorError.malformedRequest("missing or empty 'model'")
        }

        var messages: [OpenAIChatMessage] = []

        // Responses' instruction channel. Prepended (as role:"developer") so it
        // becomes the first message; transformMessagesForQoder folds developer
        // into system downstream (issue #17). Only emitted when non-empty.
        if let instructions = dict["instructions"] as? String, !instructions.isEmpty {
            messages.append(OpenAIChatMessage(
                role: "developer",
                content: .text(instructions),
                toolCalls: nil,
                toolCallID: nil
            ))
        }

        // `input` may be a string (single-user-turn shorthand) or an array of
        // typed items. Missing `input` is only acceptable when `instructions`
        // carried the conversation (rare but legal) — otherwise there is no
        // turn to send.
        let hadInstructions = !messages.isEmpty
        if let inputStr = dict["input"] as? String {
            messages.append(OpenAIChatMessage(
                role: "user",
                content: .text(inputStr),
                toolCalls: nil,
                toolCallID: nil
            ))
        } else if let inputArr = dict["input"] as? [Any] {
            for (idx, raw) in inputArr.enumerated() {
                guard let item = raw as? [String: Any] else {
                    throw QoderTranslatorError.malformedRequest("input[\(idx)] is not an object")
                }
                if let msg = try? parseMessageItem(item, idx: idx) {
                    messages.append(msg)
                }
                // Unknown item types fall through `parseMessageItem` and return
                // nil — matching the skip-unknown policy from
                // transformMessagesForQoder's default branch.
            }
        } else if !hadInstructions {
            throw QoderTranslatorError.malformedRequest(
                "missing 'input' and 'instructions' (need at least one)"
            )
        }

        // Tools translate verbatim (Responses tools shape == Chat tools shape
        // for function tools). Reuse QoderChatTranslator's parser so the
        // parameter round-tripping stays in one place.
        let tools: [OpenAITool]?
        if let rawTools = dict["tools"] as? [Any] {
            tools = try rawTools.enumerated().map { idx, raw in
                try parseToolItem(raw, idx: idx)
            }
        } else {
            tools = nil
        }

        // Responses spells it `max_output_tokens`; tolerate the Chat spellings
        // too (an OpenAI client mixing fields is not an error, just metadata).
        let maxTokens = (dict["max_output_tokens"] as? Int)
            ?? (dict["max_tokens"] as? Int)
            ?? (dict["max_completion_tokens"] as? Int)

        // Reasoning intent uses the SAME vocabulary as Chat (issue #17):
        // reasoning_effort / reasoning / thinking. parseReasoningIntent is
        // private on QoderChatTranslator; re-derive here via the same rules so
        // the Responses path does not grow a divergent vocabulary.
        let reasoningIntent = parseReasoningIntent(from: dict)

        return OpenAIChatRequest(
            model: model,
            messages: messages,
            tools: tools,
            maxTokens: maxTokens,
            reasoningIntent: reasoningIntent
        )
    }

    /// Convenience: parse + re-serialize as a Chat Completions JSON body, ready
    /// for `QoderFailoverRouter.openStream(requestBody:proxyAPIKey:)`. Preserves
    /// model/tools/maxTokens/reasoningIntent and emits the synthesized messages
    /// array. The output is byte-stable per input (no random IDs — the
    /// translator's randomness lives in `translate`, downstream of this call).
    static func synthesizeChatBody(from body: Data) throws -> Data {
        let request = try parseResponses(body: body)
        var dict: [String: Any] = [
            "model": request.model,
            "messages": request.messages.map(messageToJSONObject),
        ]
        if let tools = request.tools {
            dict["tools"] = tools.map(toolToJSONObject)
        }
        if let maxTokens = request.maxTokens {
            // Emit the Chat-Completions-native spelling; the failover router's
            // translator accepts both, but `max_completion_tokens` is current.
            dict["max_completion_tokens"] = maxTokens
            dict["max_tokens"] = maxTokens
        }
        switch request.reasoningIntent {
        case .absent:
            break
        case .disabled:
            dict["reasoning_effort"] = "none"
        case .enabled(let effort):
            dict["reasoning_effort"] = effort ?? "medium"
        }
        return try JSONSerialization.data(withJSONObject: dict)
    }

    // MARK: - Input item parsing

    /// Parse one Responses `input[]` item. Returns nil for unknown item types
    /// (skip-unknown policy); throws for malformed shapes of known types.
    private static func parseMessageItem(_ item: [String: Any], idx: Int) throws -> OpenAIChatMessage? {
        let type = (item["type"] as? String) ?? "message"
        switch type {
        case "message":
            return try parseMessageRoleItem(item, idx: idx)
        case "function_call":
            return try parseFunctionCallItem(item, idx: idx)
        case "function_call_output":
            return try parseFunctionCallOutputItem(item, idx: idx)
        default:
            // Unknown item type: skip (do not throw), mirroring
            // transformMessagesForQoder's skip-unknown-role branch.
            return nil
        }
    }

    /// `type: "message"`: a conversational turn. `role` is one of
    /// user/system/developer/assistant/tool; `content` is an array of parts
    /// (`{type:"text"|"input_text"|"output_text", text}` or
    /// `{type:"input_image", image_url}`) or a plain string (OpenAI permits
    /// `content: "hi"` on input message items).
    private static func parseMessageRoleItem(_ item: [String: Any], idx: Int) throws -> OpenAIChatMessage {
        guard let role = item["role"] as? String, !role.isEmpty else {
            throw QoderTranslatorError.malformedRequest("input[\(idx)] message item missing 'role'")
        }
        let content: OpenAIContent?
        if item["content"] == nil || item["content"] is NSNull {
            content = nil
        } else if let s = item["content"] as? String {
            content = .text(s)
        } else if let arr = item["content"] as? [Any] {
            let parts: [OpenAIContentPart] = try arr.enumerated().map { pidx, praw in
                guard let pdict = praw as? [String: Any] else {
                    throw QoderTranslatorError.malformedRequest(
                        "input[\(idx)].content[\(pidx)] is not an object"
                    )
                }
                return try parseContentPart(pdict, idx: idx, pidx: pidx)
            }
            // Flatten single-text-part content to .text for parity with
            // QoderChatTranslator's parseMessage (which preserves .parts); we
            // keep .parts so image-bearing messages survive transform unchanged.
            content = .parts(parts)
        } else {
            throw QoderTranslatorError.malformedRequest("input[\(idx)].content has unsupported type")
        }
        return OpenAIChatMessage(role: role, content: content, toolCalls: nil, toolCallID: nil)
    }

    /// Parse one content part. Responses carries text under several type names
    /// (`text` for system/assistant, `input_text` for user inputs,
    /// `output_text` for assistant outputs); all map to `.text`. Image parts
    /// (`input_image`) carry `image_url` either as a string or as the OpenAI
    /// `{url: ...}` object form — both are accepted.
    private static func parseContentPart(_ dict: [String: Any], idx: Int, pidx: Int) throws -> OpenAIContentPart {
        guard let type = dict["type"] as? String else {
            throw QoderTranslatorError.malformedRequest(
                "input[\(idx)].content[\(pidx)] missing 'type'"
            )
        }
        switch type {
        case "text", "input_text", "output_text":
            guard let text = dict["text"] as? String else {
                throw QoderTranslatorError.malformedRequest(
                    "input[\(idx)].content[\(pidx)] text part missing 'text'"
                )
            }
            return .text(text)
        case "input_image", "image_url":
            // `input_image` carries `image_url` as a string (Responses) or as
            // `{url: ...}` (Chat). Accept both.
            let urlString: String?
            if let s = dict["image_url"] as? String {
                urlString = s
            } else if let obj = dict["image_url"] as? [String: Any] {
                urlString = obj["url"] as? String
            } else {
                urlString = nil
            }
            guard let s = urlString, let url = URL(string: s) else {
                throw QoderTranslatorError.malformedRequest(
                    "input[\(idx)].content[\(pidx)] image part has no valid 'image_url'"
                )
            }
            return .imageURL(url)
        default:
            throw QoderTranslatorError.malformedRequest(
                "input[\(idx)].content[\(pidx)] unsupported part type '\(type)'"
            )
        }
    }

    /// `type: "function_call"`: an assistant's prior tool call. Maps to an
    /// assistant message carrying one tool call, mirroring how
    /// `QoderChatTranslator.parseMessage` handles assistant `tool_calls`. The
    /// Responses `call_id` becomes the OpenAI tool_call `id` (the value the
    /// subsequent `function_call_output` correlates on).
    private static func parseFunctionCallItem(_ item: [String: Any], idx: Int) throws -> OpenAIChatMessage {
        let callID = (item["call_id"] as? String) ?? ""
        let name = (item["name"] as? String) ?? ""
        // `arguments` is a JSON string on both wire shapes. Default to "" when
        // absent — matches QoderChatTranslator.parseToolCall's tolerance.
        let arguments = (item["arguments"] as? String) ?? ""
        let toolCall = OpenAIToolCall(
            id: callID,
            function: OpenAIToolFunction(name: name, arguments: arguments)
        )
        return OpenAIChatMessage(
            role: "assistant",
            content: nil,
            toolCalls: [toolCall],
            toolCallID: nil
        )
    }

    /// `type: "function_call_output"`: a tool's result. Maps to a
    /// `role: "tool"` message with `toolCallID = call_id`. `output` is a string
    /// in the Responses shape; coerce non-string outputs to a JSON string so
    /// the Chat `tool` content (always a string) round-trips losslessly.
    private static func parseFunctionCallOutputItem(_ item: [String: Any], idx: Int) throws -> OpenAIChatMessage {
        let callID = (item["call_id"] as? String) ?? ""
        let output: String
        if let s = item["output"] as? String {
            output = s
        } else if let anyObj = item["output"] {
            // Non-string output (object/array/number): re-serialize so the tool
            // message content is always a JSON string, as Chat Completions
            // requires. Fallback to "" on serialization failure.
            if let data = try? JSONSerialization.data(withJSONObject: anyObj),
               let s = String(data: data, encoding: .utf8) {
                output = s
            } else {
                output = ""
            }
        } else {
            output = ""
        }
        return OpenAIChatMessage(
            role: "tool",
            content: .text(output),
            toolCalls: nil,
            toolCallID: callID
        )
    }

    /// Parse a Responses-shaped tool entry. Responses tool definitions nest
    /// under `function` like Chat's do (OpenAI unified the shape), but the
    /// function description is sometimes absent. Reuses the same parameter
    /// round-tripping as `QoderChatTranslator.parseTool`.
    private static func parseToolItem(_ raw: Any, idx: Int) throws -> OpenAITool {
        guard let dict = raw as? [String: Any] else {
            throw QoderTranslatorError.malformedRequest("tools[\(idx)] is not an object")
        }
        // Responses wraps function tools under either `function` (Chat-shape)
        // or flat (name/description/parameters directly). Accept both.
        let funcDict = (dict["function"] as? [String: Any]) ?? dict
        guard let name = funcDict["name"] as? String else {
            throw QoderTranslatorError.malformedRequest("tools[\(idx)] missing 'name'")
        }
        let parameters: Data
        if let params = funcDict["parameters"] {
            parameters = try JSONSerialization.data(withJSONObject: params)
        } else {
            parameters = Data("{}".utf8)
        }
        return OpenAITool(
            function: OpenAIToolDefinition(
                name: name,
                description: funcDict["description"] as? String,
                parameters: parameters
            )
        )
    }

    // MARK: - Reasoning intent

    /// Re-derives the agent's reasoning intent using the SAME vocabulary
    /// `QoderChatTranslator` recognizes (issue #17): `reasoning_effort` (string
    /// shortcut) → `reasoning: {effort, exclude}` (object) → `thinking: {type,
    /// budget_tokens}`. Centralized here (not bridged through
    /// `QoderChatTranslator.parseReasoningIntent`, which is file-private and
    /// takes the body dict post-parse) so the Responses path stays self-
    /// contained for its input shape while honoring the same vocabulary.
    ///
    /// The disable-clamp (`none`/`off`/`minimal` → `.disabled`) and tier
    /// clamping (`low/medium/high/xhigh/max` + aliases) mirror
    /// `QoderChatTranslator` exactly; deviations would cause two agents
    /// sending the same intent to get different thinking selections depending
    /// on which endpoint they hit, which is a correctness bug.
    private static func parseReasoningIntent(from dict: [String: Any]) -> OpenAIReasoningIntent {
        if let effortStr = dict["reasoning_effort"] as? String, !effortStr.isEmpty {
            if isDisableAlias(effortStr) { return .disabled }
            return .enabled(effort: clampEffort(effortStr))
        }
        if let reasoning = dict["reasoning"] as? [String: Any] {
            if let effortStr = reasoning["effort"] as? String, !effortStr.isEmpty {
                if isDisableAlias(effortStr) { return .disabled }
                return .enabled(effort: clampEffort(effortStr))
            }
        }
        if let thinking = dict["thinking"] as? [String: Any] {
            let type = (thinking["type"] as? String) ?? ""
            switch type {
            case "disabled":
                return .disabled
            case "enabled":
                if let budget = thinking["budget_tokens"] as? Int, budget > 0 {
                    return .enabled(effort: effortForBudget(budget))
                }
                return .enabled(effort: nil)
            default:
                break
            }
        }
        return .absent
    }

    /// Whether an effort-string value is a "turn thinking off" signal. Mirrors
    /// `QoderChatTranslator.isDisableAlias` so both endpoints agree on which
    /// strings mean "disable" vs. "low effort."
    private static func isDisableAlias(_ raw: String) -> Bool {
        switch raw.lowercased() {
        case "none", "off", "disable", "disabled", "false":
            return true
        default:
            return false
        }
    }

    /// Map an arbitrary effort string onto one of Qoder's five tiers. Mirrors
    /// `QoderChatTranslator.clampEffort`; `minimal` clamps to `low` (NOT
    /// `.disabled`) because the caller already passed the disable check.
    private static func clampEffort(_ raw: String) -> String {
        let known: Set<String> = ["low", "medium", "high", "xhigh", "max"]
        let lowered = raw.lowercased()
        if known.contains(lowered) { return lowered }
        switch lowered {
        case "minimal":
            return "low"
        case "standard", "normal", "default", "auto":
            return "medium"
        case "ultra", "extreme", "maximum", "best", "strong":
            return "max"
        default:
            return "medium"
        }
    }

    /// Map an Anthropic-style `budget_tokens` to the nearest Qoder tier. Mirrors
    /// `QoderChatTranslator.effortForBudget`.
    private static func effortForBudget(_ budget: Int) -> String {
        switch budget {
        case ..<4096: return "low"
        case ..<16384: return "medium"
        case ..<65536: return "high"
        case ..<262144: return "xhigh"
        default: return "max"
        }
    }

    // MARK: - Serialization helpers

    /// Serialize one `OpenAIChatMessage` to its Chat Completions JSON-object
    /// form. Mirrors the wire shape `QoderChatTranslator.parseMessage` ingests
    /// so the synthesized body round-trips through `translate` cleanly.
    private static func messageToJSONObject(_ msg: OpenAIChatMessage) -> [String: Any] {
        var dict: [String: Any] = ["role": msg.role]
        switch msg.content {
        case .none:
            dict["content"] = NSNull()
        case .text(let s):
            dict["content"] = s
        case .parts(let parts):
            dict["content"] = parts.map(partToJSONObject)
        }
        if let toolCalls = msg.toolCalls, !toolCalls.isEmpty {
            dict["tool_calls"] = toolCalls.map { tc in
                [
                    "id": tc.id,
                    "type": "function",
                    "function": [
                        "name": tc.function.name,
                        "arguments": tc.function.arguments,
                    ],
                ] as [String: Any]
            }
        }
        if let toolCallID = msg.toolCallID {
            dict["tool_call_id"] = toolCallID
        }
        return dict
    }

    /// Serialize one `OpenAIContentPart` to its OpenAI-shape JSON object.
    /// Shared by `messageToJSONObject` so the parts surface can't drift from
    /// what `parseContentPart` ingests.
    private static func partToJSONObject(_ part: OpenAIContentPart) -> [String: Any] {
        switch part {
        case .text(let t):
            return ["type": "text", "text": t]
        case .imageURL(let url):
            return ["type": "image_url", "image_url": ["url": url.absoluteString]] as [String: Any]
        }
    }

    /// Serialize one `OpenAITool` to its Chat Completions JSON-object form.
    /// Parameters round-trip through `JSONSerialization` so arbitrary schemas
    /// survive verbatim — same approach as `QoderChatTranslator.parseTool`.
    private static func toolToJSONObject(_ tool: OpenAITool) -> [String: Any] {
        var function: [String: Any] = ["name": tool.function.name]
        if let description = tool.function.description {
            function["description"] = description
        }
        if let parsed = try? JSONSerialization.jsonObject(with: tool.function.parameters) {
            function["parameters"] = parsed
        } else {
            function["parameters"] = [String: Any]()
        }
        return ["type": "function", "function": function] as [String: Any]
    }
}
