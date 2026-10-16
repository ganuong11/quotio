# Qoder quota failover never triggers — diagnostic report

**Status:** Diagnosed. Root cause confirmed against live accounts. Fix not yet
implemented (per request — this is a report only).
**Date:** 2026-08-08
**Skill:** `diagnosing-bugs` (Phases 1–3 completed; fix deferred)

## Reported symptom

> "Our Quotio app, when proxying the Qoder accounts, doesn't switch to another
> Qoder account even when the current account quota is full (100%), so the agent
> receives an empty response from our proxy."

## What I confirmed empirically (live environment)

Three enabled Qoder accounts present, **none disabled**:

| Account | `accountKey` | Used | Role in this bug |
|---|---|---|---|
| ss aa | `019fdfaf-…` | **100% (exhausted)** | should rotate *away* from |
| yy uu | `019fdfbd-…` | 0% | ✅ healthy rotation target |
| dddd qqqq | `019fdfc8-…` | 0% | ✅ healthy rotation target |

(The Dashboard and menu bar show these values correctly — confirmed by the
user. The `snapshots-v1.json` cache I inspected mid-diagnosis showed stale
`used:0` for all three; the dashboard reads fresh data. Note also that
`ModelQuota.percentage` in `QoderQuotaFetcher` is **remaining** %, not used %,
so a stored `percentage:100` means 0% used — not an inconsistency.)

A real request through the running proxy:

```bash
curl -i -m 15 \
  -H "Authorization: Bearer $PROXY_KEY" \
  -H "Content-Type: application/json" \
  --data '{"model":"qoder/auto","stream":true,"messages":[{"role":"user","content":"hi"}]}' \
  http://localhost:8317/v1/chat/completions
```

**Observed wire response (reproduced 4×):**

```
HTTP/1.1 200 OK
Content-Type: text/event-stream
Cache-Control: no-cache
Connection: close
                                      ← then zero bytes until the 15s/30s/45s timeout
```

So the real failure shape is **HTTP 200 + SSE headers, then a silent stall** —
the agent (curl) blocks until its read timeout, then gets an empty body. The
router never rotates to "yy uu" or "dddd qqqq" — even though both are at 0%
used and fully eligible rotation targets.

## Root cause

The failover router decides "success vs rotate" using **only the upstream HTTP
status**, before reading any response bytes.

`Quotio/Services/Qoder/QoderFailoverRouter.swift`, `attempt()`:

```swift
let status = stream.response.statusCode
if (200..<300).contains(status) {
    return QoderOpenedStream(pump: stream.pump, accountID: account.id, ...)
}
switch status {
case 429: throw QoderAccountFailure(kind: .quota, ...)   // ← only this path rotates on quota
...
}
```

When a Qoder account is quota-exhausted, the gateway returns **HTTP 200** and
the exhaustion signal arrives **inside the SSE stream** (either as a frame with
`statusCodeValue != 200`, or — as observed live — as a silent stall where the
first frame never carries chat content). The router sees `2xx`, treats it as
success, and hands the stream to `ProxyBridge`. `ProxyBridge` writes
`HTTP/1.1 200 OK` to the agent, then either:

- trips `QoderSSEReparser`'s `statusCodeValue != 200` gate
  (`QoderSSEReparser.swift:276-281`) → mid-stream abort with no rotation, or
- blocks on `opened.pump { … }` forever because the upstream never yields
  content → agent read timeout (the live symptom).

Rotation is impossible by the time `ProxyBridge` owns the stream — the agent has
already received `200 OK`. ADR 0006 §2 explicitly lists this case as
"cannot rotate cleanly; terminate," which is correct *for mid-stream* detection.
The bug is that the router classifies the response as success at `openStream`
time without inspecting the leading bytes, so detection that *could* happen
pre-handoff never does.

This is the gap between the ADR 0006 §2 policy intent ("HTTP 429 + quota body →
rotate") and the gateway's actual signalling (quota exhaustion rides inside a
200 SSE stream). The existing test `test429RotatesToNextAccount` only exercises
the pre-stream HTTP-429 path, which the live gateway does not appear to emit.

## Evidence: red-capable feedback loop

A regression test was added at
`QuotioTests/QoderFailoverRouterTests.swift::testQuotaExhaustedInEnvelopeRotatesToNextAccount`
that models the in-envelope failure shape (HTTP 200 + first frame
`statusCodeValue: 429`).

**Run:**

