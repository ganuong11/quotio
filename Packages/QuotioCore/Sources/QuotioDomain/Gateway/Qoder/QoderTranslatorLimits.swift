import Foundation

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
/// the failover router's `requestRejected` error → the listener's error
/// envelope path.
public nonisolated struct QoderTranslatorLimits: Sendable, Equatable {
    /// Maximum number of messages forwarded in one request. Over-cap
    /// conversations are trimmed to the system preamble + newest turns
    /// (ADR 0019); only an untrimmable request (preamble alone ≥ cap,
    /// pathological) is rejected as 400. Bounds the O(n) message transform
    /// and the recordID hash.
    public let maxMessages: Int
    /// Maximum decoded byte length of a single `image_url` data-URL payload
    /// (base64 portion decoded). 10 MB matches the headroom the upstream
    /// Qoder gateway advertises for inline images. For plain http(s) URLs the
    /// URL string length is capped at this same value (a sane upper bound — a
    /// real URL is a few hundred chars; only an adversarial value runs long).
    /// Above this, reject as 413.
    public let maxImageBytes: Int
    /// Maximum number of tools accepted in one request. 128 covers the largest
    /// MCP-derived tool sets observed in practice. Above this, reject as 400.
    public let maxTools: Int
    /// Maximum serialized byte length of a single tool's `parameters` JSON
    /// Schema subtree. 1 MB is generous for a hand-authored or generated
    /// schema and bounds the per-tool memory cost. Above this, reject as 413.
    public let maxToolSchemaBytes: Int

    public init(maxMessages: Int, maxImageBytes: Int, maxTools: Int, maxToolSchemaBytes: Int) {
        self.maxMessages = maxMessages
        self.maxImageBytes = maxImageBytes
        self.maxTools = maxTools
        self.maxToolSchemaBytes = maxToolSchemaBytes
    }

    /// Production defaults (see per-field docs for sizing rationale).
    /// `maxMessages` 9999 (user decision 2026-08-18): over-cap conversations
    /// are trimmed to it (ADR 0019) rather than rejected, so availability
    /// never depends on the number. Note the upstream gateway's own
    /// message-count limit is unverified above 999 (the last
    /// empirically-observed-accepted count); if it rejects between 999 and
    /// 9999, that surfaces as the upstream's own 4xx. The byte caps must stay
    /// in their ADR 0013 pairing with Tier 1's body cap: an inline image
    /// travels as base64 (~4/3x), so `maxImageBytes * 4/3 +
    /// maxToolSchemaBytes` must stay under
    /// `HTTP1RequestParser.defaultMaxBodyBytes` (pinned by
    /// `testBodyCapStaysAboveImageCapWireFootprint`).
    public static let `default` = QoderTranslatorLimits(
        maxMessages: 9999,
        maxImageBytes: 90 * 1024 * 1024,
        maxTools: 9999,
        maxToolSchemaBytes: 5 * 1024 * 1024
    )
}
