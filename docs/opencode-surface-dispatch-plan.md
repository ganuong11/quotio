# Implementation plan — opencode surface dispatch + protocol translation

> Amended 2026-10-15 after plan review (findings B1–B5, S1–S5 merged).
> Supersedes the "surface passthrough" half of ADR 0020 — see Phase D.

## Objective

Any `opencode/<model>` request on either Quotio surface (`/v1/chat/completions`, `/v1/responses`) works, by routing to the model's **native** upstream surface and translating request/stream when surfaces differ. Matches what the real opencode client does (`provider.npm` → surface → surface-native body).

## Verified upstream facts (2026-10-15 live probes, re-verified at plan review)

- Auth: `~/.local/share/opencode/auth.json` `opencode` entry (`type: api`). No Quotio-vault opencode account exists; the router serves the detected credential.
- The free-tier gate fingerprints **transport**: identical token/headers/body via curl (LibreSSL/nghttp2) → 403 `FreeTierError`; via `URLSession` → 200. All upstream calls must stay on `URLSession`.
- Gate also requires: `stream:true`, `x-opencode-*` metadata headers, pinned UA (`opencode/1.18.30 ai-sdk/provider-utils/4.0.23 runtime/bun/1.3.14`), and a `read` tool. The short UA `opencode/1.19.0` is 403'd — the spec's earlier "impersonate 1.19.0" guidance is superseded by the spike outcome.
- Gated tool names `{read, bash, write, edit, glob, grep}` — six names — with missing/empty `parameters.properties` → 403 `FreeTierError`. Unknown tool names pass unchecked.
- Surface×model enforcement is upstream-side: wrong surface → `400 ModelProtocolUnsupported`.
- **models.dev carries per-model `provider.npm` as of 2026-10-15** (66 of 124 `opencode` models; verified live at plan review — this reverses the earlier "0/123" finding that motivated surface passthrough). Provider-level `npm` (`@ai-sdk/openai-compatible`) remains the fallback.
- **Free-set counts must use the catalog's exact rule** (live ∩ models.dev cost-0 ∩ non-deprecated − jev-/systemone). With that rule the served set is **8 chat-native + 1 responses-native** (`muse-spark-1.3-contributor-free`) today. `muse-spark-1.2-contributor-free`, `qwen3.6-plus-free`, and `minimax-m2.1/m2.5/m3-free` are all `status: deprecated` on models.dev — the raw matrix below counts them for upstream-capability reference only, NOT as servable models.

### Upstream surface matrix (capability reference; "free" = cost-0 incl. deprecated)

| Surface | Path | npm | Free (raw) | Free in served set | Live result |
|---|---|---|---|---|---|
| Chat Completions | `/inference/v1/chat/completions` | `@ai-sdk/openai-compatible` / unset | 34 | 8 | 200 SSE (`mimo-v2.6-flash-free`) |
| Responses | `/inference/v1/responses` | `@ai-sdk/openai` | 2 | 1 | 200 SSE (`muse-spark-1.3-contributor-free`, flat `read` tool) |
| Anthropic Messages | `/inference/v1/messages` | `@ai-sdk/anthropic` | 4 | 0 (all deprecated) | endpoint valid; free models "Model is unavailable"; paid `claude-haiku-4-5` → 402 |
| Gemini | `/inference/v1/models/{m}:generateContent` | `@ai-sdk/google` | 0 | 0 | endpoint exists; `gemini-3-flash` → 402 |
| Mistral | `/inference/v1/chat/completions` | `@ai-sdk/mistral` | 0 | 0 | route exists; `mistral-large-4` not free |

**Value per direction (drives sequencing):** chat→responses translation (Responses-speaking client, chat-native model) unlocks all 8 served models for Responses clients (Codex-style agents). responses→chat translation (2b) unlocks exactly 1 model (`muse-spark-1.3`) for chat clients today.

---

## Phase D — Docs sync (lands with Phase 1)

The amended spec and ADR 0020 record the *opposite* surface decision; both must move with the code or the decision record lies:

- **ADR 0021** supersedes ADR 0020's "surface passthrough, no family mapping" decision (0020's other decisions — verbatim status passthrough, released-client impersonation, cold-start 503, envelope reuse — stand).
- **Spec** (`2026-10-15-opencode-provider-design.md`): Routing loses "forwards the requested path verbatim"; gains native-surface dispatch + translation; the stale "models.dev has no per-model npm" amendment note is corrected; Task 0 outcomes (UA 1.18.30 full form accepted / 1.19.0 rejected; gate requires stream + read tool + x-opencode-*) are recorded.
- **CONTEXT.md**: opencode terms — surface dispatch, free-tier gate.
- **Header comments** that restate passthrough semantics: `OpencodeRouteGate.swift` ("no family mapping"), `OpencodeRouter.swift` (`inferenceURL` "forwarded verbatim").

