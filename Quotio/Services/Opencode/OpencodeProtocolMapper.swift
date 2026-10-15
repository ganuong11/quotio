//
//  OpencodeProtocolMapper.swift
//  Quotio
//
//  Cross-surface request translation for the opencode branch (ADR 0021).
//  Both directions:
//    - chat→responses input (`responsesRequestToChat`): a client speaking the
//      OpenAI Responses API (`POST /v1/responses`) requesting a chat-native
//      model gets its body translated into a Chat Completions request.
//    - responses→chat input (`chatRequestToResponses`, Phase 2b): a Chat
//      Completions client requesting a responses-native model (e.g.
//      muse-spark) gets its body translated into a Responses request; the
//      reverse stream translation lives in `OpencodeChatSSEAdapter`.
//
//  Reuse decision: message/item/tools structure for the responses→chat input
//  comes from the proven Qoder translator pair (`QoderResponsesTranslator
//  .parseResponses` + `synthesizeChatBody`) — the same Responses→Chat mapping
//  battle-tested by issues #11/#26 — then this mapper overlays the
//  request-level fields the Qoder DTO does not carry (sampling params,
//  tool_choice, text.format) so the opencode upstream, a real
//  OpenAI-compatible endpoint, receives them instead of silently losing them.
//  The reverse direction is written directly against JSONSerialization in the
//  same style — there is no chat→responses translator to reuse.
//
//  Field policy (ADR 0021):
//    - `previous_response_id` / `conversation` are server-side state and
//      HARD-FAIL: translating them to stateless chat by dropping them would
//      silently lose the entire conversation history.
//    - Unknown/untranslatable fields drop silently — upstream validation is
//      the arbiter. In the chat→responses direction this includes `stop`
//      sequences (no Responses equivalent — plan Risks) and `stream_options`
//      (usage placement is the terminal event on the responses surface).
//
//  Pure value type — no I/O, no actor state. `nonisolated enum` so it opts
//  out of the project's MainActor default, mirroring the Qoder translators.
//

import Foundation

nonisolated enum OpencodeMapperError: Error, LocalizedError, Equatable {
    /// Responses server-side conversation state cannot cross to the
    /// stateless chat surface — the client must resend the full history.
    case statefulConversation(field: String)

    var errorDescription: String? {
        switch self {
        case .statefulConversation(let field):
            return "'\(field)' cannot be translated to the chat completions surface "
                + "(server-side conversation state). Resend the full conversation in 'input'."
        }
    }
}

