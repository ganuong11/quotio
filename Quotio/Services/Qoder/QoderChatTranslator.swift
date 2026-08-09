//
//  QoderChatTranslator.swift
//  Quotio
//
//  Phase 2a → 2b (ADR 0001, ADR 0004, ADR 0005, ADR 0007 §3): builds Qoder's
//  bespoke chat request envelope from an OpenAI-shape request body. Pure value
//  type — no I/O, no actor state, no globals. Phase 2b lifts the tools and
//  image fail-fast gates: tools translate into the envelope `tools` field
//  (and feed the recordID hash), and image content parts become `image_url`
//  parts. The reasoning-bearing-response handling lives in the SSE reparser.
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
    /// The agent's reasoning intent, parsed from `reasoning_effort`,
    /// `reasoning: {...}`, or `thinking: {...}`. `.absent` when the request
    /// carries none of these (the common case — most agents don't speak
    /// reasoning today, so the translator falls back to gateway defaults).
    let reasoningIntent: OpenAIReasoningIntent

    /// Memberwise init with `reasoningIntent` defaulting to `.absent`. The
    /// default lets existing test call sites (and any future caller that
    /// doesn't care about reasoning) construct a request without naming the
    /// field — important because the translator predates reasoning support.
    init(
        model: String,
        messages: [OpenAIChatMessage],
        tools: [OpenAITool]? = nil,
        maxTokens: Int? = nil,
        reasoningIntent: OpenAIReasoningIntent = .absent
    ) {
        self.model = model
        self.messages = messages
        self.tools = tools
        self.maxTokens = maxTokens
        self.reasoningIntent = reasoningIntent
    }
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

// MARK: - Reasoning intent (agent request → Qoder thinking_config)

/// The agent's reasoning intent, parsed from whichever vocabulary it speaks.
/// Three states — the distinction between `.absent` and `.disabled` is
/// load-bearing: `.absent` means "agent said nothing, use gateway default";
/// `.disabled` means "agent explicitly asked to turn thinking off." Encoding
/// both as `enabled: false` (as an earlier two-field struct did) collapsed
/// them and made every default-path request force-disable thinking on
/// reasoning models — the inverse of the intended behavior.
///
/// Three input variants are recognized (see `parseReasoningIntent`):
///   - OpenAI's `reasoning_effort: "low"|"medium"|"high"` (string shortcut)
///   - OpenAI's `reasoning: {effort: "...", exclude: bool}` (object form)
///   - Anthropic-style `thinking: {type: "enabled"|"disabled", budget_tokens}`
///
/// Unknown effort strings are clamped to the closest Qoder tier rather than
/// rejected — agents that invent custom values still get a usable request.
nonisolated enum OpenAIReasoningIntent: Sendable, Equatable {
    /// Agent expressed no reasoning intent (no `reasoning_effort`, no
    /// `reasoning`, no `thinking` field). The common case — the translator
    /// falls back to the gateway's default behavior for the model.
    case absent
    /// Agent asked to disable thinking. Reachable only from explicit "off"
    /// shapes: `reasoning: {exclude: true}` (when no effort accompanies it),
    /// `thinking: {type: "disabled"}`, or an effort alias like `"none"`/`"off"`.
    case disabled
    /// Agent asked for thinking. `effort` is one of Qoder's tiers
    /// (`"low"|"medium"|"high"|"xhigh"|"max"`); `nil` means "enabled but let
    /// the gateway pick the tier" (e.g. `thinking: {type: "enabled"}` with no
    /// budget, or `reasoning: {}`).
    case enabled(effort: String?)
}

/// Qoder's thinking selection, derived from `OpenAIReasoningIntent` and the
/// resolved model config. This is what the envelope builder consumes: it fuses
/// "the agent asked for X" with "the model can actually reason" so the rest of
/// the translator doesn't re-derive that intersection.
///
/// `disabled` is distinct from `absent`: `disabled` means an envelope field IS
/// emitted (telling the gateway to turn thinking off on a reasoning-capable
/// model); `absent` means no field at all (gateway default, today's behavior).
/// Keeping them separate preserves the "agent can force-disable reasoning on
/// `ultimate`" path without forcing every request to carry a thinking_config.
nonisolated enum QoderThinkingSelection: Sendable, Equatable {
    /// No `thinking_config` field in the envelope. Used when the model is not
    /// reasoning-capable, or when the agent expressed no intent and we want the
    /// gateway's default for a reasoning model.
    case absent
    /// `{disabled: {}}` — agent explicitly asked to turn thinking off on a
    /// reasoning-capable model.
    case disabled
    /// `{enabled: {effort: <tier>}}` — agent asked for a specific effort level
    /// on a reasoning-capable model. Only emitted when the agent's intent is
    /// enabled AND the model is reasoning-capable.
    case enabled(effort: String)
}