## Phase 0 — Catalog: persist `provider.npm` → surface

**File:** `Quotio/Services/Opencode/OpencodeModelCatalog.swift`, `catalog-v2.json`

- `OpencodeSurface` enum: `chat, responses, messages, gemini, mistral`.
- Extend the catalog entry with `surface: OpencodeSurface?`, resolved at refresh with explicit precedence:
  1. per-model `provider.npm` (models.dev model-level override),
  2. else provider-level `npm`,
  3. else/unknown → `chat` (upstream default).

  | npm | surface |
  |---|---|
  | `@ai-sdk/openai` | `responses` |
  | `@ai-sdk/openai-compatible`, missing | `chat` |
  | `@ai-sdk/anthropic` | `messages` |
  | `@ai-sdk/google` | `gemini` |
  | `@ai-sdk/mistral` | `mistral` |

- `modelsdev-cache-v1.json` `Entry` gains an optional `npm` field (additive — old caches decode with nil).
- Schema bump on the persisted resolved catalog (`catalog-v2.json`); backwards-compatible decode of v1 snapshots: entries without surface decode as `nil` and resolve to `.chat` at lookup — a legacy-default window that `prime()`'s startup refresh closes in seconds (accepted; mis-dispatch inside the window degrades to the pre-dispatch verbatim-400 behavior, never a crash or a wrong-model answer).
- Synchronous `surface(for:)` on the lock-protected box (the request path is nonisolated).

## Phase 1 — Surface dispatch in `OpencodeRouter`

**File:** `Quotio/Services/Opencode/OpencodeRouter.swift`

