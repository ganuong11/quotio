# OpenCode surface dispatch: translate to the model's native surface

## Context

ADR 0020 decided surface passthrough for the opencode branch: the client's
chosen OpenAI surface (`/v1/chat/completions` vs `/v1/responses`) forwarded
verbatim, because models.dev was believed to carry no per-model npm metadata —
"there is no sound mapping to enforce."

Re-verified live on 2026-10-15 (plan review of the surface-dispatch plan):
**models.dev now carries per-model `provider.npm` overrides** (66 of 124
`opencode` models; e.g. `muse-spark-1.3-contributor-free` → `@ai-sdk/openai`,
`qwen3.6-plus-free` → `@ai-sdk/anthropic`), with the provider-level
`@ai-sdk/openai-compatible` as fallback. Upstream enforces surface×model
itself (wrong surface → `400 ModelProtocolUnsupported`), so under passthrough
a client that picks the "wrong" surface for a model simply fails — with
upstream's opaque error, after paying the round-trip. The served free set
today is 8 chat-native + 1 responses-native models; the free set's surface
mix can change under us as models.dev and the live list move.

## Decision

**Supersedes ADR 0020's "surface passthrough, no family mapping" decision
only.** Every request is dispatched to the model's **native** upstream
surface, resolved per model from the catalog (per-model `provider.npm` →
provider-level `npm` → `chat` default), and translated when the client's
surface differs:

- Same-surface (passthrough) arm: unchanged — body shaped per target surface,
  status/headers/bytes relayed verbatim, SSE pumped raw.
- **chat→responses arm** (Responses-speaking client, chat-native model) ships
  first: it reuses the proven Qoder components at the same seams
  (`QoderResponsesTranslator.parseResponses`/`synthesizeChatBody` for the
  request, `QoderResponsesAdapter` for the stream, `QoderCompletionAggregator`
  for non-streaming) and unlocks all served chat models for Responses clients.
- **responses→chat arm is deferred** as an explicit decision point: it needs
  two new components and unlocks exactly one model today. Until it lands,
  chat-surface requests for responses-native models get a provider-owned
  `422 unsupported_surface` naming the required surface — clearer than the
  upstream 400 it replaces.
- Native surfaces `messages`/`gemini`/`mistral` (and `messages` until a
  mapper exists): `422 unsupported_surface`; excluded from `/v1/models`
  advertisement (filter, not annotation — never advertise what we can't
  serve).
- **Non-streaming is aggregated on every arm** (not only translated ones):
  upstream is forced `stream:true` by the free-tier gate, so `stream:false`
  clients get one JSON body folded from the SSE (`chat.completion` /
  `response` per the client's surface), with the response head written only
  after aggregation — a mid-aggregation failure is a true HTTP 502 (issue #9
  precedent). This also fixes the passthrough arm, which previously pumped
  SSE verbatim to `stream:false` clients.
- **Error bodies:** pre-stream non-2xx relays verbatim (OpenAI's
  `{"error":{…}}` envelope is shared across both surfaces); mid-stream
  failures get surface-correct terminal frames (Responses `response.failed`
  event via the adapter; chat SSE error frame via `QoderOpenAIError`).
- **Hard-fail carve-out in translation:** `previous_response_id` /
  `conversation` (Responses server-side state) → 400 rather than silent drop
  — dropping them would translate a stateful conversation into a stateless
  one and silently lose all history. Unknown sampling fields still drop
  silently; upstream validation remains the arbiter.

ADR 0020's other decisions stand unchanged: verbatim status passthrough on
the passthrough arm, released-client impersonation (UA 1.18.30 full form —
the spike showed the gate 403s `opencode/1.19.0`, superseding the spec's
short-form guidance), cold-start 503 semantics, `QoderOpenAIError` envelope
reuse, catalog hard-allowlist.

## Considered Options

- **Keep passthrough (ADR 0020 as written).** Rejected: its factual basis
  (no per-model npm) no longer holds, and upstream's `ModelProtocolUnsupported`
  400 makes cross-surface requests fail opaquely. Keeping it also leaves the
  `stream:false` passthrough bug unowned.
- **Filter cross-surface models out of the catalog instead of translating.**
  Rejected: it would hide the newest free model (`muse-spark-1.3`) from
  chat-only clients forever and couple the advertisement to the client
  population's surface habits; translation is bounded work at proven seams.
- **Translate both directions at once.** Rejected for now: the responses→chat
  half is two new components for one model today; it stays a documented
  decision point with a complete spec in the plan doc.

## Consequences

- The opencode branch now owns protocol translation fidelity at the
  cross-surface seam: message/tool/tool_choice/text-format mapping rules and
  their fixture tests (the plan doc's Phase 2 sections carry the full list,
  including the deferred arm's `response.incomplete` → `finish_reason`
  mapping and reasoning-summary handling).
- Catalog snapshots gain a `surface` field (`catalog-v2.json`); v1 snapshots
  decode with surface nil → chat legacy default, and the startup refresh
  closes that window in seconds (inside it, behavior degrades to the
  pre-dispatch verbatim-400, never a wrong-model answer).
- The free-tier gate now sees translated (not just native) request bodies;
  live probes of translated bodies against the gate are part of the plan's
  verification — a 403 there means the gate inspects deeper body structure
  and must be escalated, not shipped.
- The injected `read` tool (gate requirement) can be *called* by the model,
  handing foreign clients an unknown `tool_call` — a documented gate tradeoff,
  not a regression; it exists on every arm.
- `GET /v1/models` filters to servable surfaces; an unservable-surface model
  that later goes free appears in the catalog but not in advertisement until
  a mapper ships.
