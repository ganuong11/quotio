# Qoder PAT Exchange Pacing

## Status

Accepted — 2026-08-11.

## Context

`POST openapi.qoder.sh/api/v1/jobToken/exchange` rate-limits when Quotio fires
too many exchanges too fast. Three paths funnel into this endpoint, and none
of them paces its calls:

1. **Quota polling** (`QoderQuotaFetcher.rotateIfNeeded` → `credentials(fromPat:)`):
   the fetcher loops enabled accounts sequentially, back-to-back, and only
   skips an account that already 429'd on `quota/usage` (per-account
   `rateLimitedUntil`, `QoderQuotaFetcher.swift:153`). That backoff does NOT
   cover exchange-endpoint 429s — it is keyed on the `quota/usage` response.
   Job-token expiries are synchronized (same login session, same ~24h expiry,
   same −5min refresh buffer), so every refresh window re-enters all accounts
   at once — an unspaced burst of N exchanges.
2. **Failover router** (`QoderFailoverRouter.resolveFreshCredential` /
   `reexchangeWithRetry` → `refreshCredential`): a 401 or expired token triggers
   re-exchange; the transient retry budget (`reexchangeRetryCount`, default 2)
   multiplies attempts.
3. **Onboarding** (`QuotaViewModel` → `credentials(fromPat:)`).

The quota poller and the router are separate actors with separate triggers, so
their exchange bursts can also overlap in wall-clock time — `QoderPATService`
serializes the calls but never paces them.

A rate-limited exchange leaves a stale job token, which the gateway then
rejects with 401: the account becomes unusable for that round.

## Decision

**Pace every exchange through one gate inside `QoderPATService`.**
`credentials(fromPat:)` and `refreshCredential` are the only production entry
points, and both call the private `exchangeJobToken(pat:)` — a single funnel.
The gate enforces a minimum interval between successive exchange *starts*
(`minExchangeInterval`, default 1s — an empirical starting point; the repo has
no measurement of Qoder's actual limit), implemented as a **sleep-recheck-claim
loop**:

- Read `nextExchangeAt`; if the slot is free (`<= now`), claim it
  (`nextExchangeAt = now + minExchangeInterval`) and return immediately.
- If taken, sleep until it frees, then loop and *re-check* on wake.
- The claim is synchronous (no `await` between check and claim), so
  exactly one caller wins a given slot even under actor reentrancy. A naive
  claim-before-sleep gate is wrong: two callers can sleep to the same deadline
  and resume out of order, producing a gap below the interval.
- The first caller is never delayed (`nextExchangeAt` starts at `.distantPast`).
- Cancellation during the wait propagates as `CancellationError`, consistent
  with `perform()`'s existing mapping of a cancelled network call.

No router or fetcher change: both already route through
`QoderPATService.shared`, so the gate applies globally without touching their
rotation/cooldown logic.

### Why this shape

- **One funnel, one gate.** Putting pacing in the router's retry loop or the
  fetcher's account loop would leave the other path unpaced — the two bursts
  can overlap. The funnel is the only place that sees *all* exchanges.
- **Proactive, not reactive.** The existing 429 machinery is reactive — it
  limits the *damage* of a 429. The gate prevents the self-inflicted burst that
  causes it.
- **Sleep-recheck-claim, not claim-before-sleep.** Verified by tracing the
  reentrancy interleavings: concurrent callers sleeping to the same deadline
  can resume late or out of order. Re-checking after every wake, and claiming
  synchronously with no suspension between check and claim, is the minimal
  correct gate.

### Deliberately NOT honoring `Retry-After` from an exchange 429

Sleeping out a server-supplied cooldown (60s–15min) inline would hang a chat
request. Self-healing is **partial**:

- **Router path self-heals.** `isPermanentReexchangeFailure`
  (`QoderFailoverRouter.swift:960`) classifies `.exchangeFailed(429)` as
  transient; the router burns its `reexchangeRetryCount` budget, and on
  exhaustion disables + schedules a one-shot recheck after `recheckInterval`
  (default 15 min, `QoderFailoverRouter.swift:221`).
- **Fetcher path has a residual gap.** `QoderQuotaFetcher.rotateIfNeeded`
  catches the exchange failure and falls back to the stale token
  (`QoderQuotaFetcher.swift:309-312`); its `rateLimitedUntil` backoff is keyed
  on `quota/usage` 429, NOT exchange 429. So the next quota cycle can re-trip
  the exchange limit. The pacing gate makes this gap academic by preventing the
  burst that causes it; if exchange-429s are observed on the fetcher path in
  practice, a follow-up could extend `rateLimitedUntil` to cover exchange
  failures. Not done now (no observation; YAGNI).

## Consequences

- Multi-account quota polling with N expired tokens now takes ~N×1s longer per
  refresh window — acceptable for background polling; chat requests with a
  fresh primary token are unaffected (no exchange fires).
- A chat request that needs a re-exchange may wait up to (queued-slot count ×
  1s) for the slot — bounded, and far cheaper than the 401 cascade it replaces.
- `QoderPATService` gains two pieces of actor state (`nextExchangeAt`,
  `minExchangeInterval`); `shared` uses defaults, so no wiring changes.
- The 1s default is unmeasured; tune the constant if observation requires.
- Fetcher-path exchange-429 backoff is a known residual gap (see above).
