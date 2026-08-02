//
//  QoderChatTranslator.swift
//  Quotio
//
//  Phase 2a (ADR 0001, ADR 0004, ADR 0005): builds Qoder's bespoke chat
//  request envelope from an OpenAI-shape request body. Pure value type — no
//  I/O, no actor state, no globals. Text path only: tools and image content
//  parts fail fast at this boundary (ticket #8 lifts both gates). The
//  reasoning-bearing-response gate lives in the SSE reparser.
//
//  Reference: pi-provider-qoder/src/stream.ts lines ~30-230 (envelope builder,
//  stableHash, stableChatRecordID) and src/transform.ts (transformMessagesForQoder,
//  transformTools). Ported for algorithmic and hashing parity; pi-ai's SDK
//  message model is replaced by minimal OpenAI-shape DTOs that ProxyBridge
//  (ticket #7) parses from the incoming request body via `parse(body:)` below.
//
//  Parity note (ADR 0004): "parity" means the Qoder↔OpenAI translation logic,
//  not identical control flow. Two deliberate, documented deviations from pi:
//    1. A `role:system` branch in `transformMessagesForQoder` (pi has none — its
//       SDK separates `systemPrompt`; OpenAI input carries system as a message).
//    2. `stableChatRecordID` hashes the normalized message list INCLUDING system.
//       Pi hashes pre-system-injection; OpenAI's "messages" includes system, and
//       Quotio's system content is caller-supplied, so including it is more
//       correct for prompt-cache affinity.
//

import CryptoKit
import Foundation

// MARK: - OpenAI-shape request DTOs (translator input)

/// Minimal OpenAI Chat Completions request shape. Only the fields the translator
/// reads; ProxyBridge forwards any others opaquely to CPA on the non-Qoder path.
/// `Sendable` so the parsed request can cross the ProxyBridge actor boundary.
nonisolated struct OpenAIChatRequest: Sendable, Equatable {
    let model: String
    let messages: [OpenAIChatMessage]
    /// OpenAI's `tools` array. Non-nil only when the body carried `tools:`.
    /// A non-empty array trips the tools fail-fast gate.
    let tools: [OpenAITool]?
    /// OpenAI carries max tokens under either `max_tokens` (legacy) or
    /// `max_completion_tokens` (newer). Nil when the caller omits it; the
    /// translator falls back to pi's 32768 default.
    let maxTokens: Int?
}

nonisolated struct OpenAIChatMessage: Sendable, Equatable {
    let role: String
    let content: OpenAIContent?
    /// Assistant tool calls. Empty/nil on the text path (tools gate blocks it).
    let toolCalls: [OpenAIToolCall]?
    /// `tool_call_id` for `role: "tool"` messages.
    let toolCallID: String?
}

nonisolated enum OpenAIContent: Sendable, Equatable {
    case text(String)
    case parts([OpenAIContentPart])
}

nonisolated enum OpenAIContentPart: Sendable, Equatable {
    case text(String)
    /// OpenAI image part. Trips the image fail-fast gate when present.
    case imageURL(URL)
}

nonisolated struct OpenAIToolCall: Sendable, Equatable {
    let id: String
    let function: OpenAIToolFunction
}

nonisolated struct OpenAIToolFunction: Sendable, Equatable {
    let name: String
    /// OpenAI streams tool-call arguments as a JSON *string*, not an object.
    let arguments: String
}

nonisolated struct OpenAITool: Sendable, Equatable {
    let function: OpenAIToolDefinition
}

nonisolated struct OpenAIToolDefinition: Sendable, Equatable {
    let name: String
    let description: String?
    /// Raw JSON-Schema bytes. Held as `Data` (not a recursive JSON tree) so
    /// arbitrary schemas round-trip without a hand-written JSON model. The
    /// translator re-emits these bytes verbatim inside the Qoder envelope via
    /// `transformTools` (itself unused on the text path — the tools gate
    /// blocks it — but ported for ticket #8).
    let parameters: Data
}

// MARK: - Qoder-side model descriptor