// MARK: - Normalized Qoder-shape message (translator → envelope builder)

/// Content of a normalized Qoder message. Phase 2b: user messages may carry
/// image parts (Qoder's gateway accepts OpenAI-shape `image_url` parts, per
/// transform.ts ~30-105); all other roles use plain text. Nil for assistant
/// turns carrying only tool calls.
nonisolated enum QoderMessageContent: Sendable, Equatable {
    case text(String)
    case parts([QoderContentPart])
}

/// One part of a multi-part user message. Phase 2b mirrors pi's QoderContent
/// union (transform.ts ~29-31): text or image_url. The image URL is passed
/// through verbatim — OpenAI input already carries a ready URL (often a
/// `data:` URL), so we don't reconstruct pi's mimeType/base64 byte model.
nonisolated enum QoderContentPart: Sendable, Equatable {
    case text(String)
    case imageURL(String)
}

/// Normalized Qoder-shape message produced by `transformMessagesForQoder`.
/// The array-of-parts shape is reachable for user messages carrying image
/// parts (Phase 2b); tool calls ride assistant turns (Phase 2b).
nonisolated struct QoderMessage: Sendable, Equatable {
    let role: String
    /// Plain text, array of parts, or nil (assistant with only tool calls).
    let content: QoderMessageContent?
    /// Assistant tool calls (OpenAI shape).
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

/// Tier 2 semantic caps for the Chat translator (issue #14, defense-in-depth
/// on top of the upstream Qoder gateway's own limits). These run BEFORE the
/// envelope is built, so an over-limit request never reaches the gateway or
/// the COSY/WAF signing path — fail-fast at the cheapest point.
///
/// Pure value type, `Sendable`, no I/O. Defaults are sized to never reject a
/// legitimate CLI-agent request while still bounding the translator's working
/// set. They're `let`s on a struct (not a global) so tests can inject tighter
/// values; the production call site uses `.default`.
///
/// The byte-size caps (image, tool schema) map to HTTP **413 Payload Too
/// Large**; the count caps (messages, tools) map to HTTP **400
/// invalid_request_error**. Rationale: a count overage is a structural misuse
/// of the API (the request shape is fine, the agent just sent too many), while
/// a byte overage is a payload that's literally too large to forward — the
/// same semantics Tier 1's body cap (ADR 0013) uses for 413. The status-code
/// split is realized via `QoderTranslatorError.httpStatus` and surfaced through
/// `QoderFailoverError.requestRejected` → `ProxyBridge.sendError`, which wraps
/// the message in the ADR 0010 OpenAI error envelope.
nonisolated struct QoderTranslatorLimits: Sendable, Equatable {
    /// Maximum number of messages accepted in one request. 500 comfortably
    /// covers long CLI-agent conversations while bounding the O(n) message
    /// transform and the recordID hash. Above this, reject as 400.
    let maxMessages: Int
    /// Maximum decoded byte length of a single `image_url` data-URL payload
    /// (base64 portion decoded). 10 MB matches the headroom the upstream
    /// Qoder gateway advertises for inline images. For plain http(s) URLs the
    /// URL string length is capped at this same value (a sane upper bound — a
    /// real URL is a few hundred chars; only an adversarial value runs long).
    /// Above this, reject as 413.
    let maxImageBytes: Int
    /// Maximum number of tools accepted in one request. 128 covers the largest
    /// MCP-derived tool sets observed in practice. Above this, reject as 400.
    let maxTools: Int
    /// Maximum serialized byte length of a single tool's `parameters` JSON
    /// Schema subtree. 1 MB is generous for a hand-authored or generated
    /// schema and bounds the per-tool memory cost. Above this, reject as 413.
    let maxToolSchemaBytes: Int

    /// Production defaults (see per-field docs for sizing rationale).
    static let `default` = QoderTranslatorLimits(
        maxMessages: 500,
        maxImageBytes: 10 * 1024 * 1024,
        maxTools: 128,
        maxToolSchemaBytes: 1024 * 1024
    )
}

/// Parse + limit errors. ProxyBridge (#7) maps each to an HTTP error response
/// body for the CLI agent via the ADR 0010 OpenAI envelope. Tokens/secrets are
/// never embedded; limit messages state the limit value and which limit was
/// hit but never echo request content (e.g. the offending image bytes).
nonisolated enum QoderTranslatorError: Error, LocalizedError {
    /// Request body was not valid OpenAI-shape JSON. Detail is structural only.
    case malformedRequest(String)

    /// Tier 2 count overages (message count, tool count). 400 — the request
    /// shape is fine, the agent just sent too many. `limit` is the configured
    /// cap; `actual` is the offending count. The message names the limit but
    /// never echoes request content.
    case limitCountExceeded(kind: CountLimitKind, limit: Int, actual: Int)

    /// Tier 2 byte overages (image size, tool schema size). 413 — the payload
    /// is literally too large to forward, matching Tier 1's body-cap semantics
    /// (ADR 0013). `limit` is the configured byte cap; `actual` is the
    /// measured size. The message names the limit but never echoes content.
    case limitSizeExceeded(kind: SizeLimitKind, limit: Int, actual: Int)

    /// Which count-based limit was exceeded. Drives the error message; the
    /// associated HTTP status is always 400.
    enum CountLimitKind: Sendable, Equatable {
        case messages
        case tools
        var displayName: String {
            switch self {
            case .messages: return "messages"
            case .tools: return "tools"
            }
        }
    }

    /// Which byte-size limit was exceeded. Drives the error message; the
    /// associated HTTP status is always 413.
    enum SizeLimitKind: Sendable, Equatable {
        case image
        case toolSchema
        var displayName: String {
            switch self {
            case .image: return "image_url"
            case .toolSchema: return "tool schema"
            }
        }
    }

    /// HTTP status for this error. Count caps → 400; size caps → 413;
    /// malformed → 400 (matches the historical Phase 2a behavior).
    var httpStatus: Int {
        switch self {
        case .malformedRequest: return 400
        case .limitCountExceeded: return 400
        case .limitSizeExceeded: return 413
        }
    }

    var errorDescription: String? {
        switch self {
        case .malformedRequest(let detail):
            return "Qoder translator: malformed request (\(detail))."
        case .limitCountExceeded(let kind, let limit, let actual):
            return "Qoder translator: \(kind.displayName) count \(actual) exceeds limit of \(limit)."
        case .limitSizeExceeded(let kind, let limit, let actual):
            return "Qoder translator: \(kind.displayName) size \(actual) bytes exceeds limit of \(limit) bytes."
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
    ///
    /// `limits` runs Tier 2 semantic caps (issue #14): message count, image
    /// size, tool count, per-tool schema size. Defaults (`.default`) are sized
    /// to never reject a legitimate CLI-agent request; tests inject tighter
    /// values. Over-limit throws `QoderTranslatorError.limitCountExceeded`
    /// (HTTP 400) or `.limitSizeExceeded` (HTTP 413).
    static func translate(
        body: Data,
        userID: String,
        proxyAPIKey: String,
        modelConfig: QoderModelConfig,
        options: QoderChatTranslatorOptions = .deferringToRandom,
        limits: QoderTranslatorLimits = .default
    ) throws -> QoderTranslationResult {
        let request = try parse(body: body)
        return try translate(
            request: request,
            userID: userID,
            proxyAPIKey: proxyAPIKey,
            modelConfig: modelConfig,
            options: options,
            limits: limits
        )
    }

    /// Build the Qoder envelope from a parsed OpenAI request. The Tier 2
    /// semantic caps (issue #14) run here regardless of entry path — a typed
    /// caller passing too many messages / oversized images still fails fast.
    static func translate(
        request: OpenAIChatRequest,
        userID: String,
        proxyAPIKey: String,
        modelConfig: QoderModelConfig,
        options: QoderChatTranslatorOptions = .deferringToRandom,
        limits: QoderTranslatorLimits = .default
    ) throws -> QoderTranslationResult {
        // Tier 2 semantic caps (issue #14, defense-in-depth). The upstream
        // Qoder gateway enforces its own limits; these bound the translator's
        // working set and fail-fast at the cheapest point. O(n) over the
        // parsed request — no extra re-parses (tool schema size reuses the
        // already-stored `parameters: Data` bytes; image size decodes the
        // base64 slice of the data-URL string only when present).
        try enforceLimits(request: request, limits: limits)

        // Model key: prefer the resolved config; fall back to the request model
        // when the catalog had no entry (defaultUnknown carries an empty key).
        let modelKey = modelConfig.key.isEmpty ? request.model : modelConfig.key

        let maxTokens = resolveMaxTokens(requestMax: request.maxTokens, modelCap: modelConfig.maxOutputTokens)
        let normalizedMessages = transformMessagesForQoder(request.messages)

        // Transform tools once: used both for the recordID hash (prompt-cache
        // affinity includes the tool surface — pi hashes `JSON.stringify(tools)`,
        // stream.ts ~173) and for the envelope's `tools` field. Empty when the
        // request carried no tools.
        let transformedTools = transformTools(request.tools ?? [])
        let toolsJSON = transformedTools.isEmpty ? "" : canonicalToolsJSON(transformedTools)

        // Content-derived record IDs (deterministic). toolsJSON is "" on the
        // text path (no tools) so the tools branch of the hash is a no-op;
        // tool-bearing requests hash the canonical tools JSON for cache
        // affinity (Phase 2b fix — previously always "" broke affinity).
        // The thinking selection is hashed too: two requests to the same
        // reasoning model with different effort tiers can legitimately
        // diverge, so conflating them under one cache key would be a
        // correctness bug. `.absent` hashes as a stable empty marker.
        let thinking = resolveThinking(
            intent: request.reasoningIntent,
            modelReasoning: modelConfig.isReasoning
        )
        let recordID = stableChatRecordID(
            model: modelKey,
            messages: normalizedMessages,
            toolsJSON: toolsJSON,
            maxTokens: maxTokens,
            thinking: thinking
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
            tools: transformedTools,
            lastUserText: lastUserText,
            thinking: thinking,
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

    // MARK: - Tier 2 semantic caps (issue #14)

    /// Enforce the four Tier 2 caps (issue #14). O(n) over the parsed request:
    /// one pass for messages + image parts, one pass for tool schema sizes.
    /// Throws the first overage encountered. Order is intentional: message
    /// count → image size → tool count → tool schema size. Message count runs
    /// first because it bounds every later pass (and is the cheapest check);
    /// tool count before per-tool schema size so a structurally-misused request
    /// reports its kind, not an incidental size overage on one tool. The
    /// message names the limit + actual but never echoes request content.
    private static func enforceLimits(
        request: OpenAIChatRequest,
        limits: QoderTranslatorLimits
    ) throws {
        // 1. Message count (HTTP 400 on overage).
        if request.messages.count > limits.maxMessages {
            throw QoderTranslatorError.limitCountExceeded(
                kind: .messages, limit: limits.maxMessages, actual: request.messages.count
            )
        }

        // 2. Per-image size (HTTP 413 on overage). Walk every message's content
        //    parts; for image_url parts measure the payload:
        //      - base64 data URLs (`data:<mime>;base64,<...>`) → decoded byte
        //        length (the real memory cost when the gateway materializes it).
        //      - plain http(s) URLs → the URL string length, capped against the
        //        same `maxImageBytes` threshold (a sane upper bound — real URLs
        //        are a few hundred chars; only an adversarial value runs long).
        //    Both user messages and tool-result messages carry images (a tool
        //    result from an image-returning tool can include image_url parts),
        //    so we walk all messages rather than just user ones.
        for msg in request.messages {
            guard case .parts(let parts)? = msg.content else { continue }
            for part in parts {
                guard case .imageURL(let url) = part else { continue }
                let size = imageSizeBytes(url: url, cap: limits.maxImageBytes)
                if size > limits.maxImageBytes {
                    throw QoderTranslatorError.limitSizeExceeded(
                        kind: .image, limit: limits.maxImageBytes, actual: size
                    )
                }
            }
        }

        // 3. Tool count (HTTP 400 on overage). `nil` tools (request carried no
        //    `tools:` field) is allowed — equivalent to an empty array.
        if let tools = request.tools, tools.count > limits.maxTools {
            throw QoderTranslatorError.limitCountExceeded(
                kind: .tools, limit: limits.maxTools, actual: tools.count
            )
        }

        // 4. Per-tool schema size (HTTP 413 on overage). The parser already
        //    re-serializes each tool's `parameters` subtree to canonical bytes
        //    (stored on `OpenAIToolDefinition.parameters: Data`), so the size
        //    check is a byte-count — no extra serialization here. Default `{}` is
        //    ~2 bytes; a real schema is a few KB; 1 MB is generous.
        if let tools = request.tools {
            for tool in tools {
                let size = tool.function.parameters.count
                if size > limits.maxToolSchemaBytes {
                    throw QoderTranslatorError.limitSizeExceeded(
                        kind: .toolSchema, limit: limits.maxToolSchemaBytes, actual: size
                    )
                }
            }
        }
    }

    /// Measure an image_url's payload size for the cap. For a base64 data URL,
    /// returns the decoded byte length (the real memory cost). For any other
    /// URL (http/https, or a malformed data URL), returns the URL string's
    /// UTF-8 byte length — a conservative proxy.
    ///
    /// `cap` is an early-out to avoid decoding up to ~10 MB of base64 for an
    /// under-cap image: a base64 payload is always at least as long as the
    /// decoded bytes (base64 inflates ~4/3× on the wire), so if the URL string
    /// (including the `data:...;base64,` prefix) is ≤ cap, the decoded size is
    /// guaranteed ≤ cap too — return the string length without decoding. Only
    /// when the string length alone exceeds the cap do we decode, to report the
    /// real decoded byte count in the error message.
    ///
    /// Decoding uses Foundation's `base64EncodedData`: a malformed base64 tail
    /// returns nil and we fall back to the string length. This deliberately
    /// over-counts a malformed tail rather than under-counting it, so an
    /// adversarial payload can't slip past the cap by ending in junk.
    private static func imageSizeBytes(url: URL, cap: Int) -> Int {
        let urlString = url.absoluteString
        let stringBytes = urlString.utf8.count
        // Fast path: under the cap by string length → safe regardless of
        // encoding (decoded ≤ string ≤ cap). Skips the base64 decode for the
        // common under-cap inline-image case.
        if stringBytes <= cap {
            return stringBytes
        }
        // Non-data URLs: the string length (already > cap) is the answer.
        guard urlString.hasPrefix("data:") else {
            return stringBytes
        }
        // data URL shape: `data:<mime>[;base64],<payload>`. Find the comma
        // separating the metadata prefix from the payload.
        guard let comma = urlString.firstIndex(of: ",") else {
            return stringBytes
        }
        let prefix = urlString[urlString.startIndex..<comma]
        let payload = urlString[urlString.index(after: comma)..<urlString.endIndex]
        // Only base64 data URLs need decoding; plain (URL-encoded) data URLs
        // are rare for images and small — use the string length.
        guard prefix.lowercased().hasSuffix("base64") else {
            return stringBytes
        }
        let payloadString = String(payload)
        guard let decoded = Data(base64Encoded: payloadString) else {
            // Malformed base64 — return the string length (conservative
            // over-count; never let junk sneak under the cap).
            return stringBytes
        }
        return decoded.count
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

    /// `stableChatRecordID(model, messages, tools, maxTokens, thinking)`: sha256 over
    /// `qoder-record \0 model [\0 role][\0 content]... [\0 toolsJSON] \0 mt=N \0 th=...`,
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
        maxTokens: Int,
        thinking: QoderThinkingSelection = .absent
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
            // Pi's JS-truthiness: hash content if non-empty. For text, hash the
            // string; for parts (image-bearing user messages), hash the
            // canonical JSON of the parts array (mirrors pi's
            // `JSON.stringify(msg.content)` for object content, stream.ts ~65).
            if let content = msg.content {
                let contentHashString: String
                switch content {
                case .text(let s):
                    contentHashString = s
                case .parts(let parts):
                    contentHashString = canonicalPartsJSON(parts)
                }
                if !contentHashString.isEmpty {
                    hash.update(data: Data([0]))
                    hash.update(data: Data(contentHashString.utf8))
                }
            }
        }
        if !toolsJSON.isEmpty {
            hash.update(data: Data([0]))
            hash.update(data: Data(toolsJSON.utf8))
        }
        hash.update(data: Data([0]))
        hash.update(data: Data("mt=\(maxTokens)".utf8))
        // Thinking selection: distinct effort tiers (and the disabled vs.
        // absent distinction) produce different cache keys, since they can
        // legitimately yield different completions for the same prompt.
        // IMPORTANT: `.absent` contributes NOTHING to the hash — not even the
        // `\0th=` separator — so the default path (agent sent no reasoning
        // field) hashes byte-identically to pre-2026-08 behavior. This
        // preserves pi parity and existing cache keys; only requests that
        // explicitly set a thinking selection shift their key.
        let marker = thinkingCacheMarker(thinking)
        if !marker.isEmpty {
            hash.update(data: Data([0]))
            hash.update(data: Data("th=\(marker)".utf8))
        }
        return hexPrefix16(hash.finalize())
    }

    /// Stable string marker for the thinking selection in the recordID hash.
    /// `.absent` → "" (no marker appended → default-path hash unchanged);
    /// `.disabled` → "off"; `.enabled(effort:)` → the effort tier verbatim.
    /// Kept simple so the hash input is auditable and the cache keys predictable.
    private static func thinkingCacheMarker(_ thinking: QoderThinkingSelection) -> String {
        switch thinking {
        case .absent: return ""
        case .disabled: return "off"
        case .enabled(let effort): return effort
        }
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
    ///   - The OpenAI `developer` role (the newer instruction role that replaces
    ///     `system` for newer models) folds into the same branch and is emitted
    ///     as role:system, preserving relative order among instruction messages.
    ///   - pi maps image content to `image_url` data-URL parts from an internal
    ///     base64 byte model; OpenAI input already carries a ready `image_url`
    ///     URL (often a `data:` URL), so Phase 2b passes the URL string through
    ///     verbatim instead of reconstructing bytes (advisor deviation, ADR 0004).
    static func transformMessagesForQoder(_ messages: [OpenAIChatMessage]) -> [QoderMessage] {
        var out: [QoderMessage] = []
        out.reserveCapacity(messages.count)
        for msg in messages {
            switch msg.role {
            case "system", "developer":
                out.append(QoderMessage(
                    role: "system",
                    content: contentText(msg.content).map { .text($0) },
                    toolCalls: [],
                    toolCallID: nil
                ))
            case "user":
                out.append(QoderMessage(
                    role: msg.role,
                    content: transformUserContent(msg.content),
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
                // no text (transform.ts ~138-146).
                let resolved: QoderMessageContent?
                if !text.isEmpty {
                    resolved = .text(text)
                } else if !toolCalls.isEmpty {
                    resolved = .text(" ")
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
                    content: contentText(msg.content).map { .text($0) },
                    toolCalls: [],
                    toolCallID: msg.toolCallID
                ))
                // A tool result may carry images (a screenshot or image-reader
                // tool returns a text note + an image block). The Qoder
                // gateway's `tool` role content is a plain string with no place
                // for image parts, so `contentText` above drops them; without a
                // follow-up the model sees only the note and reports it cannot
                // see images. Emit them as a separate `user` message carrying a
                // leading label + `image_url` parts (the same shape the user
                // branch builds). Ported from pi-provider-qoder PR #14; ADR 0004.
                let images = contentImages(msg.content)
                if !images.isEmpty {
                    let label = "[\(images.count) image\(images.count == 1 ? "" : "s") returned by the previous tool call]"
                    var parts: [QoderContentPart] = [.text(label)]
                    parts.append(contentsOf: images.map { .imageURL($0.absoluteString) })
                    out.append(QoderMessage(
                        role: "user",
                        content: .parts(parts),
                        toolCalls: [],
                        toolCallID: nil
                    ))
                }
            default:
                // Unknown role: skip, matching pi's implicit behavior for
                // roles it doesn't branch on.
                continue
            }
        }
        return out
    }

    /// Port of pi's `transformTools` (transform.ts). Phase 2b: the result feeds
    /// both the envelope `tools` field and the recordID hash (via
    /// `canonicalToolsJSON`). Tool parameters round-trip through
    /// JSONSerialization so arbitrary JSON-Schema is preserved byte-faithfully.
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

    /// Canonical JSON string of the transformed tools, for the recordID hash.
    /// Pi hashes `JSON.stringify(toolsRaw)` (stream.ts ~173) so prompt-cache
    /// affinity includes the tool surface. JS `JSON.stringify` is not key-order
    /// stable across implementations, so we serialize with `.sortedKeys` for
    /// determinism — the same logical tool set always hashes the same, which is
    /// what cache affinity needs. Cross-implementation parity with pi is not
    /// required (Quotio's recordID is Quotio-internal, never compared to pi's).
    static func canonicalToolsJSON(_ tools: [[String: Any]]) -> String {
        guard let data = try? JSONSerialization.data(
            withJSONObject: tools,
            options: [.sortedKeys, .withoutEscapingSlashes]
        ), let str = String(data: data, encoding: .utf8) else {
            return ""
        }
        return str
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
        tools: [[String: Any]],
        lastUserText: String,
        thinking: QoderThinkingSelection,
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
            // Phase 2b: transformed tools from the request (empty when no
            // tools). stream.ts ~198: `tools: toolsRaw || []`.
            "tools": tools,
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
            "model_config": modelConfigJSONObject(
                modelKey: modelKey,
                modelConfig: modelConfig,
                thinking: thinking
            ),
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

    /// Build the `model_config` envelope block, including `thinking_config`
    /// when the thinking selection is non-`.absent`. The gateway reads
    /// `thinking_config` to decide whether to invoke chain-of-thought and at
    /// what effort tier; omitting it (the `.absent` path) lets the gateway
    /// apply its own default — today's behavior for requests that carry no
    /// agent reasoning intent.
    ///
    /// The `thinking_config` shape mirrors what the live `/model/list` catalog
    /// advertises under each reasoning-capable model:
    ///   `{disabled: {}}` or `{enabled: {effort: "low"|"medium"|"high"|"xhigh"|"max"}}`.
    private static func modelConfigJSONObject(
        modelKey: String,
        modelConfig: QoderModelConfig,
        thinking: QoderThinkingSelection
    ) -> [String: Any] {
        var config: [String: Any] = [
            "key": modelKey,
            "is_reasoning": modelConfig.isReasoning,
            "max_output_tokens": modelConfig.maxOutputTokens,
            "source": modelConfig.source,
        ]
        switch thinking {
        case .absent:
            break  // no thinking_config field → gateway default
        case .disabled:
            config["thinking_config"] = ["disabled": [String: Any]()] as [String: Any]
        case .enabled(let effort):
            config["thinking_config"] = ["enabled": ["effort": effort]] as [String: Any]
        }
        return config
    }

    /// Fuse the agent's reasoning intent with the model's reasoning capability
    /// into the envelope-level thinking selection. This is the single place
    /// where "what the agent asked" meets "what the model can do":
    ///
    ///   - Non-reasoning model → `.absent` always. The gateway can't make
    ///     `qoder/auto` reason regardless of intent; sending a thinking_config
    ///     would be noise at best.
    ///   - Reasoning model + `.absent` intent → `.absent`. The gateway applies
    ///     its own default effort (e.g. `high` for `ultimate`), matching
    ///     pre-2026-08 behavior so existing requests are unchanged. **This is
    ///     the common case** — most CLI agents send no reasoning field today.
    ///   - Reasoning model + `.disabled` intent → `.disabled`. Emits
    ///     `{disabled: {}}`, letting an agent force off thinking on
    ///     `qoder/ultimate` per-request.
    ///   - Reasoning model + `.enabled(effort:)` with a tier → `.enabled(effort:)`.
    ///   - Reasoning model + `.enabled(effort: nil)` → `.absent`. Agent asked
    ///     for thinking but named no tier; let the gateway pick its default.
    ///
    /// Split out from `translate` so the rule is auditable in one place and
    /// unit-testable without spinning up a full envelope build.
    static func resolveThinking(
        intent: OpenAIReasoningIntent,
        modelReasoning: Bool
    ) -> QoderThinkingSelection {
        // A non-reasoning model can't think regardless of what the agent asked.
        guard modelReasoning else { return .absent }
        switch intent {
        case .absent:
            // No intent → gateway default. Must NOT become .disabled here —
            // that was the bug when intent was a two-field struct (absent and
            // disabled both collapsed to enabled:false and fell through to the
            // disable branch). The enum makes the distinction structural.
            return .absent
        case .disabled:
            return .disabled
        case .enabled(let effort):
            if let effort {
                return .enabled(effort: effort)
            }
            // Enabled but no tier named — let the gateway pick its default.
            return .absent
        }
    }

    /// Serialize one normalized Qoder message to its JSON-object form.
    /// Content nil → JSON null (matches pi). Text → string. Parts → array of
    /// `{"type":"text"|"image_url", ...}` objects (Phase 2b). Tool calls /
    /// tool_call_id are emitted only when present.
    private static func messageToJSONObject(_ msg: QoderMessage) -> [String: Any] {
        var dict: [String: Any] = ["role": msg.role]
        switch msg.content {
        case .none:
            dict["content"] = NSNull()
        case .text(let s):
            dict["content"] = s
        case .parts(let parts):
            dict["content"] = parts.map(partToJSONObject)
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
        let reasoningIntent = QoderReasoningVocabulary.parseReasoningIntent(from: dict)
        return OpenAIChatRequest(
            model: model,
            messages: messages,
            tools: tools,
            maxTokens: maxTokens,
            reasoningIntent: reasoningIntent
        )
    }

    // Reasoning intent parsing (parseReasoningIntent + isDisableAlias /
    // clampEffort / effortForBudget) lives in the shared
    // `QoderReasoningVocabulary` namespace (issue #27) so the Chat and
    // Responses translators can't drift apart on the reasoning vocabulary.

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
    /// first role:user. For image-bearing parts content, concatenates the text
    /// parts (image URLs are not text-summarizable; pi does the same in
    /// stream.ts ~143-153 for `lastUserText`).
    private static func lastUserMessageText(in messages: [QoderMessage]) -> String {
        for msg in messages.reversed() where msg.role == "user" {
            switch msg.content {
            case .text(let s):
                return s
            case .parts(let parts):
                return parts.compactMap { part -> String? in
                    if case .text(let t) = part { return t }
                    return nil
                }.joined()
            case .none:
                return ""
            }
        }
        return ""
    }

    /// Transform a user message's OpenAI content into Qoder-shape content.
    /// Phase 2b (transform.ts ~78-109): if the content carries any image part,
    /// emit array-of-parts (text parts + image_url parts); otherwise flatten to
    /// a plain text string (the gateway's common case). The image URL is passed
    /// through verbatim — OpenAI input already carries a ready URL.
    private static func transformUserContent(_ content: OpenAIContent?) -> QoderMessageContent? {
        guard let content else { return nil }
        switch content {
        case .text(let s):
            return .text(s)
        case .parts(let parts):
            // If no image part is present, flatten to text (pi's fast path,
            // transform.ts ~102-104) — keeps the common text-only case a string.
            let hasImage = parts.contains { if case .imageURL = $0 { return true } else { return false } }
            if !hasImage {
                let flat = parts.compactMap { part -> String? in
                    if case .text(let t) = part { return t }
                    return nil
                }.joined()
                return .text(flat)
            }
            // Preserve part order: text parts stay text, image parts become
            // image_url entries carrying the verbatim URL string.
            let qoderParts: [QoderContentPart] = parts.map { part in
                switch part {
                case .text(let t):
                    return .text(t)
                case .imageURL(let url):
                    return .imageURL(url.absoluteString)
                }
            }
            return .parts(qoderParts)
        }
    }

    /// Flatten an OpenAIContent to plain text, dropping image parts to "".
    /// Phase 2b: used for system/assistant/tool content (never image-bearing)
    /// and for `lastUserMessageText`'s text-only summary. User image content
    /// is handled separately by `transformUserContent`; tool-result images are
    /// surfaced by `contentImages` and emitted as a follow-up user message.
    private static func contentText(_ content: OpenAIContent?) -> String? {
        guard let content else { return nil }
        switch content {
        case .text(let s):
            return s
        case .parts(let parts):
            return parts.compactMap { part -> String? in
                if case .text(let t) = part { return t }
                return nil
            }.joined()
        }
    }

    /// The image URLs carried by a message's content, in order. Empty when
    /// there are none. A `role: "tool"` result from an image-returning tool
    /// (screenshot, image reader) carries `image_url` parts alongside the text
    /// note; these can't ride the Qoder gateway's string-only `tool` content,
    /// so `transformMessagesForQoder` re-emits them as a follow-up `user`
    /// message. (pi-provider-qoder PR #14.)
    private static func contentImages(_ content: OpenAIContent?) -> [URL] {
        guard case .parts(let parts)? = content else { return [] }
        return parts.compactMap { part -> URL? in
            if case .imageURL(let url) = part { return url }
            return nil
        }
    }

    /// Serialize one `QoderContentPart` to its OpenAI-shape JSON object: text
    /// → `{"type":"text","text":...}`, image → `{"type":"image_url","image_url":
    /// {"url":...}}`. Shared by `messageToJSONObject` (envelope) and
    /// `canonicalPartsJSON` (recordID hash) so the two can't drift.
    private static func partToJSONObject(_ part: QoderContentPart) -> [String: Any] {
        switch part {
        case .text(let t):
            return ["type": "text", "text": t]
        case .imageURL(let url):
            return ["type": "image_url", "image_url": ["url": url]] as [String: Any]
        }
    }

    /// Canonical JSON string of an array of `QoderContentPart`, for the
    /// recordID hash (mirrors pi's `JSON.stringify(msg.content)` for object
    /// content). Sorted keys for determinism — same parts → same hash.
    private static func canonicalPartsJSON(_ parts: [QoderContentPart]) -> String {
        let arr = parts.map(partToJSONObject)
        guard let data = try? JSONSerialization.data(
            withJSONObject: arr,
            options: [.sortedKeys, .withoutEscapingSlashes]
        ), let str = String(data: data, encoding: .utf8) else {
            return ""
        }
        return str
    }

    /// `business.begin_at` — ms since epoch, matching pi's `Date.now()`.
    private static func currentUnixMS() -> Int {
        Int(Date().timeIntervalSince1970 * 1000)
    }
}
