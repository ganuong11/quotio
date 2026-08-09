# Qoder OpenAI Proxy Gap Analysis

> **Resolution status (2026-08-09):** This report was grilling input for a
> `/grill-with-docs` session. The contract-faithfulness scope (Q1) closes the 9
> findings that are unambiguous bugs/security holes without reversing any ADR;
> the other 5 are deferred to issues #24, #9–#12. Listener-bind hardening
> split out as #13; Tier 2/Tier 3 buffer work as #14/#15. Decisions, ADRs,
> and the 4-commit execution sequence live in
> [`docs/qoder-openai-proxy-fix-plan.md`](qoder-openai-proxy-fix-plan.md).
>
> Per-finding resolution:
> - **P0 auth** → ADR 0008 (mirror CPA's access surface); #13 (listener bind).
> - **P1 finish_reason** → Q5 decision (read stash in `finish()`); ADR 0011 (template).
> - **P1 endpoint gate** → ADR 0009 (allowlist + Qoder-owned 404).
> - **P1/P2 non-stream** → deferred to #9.
> - **P1 developer role** → Q7 decision (rewrite to `system`).
> - **P2 error envelopes** → ADR 0010 (port CPA `BuildErrorResponseBody`).
> - **P2 stream_options** → Q9 decision (gate on `include_usage`); ADR 0011.
> - **P2 canonical chunk shape** → ADR 0011 (always-carried template).
> - **P2 request parameters** → partially in #9/#11; capability table deferred.
> - **P2 cancellation** → ADR 0012 (store pump Task handle).
> - **P2 buffering** → ADR 0013 (Tier 1 caps); #14 (Tier 2); #15 (Tier 3).
> - **P3 failover** → deferred to #12.
> - **P3 `/v1/models`** → deferred to #10 (reverses ADR 0003 §3); #24 (dynamic).

## Scope

This report compares:

- upstream [`router-for-me/CLIProxyAPI`](https://github.com/router-for-me/CLIProxyAPI) at commit [`197f520426374e514218ed155933ac546c98d345`](https://github.com/router-for-me/CLIProxyAPI/commit/197f520426374e514218ed155933ac546c98d345) (2026-08-08), and
- Quotio's Qoder-only OpenAI-compatible path at local commit `8349494c35332f2107bc2ffea705c82f47a77479`.

The comparison intentionally excludes providers that Quotio forwards unchanged to CLIProxyAPI. It evaluates only requests intercepted because their body model starts with `qoder/`.

OpenAI contract references use the official [`openai/openai-openapi`](https://github.com/openai/openai-openapi) specification at commit [`c309ca176bc22c6075a0c2c2543f2ac4f307c447`](https://github.com/openai/openai-openapi/commit/c309ca176bc22c6075a0c2c2543f2ac4f307c447) (2026-08-08).

## Executive summary

The Qoder implementation already has the difficult provider-specific core: PAT exchange, COSY signing, WAF encoding, multi-account failover, reasoning and image translation, tool-call streaming repair, usage capture, and pre-handoff detection of quota errors embedded inside an HTTP 200 SSE stream.

Its main weaknesses are now at the **OpenAI HTTP contract boundary**, not the Qoder protocol boundary.

The highest-priority issues are:

1. **Security: Qoder bypasses CLIProxyAPI API-key authentication.** Any non-empty Bearer token is accepted. This is especially serious when Quotio exposes its user-facing bridge through the built-in Cloudflare Quick Tunnel.
2. **Correctness: `finish_reason` is lost when content and finish reason arrive in the same upstream frame.**
3. **Compatibility: only streaming Chat Completions is supported, while interception is path-agnostic.** Non-streaming, Responses API, and legacy Completions clients do not get clean endpoint-specific behavior.
4. **Compatibility: developer instructions are silently dropped.**
5. **Protocol fidelity: errors are plain text, usage ignores `stream_options`, and generated chunks omit some canonical fields.**
6. **Robustness: cancellation is indirect, request/SSE buffers are unbounded, and a two-second first-frame stall is always classified as quota.**

## What Quotio already does well

| Area | Quotio Qoder implementation |
|---|---|
| Routing isolation | Only `qoder/*` models take the native Qoder path; non-Qoder traffic remains on the CLIProxyAPI forwarding path (`Quotio/Services/Proxy/ProxyBridge.swift:497-545`). |
| Provider protocol | WAF body encoding and COSY signing are isolated in dedicated components (`QoderWAFEncoder`, `QoderCOSYSigner`). |
| Chat translation | System/user/assistant/tool messages, function tools, image content, tool-result images, max-token clamping, and reasoning intent are translated in `QoderChatTranslator` (`Quotio/Services/Qoder/QoderChatTranslator.swift:298-408`, `535-657`, `666-814`). |
| Tool streaming | Header-only tool-call fragments are buffered so strict clients do not receive unusable sparse openings (`Quotio/Services/Qoder/QoderSSEReparser.swift:350-379`, `455-511`). |
| Reasoning | Both explicit `reasoning_content` and embedded thinking tags are normalized (`Quotio/Services/Qoder/QoderSSEReparser.swift:318-348`). |
| Usage | Qoder's OpenAI-shaped usage is preserved, including cached and reasoning token detail (`Quotio/Services/Qoder/QoderSSEReparser.swift:303-308`; `ProxyBridge.swift:1077-1114`). |
| Failover | 429 cooldown/rotation, one-shot PAT re-exchange on 401/403, transient retry, and account disable/notification are implemented (`Quotio/Services/Qoder/QoderFailoverRouter.swift:214-304`, `583-663`). |
| In-stream quota signal | The router peeks before committing the agent-facing 200 response and preserves the consumed prefix (`Quotio/Services/Qoder/QoderFailoverRouter.swift:364-379`, `431-528`). |
| Tests | Translator, SSE reparser, chunker, signer, WAF encoder, model registry, and router policy have dedicated XCTest coverage. |

These are substantial strengths. Replacing this path with a generic upstream OpenAI-compatible executor would lose Qoder-specific knowledge unless the same logic were first extracted into a reusable provider adapter.

## Prioritized findings

### P0 — Validate the proxy API key on the Qoder path

**Current behavior**

`ProxyBridge` strips the first space-delimited authorization component and passes the remainder to the router (`Quotio/Services/Proxy/ProxyBridge.swift:904-918`). It does not require the scheme to be `Bearer`, so even `Authorization: Basic anything` produces a non-empty key. The router rejects only an empty value (`Quotio/Services/Qoder/QoderFailoverRouter.swift:150-163`). The value is then used for session-ID hashing, not authentication (`QoderChatTranslator.swift:371-378`).

The normal CLIProxyAPI path authenticates `/v1` through its `AuthMiddleware`, which calls the configured access manager before executing a handler ([upstream `internal/api/server_middleware.go`](https://github.com/router-for-me/CLIProxyAPI/blob/197f520426374e514218ed155933ac546c98d345/internal/api/server_middleware.go#L143-L171); route wiring in [`internal/api/server_routes.go`](https://github.com/router-for-me/CLIProxyAPI/blob/197f520426374e514218ed155933ac546c98d345/internal/api/server_routes.go#L61-L80)).

Quotio creates a local `api-keys:` entry in its CLIProxyAPI configuration (`Quotio/Services/Proxy/CLIProxyManager.swift:303-350`, `471-479`), but the Qoder bypass never validates against it.

The impact is not limited to the local process. `ProxyBridge` creates its `NWListener` without a localhost host constraint (`Quotio/Services/Proxy/ProxyBridge.swift:258-267`), making the unauthenticated Qoder path reachable from interfaces allowed by the host firewall. Quotio can additionally publish that same user-facing port through a public Cloudflare Quick Tunnel (`Quotio/Services/Tunnel/CloudflaredService.swift:57-72`), and auto-start uses the same port (`Quotio/ViewModels/QuotaViewModel.swift:1596-1599`). A reachable caller can therefore spend Qoder quota by supplying any authorization scheme followed by any non-empty value.

**Improve**

- Give `ProxyBridge` a shared access-key validator backed by the same `api-keys:` source used by CLIProxyAPI.
- Require a correctly parsed `Authorization: Bearer <key>` value, not merely a non-empty suffix.
- Use constant-time comparison for candidate keys.
- Return HTTP 401 with an OpenAI error envelope on missing or invalid credentials.
- Add integration tests for missing, malformed, wrong, and valid keys, including a Qoder request through the user-facing listener.

### P1 — Emit deferred `finish_reason`

**Current behavior**

When an upstream choice contains both content and `finish_reason`, `QoderSSEReparser` stores the finish reason instead of emitting it immediately (`Quotio/Services/Qoder/QoderSSEReparser.swift:381-408`). However, `finish()` never reads `stashedFinishReason` (`QoderSSEReparser.swift:176-204`). The declaration and write exist (`QoderSSEReparser.swift:106`, `399`), but there is no terminal flush.

This causes a valid combined-frame response to end with `[DONE]` without any choice carrying `finish_reason`. Existing tests cover separate content and finish frames, not the combined shape (`QuotioTests/QoderSSEReparserTests.swift:592-615`).

CLIProxyAPI's translators build chunks from a template that always contains `delta` and `finish_reason`, matching the canonical chunk schema (for example, [Claude-to-OpenAI translator](https://github.com/router-for-me/CLIProxyAPI/blob/197f520426374e514218ed155933ac546c98d345/internal/translator/claude/openai/chat-completions/claude_openai_response.go#L106-L142)).

**Improve**

- In `finish()`, emit a finish chunk before the usage chunk and `[DONE]` when `stashedFinishReason` is non-nil.
- Clear the stash after emission to preserve idempotence.
- Add a regression test where one choice carries both `delta.content` and `finish_reason`.

### P1 — Make interception endpoint- and method-aware

**Current behavior**

The Qoder branch is selected solely by a `model` prefix in the body (`Quotio/Services/Proxy/ProxyBridge.swift:495-529`). It does not require `POST /v1/chat/completions`.

The implementation behind the branch only understands Chat Completions messages and always calls Qoder's chat SSE gateway (`QoderChatTranslator.swift:853-893`; `QoderGatewayClient.swift:177-190`). Consequently, a body containing `model: "qoder/..."` on `/v1/completions`, `/v1/responses`, or another endpoint can be intercepted and then rejected or misinterpreted.

CLIProxyAPI registers distinct handlers for models, Chat Completions, Completions, Responses, and Responses Compact ([`internal/api/server_routes.go`](https://github.com/router-for-me/CLIProxyAPI/blob/197f520426374e514218ed155933ac546c98d345/internal/api/server_routes.go#L61-L80)).

**Improve**

- Gate the existing translator on exactly `POST /v1/chat/completions` (and any intentionally supported alias).
- Return a clear OpenAI-shaped 404/400 for an explicitly Qoder-targeted unsupported endpoint; do not accidentally fall through to CLIProxyAPI if that would produce a misleading provider error.
- Add route matrix tests covering method, path, content type, body model, and missing body.
- If Responses API support is desired, add a separate Responses-to-Qoder adapter rather than overloading `QoderChatTranslator`.

### P1/P2 — Support non-streaming Chat Completions or reject it consistently

The official OpenAI schema defines `stream` with a default of `false` ([official spec](https://github.com/openai/openai-openapi/blob/c309ca176bc22c6075a0c2c2543f2ac4f307c447/openapi.yaml#L32968-L32977)). CLIProxyAPI streams only when `stream` is explicitly true and otherwise uses its non-stream handler ([`openai_handlers.go`](https://github.com/router-for-me/CLIProxyAPI/blob/197f520426374e514218ed155933ac546c98d345/sdk/api/handlers/openai/openai_handlers.go#L103-L132)).

Quotio rejects explicit `stream: false`, but treats a missing field as streaming (`Quotio/Services/Qoder/QoderFailoverRouter.swift:192-199`, `716-726`). The comment claiming this matches OpenAI's default is incorrect.

**Improve**

Preferred:

- Continue consuming Qoder's SSE upstream, aggregate deltas into one `chat.completion` object, and return `application/json` for `stream != true`.
- Reuse the same accumulated tool-call state and usage data.

Minimum compatible behavior:

- Treat both missing `stream` and explicit `false` as non-streaming, and return a precise OpenAI error until aggregation exists.
- Document that Qoder currently requires `stream: true`.

### P1 — Preserve `developer` messages

OpenAI defines `developer` as an instruction role that replaces prior `system` messages for newer models ([official spec](https://github.com/openai/openai-openapi/blob/c309ca176bc22c6075a0c2c2543f2ac4f307c447/openapi.yaml#L30976-L31006)).

Quotio parses the role, then silently skips it as unknown in `transformMessagesForQoder` (`Quotio/Services/Qoder/QoderChatTranslator.swift:535-615`). A test explicitly locks in that loss (`QuotioTests/QoderChatTranslatorTests.swift:240-248`). This can remove the agent's highest-priority operational instructions.

CLIProxyAPI maps both `system` and `developer` to the provider's instruction channel ([Claude request translator](https://github.com/router-for-me/CLIProxyAPI/blob/197f520426374e514218ed155933ac546c98d345/internal/translator/claude/openai/chat-completions/claude_openai_request.go#L174-L213)).

**Improve**

- Map `developer` to Qoder `system` semantics, preserving relative order among instruction messages.
- Update record-ID hashing through the normalized message list automatically.
- Replace the current skip test with translation and ordering tests.

### P2 — Return OpenAI-compatible error envelopes

`ProxyBridge.sendError` returns `text/plain` (`Quotio/Services/Proxy/ProxyBridge.swift:1419-1455`). The official schema requires an `error` object whose error contains `type`, `message`, `param`, and `code` ([official spec](https://github.com/openai/openai-openapi/blob/c309ca176bc22c6075a0c2c2543f2ac4f307c447/openapi.yaml#L37858-L37901)). CLIProxyAPI uses structured JSON errors and emits a structured terminal SSE error after streaming has begun ([`handlers.go`](https://github.com/router-for-me/CLIProxyAPI/blob/197f520426374e514218ed155933ac546c98d345/sdk/api/handlers/handlers.go#L31-L109); [`openai_handlers.go`](https://github.com/router-for-me/CLIProxyAPI/blob/197f520426374e514218ed155933ac546c98d345/sdk/api/handlers/openai/openai_handlers.go#L667-L690)).

**Improve**

- Centralize a JSON error builder for both Qoder and bridge-level failures.
- Map authentication to 401, malformed requests to 400, no usable accounts/quota exhaustion to an intentional 429 or 503 policy, upstream timeout to 504, and connection failure to 502.
- Include `param` when a known input field is invalid.
- For mid-stream errors, emit an SSE `data: {"error": ...}` frame before `[DONE]` or connection close, rather than silently truncating.
- Add wire-level tests for headers, status, body, redaction, and mid-stream failure.

### P2 — Honor `stream_options.include_usage`

Quotio emits a final usage-only chunk whenever Qoder supplies usage (`QoderSSEReparser.swift:171-203`, `303-308`) without parsing `stream_options`.

The official contract says the extra usage chunk is present only when `stream_options.include_usage` is set; its `choices` must be empty, and earlier chunks have `usage: null` ([official spec](https://github.com/openai/openai-openapi/blob/c309ca176bc22c6075a0c2c2543f2ac4f307c447/openapi.yaml#L31441-L31471), [`CreateChatCompletionStreamResponse`](https://github.com/openai/openai-openapi/blob/c309ca176bc22c6075a0c2c2543f2ac4f307c447/openapi.yaml#L33311-L33445)).

Quotio's usage chunk currently uses the normal builder, producing one `choices` entry instead of an empty array (`QoderSSEReparser.swift:195-200`, `420-432`).

**Improve**

- Parse `stream_options.include_usage` into the request DTO.
- Always capture usage internally for Quotio accounting, but expose it to the client only when requested.
- Build a dedicated usage chunk with `choices: []`.
- When usage is requested, optionally emit `usage: null` on earlier chunks for strict schema parity.

### P2 — Preserve canonical streaming chunk shape

The official chunk choice requires `delta`, `finish_reason`, and `index` ([official spec](https://github.com/openai/openai-openapi/blob/c309ca176bc22c6075a0c2c2543f2ac4f307c447/openapi.yaml#L33322-L33382)). Quotio omits `finish_reason` on content/tool/reasoning chunks and omits `delta` on finish chunks (`QoderSSEReparser.swift:420-432`, `435-510`). It also discards the upstream role-only opener (`QoderSSEReparser.swift:318-380`; test at `QuotioTests/QoderSSEReparserTests.swift:93-103`).

Many clients tolerate this, but strict SDK schemas may not.

**Improve**

- Emit `finish_reason: null` on non-terminal choices.
- Emit `delta: {}` on terminal choices.
- Preserve the first `delta.role: "assistant"` opener where available, or synthesize one consistently.
- Add a schema-conformance fixture test against the official required fields.

### P2 — Do not silently ignore meaningful request parameters

`OpenAIChatRequest` carries only model, messages, tools, max tokens, and reasoning intent (`QoderChatTranslator.swift:33-69`). Other fields are accepted syntactically and discarded.

Highest-impact omissions:

- `tool_choice`: callers cannot force no tool, any tool, or a named tool.
- `response_format` / JSON Schema: structured-output guarantees are silently lost.
- `stop`: requested termination sequences are ignored.
- `temperature`, `top_p`, frequency/presence penalties: generation controls are ignored.
- `n`: the implementation always processes choice index 0 (`QoderSSEReparser.swift:314-317`).
- `logprobs` / `top_logprobs`: requested output metadata is absent.
- `parallel_tool_calls`: no explicit policy or validation.

CLIProxyAPI translators map supported fields such as `top_p`, `stop`, and `tool_choice` where the provider supports them ([Claude request translator](https://github.com/router-for-me/CLIProxyAPI/blob/197f520426374e514218ed155933ac546c98d345/internal/translator/claude/openai/chat-completions/claude_openai_request.go#L143-L172), [tool choice](https://github.com/router-for-me/CLIProxyAPI/blob/197f520426374e514218ed155933ac546c98d345/internal/translator/claude/openai/chat-completions/claude_openai_request.go#L319-L377)).

**Improve**

- Establish a capability table from the live Qoder protocol/catalog.
- Translate fields that Qoder supports.
- Explicitly reject unsupported fields whose silent loss changes semantics (`response_format`, `n > 1`, forced `tool_choice`, logprobs).
- It is acceptable to ignore metadata-only fields such as `user` if documented; behavioral fields should not disappear silently.

### P2 — Propagate client cancellation explicitly

The Qoder pump is an unstructured `Task` with no stored handle (`ProxyBridge.swift:930-1075`). Connection cancellation does not cancel that task directly; it stops only after a future `sendToAgent` fails. Comments at `ProxyBridge.swift:889-929` describe task cancellation and `Task.checkCancellation()`, but that mechanism is not present.

CLIProxyAPI ties execution to the HTTP request context and cancels when the client disconnects ([`openai_handlers.go`](https://github.com/router-for-me/CLIProxyAPI/blob/197f520426374e514218ed155933ac546c98d345/sdk/api/handlers/openai/openai_handlers.go#L472-L502)).

**Improve**

- Store a per-connection Qoder pump task or cancellation closure.
- Cancel the URLSession task/byte source as soon as the agent disconnects or the proxy stops.
- Make `QoderGatewayStream` cancellation explicit instead of relying on iterator abandonment.
- Correct the comments and add an agent-disconnect integration test.

### P2 — Bound HTTP and SSE buffering

`receiveRequest` accumulates until the declared request is complete, with no total header or body limit (`ProxyBridge.swift:356-445`). Converting the accumulated `Data` to `String` and then the body back to `Data` adds copies (`ProxyBridge.swift:451-493`, `919`). `QoderSSEReparser` can also retain an indefinitely long line if upstream never emits a newline.

**Improve**

- Enforce separate limits for header bytes, request body bytes, message count, image/data-URL size, tools count/schema size, and one SSE frame/line.
- Return 413 for oversized requests and a structured upstream-protocol error for oversized frames.
- Parse headers as bytes and slice the body rather than converting the whole request to a Swift `String`.
- Consider moving the Qoder HTTP endpoint to a real HTTP server abstraction long-term; the current hand-written HTTP/1.1 parser also does not support chunked request bodies.

### P3 — Refine failover policy

The Qoder-specific policy is good, but less configurable and less health-aware than CLIProxyAPI's account/model routing:

- Any lack of a first frame within two seconds is classified as quota (`QoderFailoverRouter.swift:403-409`, `482-488`). A slow cold start or proxy delay can cool down a healthy account.
- Cooldown is a fixed 60 seconds and account order is stable (`QoderFailoverRouter.swift:645-681`).
- There are no credential weights, session-sticky account binding, provider-supplied retry timing, or adaptive backoff.

CLIProxyAPI exposes round-robin, weighted round-robin, fill-first, session affinity, and alias pools with before-first-output fallback ([upstream `config.example.yaml`](https://github.com/router-for-me/CLIProxyAPI/blob/197f520426374e514218ed155933ac546c98d345/config.example.yaml#L201-L217), [OpenAI-compatible alias pools](https://github.com/router-for-me/CLIProxyAPI/blob/197f520426374e514218ed155933ac546c98d345/config.example.yaml#L480-L517)).

**Improve**

- Distinguish connect timeout, first-byte timeout, first-complete-frame timeout, and an observed Qoder quota stall.
- Require stronger evidence than one two-second timeout before marking quota; for example, retry once or cross-check the cached quota snapshot.
- Honor `Retry-After` or provider retry data when available.
- Add configurable cooldown/backoff and optional weighted/session-affine account routing.

### P3 — Merge Qoder models into `/v1/models` and refresh dynamically

ADR 0003 intentionally leaves Qoder out of `/v1/models` (`docs/adr/0003-qoder-routing-surface.md:28-31`). This was a reasonable tracer-bullet tradeoff, but it prevents model-discovery clients from finding Qoder.

The registry is hardcoded and explicitly expected to drift (`Quotio/Services/Qoder/QoderModelRegistry.swift:19-29`, `49-53`). CLIProxyAPI builds `/v1/models` from its dynamic registry ([`openai_handlers.go`](https://github.com/router-for-me/CLIProxyAPI/blob/197f520426374e514218ed155933ac546c98d345/sdk/api/handlers/openai/openai_handlers.go#L51-L95)).

**Improve**

- Intercept `GET /v1/models`, fetch the CLIProxyAPI response, and merge enabled Qoder entries using `qoder/<id>`.
- Populate at least `id`, `object`, `created`, and `owned_by`.
- Add a cached, COSY-signed dynamic model-list refresh with the hardcoded registry as cold-start fallback.
- Keep unknown-ID pass-through if desired, but surface stale/unknown status in the UI and telemetry.

## Endpoint scope: what is actually worth adding

For Qoder, prioritize endpoint compatibility in this order:

1. `POST /v1/chat/completions` — finish correctness, auth, non-streaming, request fields.
2. `GET /v1/models` — discoverability and dynamic catalog.
3. `POST /v1/responses` — high value for newer OpenAI/Codex-style clients; translate Responses input/events to the existing Qoder chat core.
4. `POST /v1/completions` — low value; implement only if a real client needs the legacy endpoint.

Do **not** treat upstream image-generation, video, realtime, or unrelated provider routes as Qoder gaps unless Qoder's backend exposes corresponding capabilities. Qoder's existing image support is chat multimodal input/tool-result forwarding, which is a different feature from `/v1/images/*` generation APIs.

## Suggested implementation sequence

1. **Security patch:** shared API-key validation plus 401 JSON errors and integration tests.
2. **SSE correctness patch:** flush stashed finish reason; canonical choice shape; dedicated usage chunk.
3. **Route boundary patch:** method/path gate and route matrix tests.
4. **Instruction/parameter patch:** developer role, `stream_options`, capability validation, explicit rejection of unsupported semantic fields.
5. **Lifecycle hardening:** cancellation handle, buffer limits, timeout/error mapping.
6. **Compatibility expansion:** non-stream aggregation, merged `/v1/models`, then Responses API if demanded.
7. **Operational refinement:** dynamic model registry and configurable/health-aware account selection.

## Testing gaps to add

- Invalid Bearer rejected while valid configured key succeeds.
- Public-listener/tunnel-facing Qoder auth behavior.
- Content and finish reason in the same upstream frame.
- Missing `stream`, explicit false, and explicit true.
- `developer` instruction preservation and ordering.
- Unsupported endpoint/method matrix.
- OpenAI JSON error schema and mid-stream SSE error.
- Usage requested vs not requested; usage chunk has `choices: []`.
- Official required chunk fields on text, reasoning, tool, finish, and usage chunks.
- Forced `tool_choice`, `response_format`, `n > 1`, stop, and unsupported-field policy.
- Agent disconnect cancels the upstream stream promptly.
- Oversized headers/body/image/schema/SSE frame.
- Slow healthy first frame does not incorrectly cool down an account.

## Note on the older comparison document

The existing untracked `docs/openai-proxy-comparison.md` is stale for the current branch. It says Quotio has no native OpenAI proxy and no dedicated ProxyBridge/Qoder tests, both of which are now false. It also compares much of CLIProxyAPI's unrelated provider and media breadth rather than the Qoder-only translation path. This report does not overwrite that user-owned file.
