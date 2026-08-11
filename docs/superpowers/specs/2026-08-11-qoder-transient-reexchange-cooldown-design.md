# Qoder Transient Re-exchange Cooldown Design

## Problem

When Qoder rejects a stale job token, `QoderFailoverRouter` re-exchanges the stored PAT. If every re-exchange attempt fails because of a transient network error or HTTP 429, the router currently writes the account into `MonitorMetadataStore.disabledAccountIDs`. That persistent disable overrides a user's manual re-enable on the next client request and survives Quotio restarts, even though the PAT and account quota may remain valid.

## Decision

Treat exhausted transient PAT re-exchange failures as temporary routing unavailability, not account revocation:

- For transient failures (`QoderPATError.network`, exchange/user-info HTTP 429, or an unknown error conservatively classified transient), apply the router's existing in-memory cooldown and rotate to another account.
- Do not add the account to `disabledAccountIDs`, post a PAT-revoked notification, or schedule a persistent-disable recovery task.
- If all usable accounts fail this way, return the existing `allAccountsCoolingDown` error: HTTP 429 with `Retry-After` and an OpenAI-compatible `rate_limit_error` body.
- Preserve persistent disable behavior for proven permanent failures: invalid/missing PAT material, malformed exchange/identity responses, exchange/user-info failures other than 429, or a second gateway 401/403 after a successful re-exchange.
- Preserve user-initiated disables. The router already excludes IDs in `disabledAccountIDs`; this change does not clear or reinterpret them.

## Scope

Change only the reactive re-exchange exhaustion branch in `QoderFailoverRouter.openStream` and its tests. Remove the now-unreachable scheduled re-enable machinery if no production path remains, including its configuration, notification, and UI observer. Do not change quota-fetch behavior, cooldown duration, or PAT error classification.

## Tests

Regression coverage must prove:

1. Exhausted transient network failures rotate without persisting a disabled ID.
2. Exchange HTTP 429 rotates without persisting a disabled ID.
3. A single-account transient exhaustion returns `allAccountsCoolingDown`, not `noAccountsAvailable`.
4. The account becomes eligible again after the cooldown expires without a persistent re-enable step.
5. Permanent PAT failures still disable immediately and persistently.
6. Existing all-disabled behavior remains HTTP 503.
