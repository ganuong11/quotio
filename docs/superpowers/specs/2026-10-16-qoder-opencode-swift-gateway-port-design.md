# Port: Qoder + OpenCode providers onto the new architecture (all-Swift gateway)

Date: 2026-10-16
Branch: `uptodate` (latest upstream master + merged `qoder` branch at `0a34885`)

## Intent and the why

The `qoder` branch added two provider integrations — **Qoder** (PAT-authed, private
gateway, OpenAI-compatible translation) and **OpenCode** (device-OAuth + detected local
credentials, free-tier models across multiple upstream surfaces) — built on the old
monolithic `Quotio/` app. Its Swift `ProxyBridge` listener was the front door on
`localhost:8317`: it claimed `qoder/*` / `opencode/*` model requests, translated them
in-app, and byte-forwarded everything else to CLIProxyAPI (CPA).

Upstream has since rewritten the app as a clean-architecture monorepo. The embedded
Swift proxy was deleted; CPA binds `:8317` directly, and a Rust host (`apps/cli`)
owns accounts, credentials, quota collection, and the `/v2` snapshot contract that the
Swift frontend renders.

This project re-homes the qoder-branch subsystem into the new layout as a
**self-contained Swift vertical slice**: the app re-takes the `:8317` front door, CPA
moves to an internal port, and the Rust host is untouched except for one migration
exclusion. The qoder branch's documentation — 21 ADRs, gap analysis, fix plan,
surface-dispatch plan, and specs under `docs/` — is the authoritative behavioral spec
and is already merged onto `uptodate`.

## Decisions already made (by the user)

1. **Swift owns the front door on `:8317`.** A listener in `QuotioInfrastructure`
   intercepts `qoder/` + `opencode/` model requests and byte-forwards everything else
   to CPA on an internal port. Chosen to minimize port workload — the translators,
   failover router, and parsers port nearly verbatim.
2. **All-Swift subsystem — no Rust inference or credential involvement.** The gateway
   owns its credentials, exchange, translation, failover, quota fetch, and account
   presentation entirely in the Swift package. (Alternatives rejected along the way:
   all-Rust rewrite = ~2× effort; Rust front door + Swift handler = pointless
   cross-process hop; pushed credentials into the host vault = unnecessary transport
   seam once a Swift-side presentation overlay exists; CPA `openai-compatibility` =
   already rejected in the OpenCode design doc — no translation, no cross-account
   failover.)
3. **Scope: both providers.** Qoder and OpenCode port in the same effort (phased).

## Goals

- Agents keep pointing at `http://localhost:8317` unchanged. Requests with
  `model: "qoder/<id>"` or `"opencode/<id>"` on `POST /v1/chat/completions` and
  `POST /v1/responses` are served by the ported Swift engine; all other traffic
  (inference **and** CPA management API calls) passes through byte-faithfully to CPA.
- PAT onboarding for Qoder via the Add-Provider sheet (`pt-…` → exchange → identity
  confirm → Keychain vault), per the existing `qoder.onboarding.*` strings; OpenCode
  device-code OAuth per the old flow.
- Qoder quota (`userQuota`, `orgResourcePackage`) and OpenCode connection status
  appear on the quota dashboard via a snapshot overlay — no host changes.
- `GET /v1/models` merges `qoder/<id>` and free `opencode/<id>` entries into CPA's
  response (old merger semantics).
- `check_architecture.sh`, `swift test`, Xcode tests, and the Debug build stay green.

## Non-goals

- No visibility of qoder/opencode accounts in `quotio` CLI or companion iOS devices —
  they were app-local before; same now.
- No persistence of failover/cooldown state across restarts (in-memory, as before).
- No dynamic Qoder model-list refresh beyond the parked follow-up (seed catalog +
  persisted cache file; live `/algo/api/v2/model/list` stays parked unless trivial).
