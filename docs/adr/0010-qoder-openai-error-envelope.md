# Qoder and bridge errors use a single CPA-shaped OpenAI JSON envelope

## Context

`ProxyBridge.sendError` returns `text/plain` with the literal message as the
body (`Quotio/Services/Proxy/ProxyBridge.swift:1419-1455`). The OpenAI contract
requires a JSON `{"error":{...}}` object; CPA enforces this via
`BuildErrorResponseBody` (`sdk/api/handlers/handlers.go`), which every CPA-served
endpoint already uses. So today a client sees JSON errors for non-Qoder models
and `text/plain` for Qoder (and for bridge-level parse failures) — two different
contracts depending on the path.

The gap analysis (`docs/qoder-openai-proxy-gap-analysis.md`, P2 "error
envelopes") also flagged that mid-stream failures (after the `200 OK` SSE head
has been written) are silently truncated: the connection drops with no terminal
SSE frame, so the client cannot distinguish a clean end from an error.

This couples to the already-made decisions: ADR 0008 (auth → 401 envelope) and
ADR 0009 (endpoint gate → 404 envelope) both need a JSON error builder to exist.

## Decision

Port CPA's `BuildErrorResponseBody` to Swift as a single builder, used by both
`ProxyBridge.sendError` (replacing `text/plain`) and the Qoder path's pre-stream
failures. Qoder-path and CPA-path errors become indistinguishable at the
contract boundary — the same coherence rationale as ADR 0008.

### Envelope shape (verbatim from CPA)

```json
{ "error": { "message": "...", "type": "...", "code": "..." } }
```

No `param` field — CPA's `ErrorDetail` struct does not have one and the OpenAI
spec marks it optional. (Rejected as speculative surface area with no consumer.)

### Status → type/code map (verbatim from CPA)

| Status | type | code |
|---|---|---|
| 400 | `invalid_request_error` | (none) |
| 401 | `authentication_error` | `invalid_api_key` |
| 403 | `permission_error` | `insufficient_quota` |
| 404 | `invalid_request_error` | `model_not_found` |
| 429 | `rate_limit_error` | `rate_limit_exceeded` |
| 5xx | `server_error` | `internal_server_error` |

Mapping onto the Qoder failure kinds already in the code:

- Auth: missing/invalid key → **401** (ADR 0008).
- Endpoint gate: `qoder/` on unsupported endpoint → **404** (ADR 0009).
- `requestRejected` / malformed body → **400**.
- `noAccountsAvailable` (no enabled account, or all cooled down) → **503**.
  Not 429: this is not the *client's* rate limit, it is the *server's* lack of
  capacity. 429 would mislead the client into backing off when the fix is on
  the server side (add/enable an account).
- Catch-all upstream failure → **502**.

### JSON pass-through (verbatim from CPA)

If the error text is already valid JSON, return it verbatim instead of
re-wrapping — preserves upstream Qoder error payloads byte-faithfully.

### Mid-stream SSE error frame

After the `200 OK` SSE head has been written, a failure (transport drop,
reparser gate, upstream status) can no longer change the HTTP status. Instead of
silently truncating, emit a terminal SSE frame before close:

```
data: {"error":{"message":"...","type":"...","code":"..."}}

data: [DONE]

```

This closes the gap-analysis "mid-stream errors silently truncate" hole while
preserving ADR 0006 §2's invariant: mid-stream errors do **not** rotate accounts
(the 200 head is already committed). The SSE frame is terminal cleanup, not a
retry signal.

## Considered Options

- **Invent our own envelope with a `param` field** (gap-analysis literal).
  Rejected: CPA's struct has no `param`, OpenAI marks it optional, and there is
  no consumer for it. Speculative surface area.
- **Keep `text/plain` for bridge-level errors, JSON only for Qoder.** Rejected:
  creates the same two-contracts split ADR 0008 rejected for auth. The goal is a
  single coherent server.
- **`noAccountsAvailable` → 429.** Rejected: 429 is a client-side rate limit;
  no-accounts is server-side capacity. 429 would mislead the client into backing
  off when the fix is adding/enabling an account server-side. 503 is honest.
- **Silently truncate mid-stream errors.** Rejected: clients cannot distinguish
  a clean end from an error; the gap analysis flags this explicitly. The SSE
  error frame is cheap and contract-faithful.

## Consequences

- One error builder serves the whole bridge + Qoder path. Every status change
  (e.g., ADR 0008's 401, ADR 0009's 404) flows through it, so the status→type
  map stays consistent by construction.
- The builder's status→type map must track CPA's if CPA changes it — low risk,
  this map has been stable, and mirroring CPA is the point.
- Mid-stream SSE error frames are a new client-visible behavior; clients that
  previously relied on silent truncation (none known) now see a terminal frame.
  This is strictly more informative.
- `sendError`'s call sites each need to pass a status; the `text/plain` body is
  gone. Existing tests that assert on the literal text body must update to
  assert on the JSON envelope.
