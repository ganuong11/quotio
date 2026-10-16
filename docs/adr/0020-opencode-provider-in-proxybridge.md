# OpenCode provider: Quotio-native branch inside ProxyBridge

## Context

OpenCode Console offers free inference models behind a device-code OAuth flow
at `https://opencode.ai/console` with inference at
`https://opencode.ai/inference`. Letting OpenAI-protocol agents use those free
models through the local proxy requires an auth/refresh lifecycle CPA cannot
produce: CPA has no concept of a host-keyed `auth.json`, an `opencode*.db`
SQLite store, or opencode's console refresh grant. The Task 0 spike also
showed the upstream free-tier gate is not a plain OpenAI endpoint: it 403s
requests that don't look like a released opencode client (UA version +
`x-opencode-*` metadata + timestamp-encoded `ses_`/`msg_` ids) — a verbatim
replay of a captured released-client request returned 200 SSE, while a
synthetic or wrong-version one was rejected.

Qoder set the precedent (ADR 0001): a provider CPA can't authentically serve
gets a Quotio-native branch inside ProxyBridge — route gate, account-aware
router, upstream client — while all other traffic keeps the CPA path.

## Decision

OpenCode is a first-class provider with a Quotio-native branch inside
ProxyBridge, mirroring the Qoder shape but simpler: **byte-faithful
pass-through, no envelope translation**.

- `AIProvider.opencode` with Quotio-managed device-code login
  (`OpencodeConsoleClient` → vault credential) and read-only detection of the
  system opencode install (`OpencodeCredentialDetector` — `auth.json` and
  `opencode*.db` are read via temporary copies incl. WAL/SHM; the real store
  is never opened for write). Accounts deduplicate by console identity with
  vault preferred over detected.
- `OpencodeModelCatalog` resolves the free set at request time: live
  inference model IDs ∩ models.dev entries with `cost.input == 0`,
  `cost.output == 0`, non-deprecated — minus observed `jev-*`/`systemone`
  ids. Lock-protected synchronous view (`isFree`, `isEmpty`) for the
  nonisolated request path; persisted snapshot + async refresh.
- `OpencodeRouteGate` conjunctive gate (ADR 0009 precedent): `opencode/`
  prefix AND `POST /v1/chat/completions` or `POST /v1/responses` AND
  membership of the free set. Rejected/unknown/paid models never reach CPA.
- `OpencodeRouter` rotates across vault + detected accounts: 401 → next
  account, 429 → cooldown + rotate, transport failure → next; every other
  status (incl. 2xx, 400, 403, 5xx) is handed back verbatim — rotating can't
  fix a request-level rejection. Vault creds refresh via the console grant;
  detected creds are NEVER refreshed — they re-read their store and are
  stale-marked (with notification) when re-auth hasn't happened.
- `ProxyBridge.forwardOpencodeRequest` relays upstream status, headers
  (minus hop-by-hop), and body bytes verbatim through the existing
  `sendToAgent`/pump-task mechanics (ADR 0012). `GET /v1/models` merges
  `opencode/<id>` entries via `OpencodeModelsMerger`, chained after the
  Qoder merge in `finishModelsList` (`mergeModelsBody`).

### Recorded review-driven decisions

- **Surface passthrough, no family mapping.** The client's chosen OpenAI
  surface (`/v1/chat/completions` vs `/v1/responses`) forwards verbatim to
  `<origin>/inference/v1/...`. models.dev carries no per-model npm metadata,
  so there is no sound mapping to enforce — the request arrives on whatever
  surface the client picked.
- **Released-client impersonation.** Upstream requests carry
  `User-Agent: opencode/<released version> ai-sdk/provider-utils/…`, the
  `x-opencode-client`/`x-opencode-project`/`x-opencode-request`/
  `x-opencode-session` headers, and `msg_`/`ses_` ids in opencode's
  timestamp-encoded scheme. No `supports_org_scope`. These are the exact
  knobs the Task 0 spike proved the gate inspects (a recognized released
  version passed; an unrecognized one 403d).
