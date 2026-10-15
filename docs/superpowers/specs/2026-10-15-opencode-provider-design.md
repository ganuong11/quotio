# OpenCode Provider Design

## Intent and why

AI agents pointed at Quotio's proxy speak the OpenAI protocol. OpenCode Console serves a set of free models at `https://opencode.ai/inference` that are gated to real opencode clients — the upstream checks the `User-Agent` header and (for account-scoped access) an OAuth token from the console device flow. The user wants these free models usable by any agent through the proxy, with the upstream unable to distinguish Quotio from a real opencode client, and the free model list refreshed automatically when the proxy starts.

> **Amended 2026-10-15 after plan review**, verified against `sst/opencode` tag `v1.19.0` (latest release, what installed clients run) and branch `dev` (2.0, unreleased): released clients send `User-Agent: opencode/<version>` on model calls; the three-segment `opencode/<channel>/<version>/<cli>` form is 2.0-only — the last segment is `cli`, never `opencode`. `supports_org_scope` in the device-code request and `org_id` in the token response also exist only on 2.0. The Task 0 spike then replaced surface passthrough with surface dispatch — see the second amendment note.

> **Amended again 2026-10-15 (surface-dispatch plan review, ADR 0021)**: two facts moved. (1) The Task 0 spike proved the free-tier gate inspects more than the UA short form — the pinned impersonation is the **full released-client UA** `opencode/1.18.30 ai-sdk/provider-utils/4.0.23 runtime/bun/1.3.14` (observed on the local Homebrew install); the bare `opencode/1.19.0` form is 403'd, as is any unrecognized version. The gate additionally requires `stream:true`, a `read` tool, and the `x-opencode-*` metadata headers. (2) models.dev **now carries per-model `provider.npm` overrides** (66 of 124 `opencode` models at re-verification; e.g. `muse-spark-1.3-contributor-free` → `@ai-sdk/openai`), reversing the earlier "0/123, provider-level only" finding that had motivated surface passthrough. Requests are now dispatched to the model's native surface with translation at the seam — ADR 0021 supersedes ADR 0020's surface-passthrough decision; the implementation plan is `docs/opencode-surface-dispatch-plan.md`.

## Goals

- `.opencode` becomes a first-class `AIProvider` with two credential sources, both visible and selectable as separate accounts **only when they are genuinely different accounts**:
  - Quotio-managed OAuth login (device-code flow, tokens in `MonitorCredentialVault`).
  - Automatic detection of an existing system opencode install's auth (`~/.local/share/opencode/`).
- `ProxyBridge` serves `opencode/<model>` for every model that is currently free (see Catalog below), pass-through to the correct inference endpoint, indistinguishable from a real opencode client.
- At proxy start the OAuth tokens are refreshed where possible and the free-model catalog is re-fetched; both also refresh periodically while the proxy runs.

## Non-goals

- Paid models. Only cost-zero models are exposed, even for accounts with credits.
- Non-OpenAI client surfaces. Only `/v1/chat/completions` and `/v1/responses` are served; each request is dispatched to the model's **native** upstream surface with translation at the seam (ADR 0021 — see Serving). Models whose native surface is `messages`/`gemini`/`mistral` are not advertised and answered `422 unsupported_surface` until a mapper exists. `jev-*-free`/`systemone` models are excluded outright (typed-evaluation API that cannot serve chat).
- Quota/usage display in the Monitor UI. No known per-account quota endpoint; accounts show connection status only.
- Writing anything into the system opencode install's files (see Anti-goals).

## Anti-goals

- Breaking the user's real opencode login. Refreshing an OAuth credential rotates the refresh token server-side; the old one dies. Writing rotated tokens into `auth.json`/`opencode.db`, or refreshing a detected credential out from under the real client, can sign the user's real opencode out. See "Detected credentials".
- Tokens, device codes, or account identifiers in logs or committed files.
- Requiring a CLIProxyAPI (CPA) release or config-schema change.

## Decided how

### Provider and account model

