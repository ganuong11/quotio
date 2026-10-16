# GET /v1/models is intercepted and merged with the Qoder catalog

## Context

ADR 0003 §3 chose to leave `GET /v1/models` as a pure passthrough to CPA: Qoder
models would not be advertised via the OpenAI catalog endpoint, and users would
hardcode `qoder/<id>` in their agent config. That was a Phase 2 minimum-surface
trade — ProxyBridge stayed a byte-forwarder plus a Qoder diversion, and CPA's
registry was left untouched (CPA does not know the `qoder/` namespace).

The cost the trade deferred: **CLI agents cannot auto-discover Qoder models**.
Model-discovery clients (e.g. agents that poll `/v1/models` to populate a model
picker, or tools that validate a configured model id against the catalog) never
see `qoder/<id>`. Users have to know the Qoder ids out-of-band. Issue #10 was
filed specifically to reverse this trade, and the gap it describes is the
trigger for this ADR.

`GET /v1/models` was never matched by the ADR 0009 conjunctive gate (it carries
no body model, so the `model.hasPrefix("qoder/")` conjunct fails) and so always
fell through to CPA. ADR 0009 §Consequences anticipated exactly this: "#10 will
intercept it separately at the path level, independent of this gate." This ADR
records that interception.

## Decision

ProxyBridge now intercepts `GET /v1/models` at the **path level**, before the
ADR 0009 gate is consulted, and answers it with CPA's list merged with the
Qoder catalog. The merge is implemented as a pure helper (`QoderModelsMerger`,
side-effect-free, unit-tested without NWConnection) and the network half lives
in a new `ProxyBridge.serveModelsList`.

The merged entry shape, appended under `qoder/<id>` per catalog key:

```json
{ "id": "qoder/<key>", "object": "model", "created": <catalogEpoch>, "owned_by": "qoder" }
```

### Key invariants

- **Path-level intercept, independent of the ADR 0009 gate.** The gate never
  matched `/v1/models` (no body model on a GET) and still doesn't. The
  intercept runs first in `processRequest`, then the existing CPA fallback and
  Qoder branch are untouched.
- **Static seed is the enabled set.** All entries from `QoderModelRegistry`
  (refreshed 2026-08-03) are advertised. There is no per-model enabled flag;
  the dynamic registry (#446) will add one when it lands. `catalogKeys` (a new
  ORDERED accessor) is the enumeration source — `knownIDs` is a `Set` and its
  iteration order is unstable.
- **Merge only when `qoderRouter` is non-nil.** Advertising Qoder models while
  the Qoder branch is disabled (no router wired) would be a lie: the merged
  `qoder/<id>` ids couldn't be served. With a nil router, `serveModelsList`
  still proxies to CPA and forwards its raw response (the merge attempt is
  skipped, the passthrough behavior of ADR 0003 §3 is preserved). The router
  read happens on MainActor (`qoderRouter` is MainActor-isolated); the rest of
  `serveModelsList` is `nonisolated`, mirroring `forwardRequest`.
- **Endpoint stays on CPA's auth surface.** Client headers (Authorization etc.)
  are forwarded verbatim to CPA. CPA's `AuthMiddleware` applies to `/v1/models`
  and the client's credentials must reach it. The QoderAccessValidator (ADR
  0008) is NOT involved — this endpoint is not a Qoder call.
- **Any failure degrades to raw passthrough.** If CPA returns non-2xx, if the
  body is unparseable as the OpenAI models-list shape, if `extractHTTPBody`
  fails, or if the merge returns nil, `serveModelsList` forwards CPA's RAW
  response bytes verbatim (status line included) to the agent. Model discovery
  must never break because we tried to be clever. CPA's own error envelopes
  (e.g. 401 Unauthorized) stay visible to the agent.
- **Bounded accumulation.** The merged response is drained into a single
  `Data` buffer capped at 16 MiB. A models list is kilobytes; exceeding the cap
  signals a misbehaving upstream, so `serveModelsList` emits a 502 rather than
  risk an unbounded buffer. The Connection: close that `forwardRequest`
  upstream forces for unrelated reasons guarantees the full response lands
  before EOF, so accumulate-until-close is correct framing.

## Considered Options

- **Status quo (pure passthrough, ADR 0003 §3).** Rejected: model-discovery
  clients can't see `qoder/<id>`, which is the exact issue #10 reports. The
  trade was always "lowest implementation cost, highest UX cost"; #10 cashes in
  some implementation cost to remove the UX cost.
- **Advertise Qoder models via CPA's config.** Rejected: CPA does not know the
  `qoder/` namespace (ADR 0003 keeps Qoder out of its registry, and ADR 0001
  routes Qoder traffic direct to api3.qoder.sh, bypassing CPA). Adding Qoder to
  CPA's config would either need CPA-side changes (out of scope — Quotio
  doesn't own CPA's protocol code) or a leaky abstraction where CPA advertises
  models it can't serve.
- **Merge with the dynamic catalog now.** Rejected: the dynamic fetch
  (COSY-signed `GET /algo/api/v2/model/list?Encode=1`) is its own follow-up
  (#446) and needs a working COSY signer before first launch (cold cache). The
  static seed ships first — issue #10 explicitly allows this — and the dynamic
  registry layers on top by replacing the seed, not by changing the merge
  surface.
- **Streaming merge (incremental parse as bytes arrive).** Rejected: the models
  list is small (KB), `Connection: close` upstream means the full response
  arrives before EOF anyway, and the pure/`nonisolated` helper split keeps the
  merge unit-testable. A streaming merge would complicate both the network code
  and the tests for no measurable benefit.

## Consequences

- ProxyBridge now owns response-shaping for exactly one endpoint (`GET
  /v1/models`). This is the trade ADR 0003 §3 deferred — now deliberate. The
  rest of the proxy surface stays byte-forwarding.
- The merged list drifts with the static seed until #446 lands (the
  dynamic-fetch follow-up). Mitigated today by passing unknown ids through to
  the gateway rather than 404-ing (ADR 0003 §Consequences) — discovery is
  best-effort, routing is permissive.
- The fallback-to-raw keeps CPA errors visible: a 401 from CPA's AuthMiddleware
  is forwarded verbatim, so a misconfigured client gets the real CPA error
  rather than a Qoder-shaped one.
- The merge is pinned as a pure function (`QoderModelsMergerTests`) so the
  network path can change without the merge semantics drifting.
- The merge is only attempted when `qoderRouter` is non-nil — so a Quotio
  install with Qoder disabled sees the unchanged CPA catalog (no phantom
  `qoder/<id>` entries).
