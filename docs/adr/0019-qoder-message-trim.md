# Over-cap Qoder conversations are trimmed, not rejected

## Context

Issue #14 (Tier 2 semantic caps) made `QoderChatTranslator` reject any Chat
Completions request with more than `maxMessages` (default 999) messages:

`400 {"message":"Qoder translator: messages count 1001 exceeds limit of 999.","type":"invalid_request_error"}`

On 2026-08-18 a long-lived ZCode session crossed 999 messages and hit exactly
this on **every subsequent request** — the conversation history only grows, so
once past the cap the session is permanently broken against the qoder local
proxy. The cap was working as designed (defense-in-depth mirroring the
upstream gateway's own limits, per issue #14), but the *reject* response made
a legitimately-growing conversation unrecoverable.

Two facts constrain the fix:

- The upstream gateway's own message-count limit is real but its exact value
  is unknown. 999 is the last **empirically-verified-safe** count: the proxy
  cap always fired first, so every request upstream ever accepted was ≤999.
- CLI-agent conversation history is append-only client-side; the client (ZCode)
  compacts on *token* signals, not message count, so it cannot be relied on to
  stay under a message cap.

An in-flight working-tree change (2026-08-18) attempted to fix the symptom by
raising the defaults (`maxMessages` to 9999999, image/tool-schema bytes to
999 MiB). That moves the failure, not fixes it: an oversized request would
pass the proxy and die at the upstream gateway with an error outside our
OpenAI envelope, no trimming, and no graceful degradation. This ADR replaces
that approach for `maxMessages`. The byte caps were also restored to their
ADR 0013 pairing (90 MiB image / 5 MiB tool schema): an inline image travels
base64-inflated (~4/3x), so a 999 MiB image cap would require allowing
>1.3 GiB HTTP bodies through the bridge parser — reopening the
memory-exhaustion vector Tier 1 closed (pinned by
`testBodyCapStaysAboveImageCapWireFootprint`). The raised tool *count*
(9999) is kept: it has no byte implication and no upstream-verified bound.

## Decision

`QoderChatTranslator.translate` **trims** an over-cap conversation to
`maxMessages` messages instead of rejecting it (`QoderChatTranslator.trimmingMessages`).
Recency beats completeness:

1. Keep the maximal leading system/developer preamble verbatim — the system
   prompt is load-bearing for CLI agents.
2. Keep the newest body messages that fit the remaining budget.
3. Advance the cut to a safe boundary so the kept suffix never opens on a
   `tool` message orphaned from its assistant tool-call turn (upstream rejects
   orphaned tool results): prefer the next `user` message, else the next
   non-`tool` message.

`enforceLimits` stays as the final gate: when trimming cannot get under the
cap (preamble alone ≥ cap — pathological), the request is still rejected with
the existing 400. No notice message is injected at the cut; the trim is
silent, like context-window trimming in other gateways.

`maxMessages` is 9999 (user decision, 2026-08-18). The trim is what makes
any number safe to pick — availability no longer depends on the cap — so the
choice is purely how much context to preserve before trimming starts. The
known tradeoff: the upstream gateway's own message-count limit is unverified
above 999 (the last empirically-observed-accepted count), so a request
between 1000 and 9999 messages could still hit the upstream's own 4xx; if
that is ever observed, lowering the number (or teaching the trim to engage
at the observed upstream bound) is a one-line change.

The Responses API path (`/v1/responses`) never had Tier 2 caps wired
(issue #14 covered the Chat translator only) and is unchanged by this ADR.

## Consequences

- Long sessions keep working past the cap; the 2026-08-18 ZCode session
  (1001 messages, then capped at 999) sits far under the 9999 cap and needs
  no trim at all.
- Context loss begins at the trim boundary and only for conversations larger
  than `maxMessages` messages — under-cap requests are forwarded
  byte-identically (`trimmingMessages` returns the input unchanged).
- The recordID/session cache key is derived from the trimmed messages, so a
  trimmed request does not share a prompt-cache entry with its untrimmed
  predecessor. Correct: the upstream context genuinely differs.
- `business.name` (`lastUserText` prefix) and `chat_context.text` reflect the
  newest user message, which the trim always preserves.
- A request between 1000 and 9999 messages is forwarded untrimmed; if the
  upstream gateway's own limit lies in that range, its 4xx surfaces as-is
  (relayed by the failover router, not the ADR 0010 envelope).
- Locked by tests: `testTranslateBodyWith10001MessagesIsTrimmedNotRejected`
  (the reported failure mode at the new default), `testTrimKeepsSystemPreambleAndNewestBody`,
  `testTrimCutSkipsOrphanedToolResult`, `testTrimUntrimmablePreambleReturnsInputUnchanged`,
  `testUntrimmableMessageCountErrorNamesLimitAndActualNotContent`.