- Add `case opencode = "opencode"` to `AIProvider` (`Quotio/Models/Models.swift`) and satisfy the exhaustive switches (displayName "OpenCode", icon/logo/color, etc.). The compiler lists the sites (eight exhaustive switches today: displayName, iconName, logoAssetName, color, oauthEndpoint, menuBarSymbol, menuBarIconAsset, supportsQuotaOnlyMode).
- Accounts are `MonitorAccount`s. Quotio login accounts: `source: .quotioKeychain`, `credentialReference: "keychain"`, `canDelete: true`, `accountKey` = console user id, `displayName`/`email` = console email. Detected accounts: `source: .nativeCredential`, `credentialReference` = path into the opencode store (see below), `canDelete: false`.
- Dedup is free: `MonitorAccount.deduplicationKey` (`provider:accountKey-lowercased`) plus `MonitorAccountDiscovery.selectPreferred` already collapse same-account duplicates, with `.quotioKeychain` (priority 300) winning over `.nativeCredential` (200). **Canonical `accountKey` = console `user.id`** for both sources (stable across email changes; `MonitorAccount.id` is a fingerprint of `provider|accountKey`, so same-key sources collapse to the same row id as well). Fallback order when the id can't be resolved: `email`, then a stable fingerprint of `credentialReference + server` — the last case can produce an undeduped duplicate if the same account also logs in via Quotio, accepted as a pathological edge.
- Identity resolution for detected credentials uses only stored metadata (`metadata.accountID`/`metadata.email`). No network call during discovery (amended): discovery stays file-only, and a network-dependent accountKey would make dedup unstable across refreshes. The SQLite store carries `accountID`/`email` in metadata in practice; identity-less records fall back to email, then fingerprint.

### Quotio login (device flow)

In `MonitorOAuthCoordinator`, mirroring `kiroDeviceFlow`:

1. `POST https://opencode.ai/console/auth/device/code` JSON `{client_id: "opencode-cli"}` → `{device_code, user_code, verification_uri_complete, expires_in, interval}`. Do NOT send `supports_org_scope` — it is 2.0-dev-only; no released client sends it, so including it is itself a fingerprint.
2. Open `verification_uri_complete`, surface `user_code` via the existing `.monitorOAuthDeviceCode` notification path.
3. Poll `POST {server}/auth/device/token` `{grant_type: "urn:ietf:params:oauth:grant-type:device_code", device_code, client_id: "opencode-cli"}` every `interval` (min 5s, +5s on `slow_down`) until `{access_token, refresh_token, expires_in, org_id?}` or `expired`. `org_id` is read if present (2.0 backend forward-compat) but 1.19.0 backends never return it.
4. `GET {server}/api/user` and `GET {server}/api/orgs` (Bearer) for `user.id`, `email`, org. Org = `org_id` from the token response if present, else alphabetically-first org (matches released-client behavior). Store `orgID`/`orgName`/`server` in `MonitorOAuthCredential.extra`.

Reference: `packages/core/src/plugin/provider/opencode.ts` in `sst/opencode` (tag `v1.19.0` for released behavior, branch `dev` for 2.0).

### Detected system credentials (read-only)

`MonitorAccountDiscovery` gains `discoverOpencodeCredentials()`, reading opencode's data directory — resolved via `XDG_DATA_HOME` (honored by opencode), default `~/.local/share/opencode`:

- `auth.json` — v1 store, JSON object keyed by host (trailing slashes normalized): `{"https://opencode.ai/console": {"type": "oauth", "access": "...", "refresh": "...", "expires": <ms epoch>, "accountId"?: "..."}}`. Note the field is `accountId` (camelCase) and there is no `email` field. Tolerate key variations; confirm against a live file.
- `opencode*.db` — current store: SQLite `credential` table, `integration_id = 'opencode'`, `value` is a JSON `Credential.OAuth` (`access`, `refresh`, `expires` ms-epoch, `metadata.{server, accountID, email, orgID, orgName}`). Honor `OPENCODE_DB` naming: `opencode.db` on stable channels, `opencode-<channel>.db` otherwise — glob `opencode*.db`.
- **When both sources resolve the same `accountKey`, the SQLite row wins.** Both stores ship in 1.19.0 and 2.0 imports `auth.json` into SQLite once (migration `20260805200742_import_legacy_credentials`), so `auth.json` can linger stale on disk; both are `.nativeCredential` (priority tie), so without an explicit preference discovery order would pick the winner arbitrarily.
- Reading the DB: **copy `opencode*.db` plus its `-wal`/`-shm` siblings to a temp location and open the copy** via SQLite3. A plain read-only open of a WAL database either needs `-shm`/`-wal` writes in the original directory (violating never-write) or, under `immutable=1`, ignores the WAL and can return a stale token forever — which would break the re-read recovery path below. The copy gets the freshest committed state and leaves the originals untouched.