/// Qoder-side model descriptor. Resolved upstream (ticket #7) from the cached
/// model config; the translator does not look models up. `is_reasoning` flows
/// into `chat_context.extra.modelConfig`; `max_output_tokens` caps `maxTokens`.
nonisolated struct QoderModelConfig: Sendable, Equatable {
    let key: String
    let isReasoning: Bool
    let maxOutputTokens: Int
    let source: String

    /// Safe default for unknown models, matching pi's fallback (max 32768,
    /// non-reasoning, system-sourced). Production callers resolve a real
    /// config; this is used when the catalog has no entry.
    static let defaultUnknown = QoderModelConfig(
        key: "", isReasoning: false, maxOutputTokens: 32768, source: "system"
    )
}

// MARK: - Normalized Qoder-shape message (translator → envelope builder)

/// Normalized Qoder-shape message produced by `transformMessagesForQoder`.
/// Content is a plain string on the text path: the image gate rejects
/// multi-part content, and the tools gate rejects tool calls, so the
/// array-of-parts and tool-call shapes from pi's transform.ts are unreachable
/// in Phase 2a (ticket #8 lifts them). The fields are retained and serialized
/// faithfully so the envelope is correct once #8 opens the gates.
nonisolated struct QoderMessage: Sendable, Equatable {
    let role: String
    /// Plain-text content; nil for assistant turns carrying only tool calls.
    let content: String?
    /// Assistant tool calls (OpenAI shape). Empty in Phase 2a (tools gate).
    let toolCalls: [QoderToolCall]
    /// `role: "tool"` only. Carries the originating tool_call_id.
    let toolCallID: String?
}

nonisolated struct QoderToolCall: Sendable, Equatable {
    let id: String
    let type: String         // always "function"
    let function: QoderToolFunction
}

nonisolated struct QoderToolFunction: Sendable, Equatable {
    let name: String
    let arguments: String
}

// MARK: - Result + options + errors

/// Output of a successful translation. The envelope bytes are ready for
/// `QoderWAFEncoder.encode(...)` → `QoderCOSYSigner.sign(...)` (ticket #5).
/// The IDs are exposed for logging and ProxyBridge request tracking.
nonisolated struct QoderTranslationResult: Sendable, Equatable {
    /// UTF-8 JSON of the Qoder request envelope (pre-WAF-encoding).
    let envelopeJSON: Data
    let requestID: String
    /// Content-derived sha256 slice. Same value as `chatRecordID` (pi alias).
    let requestSetID: String
    let chatRecordID: String
    let sessionID: String
}

/// Injectable non-deterministic inputs. Production: `.deferringToRandom`.
/// Tests pin every field to assert byte-exact envelope equality against a
/// fixture captured from pi with the same values (mirrors `QoderCOSYSigner`'s
/// `Options` pattern). `requestSetID`/`chatRecordID` are content-derived and
/// deterministic regardless, but `request_id` and `business.id`/`begin_at`
/// are random in production.
nonisolated struct QoderChatTranslatorOptions: Sendable {
    /// `request_id` (UUID). Production nil → fresh lowercase UUID.
    var requestID: String?
    /// `business.id` (UUID, distinct from request_id per pi).
    var businessID: String?
    /// `business.begin_at` (ms since epoch). Production nil → now.
    var businessBeginAtMS: Int?

    /// All-random, all-now — the production configuration.
    static let deferringToRandom = QoderChatTranslatorOptions()
}

/// Fail-fast gate errors and parse errors. ProxyBridge (#7) maps each to an
/// HTTP 400 response body for the CLI agent. Tokens/secrets are never embedded.
nonisolated enum QoderTranslatorError: Error, LocalizedError {
    /// Request body was not valid OpenAI-shape JSON. Detail is structural only.
    case malformedRequest(String)
    /// Non-empty `tools` array — Phase 2a text path does not support tools
    /// (ticket #8 lifts this gate).
    case toolsNotSupported
    /// A user message carried `image_url` content parts — Phase 2a text path
    /// does not support images (ticket #8).
    case imageContentNotSupported

    var errorDescription: String? {
        switch self {
        case .malformedRequest(let detail):
            return "Qoder translator: malformed request (\(detail))."
        case .toolsNotSupported:
            return "Qoder translator: tools are not supported on the text path (Phase 2b)."
        case .imageContentNotSupported:
            return "Qoder translator: image content parts are not supported on the text path (Phase 2b)."
        }
    }
}

// MARK: - QoderChatTranslator

