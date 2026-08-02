# Qoder session IDs, usage accounting, and multi-account routing

## Context

Three coupled runtime concerns emerge once Qoder chat runs Quotio-side:
session affinity for Qoder's prompt cache, token usage visibility in Quotio's
dashboard (since CPA — the usual source of `/usage` — never sees Qoder traffic),
and multi-account routing when several Qoder PATs are stored.

## Decision

### 1. Session ID derived from client identity

`session_id` for the Qoder request envelope is derived as
`stableHash("qoder-session", userID, model) + "-" + hash(proxy API key from
Authorization header)`. Same CLI agent (same proxy key) + same model + same user
= same session = Qoder prompt-cache hits across turns. Different agents sharing
a key collapse to one session (acceptable). The OpenAI proxy protocol carries
no session concept, so this is the only signal available.

`request_set_id` and `chat_record_id` remain content-derived sha256 (ported
verbatim from `stableChatRecordID`) — deterministic, no decision needed.

### 2. Quotio-side usage accounting

Extend `ProxyBridge.RequestMetadata` with optional token fields
(`inputTokens`, `outputTokens`, `cacheReadTokens`, `cacheWriteTokens`,
`reasoningTokens`). The Qoder SSE final chunk's `usage` block feeds these via
the existing `onRequestCompleted` callback.

`RequestTracker.addRequest(from:)` already consumes `RequestMetadata` and
populates `RequestLog`. Quotio's dashboard `UsageStats` today comes from CPA's
`/usage` endpoint (`ManagementAPIClient.fetchUsageStats`) and is therefore blind
to Qoder. Add a parallel Quotio-side accumulator (`RequestStats` extension or a
new `QoderUsageAccumulator`) that merges with the CPA-sourced stats for display.

Qoder follows OpenAI semantics (`prompt_tokens` INCLUDES `cached_tokens`); pass
through unchanged. Do not replicate pi-provider-qoder's `cached_tokens`
subtraction — that adapted usage to pi-ai's Anthropic convention, irrelevant
here.

### 3. Quota-aware failover inside ProxyBridge

ProxyBridge grows a Qoder account selector. When a `qoder/<id>` request arrives:

1. Pick the primary Qoder account (user-designated, or first-enabled).
2. Sign with that account's job token + machine ID.
3. On HTTP 429 or quota-exceeded signal from Qoder, rotate to the next enabled
   Qoder account, re-sign, retry. Mark the exhausted account as cooled-down.
4. If all accounts exhausted, return 429 to the agent with a clear message.

This puts routing intelligence in ProxyBridge for the first time — it has been
a byte-forwarder until now. The selector is scoped to the Qoder branch only;
non-Qoder traffic still forwards to CPA unchanged.

## Considered Options

### Session ID

- **Fresh UUID per request.** Rejected: loses Qoder prompt-cache affinity,
  which user explicitly wants supported.
- **Opt-in `X-Qoder-Session` header.** Rejected as primary path: no standard
  agent sends it. Client-identity derivation works with zero agent-side config.
  (The header could be added later as an override if needed.)

### Usage accounting

- **Pass-through only (re-encode into OpenAI SSE, no Quotio dashboard).**
  Rejected: user wants the dashboard to reflect Qoder traffic.

### Multi-account routing

- **Single primary, no failover.** Rejected: user wants quota-aware failover.
- **Round-robin.** Rejected: wastes cache affinity (each account has its own
  prompt cache) and doesn't react to quota state. Quota-aware failover is more
  useful and simpler to reason about than blind round-robin.

## Consequences

- ProxyBridge is no longer a pure byte-forwarder — it holds Qoder account
  selection state, cooldown timers, and per-account quota signals. This is the
  biggest architectural shift in the design; the Qoder branch must be cleanly
  separable so it doesn't bleed into the CPA forwarding path.
- Multi-account session affinity is per-account: rotating to a different account
  on failover breaks that turn's cache hit (unavoidable — each Qoder account has
  its own cache namespace). Acceptable: failover is the rare path, normal
  operation stays on the primary.
- The Quotio-side usage accumulator must handle the case where CPA is also
  running and reporting its own stats — avoid double-counting by attributing
  Qoder rows distinctly (Qoder traffic never flows through CPA, so there's no
  overlap by construction, but the dashboard merge logic must be explicit).
- Cooldown state needs persistence consideration: in-memory is fine for the
  tracer (lost on restart), but a quota-exhausted account getting immediately
  re-tried on restart would burn the request budget. Consider a short TTL.