nonisolated enum OpencodeProtocolMapper {

    /// Translate an OpenAI Responses API request body into a Chat
    /// Completions request body for the same conversation.
    ///
    /// The produced body still carries the client's `model` verbatim
    /// (including any `opencode/` prefix) — prefix stripping and free-tier
    /// gate shaping happen later in `OpencodeRouter.shapeUpstreamBody`.
    static func responsesRequestToChat(_ body: Data) throws -> Data {
        guard let responses = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            // Let the Qoder translator own parse errors — it has the indexed
            // malformed-request diagnostics.
            _ = try QoderResponsesTranslator.parseResponses(body: body)
            return body   // unreachable: parseResponses throws on bad JSON
        }

        for field in ["previous_response_id", "conversation"] {
            if let value = responses[field] as? String, !value.isEmpty {
                throw OpencodeMapperError.statefulConversation(field: field)
            }
        }

        let synthesized = try QoderResponsesTranslator.synthesizeChatBody(from: body)
        guard var chat = try? JSONSerialization.jsonObject(with: synthesized) as? [String: Any] else {
            return synthesized
        }

        // The Qoder synthesizer emits BOTH token spellings deliberately —
        // keep them: an openai-compatible upstream may honor only the
        // legacy `max_tokens`, and dropping it would silently lose the
        // cap (verified live: the opencode upstream accepts both).

        // Sampling / behavior fields the DTO does not carry: passthrough.
        for key in ["temperature", "top_p", "parallel_tool_calls", "user"] {
            if let value = responses[key], value is NSNumber || value is String {
                chat[key] = value
            }
        }

        if let choice = mappedToolChoice(responses["tool_choice"]) {
            chat["tool_choice"] = choice
        }

        if let format = responseFormat(fromText: responses["text"]) {
            chat["response_format"] = format
        }

        return try JSONSerialization.data(withJSONObject: chat)
    }

    /// Responses `tool_choice` → Chat shape. String values ("auto",
    /// "none", "required") pass through; the object form is flat in
    /// Responses and nested in Chat; unrecognized shapes drop (upstream
    /// validation is the arbiter).
    private static func mappedToolChoice(_ raw: Any?) -> Any? {
        if let value = raw as? String { return value }
        guard let dict = raw as? [String: Any],
              (dict["type"] as? String) == "function",
              let name = dict["name"] as? String, !name.isEmpty else { return nil }
        return ["type": "function", "function": ["name": name]]
    }

    /// Responses `text.format` → Chat `response_format`. `json_object`
    /// maps directly; `json_schema` re-nests the schema block; `text` (the
    /// default) and unknown shapes map to nothing.
    private static func responseFormat(fromText text: Any?) -> [String: Any]? {
        guard let format = (text as? [String: Any])?["format"] as? [String: Any],
              let type = format["type"] as? String else { return nil }
        switch type {
        case "json_object":
            return ["type": "json_object"]
        case "json_schema":
            var jsonSchema: [String: Any] = [:]
            for key in ["name", "schema", "strict"] {
                if let value = format[key] { jsonSchema[key] = value }
            }
            guard !jsonSchema.isEmpty else { return nil }
            return ["type": "json_schema", "json_schema": jsonSchema]
        default:
            return nil
        }
    }

    // MARK: - Chat → Responses (Phase 2b)

    /// Translate an OpenAI Chat Completions request body into a Responses
    /// API request body for the same conversation.
    ///
    /// The produced body still carries the client's `model` verbatim
    /// (including any `opencode/` prefix) — prefix stripping and free-tier
    /// gate shaping happen later in `OpencodeRouter.shapeUpstreamBody`.
    ///
    /// System handling (plan §2b): ONLY a leading system message feeds the
    /// Responses `instructions` channel; system/developer messages elsewhere
    /// in the conversation map to in-place input items — no flattening.
    static func chatRequestToResponses(_ body: Data) throws -> Data {
        let json: Any
        do {
            json = try JSONSerialization.jsonObject(with: body)
        } catch {
            throw QoderTranslatorError.malformedRequest("body is not valid JSON")
        }
        guard let chat = json as? [String: Any] else {
            throw QoderTranslatorError.malformedRequest("body is not a JSON object")
        }
        guard let messages = chat["messages"] as? [[String: Any]] else {
            throw QoderTranslatorError.malformedRequest("missing or non-array 'messages'")
        }

        var responses: [String: Any] = [:]
        if let model = chat["model"] as? String { responses["model"] = model }

        var input: [[String: Any]] = []
        var rest = messages
        if let first = messages.first,
           (first["role"] as? String) == "system",
           let text = messageText(first), !text.isEmpty {
            responses["instructions"] = text
            rest = Array(messages.dropFirst())
        }
        for message in rest {
            input.append(contentsOf: chatMessageToInputItems(message))
        }
        responses["input"] = input

        // Chat token spellings → the Responses spelling (both accepted on
        // input; one emitted — no dual-spelling concern in this direction
        // because the upstream IS the Responses API).
        if let tokens = (chat["max_completion_tokens"] as? Int) ?? (chat["max_tokens"] as? Int) {
            responses["max_output_tokens"] = tokens
        }
        if let effort = chat["reasoning_effort"] as? String, !effort.isEmpty {
            responses["reasoning"] = ["effort": effort]
        }
        if let tools = flatTools(from: chat["tools"]) {
            responses["tools"] = tools
        }
        if let choice = flatToolChoice(chat["tool_choice"]) {
            responses["tool_choice"] = choice
        }
        if let format = textFormat(fromResponseFormat: chat["response_format"]) {
            responses["text"] = ["format": format]
        }
        for key in ["temperature", "top_p", "parallel_tool_calls", "user"] {
            if let value = chat[key], value is NSNumber || value is String {
                responses[key] = value
            }
        }

        return try JSONSerialization.data(withJSONObject: responses)
    }

    /// A message's text: string content verbatim, or the concatenated text
    /// parts of a parts array. Nil when there is no text (null content,
    /// image-only, ...).
    private static func messageText(_ message: [String: Any]) -> String? {
        if let s = message["content"] as? String { return s }
        guard let parts = message["content"] as? [Any] else { return nil }
        var text = ""
        for raw in parts {
            if let part = raw as? [String: Any],
               let t = (part["text"] as? String) {
                text += t
            }
        }
        return text.isEmpty ? nil : text
    }

    /// One Chat message → its Responses `input` items, in order. Assistant
    /// turns with tool_calls emit the message item (when they carry text)
    /// followed by one `function_call` item per call; `tool` messages emit a
    /// `function_call_output` correlated by `tool_call_id`.
    private static func chatMessageToInputItems(_ message: [String: Any]) -> [[String: Any]] {
        let role = (message["role"] as? String) ?? "user"
        if role == "tool" {
            return [[
                "type": "function_call_output",
                "call_id": (message["tool_call_id"] as? String) ?? "",
                "output": messageText(message) ?? "",
            ]]
        }

        var items: [[String: Any]] = []
        if let calls = message["tool_calls"] as? [Any], !calls.isEmpty {
            if let text = messageText(message), !text.isEmpty {
                items.append(messageItem(role: role, message: message))
            }
            for raw in calls {
                guard let call = raw as? [String: Any],
                      let function = call["function"] as? [String: Any],
                      let name = function["name"] as? String else { continue }
                items.append([
                    "type": "function_call",
                    "call_id": (call["id"] as? String) ?? "",
                    "name": name,
                    "arguments": (function["arguments"] as? String) ?? "",
                ])
            }
            return items
        }

        items.append(messageItem(role: role, message: message))
        return items
    }

    /// A conversational message item. Text parts map by role — user/system/
    /// developer inputs are `input_text`, assistant history is `output_text`
    /// — and image parts map to `input_image` with the URL string form.
    /// A message with no content at all omits the field (upstream validation
    /// is the arbiter).
    private static func messageItem(role: String, message: [String: Any]) -> [String: Any] {
        var item: [String: Any] = ["type": "message", "role": role]
        if let s = message["content"] as? String {
            item["content"] = [textPart(role: role, text: s)]
        } else if let parts = message["content"] as? [Any] {
            var mapped: [[String: Any]] = []
            for raw in parts {
                guard let part = raw as? [String: Any] else { continue }
                let type = (part["type"] as? String) ?? "text"
                if let text = part["text"] as? String {
                    mapped.append(textPart(role: role, text: text))
                } else if type == "image_url" {
                    let url = (part["image_url"] as? String)
                        ?? ((part["image_url"] as? [String: Any])?["url"] as? String)
                    if let url, !url.isEmpty {
                        mapped.append(["type": "input_image", "image_url": url])
                    }
                }
            }
            if !mapped.isEmpty { item["content"] = mapped }
        }
        return item
    }

    private static func textPart(role: String, text: String) -> [String: Any] {
        ["type": role == "assistant" ? "output_text" : "input_text", "text": text]
    }

    /// Chat nested tools → the flat Responses function-tool shape. A tool
    /// already in the flat shape (name at top level) passes through; unknown
    /// shapes drop. Nil when there are no tools at all.
    private static func flatTools(from raw: Any?) -> [[String: Any]]? {
        guard let tools = raw as? [Any], !tools.isEmpty else { return nil }
        var flat: [[String: Any]] = []
        for entry in tools {
            guard let tool = entry as? [String: Any] else { continue }
            let function = (tool["function"] as? [String: Any]) ?? tool
            guard let name = function["name"] as? String, !name.isEmpty else { continue }
            var item: [String: Any] = ["type": "function", "name": name]
            if let description = function["description"] as? String {
                item["description"] = description
            }
            if let parameters = function["parameters"] {
                item["parameters"] = parameters
            }
            flat.append(item)
        }
        return flat.isEmpty ? nil : flat
    }

    /// Chat `tool_choice` → the flat Responses shape. String values pass
    /// through; the nested function form flattens; unrecognized shapes drop.
    private static func flatToolChoice(_ raw: Any?) -> Any? {
        if let value = raw as? String { return value }
        guard let dict = raw as? [String: Any],
              (dict["type"] as? String) == "function",
              let name = ((dict["function"] as? [String: Any])?["name"] as? String),
              !name.isEmpty else { return nil }
        return ["type": "function", "name": name]
    }

    /// Chat `response_format` → the Responses `text.format` object.
    /// `json_object` maps directly; `json_schema` un-nests the schema block;
    /// anything else maps to nothing.
    private static func textFormat(fromResponseFormat raw: Any?) -> [String: Any]? {
        guard let format = raw as? [String: Any],
              let type = format["type"] as? String else { return nil }
        switch type {
        case "json_object":
            return ["type": "json_object"]
        case "json_schema":
            guard let jsonSchema = format["json_schema"] as? [String: Any] else { return nil }
            var out: [String: Any] = [:]
            for key in ["name", "schema", "strict"] {
                if let value = jsonSchema[key] { out[key] = value }
            }
            return out.isEmpty ? nil : out
        default:
            return nil
        }
    }
}
