//
//  OpencodeProtocolMapper.swift
//  Quotio
//
//  Cross-surface request translation for the opencode branch (ADR 0021).
//  Today this is the chat→responses arm only: a client speaking the OpenAI
//  Responses API (`POST /v1/responses`) requesting a chat-native model gets
//  its body translated into a Chat Completions request for the native
//  upstream surface. The reverse direction (chat client, responses-native
//  model) is a documented 422 decision point — see
//  docs/opencode-surface-dispatch-plan.md Phase 2b.
//
//  Reuse decision: message/item/tools structure comes from the proven Qoder
//  translator pair (`QoderResponsesTranslator.parseResponses` +
//  `synthesizeChatBody`) — the same Responses→Chat mapping battle-tested by
//  issues #11/#26 — then this mapper overlays the request-level fields the
//  Qoder DTO does not carry (sampling params, tool_choice, text.format) so
//  the opencode upstream, a real OpenAI-compatible endpoint, receives them
//  instead of silently losing them.
//
//  Field policy (ADR 0021):
//    - `previous_response_id` / `conversation` are server-side state and
//      HARD-FAIL: translating them to stateless chat by dropping them would
//      silently lose the entire conversation history.
//    - Unknown/untranslatable fields drop silently — upstream validation is
//      the arbiter.
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

        // The Qoder synthesizer emits both token spellings because its
        // gateway accepts either; the opencode upstream gets only the
        // modern one.
        chat.removeValue(forKey: "max_tokens")

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
}
