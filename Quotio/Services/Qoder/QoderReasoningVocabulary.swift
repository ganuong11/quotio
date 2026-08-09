//
//  QoderReasoningVocabulary.swift
//  Quotio
//
//  Shared reasoning-effort vocabulary for the two Qoder input translators
//  (issue #27). Both `QoderChatTranslator` (Chat Completions path) and
//  `QoderResponsesTranslator` (Responses API path) need to interpret an agent's
//  reasoning intent — `reasoning_effort` (OpenAI shortcut), `reasoning: {...}`
//  (OpenAI object), and `thinking: {...}` (Anthropic-style) — using the SAME
//  tier-and-disable rules. Before this file existed, `QoderResponsesTranslator`
//  carried byte-identical private copies of the four helpers below, which meant
//  a vocabulary change had to be made in two places and the two endpoints could
//  silently drift (a correctness bug — two agents sending the same intent would
//  get different thinking selections depending on which endpoint they hit).
//
//  This file is the single source of truth. It owns the parsing entry point and
//  its three private helpers; both translators now call into it. `nonisolated
//  enum` (caseless namespace) → all members inherit nonisolated, callable from
//  any isolation domain. Pure value semantics, no I/O — the helpers are static
//  functions over plain dictionaries and strings, matching the declaration style
//  of `QoderChatTranslator` and `QoderResponsesTranslator`.
//
//  `OpenAIReasoningIntent` (the return type of `parseReasoningIntent`) remains
//  declared in `QoderChatTranslator.swift`; it is a top-level, module-internal
//  type that both translators and the tests already reference by name.
//

import Foundation

