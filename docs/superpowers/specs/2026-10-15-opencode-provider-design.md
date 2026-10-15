# OpenCode Provider Design

## Intent and why

AI agents pointed at Quotio's proxy speak the OpenAI protocol. OpenCode Console serves a set of free models at `https://opencode.ai/inference` that are gated to real opencode clients — the upstream checks the `User-Agent: opencode/<channel>/<version>/<name>` header and (for account-scoped access) an OAuth token from the console device flow. The user wants these free models usable by any agent through the proxy, with the upstream unable to distinguish Quotio from a real opencode client, and the free model list refreshed automatically when the proxy starts.

## Goals

- `.opencode` becomes a first-class `AIProvider` with two credential sources, both visible and selectable as separate accounts **only when they are genuinely different accounts**:
  - Quotio-managed OAuth login (device-code flow, tokens in `MonitorCredentialVault`).
  - Automatic detection of an existing system opencode install's auth (`~/.local/share/opencode/`).
- `ProxyBridge` serves `opencode/<model>` for every model that is currently free (see Catalog below), pass-through to the correct inference endpoint, indistinguishable from a real opencode client.
- At proxy start the OAuth tokens are refreshed where possible and the free-model catalog is re-fetched; both also refresh periodically while the proxy runs.

## Non-goals

- Paid models. Only cost-zero models are exposed, even for accounts with credits.
- Anthropic- and Gemini-family upstreams. Free models are almost all served by the OpenAI Chat Completions family; `muse-spark-*-contributor-free` uses the Responses family; `jev-*-free` uses `systemone`, a typed-evaluation API that cannot serve chat at all. Models whose catalog entry requires `/v1/messages` (Anthropic) or `/v1/models/<m>:generateContent` (Gemini) are skipped — none are free today. Revisit if a free model lands on those families.
- Quota/usage display in the Monitor UI. No known per-account quota endpoint; accounts show connection status only.
- Writing anything into the system opencode install's files (see Anti-goals).

## Anti-goals

- Breaking the user's real opencode login. Refreshing an OAuth credential rotates the refresh token server-side; the old one dies. Writing rotated tokens into `auth.json`/`opencode.db`, or refreshing a detected credential out from under the real client, can sign the user's real opencode out. See "Detected credentials".
- Tokens, device codes, or account identifiers in logs or committed files.
- Requiring a CLIProxyAPI (CPA) release or config-schema change.

## Decided how

### Provider and account model

- Add `case opencode = "opencode"` to `AIProvider` (`Quotio/Models/Models.swift`) and satisfy the exhaustive switches (displayName "OpenCode", icon/logo/color, etc.). The compiler lists the sites.
- Accounts are `MonitorAccount`s. Quotio login accounts: `source: .quotioKeychain`, `credentialReference: "keychain"`, `canDelete: true`, `accountKey` = console user id, `displayName`/`email` = console email. Detected accounts: `source: .nativeCredential`, `credentialReference` = path into the opencode store (see below), `canDelete: false`.
- Dedup is free: `MonitorAccount.deduplicationKey` (`provider:accountKey-lowercased`) plus `MonitorAccountDiscovery.selectPreferred` already collapse same-account duplicates, with `.quotioKeychain` (priority 300) winning over `.nativeCredential` (200). **Canonical `accountKey` = console `user.id`** for both sources (stable across email changes; `MonitorAccount.id` is a fingerprint of `provider|accountKey`, so same-key sources collapse to the same row id as well). Fallback order when the id can't be resolved: `email`, then a stable fingerprint of `credentialReference + server` — the last case can produce an undeduped duplicate if the same account also logs in via Quotio, accepted as a pathological edge.
- Identity resolution for detected credentials: use `metadata.accountID`/`metadata.email` from the stored record first; only if both are absent, call `GET {server}/api/user` with the detected access token. If the token is expired and the record carries no identity, show the account under the fingerprint key — invisible would hide a credential the user may want gone.

### Quotio login (device flow)

In `MonitorOAuthCoordinator`, mirroring `kiroDeviceFlow`:

1. `POST https://opencode.ai/console/auth/device/code` JSON `{client_id: "opencode-cli", supports_org_scope: true}` → `{device_code, user_code, verification_uri_complete, expires_in, interval}`.
2. Open `verification_uri_complete`, surface `user_code` via the existing `.monitorOAuthDeviceCode` notification path.
3. Poll `POST {server}/auth/device/token` `{grant_type: "urn:ietf:params:oauth:grant-type:device_code", device_code, client_id: "opencode-cli"}` every `interval` (min 5s, +5s on `slow_down`) until `{access_token, refresh_token, expires_in, org_id}` or `expired`.
4. `GET {server}/api/user` and `GET {server}/api/orgs` (Bearer) for `user.id`, `email`, org. Store `orgID`/`orgName`/`server` in `MonitorOAuthCredential.extra`.