```bash
xcodebuild test -project Quotio.xcodeproj -scheme Quotio \
  -destination 'platform=macOS' \
  -only-testing:QuotioTests/QoderFailoverRouterTests/testQuotaExhaustedInEnvelopeRotatesToNextAccount
```

**Result (red, reproducing the user's symptom):**

```
QoderFailoverRouterTests.swift: XCTAssertEqual failed:
  ("monitor-0b35…") is not equal to ("monitor-24c0…")
  - should rotate to secondary after in-envelope 429
QoderFailoverRouterTests.swift: XCTAssertEqual failed:
  ("1") is not equal to ("2")
  - two attempts: primary (envelope-429) then secondary (200)
```

`callCount = 1` proves the router accepted the quota-exhausted primary as
success and never tried the secondary — exactly the reported behavior.

**Full router suite baseline:** 14 pass, 1 fail (the new test only). The new
test isolates the bug without disturbing existing coverage.

The test is intentionally left in place, red, as a documenting regression. A
second observed shape — the **silent stall** (200 + headers + no bytes, the live
symptom) — is described in the test's section comment but not encoded as a
separate assertion because the mock layer would need a "never-yields pump" to
model it; that belongs with the fix.

## Ranked fix hypotheses (Phase 3 — not implemented)

1. **Peek the first SSE chunk inside `attempt()` before declaring success.**
   Falsifiable prediction: if the router reads the leading bytes of
   `QoderGatewayStream` and feeds them through the reparser's
   `statusCodeValue` gate *before* returning `QoderOpenedStream`, the in-envelope
   429 becomes a `QoderAccountFailure(.quota)` and the existing rotation policy
   rotates. Risk: the `QoderOpenedStream.pump` contract must change to carry the
   already-buffered prefix (and the remaining stream) so no bytes are lost on the
   clean-success path. This is the most complete fix and addresses both observed
   shapes (a stall surfaces as a bounded timeout on the peek read).

2. **Add a pre-flight quota gate using the dashboard snapshot.**
   `QoderQuotaFetcher` already produces per-account `percentage`. The router
   could skip accounts the snapshot marks as exhausted before attempting. This
   is cheap and simple, but (a) the snapshot is stale between polls, (b) it
   couples the router to quota-fetch cadence, and (c) the dashboard already
   shows the correct values — so the snapshot *is* a usable signal once refresh
   cadence is accounted for. Best as a *secondary* fast-path defense behind #1,
   not a replacement.

3. **Treat the silent-stall shape as transient (5xx-style) and rotate.**
   If the first chunk doesn't arrive within a short deadline, classify the
   account as failed and rotate. Risk: genuine slow-first-byte chats would be
   mis-rotated; the deadline must be tight (sub-second) and the quota-exhaustion
   account would not be cooled down as `.quota`, so it would be retried next
   request. Partial mitigation only.

**Recommended primary fix:** #1, with #2 as a fast-path optimization once the
snapshot semantics are confirmed. #3 alone is insufficient.

## Open questions for the implementer

- Is there a captured HAR / first-frame sample of the gateway's quota-exhausted
  response? The live repro showed a silent stall (no envelope at all within 45s),
  but the reparser's `statusCodeValue` gate and the pi reference
  (`stream.ts:298-299`) both expect an in-envelope non-200. Confirming which
  shape the gateway emits — or whether it emits both depending on timing —
  determines whether fix #1 needs a timeout in addition to the envelope gate.
- ~~The dashboard's `percentage: 100` with `used: 0, limit: 300` for all three
  accounts deserves a separate look~~ — **resolved**: those numbers were a stale
  snapshot I read mid-diagnosis; the dashboard shows fresh values (ss aa = 100%
  used, the other two = 0%). No separate display bug. This also means fix #2
  (pre-flight quota gate) has a trustworthy signal available once refresh cadence
  is handled.

## Files touched in this diagnosis

- `QuotioTests/QoderFailoverRouterTests.swift` — added one red regression test
  (+ section comment). No production code changed. No instrumentation left in
  production code; temp capture files cleaned up.

## What would have prevented this bug

A feedback loop that ran a real (or faithfully-mocked) quota-exhausted account
through `QoderFailoverRouter.openStream` and asserted on rotation. The existing
suite mocked the gateway's *HTTP status* only, so it could never catch a signal
the gateway carries *inside* a 200 stream. The seam (router reads
`response.statusCode` only; pump is handed off un-peeked) is the architectural
gap — the fix in #1 deepens the router's contract from "open a 2xx stream" to
"open a 2xx stream whose first chunk is clean," which is where the
architectural recommendation (`/improve-codebase-architecture`) would land.
