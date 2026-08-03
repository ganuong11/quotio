//
//  QoderModelRegistry.swift
//  Quotio
//
//  Phase 2a (ADR 0003): catalog of Qoder model IDs that ProxyBridge
//  (ticket #7) consults to resolve `qoder/<id>` into a `QoderModelConfig` for
//  the chat-translator envelope. The catalog is a *display hint*, not a gate:
//  unknown `qoder/<id>` IDs still forward to the gateway, which rejects invalid
//  IDs upstream — only the prefix `qoder/` is load-bearing for routing.
//
//  ADR 0003 §2 puts the registry "behind an actor so a future dynamic fetch
//  (COSY-signed /model/list?Encode=1) can slot in without touching the routing
//  path." This tracer ships a `nonisolated enum` instead: the only Phase 2a
//  consumer is the routing gate, which a hardcoded list satisfies, and a static
//  seed is required regardless (dynamic fetch needs a working COSY signer
//  before first launch — cold cache). The dynamic-fetch actor can wrap this
//  enum later without touching routing. Deviation noted in ticket #7 commit.
//
//  The entries below were refreshed on 2026-08-03 against the live
//  `GET /algo/api/v2/model/list?Encode=1` catalog (COSY-signed), scoped to the
//  `chat` group — the surface `qoder/<id>` routes to. `isReasoning` now comes
//  from real gateway data rather than the Phase 2a "always false" placeholder,
//  which matters now that Phase 2b (commit 3919161) lifted the reasoning gate.
//  This list will drift silently as Qoder adds/removes entries; the dynamic-
//  fetch follow-up (see follow-up issue) is the long-term fix.
//
//  Key-name caveat: `gm51model` is the gateway key for GLM-5.2. The key
//  predates the 5.2 version bump — Qoder has not renamed it upstream — so
//  `gm52model` is NOT a valid routing ID despite matching the display name.
//

import Foundation

/// Hardcoded registry of Qoder model IDs. `nonisolated enum` → all members
/// inherit `nonisolated`, callable from any isolation domain (ProxyBridge is
/// `@MainActor`; the registry is borrowed with no synchronization needs).
/// Matches the shape of `QoderWAFEncoder` / `QoderCOSYSigner`.
nonisolated enum QoderModelRegistry {
    /// One catalog row. `maxInputTokens` is what the gateway advertises for the
    /// model (used for documentation / future max-tokens clamping); the
    /// translator's `defaultMaxTokens` is still the per-request cap unless a
    /// row pins a smaller value.
    private struct Entry {
        let key: String
        let isReasoning: Bool
        let maxInputTokens: Int
    }

    /// The known Qoder model IDs (live `chat` group, refreshed 2026-08-03).
    /// Source: `GET /algo/api/v2/model/list?Encode=1` against a global-mode
    /// account. The gateway may add or remove entries under these keys; the
    /// registry drifts silently as a result, mitigated by passing unknown IDs
    /// through (ADR 0003 consequence).
    private static let entries: [Entry] = [
        // Smart-routing tiers (no fixed backend).
        .init(key: "auto", isReasoning: false, maxInputTokens: 180_000),
        .init(key: "ultimate", isReasoning: true, maxInputTokens: 1_000_000),
        .init(key: "performance", isReasoning: false, maxInputTokens: 1_000_000),
        .init(key: "efficient", isReasoning: false, maxInputTokens: 180_000),
        .init(key: "lite", isReasoning: false, maxInputTokens: 180_000),

        // Qwen family. `qmodel` (Qwen3.7-Plus), `qmodel_latest` (Qwen3.7-Max),
        // `qmodel_38max` (Qwen3.8-Max, reasoning-capable).
        .init(key: "qmodel", isReasoning: false, maxInputTokens: 1_000_000),
        .init(key: "qmodel_latest", isReasoning: false, maxInputTokens: 1_000_000),
        .init(key: "qmodel_38max", isReasoning: true, maxInputTokens: 180_000),

        // DeepSeek family. Both reasoning-capable.
        .init(key: "dmodel", isReasoning: true, maxInputTokens: 1_000_000),
        .init(key: "dfmodel", isReasoning: true, maxInputTokens: 1_000_000),

        // GLM. `gm51model` resolves to GLM-5.2 (the key name predates the 5.2
        // bump; Qoder has not renamed it upstream, so `gm52model` is NOT valid).
        .init(key: "gm51model", isReasoning: true, maxInputTokens: 1_000_000),

        // Kimi. `kmodel` (Kimi-K2.7-Code), `kmodel_latest` (Kimi-K3).
        .init(key: "kmodel", isReasoning: false, maxInputTokens: 256_000),
        .init(key: "kmodel_latest", isReasoning: false, maxInputTokens: 180_000),

        // MiniMax.
        .init(key: "mmodel", isReasoning: false, maxInputTokens: 1_000_000),

        // Cantus — premium 3.2× tier, reasoning-capable.
        .init(key: "cmodel", isReasoning: true, maxInputTokens: 180_000),
    ]

    /// Convenience: just the keys, for membership tests and UI listings.
    static let knownIDs: Set<String> = Set(entries.map { $0.key })

    /// Whether an ID (already prefix-stripped) is in the known catalog. Used by
    /// ProxyBridge to short-circuit obviously-wrong IDs in error messages; NOT
    /// a routing gate.
    static func isKnown(_ modelID: String) -> Bool {
        knownIDs.contains(modelID)
    }

    /// Resolve a prefix-stripped Qoder model ID into a config for the chat
    /// translator. Known IDs get a populated config sourced from the live
    /// catalog (reasoning flag from real gateway data, max-tokens from the
    /// gateway's advertised input cap); unknown IDs fall back to
    /// `QoderModelConfig.defaultUnknown`, which the translator handles by
    /// falling back to the request model and pi's 32768 default max-tokens.
    static func resolve(_ modelID: String) -> QoderModelConfig {
        guard let entry = entries.first(where: { $0.key == modelID }) else {
            return .defaultUnknown
        }
        return QoderModelConfig(
            key: entry.key,
            isReasoning: entry.isReasoning,
            maxOutputTokens: QoderChatTranslator.defaultMaxTokens,
            source: "system"
        )
    }
}
