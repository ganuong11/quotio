# Qoder routing surface: prefix-gated, hardcoded catalog, /v1/models passthrough

## Context

ADR 0001 put COSY signing inside `ProxyBridge`. That raises three coupled
questions: how does ProxyBridge know a request is Qoder-bound, where does the
list of valid Qoder models come from, and who answers `/v1/models` for Qoder.

ProxyBridge already parses the request body's `model:` field for telemetry
(`extractMetadata`), so the parsing seam exists; the choice is what namespace
Qoder lives in and how visible it is to CPA and to CLI agents.

## Decision

Three facets, all chosen for minimum surface in Phase 2:

1. **Model namespace is prefixed: `qoder/<id>`.** ProxyBridge routes any request
   whose `model:` starts with `qoder/` to the COSY path; everything else forwards
   to CPA unchanged. The prefix is stripped before the ID is sent upstream
   (`qoder/auto` → `auto`).
2. **Model catalog is hardcoded** in Phase 2 as a Swift constant seeding the
   routing whitelist (15 known global IDs as of the 2026-08-03 catalog refresh:
   `auto`, `ultimate`, `performance`, `efficient`, `lite`, `qmodel`,
   `qmodel_latest`, `qmodel_38max`, `dmodel`, `dfmodel`, `gm51model`, `kmodel`,
   `kmodel_latest`, `mmodel`, `cmodel`; see `QoderModelRegistry.entries` for the
   live list). Unknown `qoder/<id>` is forwarded anyway —
   the catalog is a display hint, not a gate; Qoder rejects invalid IDs upstream.
3. **`/v1/models` passes through to CPA untouched.** Qoder models are not
   advertised to CLI agents via the OpenAI catalog endpoint. Users hardcode
   `qoder/auto` etc. in their agent config; Quotio may surface the model list
   in-app as documentation.

   > **Superseded by ADR 0016 for the `/v1/models` facet** — `GET /v1/models`
   > is now intercepted by ProxyBridge and answered with CPA's list merged with
   > the Qoder catalog under `qoder/<id>`. §1 and §2 stand.

The registry sits behind an actor so a future dynamic fetch (COSY-signed
`/model/list?Encode=1`) can slot in without touching the routing path. When
enabled, the cache lives at `~/Library/Application Support/Quotio/qoder-models.json`
and refreshes on-demand when the model-reference UI opens.

## Considered Options

- **Namespace: aliased (`qoder-*`) or shadow (raw `auto`, `qwen3.7-plus`).**
  Rejected: shadow collides structurally (`auto` is used by many providers);
  aliased is a style preference with no upside over `qoder/`.
- **Catalog: dynamic fetch from day one.** Rejected for Phase 2: the only
  consumer would be the routing gate, which a hardcoded list satisfies. Dynamic
  fetch also needs a working COSY signer before first launch (cold cache), so a
  static seed is required regardless. Dynamic is parked behind the registry
  actor for a later upgrade.
- **`/v1/models`: intercept, call CPA, merge Qoder entries.** Rejected: makes
  ProxyBridge own response-shaping, not just byte-forwarding + Qoder diversion.
  Highest UX cost (auto-discovery wouldn't work), lowest implementation cost —
  the right trade for a tracer bullet.

## Consequences

- CLI agents cannot auto-discover Qoder models. Agent config must hardcode
  `qoder/<id>`. Acceptable for Phase 2; revisit if users hit it often.
- ProxyBridge's routing rule is a single prefix test, not a registry membership
  lookup — keeps the COSY branch cheap and the code honest.
- The hardcoded catalog will drift silently when Qoder adds/removes models.
  Mitigated by passing unknown IDs through to the gateway rather than 404-ing.
- If dynamic fetch is added later, it layers on top: refresh the registry actor's
  backing store, routing logic unchanged.
