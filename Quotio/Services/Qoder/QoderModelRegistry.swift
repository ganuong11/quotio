//
//  QoderModelRegistry.swift
//  Quotio
//
//  Phase 2a (ADR 0003): hardcoded catalog of Qoder model IDs that ProxyBridge
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

import Foundation

/// Hardcoded registry of Qoder model IDs. `nonisolated enum` → all members
/// inherit `nonisolated`, callable from any isolation domain (ProxyBridge is
/// `@MainActor`; the registry is borrowed with no synchronization needs).
/// Matches the shape of `QoderWAFEncoder` / `QoderCOSYSigner`.
nonisolated enum QoderModelRegistry {
    /// The known global Qoder model IDs, per ADR 0003 §2. The gateway may add
    /// or remove entries under these keys; the registry drifts silently as a
    /// result, mitigated by passing unknown IDs through (ADR 0003 consequence).
    static let knownIDs: Set<String> = [
        "auto",
        "ultimate",
        "performance",
        "efficient",
        "lite",
        "qmodel",
        "qmodel_latest",
        "dmodel",
        "dfmodel",
        "gm51model",
        "kmodel",
        "mmodel",
    ]

    /// Whether an ID (already prefix-stripped) is in the known catalog. Used by
    /// ProxyBridge to short-circuit obviously-wrong IDs in error messages; NOT
    /// a routing gate.
    static func isKnown(_ modelID: String) -> Bool {
        knownIDs.contains(modelID)
    }

    /// Resolve a prefix-stripped Qoder model ID into a config for the chat
    /// translator. Known IDs get a populated config; unknown IDs fall back to
    /// `QoderModelConfig.defaultUnknown`, which the translator handles by
    /// falling back to the request model and pi's 32768 default max-tokens.
    ///
    /// `is_reasoning` is `false` for every Phase 2a entry — the reasoning gate
    /// (QoderSSEReparser) rejects `reasoning_content` on the text path. Ticket
    /// #8 (Phase 2b) lifts the gate and may flag reasoning-capable models here.
    static func resolve(_ modelID: String) -> QoderModelConfig {
        guard knownIDs.contains(modelID) else {
            return .defaultUnknown
        }
        return QoderModelConfig(
            key: modelID,
            isReasoning: false,
            maxOutputTokens: QoderChatTranslator.defaultMaxTokens,
            source: "system"
        )
    }
}
