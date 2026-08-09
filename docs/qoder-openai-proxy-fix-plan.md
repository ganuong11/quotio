# Qoder OpenAI Proxy — Contract-Faithfulness Fix Plan

This plan operationalizes `docs/qoder-openai-proxy-gap-analysis.md` for the
**contract-faithfulness scope** (Q1 decision): close the 9 findings that are
unambiguously bugs/security-holes and do *not* reverse any ADR. The other 5
findings (non-stream aggregation, `/v1/models` merge, Responses API, dynamic
registry, failover tuning) are deferred to issues
[#9](https://github.com/ganuong11/quotio/issues/9)–#12 and existing
#24; the listener-bind defense-in-depth is #13; Tier 2/Tier 3 buffer work is
#14/#15.

Scope, decisions, and sequencing were produced by a `/grill-with-docs` session.
Each decision's rationale lives in its ADR; this document is the execution map.

## Dependency graph

```
ADR 0010 (error envelope) ──┬──► ADR 0008 (auth, 401)
                             ├──► ADR 0009 (endpoint gate, 404)
                             └──► ADR 0013 (buffer caps, 413 + mid-stream)

ADR 0011 (chunk template) ──┬──► finish_reason flush (Q5)
                             └──► stream_options (Q9, buildUsageChunk)

developer role (Q7) ─────── independent (translator-only)
ADR 0012 (cancellation) ─── independent (lifecycle)
```

## Tickets

The work is broken into 8 tracer-bullet tickets
([#16](https://github.com/ganuong11/quotio/issues/16)–#23), each
declaring its blockers textually (GitHub's native issue-dependency API is not
enabled on this repo; the `## Blocked by` section in each ticket is the
canonical edge). Frontier on publication: **#16** and **#17** (no blockers).

| # | Ticket | Blocked by | Commit |
|---|---|---|---|
| [#16](https://github.com/ganuong11/quotio/issues/16) | Foundation: error envelope + chunk template (ADRs 0010/0011) | — | 1 |
| [#17](https://github.com/ganuong11/quotio/issues/17) | Rewrite `developer` role to `system` | — | 2 |
| [#18](https://github.com/ganuong11/quotio/issues/18) | Preserve deferred `finish_reason` on combined frames | #16 | 2 |
| [#19](https://github.com/ganuong11/quotio/issues/19) | Gate usage chunk on `stream_options.include_usage` | #16 | 2 |
| [#20](https://github.com/ganuong11/quotio/issues/20) | Endpoint/method gate (ADR 0009) | #16 | 2 |
| [#21](https://github.com/ganuong11/quotio/issues/21) | API-key validation (ADR 0008) | #16 | 3 |
| [#22](https://github.com/ganuong11/quotio/issues/22) | Pump cancellation (ADR 0012) | #16 | 4 |
| [#23](https://github.com/ganuong11/quotio/issues/23) | Tier 1 buffer caps (ADR 0013) | #16 | 4 |

## Commit sequence (4 PR-sized commits, each green before the next)

### Commit 1 — Foundation — [#16](https://github.com/ganuong11/quotio/issues/16)

| Change | ADR/decision | Notes |
|---|---|---|
| Error envelope builder | ADR 0010 | Port CPA `BuildErrorResponseBody`; JSON pass-through; status→type map; mid-stream SSE error frame. Replaces `sendError`'s `text/plain`. |
| Chunk template | ADR 0011 | `emitChunk` always stamps `delta` (default `{}`) + `finish_reason` (default `null`); dedicated `buildUsageChunk` (`choices: []`); synthesize `role: assistant` opener once. |

**Tests:** canonical-chunk-shape schema fixture (required fields on
text/reasoning/tool/finish/usage chunks); error-envelope wire tests (status,
type, code, JSON pass-through, mid-stream SSE frame).

### Commit 2 — Contract fixes (ride the foundation) — [#17](https://github.com/ganuong11/quotio/issues/17), [#18](https://github.com/ganuong11/quotio/issues/18), [#19](https://github.com/ganuong11/quotio/issues/19), [#20](https://github.com/ganuong11/quotio/issues/20)

| Change | ADR/decision | Notes |
|---|---|---|
| `finish_reason` flush | Q5 (a) | Read `stashedFinishReason` in `finish()` before usage chunk; clear after. Covers content/reasoning/tool combined frames. |
| `stream_options.include_usage` | Q9 (a) | Parse the field; always capture internally for Quotio accounting; emit client-facing usage chunk only when `include_usage == true`. |
| `developer` role | Q7 (a) | Rewrite `developer` → `system` at translation; collapse the two cases; record-ID hash follows automatically. |
| Endpoint/method gate | ADR 0009 | `isQoderBound` becomes `model qoder/ && POST && /v1/chat/completions`; Qoder-owned 404 for anything else. |

**Tests:** combined-frame `finish_reason` regression (content+finish,
reasoning+finish, tool+finish); `include_usage` on/off; `developer` translation
+ ordering; route matrix (method × path × body-model × content-type).

### Commit 3 — Security — [#21](https://github.com/ganuong11/quotio/issues/21)

| Change | ADR/decision | Notes |
|---|---|---|
| API-key validation | ADR 0008 | `QoderAccessValidator` mirrors CPA's `config_access` provider: five candidate sources, lenient `extractBearerToken`, constant-time compare, 401 envelope. Key set reloaded on `fetchAPIKeys()` cadence. |

**Tests:** auth matrix — missing, malformed-scheme, wrong, valid key; all five
candidate sources; tunnel-listener-facing case. (Listener-bind hardening is
#13, out of this commit.)

### Commit 4 — Robustness — [#22](https://github.com/ganuong11/quotio/issues/22), [#23](https://github.com/ganuong11/quotio/issues/23)

| Change | ADR/decision | Notes |
|---|---|---|
| Cancellation | ADR 0012 | Store pump `Task` handle keyed by `connectionId` on MainActor; cancel from agent connection's `stateUpdateHandler`; `QoderGatewayStream.cancel()` tears down URLSession; fix misleading comment. |
| Buffer bounds | ADR 0013 | Tier 1 only: `MAX_REQUEST_HEADER_BYTES`, `MAX_REQUEST_BODY_BYTES` (shared Qoder+CPA), `MAX_SSE_LINE_BYTES`; 413 + mid-stream error via ADR 0010. |

**Tests:** agent-disconnect cancels upstream promptly; oversized header/body →
413; oversized SSE line → mid-stream error + stream teardown.

## Validation gate per commit

```bash
xcodebuild -project Quotio.xcodeproj -scheme Quotio -configuration Debug build
xcodebuild -project Quotio.xcodeproj -scheme Quotio -configuration Debug test
```

Per AGENTS.md: for provider/proxy/menu-bar changes, also manually verify the
affected flow; for UI changes, check light/dark mode.

## ADRs created by this plan

- [ADR 0008 — Qoder API-key validation](adr/0008-qoder-api-key-validation.md)
- [ADR 0009 — Endpoint/method gate](adr/0009-qoder-endpoint-method-gate.md)
- [ADR 0010 — OpenAI error envelope](adr/0010-qoder-openai-error-envelope.md)
- [ADR 0011 — Streaming chunk template](adr/0011-qoder-streaming-chunk-template.md)
- [ADR 0012 — Pump cancellation](adr/0012-qoder-pump-cancellation.md)
- [ADR 0013 — Buffer bounds (Tier 1)](adr/0013-qoder-buffer-bounds.md)

## Deferred-scope issues

| # | Topic |
|---|---|
| [#24](https://github.com/ganuong11/quotio/issues/24) | Dynamic model registry |
| [#9](https://github.com/ganuong11/quotio/issues/9) | Non-streaming Chat Completions aggregation |
| [#10](https://github.com/ganuong11/quotio/issues/10) | Merge Qoder into `/v1/models` (reverses ADR 0003 §3) |
| [#11](https://github.com/ganuong11/quotio/issues/11) | Responses API adapter |
| [#12](https://github.com/ganuong11/quotio/issues/12) | Failover policy tuning |
| [#13](https://github.com/ganuong11/quotio/issues/13) | Listener-bind + tunnel-exposure hardening |
| [#14](https://github.com/ganuong11/quotio/issues/14) | Translator-level semantic caps (Tier 2) |
| [#15](https://github.com/ganuong11/quotio/issues/15) | Byte-wise HTTP parser + chunked bodies (Tier 3) |
