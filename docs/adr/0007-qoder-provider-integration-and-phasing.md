# Qoder AIProvider integration, branding, and phasing

## Context

Six ADRs established Qoder's architecture (0001-0006). This ADR pins the final
integration points: how `.qoder` declares itself in Quotio's `AIProvider` enum,
the brand assets, and the phased delivery boundary so the tracer bullets are
unambiguous.

## Decision

### 1. AIProvider.qoder flag matrix

Add `.qoder = "qoder"` to the `AIProvider` enum with these flags:

| Property | Value | Rationale |
|---|---|---|
| `rawValue` | `"qoder"` | Persisted in MonitorAccount identity, Vault account-id seed |
| `displayName` | `"Qoder"` | |
| `oauthEndpoint` | `""` (empty) | No management-API OAuth; onboarding is PAT paste (ADR 0006) |
| `supportsManualAuth` | `true` | Appears in Add Provider popover |
| `usesAPIKeyAuth` | `false` | PAT is not sent as Bearer upstream; keeps Qoder out of CustomProviderService (ADR 0002) |
| `isQuotaTrackingOnly` | `false` | Routable per ADR 0001 |
| `supportsLocalProxySetup` | `true` | Derived |
| `usesBrowserAuth` | `false` | |
| `usesCLIQuota` | `false` | |
| `cliAgent` | `nil` | No Quotio-managed CLI |
| `color` | `Color(hex: "4CAF50") ?? .green` | Brand primary, extracted from qoder.png |
| `logoAssetName` | `"qoder"` | Requires new asset in ProviderIcons catalog |
| `menuBarIconAsset` | `"qoder-menubar"` | Requires simplified single-color variant |
| `menuBarSymbol` | `"QD"` | Two-letter convention (matches Cursor "CR", OpenRouter "OR") |
| `supportsQuotaOnlyMode` | `true` | Phase 1 ships quota-only |

The `usesAPIKeyAuth: false` choice is load-bearing: it keeps Qoder out of the
CustomProvider YAML pipeline, forcing onboarding through the dedicated PAT-paste
sheet (ADR 0006) into `MonitorCredentialVault` (ADR 0002).

`DirectAuthFileService.mapTypeToProvider` and `parseAuthFileName` do NOT need a
`"qoder"` entry — Qoder never writes a CPA auth file (ADR 0001 bypasses CPA
entirely). This is the inverse of how Grok was integrated (which added `"xai"`
to both maps).

### 2. Branding

- Primary color: `#4CAF50` (vibrant green, extracted from `/Users/home/Desktop/qoder.png`).
- Logo source: `qoder.png` (128×128, 8-bit colormap) — to be added to
  `Assets.xcassets` as `qoder` and a simplified `qoder-menubar` variant.
- Assets are out of scope for code; flagged for pre-release.

### 3. Phased delivery

**Phase 1 — Quota Monitor tracer bullet.** A user can add a Qoder PAT and see
quota in the dashboard.

Scope:
- `AIProvider.qoder` in enum (flags above).
- `QoderQuotaFetcher` actor mirroring `ClinePassQuotaFetcher` shape; calls
  `GET openapi.qoder.sh/api/v2/quota/usage` with Bearer job token. No COSY, no
  WAF — quota endpoint needs neither.
- PAT exchange (`POST /api/v1/jobToken/exchange`) + user info (`/api/v1/userinfo`).
- PAT onboarding sheet (ADR 0006 two-step flow).
- `MonitorCredentialVault` storage (ADR 0002).
- Job-token re-exchange on ~24h expiry (needed even for quota-only).
- `QuotaViewModel` per-provider switch case.
- Quota response mapping → `ModelQuota` rows (mirror `usage.ts`: userQuota,
  orgResourcePackage).
- **Excludes:** ProxyBridge changes, COSY, WAF, chat, routing.

**Phase 2a — Local proxy routing, text + streaming only.** A CLI agent sending
`qoder/auto` gets a streamed OpenAI-shape response. Tools/images/thinking-split
fail fast with HTTP 400.

Scope:
- `QoderCOSYSigner` (port `buildAuthHeaders`).
- `QoderWAFEncoder` (port `qoderEncodeBody`).
- `QoderChatTranslator` (port `transform.ts` + request-envelope builder, text
  path only).
- `QoderSSEReparser` (port response parser; skip thinking-tag splitter, skip
  tool state machine).
- ProxyBridge Qoder branch: prefix-detect, account-select, COSY-sign, ship,
  re-encode text deltas, stream.
- Multi-account failover router (ADR 0005 §3).
- `RequestMetadata` token fields + Quotio-side usage accumulator (ADR 0005 §2).
- Hardcoded model registry (ADR 0003).
- Fail-fast paths: requests with `tools`, image content, or
  `reasoning`-tag-bearing responses return HTTP 400 with a clear message.

**Phase 2b — Full parity remainder.** Tools, images, thinking-split — the
remaining surface from ADR 0004.

Scope:
- Thinking-tag streaming parser (port `thinking-parser.ts` cross-delta
  buffering).
- Tool-call delta state machine (port toolCallsState accumulation).
- Image content parts in message transform.
- Re-enable the fail-fast paths from 2a as supported.

### 4. Implementation details deferred to coding (no decision needed)

- Quota response field mapping (`userQuota`, `orgResourcePackage`, `total`,
  `used`, `remaining`, `percentage`, `unit`, `expiresAt`) — port verbatim from
  `usage.ts`.
- Token expiry buffer: `expiresAt - 5min` (match Grok).
- WAF `=` → `$` substitution — verbatim from `qoder-encoding.ts`.
- `business.*` envelope fields (`product: "cli"`, `version: "1.0.0"`,
  `type: "agent"`, `stage: "start"`) — verbatim magic strings.
- `session_type: "qodercli"`, `agent_id: "agent_common"`, `task_id: "common"`
  — verbatim.
- `Accept-Encoding: identity` mandatory header — WAF encoder breaks under
  transport compression.
- Localization strings via `Localizable.xcstrings`.

## Consequences

- Phase 1 ships fast (mirrors existing ClinePass/GLM quota-fetcher shape, no
  COSY). Delivers most of the user value with a fraction of Phase 2's risk.
- Phase 2a is the milestone where ProxyBridge stops being a pure byte-forwarder.
  2a is sized to exercise every hard path (COSY, WAF, envelope, SSE, failover)
  without the trickiest parser ports (thinking tags, tool state machine).
- Phase 2b is "port the rest" — well-scoped, independently shippable.
- The Qoder branch in ProxyBridge must remain cleanly separable so the CPA
  forwarding path for other providers is untouched. Code review gate: any change
  to non-Qoder forwarding paths in ProxyBridge is a regression risk.
