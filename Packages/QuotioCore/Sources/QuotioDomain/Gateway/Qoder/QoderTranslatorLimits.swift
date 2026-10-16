//
//  QoderTranslatorLimits.swift
//  QuotioDomain
//
//  Ported from the qoder branch (QoderChatTranslator.swift) — extracted early
//  because HTTP1RequestParser's Tier-1 body cap test pins the byte-cap
//  relationship against these values. Task 9's translator port references
//  this type rather than re-declaring it.
//

import Foundation

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

    public init(
        maxMessages: Int,
        maxImageBytes: Int,
        maxTools: Int,
        maxToolSchemaBytes: Int
    ) {
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