- **Cold-start 503 semantics.** A `.notInFreeSet` verdict on a NON-empty
  catalog is a 404 (`model_not_found` — unknown or paid model). On an EMPTY
  catalog (refresh pending/failed) it is a 503 catalog-unavailable — the
  "unknown" answer is provisional, not a billing signal.
- **Verbatim upstream status passthrough.** After `open`, the upstream
  status line + headers are written back to the agent (hop-by-hop headers
  stripped, `Connection: close` forced). A mid-stream failure truncates
  exactly like a real opencode client sees — no fabricated error frames on
  a surface the client never asked us to author.
- **Reuse of the `QoderOpenAIError` envelope.** `ProxyBridge.sendError`
  builds the ADR 0010 OpenAI error JSON via `QoderOpenAIError.body`; the
  opencode branch reuses it as-is. No opencode twin — the envelope is
  provider-neutral (its "Qoder" name is now historical).
- **Shared `accessValidator` authentication.** The Qoder and opencode
  branches share one API-key auth block (`authenticateProxyRequest`,
  extracted from `forwardQoderRequest`): the validator checks proxy API
  keys and is provider-agnostic — opencode traffic presents the same
  proxy key as everything else.
- **Stale-account observer wiring.** `OpencodeRouter` posts
  `opencodeAccountStale`/`opencodeAccountRecovered`; `QuotaViewModel`
  maps them onto `monitorAccountIssues` by case-insensitive `accountKey`
  (localized `monitor.opencode.stale` message). This was added deliberately
  even though the `qoderPATRevoked` precedent has zero consumers — opencode
  has no quota fetcher, so without the observer a stale detected account
  would silently stop serving.
- **Lifecycle.** `startProxy` wires `opencodeRouter` (with a
  `OpencodeDetectedCache` snapshot refreshed on a 5-minute tick rather than
  per-request disk discovery), primes the persisted catalog, kicks the
  first network refresh, and starts one lifecycle task (catalog 1 h,
  detected 5 min, vault proactive refresh 15 min). `stopProxy` cancels the
  task, removes observers, and nils the router — same nil-router posture
  as Qoder.

## Considered Options

- **CPA openai-compat provider + headers.** Rejected: CPA can't run the
  device-code/refresh lifecycle, can't read opencode's credential stores,
  and can't produce the released-client impersonation (UA + `x-opencode-*`
  + timestamp ids) the free-tier gate requires. A CPA provider would serve
  a 403s-only path.
- **Upstream CPA changes.** Rejected: Quotio doesn't own CPA's protocol
  code; the branch must live in the app. Same argument as ADR 0001.
- **Translate opencode SSE into a normalized OpenAI envelope.** Rejected:
  the Qoder branch translates because Qoder's envelope is proprietary and
  unversioned; opencode's inference surface IS OpenAI-shaped and the client
  picked its surface deliberately. Translation would only add drift.

## Consequences

- We now own opencode protocol drift: a UA version bump in the pinned
  impersonation string is a maintenance item (the gate 403s unrecognized
  versions — the catalog of released versions must be tracked).
- The `opencode*.db` read is a coupling to opencode's internal store
  layout; a schema change degrades detection to `auth.json` only (and a
  changed layout fails closed — read-only copies can't corrupt the store).
- Free-catalog drift: the allowlist tracks live inference ∩ models.dev;
  a model that goes paid disappears on next refresh (requests then 404 —
  correct, protects paid models from accidental forwarding).
- `GET /v1/models` now merges two namespaces (Qoder + opencode) with the
  same degrade-to-raw guarantee ADR 0016 established — discovery can't
  break because a merge failed.
- QuotaViewModel must not be instantiated inside the test host (a deinit
  abort in `swift_task_deinitOnExecutor` — a test-runtime defect, not app
  code); the stale-issue logic is therefore tested as a static pure core.
