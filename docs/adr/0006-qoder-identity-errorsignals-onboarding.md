# Qoder identity, error signals, and onboarding

## Context

Three runtime-detail concerns that bite in implementation if left implicit:
whether machine IDs are shared or per-account, how the failover router
(ADR 0005) distinguishes quota-exhaustion from auth failure from transient
errors, and what the user-facing PAT onboarding flow looks like given that
Qoder lives in `MonitorCredentialVault` (ADR 0002), not `CustomProviderService`.

## Decision

### 1. Machine ID is per-account

Each Qoder PAT mints its own machine ID at first PAT-exchange, stored in
`MonitorOAuthCredential.extra["machineID"]`. Different accounts present as
different installs to Qoder. Quotio does NOT reuse `~/.qoder/.auth/machine_id`
or `~/.pi/agent/qoder-machine-id` — Quotio's identity is independent of whether
the official Qoder CLI or pi provider is also installed on the machine.

### 2. Error signal taxonomy with one-shot re-exchange on 401

| Signal | Action |
|---|---|
| HTTP 429 + quota body | Rotate to next enabled account; cool down this one |
| HTTP 401/403 (first occurrence) | Re-exchange PAT once, retry same account |
| HTTP 401/403 (after re-exchange) | Mark PAT revoked: disable account, notify user, silently rotate to next account |
| HTTP 5xx | Transient: retry same account with backoff, do NOT rotate |
| Network timeout | Transient: retry same account |
| HTTP 200 + non-200 `statusCodeValue` on the **first** SSE chunk | Rotate (the 200 head has NOT been written to the agent yet — the router peeks the leading bytes before handing the stream off). Classify by the in-envelope status: 429 → quota, 401/403 → auth, 5xx → transient. |
| HTTP 200 + silent stall (no first chunk within the peek timeout) | Rotate as quota. Observed on exhausted accounts; the gateway returns 200 + headers then never yields content. |
| SSE `statusCodeValue !== 200` **mid-stream** (after the first clean chunk) | Cannot rotate cleanly (the 200 head + earlier chunks were already written to the agent); terminate with error. |

> **Clarification (2026-08):** the "cannot rotate cleanly" rule applies only
> once ProxyBridge has written the `200 OK` SSE head to the agent socket. The
> router peeks the first upstream chunk *before* that write — so detection of a
> quota/auth signal (or a silent stall) on the opening chunk CAN rotate. The
> pre-fix bug was that the router decided success from the HTTP status alone
> and never inspected the leading bytes; the fix added a bounded peek
> (`QoderFailoverRouter.confirmStreamAndHandOff`) that closes the gap while
> preserving the mid-stream no-rotate invariant.

Failover is **invisible to the agent** (transparent retry). No
`X-Qoder-Account-Rotated` header is surfaced. Rationale: the OpenAI proxy
contract has no concept of upstream account rotation; surfacing it would confuse
agents that don't know to read it.

The "one re-exchange on 401" path exists because most 401s are job-token
expiry (~24h), not PAT revocation. Without it, every job-token expiry would
disable the account — wrong UX.

### 3. Two-step PAT onboarding via Add Provider → Qoder

Onboarding flow:

1. User picks Qoder from Add Provider popover (Qoder joins the
   `supportsManualAuth` set in `AIProvider`).
2. Sheet appears with a single PAT paste field.
3. On submit: Quotio calls `openapi.qoder.sh/api/v1/jobToken/exchange`
   synchronously. No COSY signature required for this call.
4. On success: fetch user info (`/api/v1/userinfo`), confirm identity
   (email/name/userID) with the user, generate a per-account machine ID, save
   `MonitorOAuthCredential` to the Vault with `extra["pat"]`,
   `extra["machineID"]`, `extra["jobRefreshToken"]`.
5. On failure (including a CN-region PAT rejected by the global endpoint):
   show the upstream error, do not save.

This mirrors how the pi provider's `credentialsFromPat` sequence works, minus
pi-specific fallbacks. CN-region PATs are rejected implicitly: they fail
exchange against `openapi.qoder.sh` (per the locked Q2 from wave 1 — drop the
whole CN endpoint set).

## Considered Options

### Machine ID

- **(α) Shared per-install.** Rejected: user chose per-account. Per-account
  isolates accounts from each other's rate-limit/fingerprint blast radius —
  one account tripping a machine-ID-based limit doesn't drag the others.
- **Reuse `~/.qoder/.auth/machine_id`.** Rejected: ties Quotio's identity to
  the official CLI's install state. Keeping them independent avoids cross-tool
  coupling and matches how the Vault already isolates per-account identity.

### Error signals

- **Disable-on-first-401.** Rejected: every ~24h job-token expiry would
  disable the account. Wrong UX. One re-exchange is the safe default.

### Onboarding

- **Custom Provider UI (ClinePass-style).** Rejected: would force Qoder into
  `CustomProviderService`/UserDefaults, contradicting ADR 0002.
- **OAuth device flow (Grok-style).** Rejected: Q2 of wave 1 locked PAT-only,
  no OAuth.

## Consequences

- A user with the official Qoder CLI installed will see Quotio present as a
  separate install to Qoder (different machine ID). This is intentional but
  means Qoder's account dashboard may show multiple "devices" — worth a help
  note.
- The disable-on-revoked-PAT + silent-rotate path means a revoked PAT produces
  no agent-visible error as long as another account is available. The user
  learns about the revocation via Quotio's notification, not via a failed
  agent request. This matches how CPA-native providers behave today and is the
  right UX, but the notification must be reliable (no silent loss).
- The synchronous exchange call in onboarding blocks the UI for one network
  round-trip. Acceptable; show a spinner.