Reference: `packages/core/src/plugin/provider/opencode.ts` in `anomalyco/opencode`.

### Detected system credentials (read-only)

`MonitorAccountDiscovery` gains `discoverOpencodeCredentials()`, reading `~/.local/share/opencode/`:

- `auth.json` — v1 store: `{"opencode": {"type": "oauth", "access": "...", "refresh": "...", "expires": <ms epoch>}}` (shape to be confirmed against a live file; tolerate key variations).
- `opencode*.db` — current store: SQLite `credential` table, `integration_id = 'opencode'`, `value` is a JSON `Credential.OAuth` (`access`, `refresh`, `expires`, `metadata.accountID/email/orgID/server`). Honor `OPENCODE_DB` naming: `opencode.db` on stable channels, `opencode-<channel>.db` otherwise — glob `opencode*.db`.
- Reading the DB: **copy `opencode*.db` plus its `-wal`/`-shm` siblings to a temp location and open the copy** via SQLite3. A plain read-only open of a WAL database either needs `-shm`/`-wal` writes in the original directory (violating never-write) or, under `immutable=1`, ignores the WAL and can return a stale token forever — which would break the re-read recovery path below. The copy gets the freshest committed state and leaves the originals untouched.

Detected credentials are **never written back and never refreshed by us**. When a detected access token is expired or returns 401, we re-read the store (the real client may have rotated it); if the re-read copy is still expired, that account reports a "signed out / reopen opencode" state and is skipped by the router until it recovers. This is the accepted tradeoff the user chose over write-back.

Quotio-vault credentials refresh via `POST {server}/auth/device/token` `{grant_type: "refresh_token", refresh_token, client_id}`; rotated tokens persist back to the vault only. `invalid_grant` → mark the account needs-auth ("Reconnect OpenCode Console to continue" equivalent).

### Serving (Path B — ProxyBridge branch, Qoder precedent)

CPA stays untouched. New `Quotio/Services/Opencode/` group mirroring the Qoder layout:

- `OpencodeRouteGate` (mirror `QoderRouteGate`, ADR 0009 semantics): conjunctive allowlist — `model` starts with `opencode/`, method `POST`, path `/v1/chat/completions` or `/v1/responses`. No `opencode/` prefix → CPA passthrough unchanged.
- **The catalog is a hard allowlist, not just an advertisement.** An `opencode/<model>` request for a model absent from the resolved free set — wrong family, paid, deprecated, or unknown — gets a provider-owned `404 model_not_found`; it is never forwarded. This is deliberate enforcement of the free-only scope: pass-through of a paid model on a credit-bearing account would spend real money. Cold start: if the catalog has never resolved (first fetch failed and no persisted snapshot), `opencode/` requests get a catalog-unavailable error in the `OpencodeOpenAIError` envelope rather than a misleading `model_not_found`.
- `OpencodeRouter` (slim `QoderFailoverRouter` analog): iterate enabled, non-disabled opencode accounts (enumerated via `MonitorAccountDiscovery`, not `vault.accounts()` alone — detected accounts live in the store discovery path); per request pick credential → ensure fresh (vault: refresh if expiring; detected: re-read store) → forward. On 401 mark/rotate to next account once; on 429 cooldown that account briefly and try the next. No COSY, no body translation — the upstream already speaks the client's protocol. **At least one enabled opencode account is required** — no anonymous UA-only mode. Anonymous free access is tighter rate-limited per-IP and outside the ask; revisit as a follow-up if wanted.
- A detected account that stays expired after a store re-read surfaces to the UI via the existing `qoderPATRevoked`-style notification → `monitorAccountIssues` channel ("reopen opencode"), not a new reporting mechanism.
- Upstream calls: pass the request body through with `model` stripped of the `opencode/` prefix, `Authorization: Bearer <access token>`, `User-Agent: opencode/<channel>/<version>/<name>` (real format confirmed in their `app.ts`; e.g. `opencode/latest/1.x.y/opencode` — when a system install exists, prefer reading its version so the UA matches a real current client), plus `x-org-id: <orgID>` when the credential carries one (the `org_id` the token response carried, or `metadata.orgID` for detected credentials; absent → omit the header). Chat-family models → `<inference>/v1/chat/completions`; responses-family → `<inference>/v1/responses`, where `<inference>` is `<origin of credential.server>/inference` — `https://opencode.ai/inference` for the default console, and the right host for non-default-server credentials. Streaming responses are pumped byte-wise like CPA passthrough (no reparse needed — upstream SSE is already OpenAI-shaped); non-streaming returned as-is. Errors map through an `OpencodeOpenAIError`-style envelope mirroring `QoderOpenAIError` (ADR 0010).
- `GET /v1/models` gains `opencode/<id>` entries via a merger mirroring `QoderModelsMerger` (ADR 0016).
- Proxy auth unchanged: requests still authenticate to ProxyBridge the same way; the opencode token never appears on the client-facing side.

