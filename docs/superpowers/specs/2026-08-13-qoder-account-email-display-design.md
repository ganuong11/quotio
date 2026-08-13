# Qoder Account Email Display Design

## Problem

The Providers and Quota tabs show Qoder accounts with only the display name (e.g. "John Doe"). Qoder permits multiple accounts, and users who add more than one see several rows with identical or ambiguous names. The account email is the natural differentiator, but it is discarded when the account is persisted.

`QoderPATService.fetchUserInfo` already resolves the email during PAT onboarding (`QoderPATService.swift`), and the onboarding confirmation sheet shows it. But `saveQoderAccount(from:)` (`QuotaViewModel.swift`) collapses the identity into a single `displayName = name ?? email ?? userID` on `MonitorAccount`, which has no email field. Both tabs render only that one string.

## Decision

Carry the email as a first-class field on `MonitorAccount` and render it as a secondary line beneath the display name in both tabs.

- `MonitorAccount` gains `var email: String? = nil` (default `nil` in `make`). Declared as a `var` with a default so the synthesized memberwise initializer gives every existing direct construction site a defaulted parameter — no call-site churn. `MonitorAccount` is `Codable`; an optional field means existing persisted metadata decodes as `nil` with no migration.
- `saveQoderAccount(from:)` passes `identity.email` through to the new field. The account key (`userID`), display name fallback chain, and dedup guard are unchanged. No new API calls: the email comes from the identity the PAT exchange already fetches.
- `MonitorRuntime.applyingQuotaDisplayNames` copies `email` alongside the other fields so a quota refresh cannot wipe it. The field-by-field `MonitorAccount` copy inside `makeQuotaDerivedAccount` / quota-derived paths does not apply to Qoder (Qoder accounts come from the Vault metadata, not quota derivation).
- Per user decision: **no backfill.** Accounts created before this change keep showing the name only. Only accounts added after the change display an email.

## UI

Layout chosen: name stays the primary line, email as a secondary caption.

- **Providers tab** — `AccountRowData.from(monitorAccount:status:statusMessage:)` carries the email as a new optional `subtitle` field. `AccountRow` renders it as a `.caption`/secondary-style line under the display name, masked when "hide sensitive info" is on (same `masked(if:)` helper the display name uses), and omitted entirely when nil.

  ```
  John Doe
  john@corp.com · Quotio keychain      ← new line
  ```

- **Quota tab** — `AccountQuotaCardV2` header gains the same secondary line. `QuotaScreen` builds a `[accountKey: email]` lookup from `viewModel.monitorAccounts` (same pattern as the existing `directAuthEmailsByKey` backfill at `QuotaScreen.swift`) and threads it into `AccountInfo` as an optional subtitle.

  ```
  [Pro] John Doe
        john@corp.com                  ← new line
  ```

- Non-Qoder providers are unaffected: they pass `email == nil`, so no subtitle renders. The component change is generic, but only Qoder populates the field in this change.

## Scope

Change: `MonitorAccount` (+ `make`), `saveQoderAccount`, `applyingQuotaDisplayNames`, `AccountRowData`/`AccountRow`, `QuotaScreen` `AccountInfo` plumbing.

Do not change: the menu bar, `MonitorToCLIProxyAuthExporter` (Qoder auth files key off `accountKey`, not email), the quota fetchers, `ProviderQuotaData`, the onboarding sheet (it already shows the email), or any API/network behavior.

## Tests

1. `saveQoderAccount` persists a `MonitorAccount` whose `email` equals the identity's email; blank email persists as `nil`.
2. `MonitorAccount` metadata with no `email` key decodes to `nil` (back-compat with existing persisted records).
3. `applyingQuotaDisplayNames` preserves `email` across a refresh.
4. `AccountRowData.from(monitorAccount:)` exposes the email as subtitle; nil email yields no subtitle.