- No CPA auth-file export for Qoder (ADR 0007).
- No Cloudflare-tunnel exposure redesign for the provider models (preserve old
  sharing semantics if CPA's bind widens; document whichever lands).
- No iOS app changes beyond name/icon mappings if keyed by id.
- No new request-log UI (see Usage accounting).

## Anti-goals / failure modes

- A "fake port" where code exists but nothing binds the port or wires the gates —
  the end-to-end agent flow is the deliverable.
- Provider logic in banned frontend files (`check_architecture.sh` bans provider
  endpoints/dispatch in `QuotioCLIBackend`, `QuotaFeatureController`,
  `AccountsScreenModel`). The gateway subsystem lives in `QuotioInfrastructure` +
  `QuotioDomain`, wired only from `CompositionRoot`; the dashboard seam is a
  decorator on the `QuotaCoordinating` port, not provider branches in banned files.
- Storing/logging PATs, job tokens, OAuth codes, upstream credential material.
- Breaking CPA management access: `ProxyEndpoint.managementURL` continues to hit CPA
  directly (at the internal port — see Port split).

## Constraints

- Layering per `apps/macos/AGENTS.md`: pure translators/parsers/registries →
  `QuotioDomain` (no I/O); listeners, HTTP clients, Keychain, SQLite →
  `QuotioInfrastructure` behind Application ports; UI → `QuotioPresentation`;
  only `CompositionRoot` imports Infrastructure. The old code is mostly already
  shaped this way (pure types + a few actors), so the port is relocation + rewiring,
  not redesign.
- The NWListener front door is permitted in `QuotioInfrastructure` (`Network` is not
  on the banned-imports list); it must not leak into Presentation.
- `check_architecture.sh` bans the symbols `MonitorAccount`, `MonitorAccountSource`,
  `ModelQuota`, and `*QuotaFetcher` construction in production sources — ported types
  get mechanical renames (`GatewayAccount`, `GatewayCredential`,
  `GatewayQuotaService`, …; builder picks names). Its `unexpected_app_tests`
  allowlist covers only a few existing `QuotioTests` files — new tests go in the
  package test targets (`QuotioDomainTests`, `QuotioInfrastructureTests`, …).
- Dev/prod port split preserved: `8317` prod / `8318` dev remain the *front-door*
  ports.
- New or resurrected Swift code follows existing conventions: `@MainActor` UI state,
  `actor` for async services, `Sendable` DTOs, layer-owned logging ports, `.localized()`.
- Rust change budget: **one small change** — the legacy-migration exclusion below.
  Nothing else in `apps/cli`.

## Design

### Request topology

```
agent → :8317 (QuotioInfrastructure GatewayListener, NWListener)
          ├─ GET /v1/models        → forward to CPA, merge qoder/opencode entries
          ├─ qoder/* POSTs         → access validator → QoderFailoverRouter → api3.qoder.sh
          ├─ opencode/* POSTs      → access validator → OpencodeRouter → <server>/inference/v1
          └─ everything else       → byte-faithful forward → CPA at 127.0.0.1:<internal>
```

`GatewayListener` is the ported `ProxyBridge` + `HTTP1RequestParser` (the bytewise
HTTP/1.1 parser ports unchanged — ADR 0015). Routing order preserved: `/v1/models`
intercept → qoder gate → opencode gate → CPA passthrough. Owned routes return
`QoderOpenAIError` envelopes; they never fall through to CPA.

### Port split (decided)

`status.port`/`proxyPort` keeps meaning the user-visible front-door port (8317/8318).
CPA is force-pinned to an internal loopback-only port (suggest `18317`/`18318`)
written into `config.yaml`. Required consequences:

- `FileProxyConfigurationRepository.ensureExists` only writes a missing config.yaml —
  add a one-time migration that rewrites an existing `port: <front-door>` (and any
  `host:`) to the internal loopback values, so upgrades actually move CPA and never
  expose its management API on LAN (an existing `host: 0.0.0.0` would otherwise leak
  it; `host` semantics move to the *listener*, not CPA).
- `ProxyLifecycleController.setPort`/`prepareConfigurationForStart` keep writing the
  front-door port everywhere user-facing (health checks, agent `proxyURL`, tunnel
  `--url`, settings UI) but stop rewriting CPA's internal port — CPA's `port:`/`host:`
  become managed constants.
- `cleanupProcesses`/`stop` port-kill helpers cover the internal port too (stale CPA
  after a crash → bind-failure loops otherwise; the own-PID exclusion still applies
  to the app's listener).
- `ProxyEndpoint.managementURL` targets the internal CPA port directly (preserves the
  AGENTS.md localhost-only invariant; simpler than routing management through the
  front door).
- The listener binds only while the proxy runs (old semantics: routers exist only
  during proxy lifetime).

### Module placement (Swift)

| Old file (`git show qoder:Quotio/...`) | New home | Type |
|---|---|---|
| `Services/Proxy/ProxyBridge.swift`, `Services/Proxy/HTTP1RequestParser.swift` | `QuotioInfrastructure/Gateway/` (parser may land in Domain — it's pure) | listener, forwarding, pump tasks |
| `Services/Qoder/Qoder{WAFEncoder,ThinkingTagParser,ChatTranslator,SSEReparser,CompletionAggregator,ResponsesTranslator,ResponsesAdapter,OpenAIError,ModelRegistry,RouteGate,ModelsMerger}.swift` | `QuotioDomain/Gateway/Qoder/` | pure transforms |
| `Services/Qoder/Qoder{COSYSigner,GatewayClient,FailoverRouter,AccessValidator,PATService}.swift` | `QuotioInfrastructure/Gateway/Qoder/` | crypto, upstream, rotation, auth, PAT exchange |
| `Services/Opencode/Opencode{ProtocolMapper,ChatSSEAdapter,ResponsesAggregator,ModelsMerger,RouteGate}.swift` (pure) | `QuotioDomain/Gateway/Opencode/` | pure transforms |
| `Services/Opencode/Opencode{ConsoleClient,CredentialDetector,DetectedCache,ModelCatalog,Router,UpstreamClient}.swift` | `QuotioInfrastructure/Gateway/Opencode/` | network, fs/SQLite, rotation |
| `Services/QuotaFetchers/QoderQuotaFetcher.swift` | `QuotioInfrastructure/Gateway/Qoder/` as `GatewayQuotaService` (renamed — banned symbol) | quota fetch |
| `Services/Monitor/MonitorCredentialVault` + PAT account mgmt | `QuotioInfrastructure/Gateway/` vault + `QuotioApplication` ports | Keychain store |
| `Views/Components/QoderPATOnboardingSheet.swift` | `QuotioPresentation/Components/` | two-step sheet; strings exist |
| `ViewModels/QuotaViewModel.swift` qoder additions | `QuotioApplication` overlay + Presentation screen-model wiring | see Dashboard seam |
| `Services/Monitor/MonitorToCLIProxyAuthExporter.swift` | **not ported** (ADR 0007: no CPA auth files for qoder) | — |

File-level granularity may shift; the rule that matters is the layer.

### Credentials (all Swift, single owner)

- Vault: ported `MonitorCredentialVault` → `QuotioInfrastructure/Gateway` Keychain
  store under a **new** service name (e.g. `app.quotio.gateway.credentials`) — not
  `dev.quotio.desktop.monitor-auth`, which the legacy migration reads. CAS rotation
  semantics preserved.
- Qoder credential record: PAT + jobToken + expiry + `machineID` +
  `jobRefreshToken` + identity (`userID` = account key; `name ?? email ?? userID` =
  display name).
- **Single exchanger:** all PAT→jobToken exchanges funnel through the ported
  `QoderPATService` pacing gate (ADR 0017): quota refreshes, failover re-exchange,
  and onboarding all share the 1s `nextExchangeAt` gate.
- Account metadata (enabled/disabled, display names, dedup keys) lives in a
  Swift-owned store ported from `MonitorMetadataStore`/`accounts-v1.json` semantics —
  the gateway router consults it per request for enabled accounts.
- OpenCode: managed device-code OAuth tokens in the same vault; detected creds read
  read-only from `~/.local/share/opencode` (`auth.json` + `opencode*.db` via temp
  copies incl. WAL/SHM — never write back, never refresh); dedup by console
  `user.id`, vault priority over detected; stale → issue surface.

### Dashboard seam — snapshot overlay (the piece that replaces host integration)

The new dashboard renders `QuotaSnapshot` from the `QuotaCoordinating` port
(`QuotioCLIBackend` → host `/v2/snapshot`). We add a Swift-side overlay:

- `GatewayQuotaOverlay: QuotaCoordinating` — decorator wrapping the backend adapter,
  composed in `CompositionRoot` (the only file allowed to wire Infrastructure).
  Each snapshot/refresh response gets gateway accounts' `accountStates`, `quotas`
  (`qoder` → `userQuota`/`orgResourcePackage` rows, percentage = remaining),
  `providerNames`, `accountAliases`/`accountIDs`, `issues`/`accountIssues`
  (opencode stale), and `refreshingProviders` merged in.
- Refresh fan-out: overlay forwards refreshes to the wrapped coordinator AND the
  `GatewayQuotaService` (ported `QoderQuotaFetcher`: `GET
  openapi.qoder.sh/api/v2/quota/usage` Bearer jobToken, per-account
  `rateLimitedUntil`, stale-token fallback) + the OpenCode connection probe.
- Remove/disable/disable-account actions for gateway accounts route through the
  overlay to the vault/metadata store (host paths handle the rest).

### Onboarding

- Qoder: `QoderPATOnboardingSheet` → Application use case → `QoderPATService`
  (exchange + userinfo) → vault write + metadata store register. Wire into the
  Add-Provider surface per `QuotaProvider` capability flags
  (`supportsManualAuth`/`usesAPIKeyAuth` set to keep it out of the generic API-key
  and custom-provider YAML paths — old load-bearing semantics preserved).
- OpenCode: device-code flow ports as a Swift Infrastructure service
  (`OpencodeConsoleClient`); surfaced via the existing device-code/OAuth onboarding
  path (`authorize_native`/`start_oauth` action plumbing in the new UI — builder maps
  the concrete hook). Detected installs appear via the detector + overlay, read-only,
  `canDelete:false`.

### Auth at the seam

Old behavior preserved: `QoderAccessValidator` mirrors CPA's `config_access` — five
credential sources (Bearer-or-bare `Authorization`, `X-Api-Key`, `X-Goog-Api-Key`,
`?key=`, `?auth_token=`), constant-time compare, key snapshot = CPA's API keys
refreshed via the management API cadence, 401 OpenAI envelope. Preserves ADR 0005
session-affinity derivation (session id keyed partly on the agent's API key) since
agents keep their existing CPA keys. `/v1/models` stays on the passthrough path.

### Usage accounting

The front door sees every request. Port the `RequestMetadata` token fields +
completion hook into whatever replaces `RequestTracker`/`RequestLog`; if no
equivalent surface is mounted (the old request-stats UI is dormant on master),
record into the smallest existing store or defer with a TODO in the plan. No new
request-log UI in this project.

### Failover semantics (unchanged — port verbatim)

429/quota → rotate + cooldown (honor `Retry-After`, clamp [60s, 300s], recheck
15 min); 401/403 → one credential refresh + retry, then rotate; 408/5xx/timeout →
transient same-account retry; first-chunk silent stall → rotate after 2 consecutive
strikes; mid-stream → terminal error frame/event then `[DONE]`; all cooling → 429 +
`Retry-After`. In-memory only.

### OpenCode specifics (unchanged — port verbatim)

Free-set catalog (opencode inference models ∩ models.dev cost-0 non-deprecated minus
`jev-*`/`systemone`, ~1h TTL, persisted caches); surface dispatch by models.dev
`provider.npm` precedence (chat/responses/messages/gemini/mistral); same-surface byte
passthrough vs cross-surface translation (both directions); forced upstream
`stream:true` + aggregation for `stream:false`; impersonation headers (pinned
`opencode/1.18.30 …` UA, `x-opencode-*`, `ses_`/`msg_` ids, `x-org-id`, injected
`read` tool with six-schema substitution); conformance clamps (`max_output_tokens`
≥16, `reasoning.effort` none→minimal); `previous_response_id`/`conversation` → 400;
unsupported surfaces → 422 + filtered from models list.

**Apple-TLS note:** OpenCode's free-tier gate wants an Apple-TLS fingerprint —
satisfied automatically since everything stays on `URLSession`. Verify early anyway
(client versions drift).

### The one Rust change: legacy migration exclusion

`QuotioCLILegacyAccountMigration` imports every `quotioKeychain`/`apiKey` account in
the legacy `accounts-v1.json` + `monitor-auth` Keychain records into the host vault.
For users coming from the `qoder` branch: `Provider::from_str("qoder")` is
unregistered → records sit `pending` and retry every launch. Add an explicit skip for
`qoder`/`opencode` provider ids in `migration::prepare` (apps/cli, ~5 lines + test).
Our new gateway vault performs its own one-time import of legacy `monitor-auth`
qoder/opencode records (same record shape), leaving the legacy items in place —
never delete user credential material.

## Phasing

- **Phase 0 — seam + spike:** CPA moved to internal port (+config.yaml migration);
  `GatewayListener` skeleton doing pure byte-faithful passthrough (proves topology
  before provider work); OpenCode URLSession fingerprint re-verified; vault service
  name + record shape decided.
- **Phase 1 — Qoder primitives:** pure translators/parsers/registries/error envelope
  into Domain + ported tests.
- **Phase 2 — Qoder path live:** vault + metadata store + PAT service + onboarding
  sheet + COSY/WAF + gateway client + failover router + access validator + gate;
  `/v1/models` merge; usage recording hook.
- **Phase 3 — dashboard overlay:** `GatewayQuotaService`, `GatewayQuotaOverlay`
  decorator wired in `CompositionRoot`, account rows/quota cards surface, provider
  presentation + assets, legacy-vault import + Rust migration exclusion.
- **Phase 4 — OpenCode:** console client, detector, catalog, gates, mapper/adapters,
  router, upstream client, device-code onboarding, stale signaling.
- **Phase 5 — hardening:** all verification commands green; manual agent flows
  (chat + responses, stream + non-stream, failover) verified against real endpoints
  or recorded fixtures.

## Testing

Port the qoder-branch XCTest matrix into `Quotio{Domain,Infrastructure}Tests` (the
old suite is the spec: failover matrix, SSE reparse incl. split-UTF-8, translator
trim, COSY/WAF vectors, auth matrix, catalog/npm precedence, mapper fixtures,
aggregators, `HTTP1RequestParser` chunked/CL/cap cases, overlay merge tests).
`QuotioTests` only for composition/lifecycle changes respecting the
`unexpected_app_tests` allowlist.

Verification:
```bash
swift test --package-path Packages/QuotioCore
./apps/macos/scripts/check_architecture.sh
xcodebuild -project apps/macos/Quotio.xcodeproj -scheme Quotio -configuration Debug -destination 'platform=macOS' test
cargo test --manifest-path apps/cli/Cargo.toml --locked --all-features   # the one migration change
```

## What's left to the builder

- Exact internal CPA port numbers; `managementURL` targets it directly (decided).
- Whether pure translator files land in `Domain` vs `Infrastructure` per actual
  imports; final module directory names and renamed type names.
- The `GatewayQuotaOverlay` decorator's exact merge semantics (provider ordering,
  dedup vs. host accounts — none expected since ids are disjoint).
- Where the PAT-service port interface lives in `QuotioApplication` and its shape.
- The concrete device-code onboarding hook in the new UI's action plumbing.
- Phase-0 verifications: jobToken exchange revocation semantics (design safe either
  way — single exchanger); OpenCode fingerprint for current client versions.

## Explicitly rejected

- Rust rewrite of the translation engine (~2× effort).
- Rust front door + Swift translator split (cross-process hop, worst of both).
- Pushing credentials into the host vault (unnecessary once the overlay seam exists;
  adds a credential-transport surface for zero UX gain over app-local accounts).
- Rust reading Swift-written Keychain items (cross-signature reads fail in
  background — `errSecInteractionNotAllowed`).
- CPA `openai-compatibility` as the serving mechanism (no translation, no
  cross-account failover — per the original OpenCode design doc).
- Reusing `dev.quotio.desktop.monitor-auth` for the new vault (migration reader
  collision) or resurrecting `MonitorToCLIProxyAuthExporter` for qoder (ADR 0007).