### Catalog (what counts as "currently free")

`OpencodeModelCatalog` service, refreshed at proxy start and on a timer while running (TTL ~1h; failures keep the last good list):

1. `GET https://opencode.ai/inference/v1/models` (public) → live servable set.
2. `GET https://models.dev/api.json` → `opencode` provider: per-model `cost`, `status`, `provider.npm`.
3. Expose a model iff: it appears in the live list AND `cost.input == 0 && cost.output == 0` AND `status != "deprecated"` AND its family is chat-completions or responses (`provider.npm` `@ai-sdk/openai-compatible` / `@ai-sdk/openai`; per-model `provider` override wins over the provider default). `systemone`/anthropic/google-family entries are dropped. Persist the resolved list so a models.dev outage doesn't empty the proxy.

## Constraints

- `ProxyBridge` target host stays localhost; the opencode branch dials `opencode.ai` directly (the Qoder branch already dialed `api3.qoder.sh` — same precedent).
- UI state `@MainActor`; new services are actors; DTOs `Sendable`. Strings via existing `.localized()` helpers.
- Do not log tokens/codes; never write to `~/.local/share/opencode/`.

## Left to the builder

- Exact `auth.json`/SQLite field shapes on a live install (confirm against real files; tolerate missing keys).
- Whether the inference API also requires `x-opencode-*` headers beyond `Authorization` + `User-Agent` — verify by calling a free model; add only what's needed.
- Exact opencode version string in the UA (pin a recent release; prefer the detected install's version).
- Refresh/cooldown constants (token refresh margin, 429 cooldown duration, catalog TTL).
- Whether the `expires` field is ms epoch (v1 `auth.json`) vs s — verify on real data.
- UI placement of the provider row/login button, following existing provider sheets.

## Open questions resolved in conversation

- Both login sources as separate accounts **only when truly different accounts** — dedupe by console identity.
- Path B (ProxyBridge branch) chosen over CPA `openai-compatibility` + `headers:` (CPA does support `headers:` per-entry; Quotio's YAML generator doesn't emit it for openai-compat, and Path B gives refresh-on-fail plus per-account failover).
- Detected credentials are read-only; stale-until-opencode-runs accepted.

## Calls I made (check these while reading)

- **Hard allowlist**: the free catalog enforces at request time — non-free `opencode/*` requests 404 rather than pass through and risk spending a credited account's money.
- **No anonymous mode**: at least one enabled opencode account is required; UA-only free access is out of scope.
- **DB copy-on-read**: detected SQLite credentials are read via a temp copy of db+wal+shm, not an immutable/ro open of the live file.
- **Inference host derived** from the credential's console-server origin (`{origin}/inference`), covering non-default servers.
- **`x-org-id`** sent only when the credential carries an org (token's `org_id` / stored `metadata.orgID`).
- **Stale-account surfacing** reuses the `qoderPATRevoked` → `monitorAccountIssues` channel.
- Proxy model prefix `opencode/<model>` and cross-account failover mirror the `qoder/` precedent.

## Tests

1. Route gate: `opencode/x` + `POST /v1/chat/completions` → chat route; `/v1/responses` → responses route only for responses-family models; wrong family/method/GET → `404 model_not_found`; non-`opencode/` model → passthrough.
2. Device flow: code request → poll pending/slow_down/success → credential saved with correct accountKey (unit test with stubbed HTTP).
3. Refresh: expiring vault credential → rotated and persisted; `invalid_grant` → needs-auth state; detected credential is never refresh-attempted, and an expired one triggers a store re-read.
4. Catalog: fixtures for models.dev + live list → correct free set (cost-0, non-deprecated, chat/responses family only); outage keeps last good list.
5. Dedup: vault account + detected account with same console identity → one row, `.quotioKeychain` wins; different identities → two rows.
6. Models merge: `GET /v1/models` includes `opencode/<id>` entries; disabling all opencode accounts removes them (or leaves them unroutable with a clear error — pick whichever `QoderModelsMerger` does).
7. Upstream pass-through: streamed SSE arrives unmodified; `opencode/` prefix stripped from `model`; UA/Bearer/org headers present.