/// Shared reasoning-effort vocabulary for the Chat and Responses translators
/// (issue #27). A caseless enum namespace: pure static functions only, no
/// instances. `nonisolated` so the helpers are callable from any isolation
/// domain — both translators are themselves `nonisolated enum` namespaces that
/// ProxyBridge (an `actor`) borrows without synchronization.
///
/// Keep these rules IN SYNC with exactly one place; do not re-duplicate in
/// either translator. The four members are:
///   - `parseReasoningIntent(from:)` — the entry point. Precedence:
///     `reasoning_effort` → `reasoning` → `thinking`; first non-`.absent` wins.
///   - `isDisableAlias(_:)` — whether an effort string is really an "off"
///     signal, split out so the entry point short-circuits to `.disabled`
///     before `clampEffort` would fold `"none"` down to `"low"`.
///   - `clampEffort(_:)` — map an arbitrary effort string onto Qoder's five
///     tiers (`low/medium/high/xhigh/max`).
///   - `effortForBudget(_:)` — map an Anthropic-style `budget_tokens` to the
///     nearest tier.
nonisolated enum QoderReasoningVocabulary {

    /// Parse the agent's reasoning intent from whichever vocabulary it speaks.
    /// Precedence (first non-`.absent` wins): `reasoning_effort` (OpenAI
    /// shortcut) → `reasoning: {...}` (OpenAI object) → `thinking: {...}`
    /// (Anthropic-style). Returns `.absent` when the request carries none of
    /// these — the common case, since most CLI agents don't set any reasoning
    /// field today.
    ///
    /// Tolerant of shape variation: an unrecognized effort string clamps to the
    /// nearest Qoder tier rather than rejecting the request, so an agent that
    /// invents `"ultra"` still gets a usable mapping. Unknown object shapes
    /// fall through to `.absent` (the gateway's default behavior) rather than
    /// failing — reasoning intent is metadata, not a request requirement.
    static func parseReasoningIntent(from dict: [String: Any]) -> OpenAIReasoningIntent {
        // 1. `reasoning_effort: "low"|"medium"|"high"` — OpenAI's shortcut form.
        //    Codex CLI and several agent frameworks send this. The "off"-family
        //    aliases (`none`/`off`/`minimal`) map to `.disabled` rather than a
        //    tier — an agent saying "no reasoning" means disable, not low effort.
        if let effortStr = dict["reasoning_effort"] as? String, !effortStr.isEmpty {
            if isDisableAlias(effortStr) { return .disabled }
            return .enabled(effort: clampEffort(effortStr))
        }
        // 2. `reasoning: {effort: "...", exclude: bool}` — OpenAI's object form.
        //    NOTE on `exclude`: in OpenAI semantics `exclude: true` means
        //    "exclude reasoning *content from the response*" while the model
        //    STILL reasons — it's a response-shape flag, not a thinking toggle.
        //    Qoder's `thinking_config` controls whether the model reasons, so
        //    mapping `exclude` to `{disabled: {}}` would wrongly change model
        //    behavior. We therefore ignore `exclude` for the thinking decision
        //    and let the SSE reparser keep emitting reasoning_content (the agent
        //    can choose to drop it). Effort, if present, still wins.
        if let reasoning = dict["reasoning"] as? [String: Any] {
            if let effortStr = reasoning["effort"] as? String, !effortStr.isEmpty {
                if isDisableAlias(effortStr) { return .disabled }
                return .enabled(effort: clampEffort(effortStr))
            }
            // `reasoning: {}` or `{exclude: ...}` with no effort → no signal.
            // Falls through to the thinking-shape check below, then .absent.
        }
        // 3. `thinking: {type: "enabled"|"disabled", budget_tokens: N}` — the
        //    Anthropic-style shape some agents send. `type: "disabled"` is a
        //    true thinking toggle (unlike OpenAI's `exclude`), so it maps to
        //    `.disabled`. When enabled, derive an effort from budget_tokens.
        if let thinking = dict["thinking"] as? [String: Any] {
            let type = (thinking["type"] as? String) ?? ""
            switch type {
            case "disabled":
                return .disabled
            case "enabled":
                if let budget = thinking["budget_tokens"] as? Int, budget > 0 {
                    return .enabled(effort: effortForBudget(budget))
                }
                // enabled with no budget → let the gateway pick its default.
                return .enabled(effort: nil)
            default:
                break
            }
        }
        return .absent
    }

    /// Whether an effort-string value is really a "turn thinking off" signal
    /// rather than a tier. Split out so `parseReasoningIntent` can short-circuit
    /// to `.disabled` before `clampEffort` would otherwise fold `"none"` down
    /// to `"low"` (which would enable thinking when the agent asked for none).
    static func isDisableAlias(_ raw: String) -> Bool {
        switch raw.lowercased() {
        case "none", "off", "disable", "disabled", "false":
            return true
        default:
            return false
        }
    }

    /// Map an arbitrary effort string onto one of Qoder's five tiers
    /// (`low/medium/high/xhigh/max`, per the live `/model/list` catalog).
    /// Recognized strings map verbatim; unknowns clamp to the closest known
    /// tier by name. The mapping is deliberately generous — agents that send
    /// `"ultra"`, `"max"`, `"extreme"` etc. still get a sensible tier.
    ///
    /// Callers should check `isDisableAlias` first — this function assumes the
    /// input is a real effort request, not a disguised disable. Kept as a pure
    /// function so tests can pin golden vectors per input.
    static func clampEffort(_ raw: String) -> String {
        let known: Set<String> = ["low", "medium", "high", "xhigh", "max"]
        let lowered = raw.lowercased()
        if known.contains(lowered) { return lowered }
        // Aliases observed across agent frameworks.
        switch lowered {
        case "minimal":
            return "low"
        case "standard", "normal", "default", "auto":
            return "medium"
        case "ultra", "extreme", "maximum", "best", "strong":
            return "max"
        default:
            // Unknown but non-empty: round up to `medium` (Qoder's gateway
            // default for most reasoning models) rather than guessing low/high.
            return "medium"
        }
    }

    /// Map an Anthropic-style `budget_tokens` to the nearest Qoder effort tier.
    /// Rough banding — the live catalog doesn't expose per-tier token budgets,
    /// so we use conventional ranges. Tighter budgets → lower effort.
    static func effortForBudget(_ budget: Int) -> String {
        switch budget {
        case ..<4096: return "low"
        case ..<16384: return "medium"
        case ..<65536: return "high"
        case ..<262144: return "xhigh"
        default: return "max"
        }
    }
}