Detected credentials are **never written back and never refreshed by us**. When a detected access token is expired or returns 401, we re-read the store (the real client may have rotated it); if the re-read copy is still expired, that account reports a "signed out / reopen opencode" state and is skipped by the router until it recovers. This is the accepted tradeoff the user chose over write-back.

Quotio-vault credentials refresh via `POST {server}/auth/device/token` `{grant_type: "refresh_token", refresh_token, client_id}`; rotated tokens persist back to the vault only. `invalid_grant` → mark the account needs-auth ("Reconnect OpenCode Console to continue" equivalent).

### Serving (Path B — ProxyBridge branch, Qoder precedent)

CPA stays untouched. New `Quotio/Services/Opencode/` group mirroring the Qoder layout:

- `OpencodeRouteGate` (mirror `QoderRouteGate`, ADR 0009 semantics): conjunctive allowlist — `model` starts with `opencode/`, method `POST`, path `/v1/chat/completions` or `/v1/responses`, model in the free set. The client's surface is the *request* surface only; the upstream target is the model's **native** surface resolved from the catalog (ADR 0021 — same-surface requests pass through, cross-surface requests are translated; `messages`/`gemini`/`mistral`-native models → `422 unsupported_surface` without contacting upstream). The gate distinguishes `.notInFreeSet` (prefix/POST/path OK but outside the free set → `404 model_not_found`) from structural `.rejected` (wrong method/path → `404`). No `opencode/` prefix → CPA passthrough unchanged.
- **The catalog is a hard allowlist, not just an advertisement.** An `opencode/<model>` request for a model absent from the resolved free set — paid, deprecated, or unknown — gets a provider-owned `404 model_not_found`; it is never forwarded. This is deliberate enforcement of the free-only scope: pass-through of a paid model on a credit-bearing account would spend real money. Cold start: if the catalog has never resolved (first fetch failed and no persisted snapshot), `opencode/` requests get a `503` catalog-unavailable envelope rather than a misleading `model_not_found` — implemented as `.notInFreeSet` + `catalog.isEmpty` at the ProxyBridge call site.
- `OpencodeRouter` (slim `QoderFailoverRouter` analog): enumerate enabled, non-disabled opencode accounts from the vault (QoderFailoverRouter precedent) **plus a periodically-refreshed snapshot of detected credentials** — not a full `MonitorAccountDiscovery.discover()` per request, which rescans every provider's files and keychains on each call. Per request, the selected account's credential is fetched targeted (`vault.credential(for:)` for Quotio logins, `OpencodeCredentialDetector.reload(sourcePath:)` for detected ones). Vault credentials expiring within a margin are refreshed first (rotated tokens persist to the vault only). On 401 mark/rotate to next account once; on 429 cooldown that account briefly and try the next; network error → next. **Upstream HTTP responses — including non-2xx like 400/413/422 — are passed through verbatim** (status + filtered headers + body), the most client-faithful behavior; only transport-level failures (no accounts, all cooling down, catalog unavailable) are mapped to Quotio-owned error envelopes via the existing `sendError` path (its `QoderOpenAIError` builder produces provider-neutral OpenAI error JSON and is reused as-is — no `OpencodeOpenAIError` twin). No COSY; body translation happens only at the cross-surface seam (ADR 0021) — same-surface requests pass through byte-faithful. **At least one enabled opencode account is required** — no anonymous UA-only mode. Anonymous free access is tighter rate-limited per-IP and outside the ask; revisit as a follow-up if wanted.
- A detected account that stays expired after a store re-read surfaces to the UI via a notification → `monitorAccountIssues` ("reopen opencode"). Amended after review: `qoderPATRevoked` has **no consumer today** (defined and posted in `QoderFailoverRouter`, zero observers repo-wide; `monitorAccountIssues` is fed only by the nil-quota path, which never runs for opencode). So this is **new wiring, not reuse**: the router posts `dev.quotio.opencode.account-stale` (userInfo `accountKey`/`displayName`) when a detected credential stays expired after a re-read and `dev.quotio.opencode.account-recovered` when a later request through that account succeeds, and `QuotaViewModel` gains an observer that sets/clears a `MonitorRefreshIssue` in `monitorAccountIssues` for the matching account.
- Upstream calls: pass the request body through with `model` stripped of the `opencode/` prefix, `Authorization: Bearer <access token>`, the full released-client `User-Agent` pinned from the Task 0 spike (`opencode/1.18.30 ai-sdk/provider-utils/4.0.23 runtime/bun/1.3.14` — the gate 403s unrecognized versions, including the bare `opencode/1.19.0` form; provenance recorded in a comment), plus `x-org-id: <orgID>` when the credential carries one (`metadata.orgID` for detected credentials, stored org for Quotio logins; absent → omit the header). The upstream target is the model's **native** surface (chat → `<inference>/v1/chat/completions`, responses → `<inference>/v1/responses`, messages → `<inference>/v1/messages`), where `<inference>` is `<origin of credential.server>/inference` — `https://opencode.ai/inference` for the default console, and the right host for non-default-server credentials. Same-surface responses are pumped byte-wise: status line + upstream headers minus hop-by-hop (`Connection`, `Transfer-Encoding`, `Content-Length`, `Keep-Alive`) + `Connection: close`, then raw bytes until EOF. The gate forces `stream:true` upstream, so `stream:false` clients are served by aggregation on every arm: the head is written only after the full body is folded (`chat.completion` / `response` per the client's surface), and a mid-aggregation failure is a true HTTP 502. Cross-surface requests (Responses client, chat-native model) are translated at the seam per ADR 0021; mid-stream failures on a Responses stream get a Responses-shaped terminal event, not a chat-shaped frame.
- `GET /v1/models` gains `opencode/<id>` entries via a merger mirroring `QoderModelsMerger` (ADR 0016), chained after the Qoder merge.
- Proxy auth unchanged: requests still authenticate to ProxyBridge the same way; the opencode token never appears on the client-facing side.