- `open(requestBody:route:)` currently forwards to the client-chosen surface. Change:
  1. Parse model id → catalog lookup → `nativeSurface`.
  2. `clientSurface == nativeSurface` → passthrough path (unchanged upstream body shaping semantics, Phase 3 refines shape).
  3. `client == .responses && native == .chat` → Phase 2a translation, post to chat surface, translate stream back.
  4. `client == .chat && native == .responses` → Phase 2b — **deferred**: explicit 422 `unsupported_surface` naming the required surface (better than today's confusing upstream `400 ModelProtocolUnsupported`; see Decision point).
  5. `nativeSurface` ∈ {`messages`, `gemini`, `mistral`} → 422 `unsupported_surface` (`messages` until Phase 5 — there is no client-facing `/v1/messages`, so a messages-native model is unservable pre-Phase-5 exactly like gemini/mistral).
- `inferenceURL` takes the surface, not the route; add the `/v1/messages` path mapping for completeness.
- The opened-stream handoff carries a small dispatch plan (client surface, native surface, translated?) so ProxyBridge doesn't re-derive it.

**Non-streaming clients — all arms (B3):** upstream is forced `stream:true`, so a client that sent `stream:false` must get one JSON body, never SSE. The response head is written only after aggregation (`Content-Length` exact); a mid-aggregation failure is a **true HTTP 502** — nothing was written yet (issue #9 precedent). Per arm:

| Arm | Aggregator |
|---|---|
| passthrough, chat native | `QoderCompletionAggregator.completionJSON(requestModel:)` (reused as-is; consumes raw upstream chat SSE, skips `[DONE]`) |
| passthrough, responses native | new `OpencodeResponsesAggregator` — capture the `response.completed` event's response object directly; delta-fold fallback if the terminal event never arrives |
| 2a (responses client, chat native) | `QoderCompletionAggregator.responsesObject(requestModel:)` (reused as-is) |

This is also a **bug fix for today**: the current passthrough arm forces `stream:true` and pumps SSE verbatim, so `stream:false` clients already receive a broken SSE body.

## Phase 2a — chat→responses translation (reuse-heavy)

**New file:** `Quotio/Services/Opencode/OpencodeProtocolMapper.swift` — `responsesRequestToChat(json:) throws -> Data`:

- Reuse `QoderResponsesTranslator.parseResponses` + `synthesizeChatBody(from:)` for structure: `input` items → `messages` (system/developer/user/assistant/tool roles pass through losslessly, including interleaved system messages — no `instructions`-flattening in this direction), flat `tools` → nested chat shape, `max_output_tokens` → BOTH chat spellings (an openai-compatible upstream may honor only legacy `max_tokens` — dropping it silently loses the cap; verified live), `instructions` → prepended developer message, reasoning intent → `reasoning_effort`.
- Overlay onto the synthesized body (fields the DTO does not carry):
  - `temperature`, `top_p` — passthrough.
  - `tool_choice`: string values passthrough; `{type:"function", name:X}` → `{type:"function", function:{name:X}}`.
  - `text.format` → `response_format`: `json_object` passthrough; `json_schema` → `{type:"json_schema", json_schema:{…}}`; anything else dropped.
  - `stream_options.include_usage: true` — always injected on this arm (the Responses contract puts usage on `response.completed`; the chat upstream only emits usage when asked). Mirrors the Qoder `responsesMode` rule (ProxyBridge.swift:1736).
- **Hard-fail carve-out (S2):** `previous_response_id` / `conversation` (server-side state) → 400 with a clear message — translating them to stateless chat by dropping would silently lose the entire conversation. All other unknown fields still drop silently; upstream validation is the arbiter.
- Stream back: pump upstream chat SSE → `QoderResponsesAdapter` → Responses events (verified decoupled from Qoder envelope internals; skips `[DONE]`; `errorEvent`/`finish` provide the terminals). Mid-stream failure → `errorEvent` terminal frame (ADR 0010 precedent; the 200 head already shipped).

**Error bodies (B2):** pre-stream non-2xx upstream statuses relay **verbatim** — OpenAI's `{"error":{…}}` envelope is shared across both surfaces, so a Responses client already receives a well-formed error. Mid-stream failures on the TRANSLATED arm get Responses-shaped terminal `error` events (above); the same-surface passthrough arm truncates exactly like a real opencode client (ADR 0020 posture — no fabricated frames on a surface the client picked itself). Live probes (Verification) confirm the upstream error envelope really is shared.

## Phase 2b — responses→chat translation (DEFERRED — decision point)

Not in this pass. `chatRequestToResponses` (`messages` → `input` items with **interleaved** system/developer mapped in place — do NOT flatten everything into `instructions`; `instructions` takes only a leading system message if the conversation starts with one), plus `OpencodeChatSSEAdapter` (responses SSE → chat chunks): `response.output_text.delta` → `delta.content`; `response.output_item.done` function_call → `delta.tool_calls`; `response.completed` → `finish_reason` + `usage`; **`response.incomplete`** (`reason:"max_output_tokens"`) → `finish_reason:"length"`; `response.failed` → terminal error frame; reasoning-summary deltas → decide drop vs `<think>` tags (`QoderThinkingTagParser` precedent); stamp `object:"chat.completion.chunk"`, stable ids, and `data: [DONE]`.

**Decision point when this phase is reached:** today it unlocks exactly one model (`muse-spark-1.3-contributor-free`) for chat-surface clients; re-check the served set then — if no responses-native free model exists, skip. Until 2b lands, chat-surface requests for responses-native models get the 422 with the required-surface message.

## Phase 3 — Free-tier gate conformance fix

**File:** `OpencodeRouter.swift` (`shapeUpstreamBody(targetSurface:)`)

- Emit the injected `read` tool in the **target** surface's shape:
  - chat → `{"type":"function","function":{"name":"read",…}}`
  - responses → `{"type":"function","name":"read",…}` flat
- Normalize client tools: for any tool whose resolved name ∈ `{read, bash, write, edit, glob, grep}` (**six** gated names) with missing/empty `parameters.properties`, substitute the real opencode schema for that tool — the **six** canonical schemas embedded as constants, pinned from `sst/opencode` at the UA-pinned version with a provenance comment.
- Keep: prefix strip, `stream:true` upstream, verbatim status/error forwarding, `x-opencode-*`/UA headers untouched.

## Phase 4 — Model advertisement hygiene

**Files:** `OpencodeModelCatalog.swift`, `ProxyBridge.swift` (models snapshot)

- `/v1/models` listing for `opencode/`: **filter** (decided — not annotate) to models servable on at least one client surface: chat-native (both surfaces) and responses-native (native surface; chat surface 422s until 2b). Exclude `messages`/`gemini`/`mistral`-native (currently a no-op — zero such models in the served set — but the mechanism guards future free models).
- Direct request for a model on an unsupported pairing → 422 `unsupported_surface` (Phase 1) instead of upstream 400/404 noise.

## Phase 5 (deferred) — Anthropic Messages

- `chatRequestToMessages` / `messagesSSE→chatSSE` for anthropic-surface models. Deferred: **zero** anthropic-surface models are in the served set today (all four cost-0 anthropic models are `status: deprecated` on models.dev and absent from the live free set) — there is no user-facing benefit until one un-deprecates. The dispatch seam makes this a new mapper pair only.

---

## Testing

`QuotioTests/` — mirror the Qoder test style (mock `OpencodeUpstreamClientProtocol` already exists):

1. `shapeUpstreamBody`: per-surface `read` shape; gated-name schema normalization (all six); unknown names untouched; `include_usage` injection rules.
2. `OpencodeProtocolMapper` (2a request): fixture JSON pairs — `input` items → messages (incl. interleaved system), tools both shapes, token fields, `tool_choice` both forms, `text.format` → `response_format`, `temperature`/`top_p` passthrough, `previous_response_id`/`conversation` → 400.
3. `OpencodeResponsesAggregator`: completed-event capture; delta-fold fallback; failed/incomplete events.
4. Router dispatch: scripted mock upstream asserting URL = native surface per model; 422 for gemini/mistral/messages-native; 400 for `previous_response_id`; 2a body reaches upstream as chat JSON (stream:true + chat-shape read tool + include_usage).
5. Non-stream aggregation: all three arms; mid-aggregation failure → true 502.
6. Catalog: npm precedence (per-model beats provider-level; unknown → chat); v1 snapshot decodes with surface nil → `.chat` at lookup; v2 round-trip; `surface(for:)` sync surface.
7. Advertisement: servable filter excludes `messages`/`gemini`/`mistral`-native entries.
8. Reused-component seams: `QoderResponsesAdapter` fed raw upstream-style chat SSE incl. `data: [DONE]` (regression: skips sentinel); `QoderCompletionAggregator` on raw upstream chunks.

## Verification (live)

- **VERIFIED 2026-10-15** (fresh Debug build, real upstream, `mimo-v2.6-flash-free` + `muse-spark-1.3-contributor-free`): all cells pass — ① chat×mimo stream (verbatim SSE), ② chat×mimo stream:false (single `chat.completion` JSON, usage + model echo — the B3 fix), ③ responses×mimo stream (**2a translated body cleared the free-tier gate**; `response.created`… events), ④ responses×mimo stream:false (`response` object via `responsesObject`), ⑤ responses×muse-spark stream (native passthrough), ⑥ responses×muse-spark stream:false (terminal-event capture — full response with usage), ⑦ chat×muse-spark → 422 naming `/v1/responses`, ⑧ `previous_response_id` → 400 with the resend hint. `/v1/models` advertised 10 opencode entries (9 chat + muse-spark; no messages/gemini). ZCode end-to-end (chat-surface cells) left for the user's own client.
- **Translated-body gate probes (B4):** the original probes used native-shape bodies only. Probe each direction with the actual translated body shape through the running proxy — 2a (responses client → translated chat body) must clear the gate (200 SSE). A 403 `FreeTierError` here means the gate inspects deeper body structure than the matrix showed — escalate before shipping. *(Done — see ③ above.)*
- Rebuild app, run the 2×2 matrix on `:8317` — all four cells return usable responses (muse-spark×responses passthrough, mimo×chat passthrough, mimo×responses via 2a; muse-spark×chat = expected 422 until 2b). Plus a stream:false cell on each arm (single JSON body, correct `object` type). *(Done.)*
- ZCode end-to-end covers only the chat-surface cells; the responses-surface cells need a Responses-speaking client (plain `curl` against `localhost:8317` is fine — the TLS gate is upstream-side only; the local hop is plain HTTP).
- `xcodebuild -project Quotio.xcodeproj -scheme Quotio -configuration Debug build` + `xcodebuild test`. *(Both green, full suite.)*

## Risks / non-obvious constraints

- **Do not regress transport fingerprint:** the gate rejects non-Apple TLS stacks (curl = 403). All upstream calls must stay on `URLSession`. Translators are pure JSON — they never touch transport.
- **Gate may tighten to content-matching schemas** → keep the real opencode schemas for the six gated names, not placeholders; pin the source version.
- **The model may actually call the injected `read` tool** — a foreign client (ZCode) that never defined `read` receives an unknown `tool_call`. True today already; translation multiplies the arms where it can happen. Documented tradeoff of the gate, not a regression.
- **Schema substitution changes model-visible schemas** for gated-named client tools with degenerate `parameters` — the price of the gate; substitution only fires on missing/empty properties.
- `x-opencode-session`/`request` IDs and pinned UA must stay as-is.
- Reasoning fields, `function_call` history, and image parts in translation are the fidelity edges where semantics can be silently lost; covered by fixture tests (2b carries the full list; 2a is lossless on message roles by construction).
- `stop` sequences (chat) have no Responses equivalent — documented drop when crossing to responses-native (2b); nothing to carry in 2a.
