# xAI Grok as first-class provider

Date: 2026-07-23  
Status: approved (Approach A)  
Updated: 2026-08-02 — bumped bundled CPA from v7.2.96 to v7.2.113 (binary refreshed; see `ProxyBinarySource.plusLocalVersion`/`plusLocalSHA256`).

## Goal

Promote existing Grok from quota-tracking-only to a routable provider: Add Provider → CLIProxyAPI xAI device OAuth → auth file → proxy routing. Keep native `~/.grok` quota tracking.

Bundle CLIProxyAPI **v7.2.113** as the Plus-local binary so xAI works out of the box.

## Non-goals

- Native `xai-api-key` custom provider type
- Renaming Plus branding/paths

## Monitor mode (added)

Add Account → xAI device OAuth (`auth.x.ai`) → `MonitorCredentialVault` → `GrokQuotaFetcher` vault path. Native `~/.grok` auto-detect unchanged.

## Architecture

```
Add Grok → GET /v0/management/xai-auth-url
         → device URL + user_code → user authorizes
         → poll /get-auth-status?state=…
         → auth file type "xai" under auth-dir
         → DirectAuthFileService maps "xai" → AIProvider.grok
         → proxy routes; GrokQuotaFetcher still reads ~/.grok
```

App identity stays `AIProvider.grok` (`rawValue: "grok"`). Wire key at CPA boundary is `"xai"`.

## Changes

### Bundle

- Replace `Quotio/Resources/Proxy/cli-proxy-api-plus` with CPA v7.2.113 darwin aarch64 binary (keep filename).
- `ProxyBinarySource.plusLocalVersion` / `plusLocalSHA256` + display strings.

### Model flags (`AIProvider.grok`)

| Property | To |
|----------|-----|
| `oauthEndpoint` | `/xai-auth-url` |
| `supportsManualAuth` | `true` |
| `isQuotaTrackingOnly` | `false` |

### Auth discovery

- `mapTypeToProvider`: `"xai" → .grok`
- filename prefix: `xai-`

### OAuth UI

- Decode optional `user_code` from OAuth URL response.
- Store on `OAuthState`; show device-code UI for Grok (same pattern as Copilot/Kiro).
- Do not put `user_code` in poll `state` (session id must stay for `/get-auth-status`).

### Unchanged

- `GrokQuotaFetcher`, `discoverGrokCredentials()`
- Onboarding featured list
- Agent configuration

## Risks

Bundled binary is upstream CPA, not historical Plus — legacy Plus-only Copilot/Kiro behavior may change. Smoke-test those flows after upgrade.

## Verification

- Debug build
- Bundled proxy SHA matches model constant
- Manual: Add Grok → authorize → account + models + one proxied request
- Manual: `~/.grok` quota still refreshes