### Catalog (what counts as "currently free")

`OpencodeModelCatalog` service, refreshed at proxy start and on a timer while running (TTL ~1h; failures keep the last good list):

1. `GET https://opencode.ai/inference/v1/models` (public, no auth — confirmed) → live servable set, OpenAI `{"object":"list","data":[...]}` shape.
2. `GET https://models.dev/api.json` → `opencode` provider: per-model `cost.{input,output,cache_read,cache_write}`, optional `status` (values seen: `"deprecated"` or absent), and the surface source — **per-model `provider.npm` override when present, else the provider-level `npm`** (`@ai-sdk/openai-compatible`), mapped `@ai-sdk/openai`→responses, `@ai-sdk/openai-compatible`/missing→chat, `@ai-sdk/anthropic`→messages, `@ai-sdk/google`→gemini, `@ai-sdk/mistral`→mistral (ADR 0021). The per-model overrides appeared on models.dev between the first review and re-verification (66 of 124 models as of 2026-10-15).
3. Expose a model iff: it appears in the live list AND `cost.input == 0 && cost.output == 0` AND `status != "deprecated"` AND not `jev-*`/`systemone`. Persist the resolved list with each model's surface (`catalog-v2.json`; v1 snapshots decode with surface nil → chat legacy default until the startup refresh) so a models.dev outage doesn't empty the proxy. `/v1/models` advertises only models servable on at least one client surface (filter, not annotation).

## Constraints

- `ProxyBridge` target host stays localhost; the opencode branch dials `opencode.ai` directly (the Qoder branch already dialed `api3.qoder.sh` — same precedent).
- UI state `@MainActor`; new services are actors; DTOs `Sendable`. Strings via existing `.localized()` helpers.
- Do not log tokens/codes; never write to the opencode data directory.

## Left to the builder

- Task 0 spike outcomes (resolved 2026-10-15, recorded here): the gate accepts the full released-client UA (`opencode/1.18.30 ai-sdk/provider-utils/4.0.23 runtime/bun/1.3.14`) and 403s unrecognized versions (`opencode/1.19.0` failed); it requires `stream:true`, a `read` tool, and the `x-opencode-*` metadata headers, and fingerprints the TLS stack (URLSession passes, curl 403s). The live list does include `jev-*`/systemone models — the catalog excludes them explicitly. `/v1/responses` works for `muse-spark-1.3-contributor-free`. Remaining open item: live-probe the **translated** body shapes against the gate (surface-dispatch plan, Verification).
- Exact `auth.json`/SQLite field shapes on a live install (source-confirmed above; confirm locally, tolerate missing keys).
- Refresh/cooldown constants (token refresh margin, 429 cooldown duration, catalog TTL, detected-credential snapshot interval).
- UI placement of the provider row/login button, following existing provider sheets.

## Open questions resolved in conversation