/// Qoder chat request-envelope builder. Two entry points:
///   - `translate(body:...)` parses a raw OpenAI request body, applies the
///     fail-fast gates, and builds the envelope. This is what ProxyBridge (#7)
///     calls.
///   - `translate(request:...)` takes already-typed input (the gates still run).
///     Used by tests to exercise the envelope builder in isolation.
///
/// `nonisolated enum` → all members inherit nonisolated, callable from any
/// isolation domain (ProxyBridge is an `actor`; the translator is borrowed
/// with no synchronization needs). Matches `QoderWAFEncoder` / `QoderCOSYSigner`.
nonisolated enum QoderChatTranslator {
    /// Pi's default max-output-tokens cap when the model config doesn't carry one.
    static let defaultMaxTokens = 32768

    // MARK: - Entry points

    /// Parse an OpenAI-shape request body, apply fail-fast gates, build the
    /// Qoder envelope. Combines parsing + gate-checking + translation — the
    /// single call ProxyBridge (ticket #7) makes per Qoder-bound request.
    static func translate(
        body: Data,
        userID: String,
        proxyAPIKey: String,
        modelConfig: QoderModelConfig,
        options: QoderChatTranslatorOptions = .deferringToRandom
    ) throws -> QoderTranslationResult {
        let request = try parse(body: body)
        return try translate(
            request: request,
            userID: userID,
            proxyAPIKey: proxyAPIKey,
            modelConfig: modelConfig,
            options: options
        )
    }

    /// Build the Qoder envelope from a parsed OpenAI request. The tools/image
    /// fail-fast gates run here regardless of entry path — a typed caller
    /// passing tools still fails fast.
    static func translate(
        request: OpenAIChatRequest,
        userID: String,
        proxyAPIKey: String,
        modelConfig: QoderModelConfig,
        options: QoderChatTranslatorOptions = .deferringToRandom
    ) throws -> QoderTranslationResult {
        // Gate 1: tools. Phase 2a is text-only.
        if let tools = request.tools, !tools.isEmpty {
            throw QoderTranslatorError.toolsNotSupported
        }
        // Gate 2: image content parts. Walk every message's content.
        for msg in request.messages {
            if case .parts(let parts) = msg.content,
               parts.contains(where: { if case .imageURL = $0 { return true } else { return false } }) {
                throw QoderTranslatorError.imageContentNotSupported
            }
        }

        // Model key: prefer the resolved config; fall back to the request model
        // when the catalog had no entry (defaultUnknown carries an empty key).
        let modelKey = modelConfig.key.isEmpty ? request.model : modelConfig.key

        let maxTokens = resolveMaxTokens(requestMax: request.maxTokens, modelCap: modelConfig.maxOutputTokens)
        let normalizedMessages = transformMessagesForQoder(request.messages)

        // Content-derived record IDs (deterministic). Tools JSON is always ""
        // here (gate 1), so the tools branch of the hash is a no-op — but the
        // signature accepts it for parity with pi and for ticket #8.
        let recordID = stableChatRecordID(
            model: modelKey,
            messages: normalizedMessages,
            toolsJSON: "",
            maxTokens: maxTokens
        )

        // Session ID per ADR 0005 §1: stable across same user + same model +
        // same proxy API key. The client-identity hash is sha256 of the proxy
        // key — same agent across restarts collapses to one Qoder session,
        // preserving prompt-cache affinity. (Pi uses a random UUID here; the
        // deterministic derivation is Quotio's addition per ADR 0005.)
        let sessionStable = stableHash("qoder-session", userID, modelKey)
        let sessionKey = stableHash("qoder-client", proxyAPIKey)
        let sessionID = "\(sessionStable)-\(sessionKey)"

        let requestID = options.requestID ?? UUID().uuidString.lowercased()
        let businessID = options.businessID ?? UUID().uuidString.lowercased()
        let businessBeginAt = options.businessBeginAtMS ?? currentUnixMS()
        let lastUserText = lastUserMessageText(in: normalizedMessages)

        let envelope = buildEnvelope(
            requestID: requestID,
            recordID: recordID,
            sessionID: sessionID,
            modelKey: modelKey,
            modelConfig: modelConfig,
            maxTokens: maxTokens,
            messages: normalizedMessages,
            lastUserText: lastUserText,
            businessID: businessID,
            businessBeginAtMS: businessBeginAt
        )

        let envelopeJSON = try JSONSerialization.data(withJSONObject: envelope)
        return QoderTranslationResult(
            envelopeJSON: envelopeJSON,
            requestID: requestID,
            requestSetID: recordID,
            chatRecordID: recordID,
            sessionID: sessionID
        )
    }

    // MARK: - Stable hashing (ported verbatim from stream.ts ~30-75)

    /// `stableHash(prefix, ...inputs)`: sha256 over
    /// `prefix \0 input \0 input ...`, first 16 hex chars. Mirrors pi's
    /// `stableHash` exactly — the separator is a NUL byte, not empty string.
    /// Used for the session ID and the client-identity hash.
    static func stableHash(_ prefix: String, _ inputs: String...) -> String {
        stableHash(prefix, inputs)
    }

    /// Array-backed implementation the variadic overload delegates to. Also the
    /// seam tests call directly to assert golden vectors.
    static func stableHash(_ prefix: String, _ inputs: [String]) -> String {
        var hash = SHA256()
        hash.update(data: Data(prefix.utf8))
        for input in inputs {
            hash.update(data: Data([0])) // "\0"
            hash.update(data: Data(input.utf8))
        }
        return hexPrefix16(hash.finalize())
    }

    /// `stableChatRecordID(model, messages, tools, maxTokens)`: sha256 over
    /// `qoder-record \0 model [\0 role][\0 content]... [\0 toolsJSON] \0 mt=N`,
    /// first 16 hex chars. Mirrors pi's `stableChatRecordID` exactly.
    ///
    /// Content-hashing rule matches pi's JS truthiness: role is hashed if
    /// non-empty, content is hashed if non-nil AND non-empty (JS `if (msg.content)`
    /// skips empty strings). Tools JSON is hashed only if non-empty (always ""
    /// on the text path — gate 1 — so this branch is dead in Phase 2a).
    ///
    /// Deviation from pi (ADR 0004): the normalized message list here INCLUDES
    /// the system message, because OpenAI input carries system as a message
    /// and Quotio's system content is caller-supplied. Pi hashes pre-system-
    /// injection. Same conversation → different recordID than pi, by design.
    static func stableChatRecordID(
        model: String,
        messages: [QoderMessage],
        toolsJSON: String,
        maxTokens: Int
    ) -> String {
        var hash = SHA256()
        hash.update(data: Data("qoder-record".utf8))
        hash.update(data: Data([0]))
        hash.update(data: Data(model.utf8))
        for msg in messages {
            if !msg.role.isEmpty {
                hash.update(data: Data([0]))
                hash.update(data: Data(msg.role.utf8))
            }
            if let content = msg.content, !content.isEmpty {
                hash.update(data: Data([0]))
                hash.update(data: Data(content.utf8))
            }
        }
        if !toolsJSON.isEmpty {
            hash.update(data: Data([0]))
            hash.update(data: Data(toolsJSON.utf8))
        }
        hash.update(data: Data([0]))
        hash.update(data: Data("mt=\(maxTokens)".utf8))
        return hexPrefix16(hash.finalize())
    }

    /// Lowercased hex of a SHA256 digest, truncated to 16 chars. Hoisted so
    /// both hash functions share one formatter.
    private static func hexPrefix16(_ digest: SHA256.Digest) -> String {
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(16))
    }

    // MARK: - Message transform (ported from transform.ts)

    /// Port of pi's `transformMessagesForQoder` (transform.ts).
    ///
    /// Differences from pi (both sanctioned by ADR 0004):
    ///   - pi skips assistant messages with stopReason error/aborted (a pi-ai
    ///     SDK artifact). OpenAI input has no stopReason, so no skip.
    ///   - pi has no `system` branch (its SDK separates `systemPrompt`). OpenAI
    ///     input carries system as a message, so we add a branch that passes it
    ///     through — Qoder honors role:system messages (the top-level `system:`
    ///     field is what the server ignores, confirmed in stream.ts).
    ///   - pi maps image content to `image_url` parts; the translator's image
    ///     gate rejects images before this runs, so parts are flattened to text
    ///     here and the array-of-parts output shape is never produced in Phase 2a.
    static func transformMessagesForQoder(_ messages: [OpenAIChatMessage]) -> [QoderMessage] {
        var out: [QoderMessage] = []
        out.reserveCapacity(messages.count)
        for msg in messages {
            switch msg.role {
            case "system", "user":
                out.append(QoderMessage(
                    role: msg.role,
                    content: contentText(msg.content),
                    toolCalls: [],
                    toolCallID: nil
                ))
            case "assistant":
                let text = contentText(msg.content) ?? ""
                let toolCalls = (msg.toolCalls ?? []).map {
                    QoderToolCall(
                        id: $0.id,
                        type: "function",
                        function: QoderToolFunction(name: $0.function.name, arguments: $0.function.arguments)
                    )
                }
                // Qoder's gateway drops assistant messages whose content is
                // null, orphaning the following tool_result and making dmodel/
                // ultimate upstreams reject the request. Pi injects a single-
                // space placeholder when an assistant turn has tool calls but
                // no text. (Tool calls are unreachable in Phase 2a — gate 1 —
                // but the branch is correct for ticket #8.)
                let resolved: String?
                if !text.isEmpty {
                    resolved = text
                } else if !toolCalls.isEmpty {
                    resolved = " "
                } else {
                    resolved = nil
                }
                out.append(QoderMessage(
                    role: "assistant",
                    content: resolved,
                    toolCalls: toolCalls,
                    toolCallID: nil
                ))
            case "tool":
                out.append(QoderMessage(
                    role: "tool",
                    content: contentText(msg.content),
                    toolCalls: [],
                    toolCallID: msg.toolCallID
                ))
            default:
                // Unknown role: skip, matching pi's implicit behavior for
                // roles it doesn't branch on.
                continue
            }
        }
        return out
    }

    /// Port of pi's `transformTools` (transform.ts). UNUSED on the text path —
    /// the tools gate rejects non-empty tools before this runs. Ported for
    /// parity and so ticket #8 can lift the gate without re-implementing.
    /// Tool parameters round-trip through JSONSerialization so arbitrary
    /// JSON-Schema is preserved byte-faithfully.
    static func transformTools(_ tools: [OpenAITool]) -> [[String: Any]] {
        tools.map { tool in
            var function: [String: Any] = ["name": tool.function.name]
            if let description = tool.function.description {
                function["description"] = description
            }
            // Re-parse the stored schema bytes; fall back to an empty object
            // on malformed input (matches pi's effective default).
            if let parsed = try? JSONSerialization.jsonObject(with: tool.function.parameters) {
                function["parameters"] = parsed
            } else {
                function["parameters"] = [String: Any]()
            }
            return [
                "type": "function",
                "function": function,
            ] as [String: Any]
        }
    }

    // MARK: - Envelope builder

    /// Assemble the Qoder request envelope as a JSON object tree. Field set
    /// mirrors stream.ts lines ~175-224 verbatim. Key order is irrelevant to
    /// the gateway (it parses JSON); `JSONSerialization` may reorder, which is
    /// fine because the WAF encoder + COSY signer hash the *serialized* bytes
    /// consistently downstream.
    private static func buildEnvelope(
        requestID: String,
        recordID: String,
        sessionID: String,
        modelKey: String,
        modelConfig: QoderModelConfig,
        maxTokens: Int,
        messages: [QoderMessage],
        lastUserText: String,
        businessID: String,
        businessBeginAtMS: Int
    ) -> [String: Any] {
        let messagesJSON = messages.map(messageToJSONObject)

        return [
            "request_id": requestID,
            "request_set_id": recordID,
            "chat_record_id": recordID,
            "session_id": sessionID,
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
            "image_urls": NSNull(),
            "aliyun_user_type": "",
            // Qoder's server ignores the top-level `system` field (verified in
            // stream.ts: the model never sees it). System content rides as a
            // leading role:system message in `messages` instead.
            "system": "",
            "messages": messagesJSON,
            "tools": [],   // gate 1 blocks non-empty tools in Phase 2a
            "parameters": ["max_tokens": maxTokens],
            "chat_context": [
                "chatPrompt": "",
                "imageUrls": NSNull(),
                "extra": [
                    "context": [],
                    "modelConfig": [
                        "key": modelKey,
                        "is_reasoning": modelConfig.isReasoning,
                    ],
                    "originalContent": lastUserText,
                ],
                "features": [],
                "text": lastUserText,
            ],
            "model_config": [
                "key": modelKey,
                "is_reasoning": modelConfig.isReasoning,
                "max_output_tokens": modelConfig.maxOutputTokens,
                "source": modelConfig.source,
            ],
            "business": [
                "product": "cli",
                "version": "1.0.0",
                "type": "agent",
                "stage": "start",
                "id": businessID,
                "name": String(lastUserText.prefix(30)),
                "begin_at": businessBeginAtMS,
            ],
        ] as [String: Any]
    }

    /// Serialize one normalized Qoder message to its JSON-object form.
    /// Content nil → JSON null (matches pi). Tool calls / tool_call_id are
    /// emitted only when present (always empty on the text path).
    private static func messageToJSONObject(_ msg: QoderMessage) -> [String: Any] {
        var dict: [String: Any] = ["role": msg.role]
        if let content = msg.content {
            dict["content"] = content
        } else {
            dict["content"] = NSNull()
        }
        if !msg.toolCalls.isEmpty {
            dict["tool_calls"] = msg.toolCalls.map { tc in
                [
                    "id": tc.id,
                    "type": tc.type,
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

    // MARK: - Body parsing (OpenAI → typed DTOs)

    /// Parse an OpenAI-shape request body into typed DTOs. Tolerant of extra
    /// fields (forwarded opaquely by ProxyBridge on the non-Qoder path);
    /// strict about the structural shape the translator reads.
    static func parse(body: Data) throws -> OpenAIChatRequest {
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
        guard let messagesArray = dict["messages"] as? [Any], !messagesArray.isEmpty else {
            throw QoderTranslatorError.malformedRequest("missing or empty 'messages' array")
        }
        let messages: [OpenAIChatMessage] = try messagesArray.enumerated().map { idx, raw in
            guard let msgDict = raw as? [String: Any] else {
                throw QoderTranslatorError.malformedRequest("messages[\(idx)] is not an object")
            }
            return try parseMessage(msgDict, idx: idx)
        }
        let tools: [OpenAITool]?
        if let rawTools = dict["tools"] as? [Any] {
            tools = try rawTools.enumerated().map { idx, raw in
                try parseTool(raw, idx: idx)
            }
        } else {
            tools = nil
        }
        // OpenAI carries max tokens under either spelling.
        let maxTokens = (dict["max_tokens"] as? Int) ?? (dict["max_completion_tokens"] as? Int)
        return OpenAIChatRequest(model: model, messages: messages, tools: tools, maxTokens: maxTokens)
    }

    private static func parseMessage(_ dict: [String: Any], idx: Int) throws -> OpenAIChatMessage {
        guard let role = dict["role"] as? String, !role.isEmpty else {
            throw QoderTranslatorError.malformedRequest("messages[\(idx)] missing 'role'")
        }
        let content: OpenAIContent?
        if dict["content"] == nil || dict["content"] is NSNull {
            content = nil
        } else if let s = dict["content"] as? String {
            content = .text(s)
        } else if let arr = dict["content"] as? [Any] {
            let parts: [OpenAIContentPart] = try arr.enumerated().map { pidx, praw in
                guard let pdict = praw as? [String: Any] else {
                    throw QoderTranslatorError.malformedRequest("messages[\(idx)].content[\(pidx)] is not an object")
                }
                return try parseContentPart(pdict, idx: idx, pidx: pidx)
            }
            content = .parts(parts)
        } else {
            throw QoderTranslatorError.malformedRequest("messages[\(idx)].content has unsupported type")
        }
        let toolCalls: [OpenAIToolCall]?
        if let rawToolCalls = dict["tool_calls"] as? [Any] {
            toolCalls = try rawToolCalls.enumerated().map { tcidx, raw in
                guard let tcDict = raw as? [String: Any] else {
                    throw QoderTranslatorError.malformedRequest("messages[\(idx)].tool_calls[\(tcidx)] is not an object")
                }
                return try parseToolCall(tcDict, idx: idx, tcidx: tcidx)
            }
        } else {
            toolCalls = nil
        }
        return OpenAIChatMessage(
            role: role,
            content: content,
            toolCalls: toolCalls,
            toolCallID: dict["tool_call_id"] as? String
        )
    }

    private static func parseContentPart(_ dict: [String: Any], idx: Int, pidx: Int) throws -> OpenAIContentPart {
        guard let type = dict["type"] as? String else {
            throw QoderTranslatorError.malformedRequest("messages[\(idx)].content[\(pidx)] missing 'type'")
        }
        switch type {
        case "text":
            guard let text = dict["text"] as? String else {
                throw QoderTranslatorError.malformedRequest("messages[\(idx)].content[\(pidx)] text part missing 'text'")
            }
            return .text(text)
        case "image_url":
            // Surface a clear error here rather than at the gate: a part
            // shaped like image_url but missing its url is a malformed request,
            // not a "supported but gated" image.
            guard let imageUrlDict = dict["image_url"] as? [String: Any],
                  let urlString = imageUrlDict["url"] as? String,
                  let url = URL(string: urlString) else {
                throw QoderTranslatorError.malformedRequest(
                    "messages[\(idx)].content[\(pidx)] image_url part has no valid 'url'"
                )
            }
            return .imageURL(url)
        default:
            throw QoderTranslatorError.malformedRequest(
                "messages[\(idx)].content[\(pidx)] unsupported part type '\(type)'"
            )
        }
    }

    private static func parseToolCall(_ dict: [String: Any], idx: Int, tcidx: Int) throws -> OpenAIToolCall {
        guard let id = dict["id"] as? String else {
            throw QoderTranslatorError.malformedRequest("messages[\(idx)].tool_calls[\(tcidx)] missing 'id'")
        }
        guard let funcDict = dict["function"] as? [String: Any] else {
            throw QoderTranslatorError.malformedRequest("messages[\(idx)].tool_calls[\(tcidx)] missing 'function'")
        }
        guard let name = funcDict["name"] as? String else {
            throw QoderTranslatorError.malformedRequest("messages[\(idx)].tool_calls[\(tcidx)].function missing 'name'")
        }
        let arguments = (funcDict["arguments"] as? String) ?? ""
        return OpenAIToolCall(id: id, function: OpenAIToolFunction(name: name, arguments: arguments))
    }

    private static func parseTool(_ raw: Any, idx: Int) throws -> OpenAITool {
        guard let dict = raw as? [String: Any] else {
            throw QoderTranslatorError.malformedRequest("tools[\(idx)] is not an object")
        }
        guard let funcDict = dict["function"] as? [String: Any] else {
            throw QoderTranslatorError.malformedRequest("tools[\(idx)] missing 'function'")
        }
        guard let name = funcDict["name"] as? String else {
            throw QoderTranslatorError.malformedRequest("tools[\(idx)].function missing 'name'")
        }
        // Re-serialize parameters to canonical bytes for round-trip. Default
        // to `{}` when absent (matches pi's effective handling).
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

    // MARK: - Helpers

    /// Resolve max tokens: pi takes min(modelConfig.max_output_tokens,
    /// options.maxTokens), defaulting to 32768. `requestMax <= 0` is ignored.
    private static func resolveMaxTokens(requestMax: Int?, modelCap: Int) -> Int {
        var max = defaultMaxTokens
        if modelCap > 0 { max = modelCap }
        if let r = requestMax, r > 0, r < max { max = r }
        return max
    }

    /// Last user message's text — feeds `chat_context.text` / `originalContent`
    /// and `business.name`. Pi walks normalized messages backwards for the
    /// first role:user.
    private static func lastUserMessageText(in messages: [QoderMessage]) -> String {
        for msg in messages.reversed() where msg.role == "user" {
            return msg.content ?? ""
        }
        return ""
    }

    /// Flatten an OpenAIContent to plain text. Image parts drop to "" — the
    /// image gate rejects them before this runs, so this is text-only in 2a.
    private static func contentText(_ content: OpenAIContent?) -> String? {
        guard let content else { return nil }
        switch content {
        case .text(let s):
            return s
        case .parts(let parts):
            // Gate 2 rejects image parts; if it somehow slipped through, drop
            // them here rather than emit image_url (Phase 2b will handle it).
            return parts.compactMap { part -> String? in
                if case .text(let t) = part { return t }
                return nil
            }.joined()
        }
    }

    /// `business.begin_at` — ms since epoch, matching pi's `Date.now()`.
    private static func currentUnixMS() -> Int {
        Int(Date().timeIntervalSince1970 * 1000)
    }
}
