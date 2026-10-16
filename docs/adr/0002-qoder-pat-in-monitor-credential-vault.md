# Store the Qoder PAT in MonitorCredentialVault, not CustomProviderService

## Context

The Qoder PAT is a long-lived bearer secret (`pt-...`) that can mint job tokens
until revoked. Two storage seams exist in Quotio:

- **MonitorCredentialVault** — Keychain (`dev.quotio.desktop.monitor-auth`),
  per-account `MonitorOAuthCredential` JSON, CAS-protected rotation. Used by
  refresh-style OAuth providers (Grok, Copilot, Kiro, Antigravity).
- **CustomProviderService** — `UserDefaults` plaintext JSON. Used by API-key
  providers (GLM, ClinePass) whose keys must round-trip into CPA's YAML config
  as Bearer headers.

The PAT does not fit CustomProviderService's purpose: it never goes into any
YAML config (CPA never sees it — see ADR 0001), and it needs ~24h rotation
(re-exchange), which CustomProviderService has no mechanism for.

## Decision

Store the Qoder PAT in `MonitorCredentialVault` as a `MonitorOAuthCredential`:

- `accessToken` = current job token (`jt-...`), the short-lived working token
- `expiresAt` = job-token expiry
- `extra["pat"]` = the long-lived PAT
- `extra["machineID"]`, `extra["jobRefreshToken"]` = supplementary Qoder fields

Rotation re-exchanges the PAT on expiry and updates `accessToken` / `expiresAt`
in place via the existing `compareAndSwapMonitorCredential` path.

## Considered Options

- **MonitorCredentialVault** *(chosen)* — fits the shape (long-lived secret
  needing rotation), matches Grok precedent (PAT ≈ refresh token; job token ≈
  access token), reuses CAS, PAT never touches UserDefaults.
- **New dedicated Keychain drawer** (`dev.quotio.desktop.qoder`) — cleaner type
  boundary, but reinvents CAS and account-key derivation that the Vault already
  provides. Justified only if Qoder auth diverges sharply (e.g., multiple
  machine IDs per account). Not justified today.
- **CustomProviderService** (UserDefaults) — fastest, reuses AddCustomProvider
  UI, but leaks a long-lived account-takeover secret into plaintext JSON for no
  benefit, since the PAT never needs to round-trip into CPA config.

## Consequences

- The PAT is held to the same bar as Quotio's other long-lived refresh
  credentials (Grok OAuth refresh tokens).
- `extra["pat"]` is slightly unusual phrasing (the struct is named for OAuth),
  but `extra` is already the established drawer for provider-specific auth bits
  (Grok stores `clientId` there).
- Phase 1 (quota monitor) cannot ride the CustomProviderService + ClinePass UI
  fast-path. We need a dedicated Add Account flow for Qoder PAT entry, modelled
  on how Grok's monitor-mode onboarding works.