- Both login sources as separate accounts **only when truly different accounts** — dedupe by console identity.
- Path B (ProxyBridge branch) chosen over CPA `openai-compatibility` + `headers:` (CPA does support `headers:` per-entry; Quotio's YAML generator doesn't emit it for openai-compat, and Path B gives refresh-on-fail plus per-account failover).
- Detected credentials are read-only; stale-until-opencode-runs accepted.

## Calls I made (check these while reading)

- **Hard allowlist**: the free catalog enforces at request time — non-free `opencode/*` requests 404 rather than pass through and risk spending a credited account's money.
- **No anonymous mode**: at least one enabled opencode account is required; UA-only free access is out of scope.
- **Surface dispatch, translation at the seam** (re-amended, ADR 0021): models.dev carries per-model `provider.npm`; each request targets the model's native surface. Same-surface passes through byte-faithful; Responses-client × chat-native-model translates (reusing the Qoder components); chat-client × responses-native-model is `422 unsupported_surface` until the reverse translator ships (decision point — see the surface-dispatch plan). `previous_response_id`/`conversation` are 400'd, never silently dropped.
- **Impersonate released clients** (re-amended): full released-client UA `opencode/1.18.30 ai-sdk/provider-utils/4.0.23 runtime/bun/1.3.14` pinned from the Task 0 spike (the gate 403s unrecognized versions — including the bare `opencode/1.19.0` form the first amendment assumed); no `supports_org_scope`; org from sorted-first `/api/orgs`.
- **DB copy-on-read**: detected SQLite credentials are read via a temp copy of db+wal+shm, not an immutable/ro open of the live file.
- **SQLite rows beat `auth.json`** for the same account (auth.json can be stale post-migration).
- **Inference host derived** from the credential's console-server origin (`{origin}/inference`), covering non-default servers.
- **`x-org-id`** sent only when the credential carries an org.
- **Stale-account surfacing is new wiring** (amended): `qoderPATRevoked` has no consumer; the opencode stale/recovered notifications get their own observer into `monitorAccountIssues`.
- Proxy model prefix `opencode/<model>` and cross-account failover mirror the `qoder/` precedent.

## Tests

1. Route gate: `opencode/<free-model>` + `POST /v1/chat/completions` → chat route; + `POST /v1/responses` → responses route (either client surface is accepted for any free model; the native target surface is resolved separately); wrong method/path → `404`; model outside free set → `404 model_not_found`; empty catalog at cold start → `503` catalog-unavailable; non-`opencode/` model → passthrough.
2. Device flow: code request → poll pending/slow_down/success → credential saved with correct accountKey (unit test with stubbed HTTP); request body matches released-client form (no `supports_org_scope`).
3. Refresh: expiring vault credential → rotated and persisted; `invalid_grant` → needs-auth state; detected credential is never refresh-attempted, and an expired one triggers a store re-read; still-expired → stale notification, next account tried.
4. Catalog: fixtures for models.dev + live list → correct free set (live ∩ cost-0 ∩ non-deprecated; model absent from models.dev → excluded); outage keeps last good list.
5. Dedup: vault account + detected account with same console identity → one row, `.quotioKeychain` wins; different identities → two rows; SQLite row preferred over `auth.json` for the same accountKey.
6. Models merge: `GET /v1/models` includes `opencode/<id>` entries; disabling all opencode accounts removes them (or leaves them unroutable with a clear error — pick whichever `QoderModelsMerger` does).
7. Upstream pass-through: streamed SSE arrives unmodified on the same-surface arm; `opencode/` prefix stripped from `model`; UA/Bearer/org headers present; upstream non-2xx status forwarded verbatim with its body; `stream:false` clients get one aggregated JSON body (`chat.completion` / `response` per their surface) with mid-aggregation failure → true 502.
8. Stale surfacing: `account-stale` notification → `MonitorRefreshIssue` in `monitorAccountIssues` for the matching account; `account-recovered` clears it.
9. Surface dispatch (ADR 0021): mock upstream asserts the native-surface URL per model; Responses-client × chat-native model translates (fixture pairs for `input`→messages, tools both shapes, `tool_choice` both forms, `text.format`→`response_format`, `previous_response_id` → 400); `messages`/`gemini`/`mistral`-native → 422 `unsupported_surface`; chat-client × responses-native model → 422 until the reverse translator ships; catalog npm precedence (per-model beats provider-level; unknown → chat; v1 snapshot decodes surface-less → chat legacy default).
