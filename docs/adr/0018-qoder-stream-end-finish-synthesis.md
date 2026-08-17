# Qoder streams ending without an upstream finish_reason get a synthesized `stop`

## Context

OpenAI's streaming contract requires exactly one chunk with a non-null
`finish_reason` before the terminal `[DONE]`. ADR 0011 guarantees the *shape*
of every chunk (`delta` always present, `finish_reason` present but `null` on
non-terminal chunks) — it says nothing about whether a terminal chunk arrives
at all. That arrival was entirely upstream-dependent: `QoderSSEReparser.finish`
emitted the stashed finish chunk only if the upstream Qoder gateway had sent a
`finish_reason` frame.

On 2026-08-17 a live ZCode session hit the gap. The Qoder gateway ended the
SSE body cleanly (proper end of chunked encoding — no transport error, no
reparser gate) after content deltas but without any finish frame, during
per-minute quota exhaustion. `finish()` emitted content chunks followed by a
bare `data: [DONE]`. ZCode's StreamAdapter (verified in the client bundle)
warns `[StreamAdapter] Stream ended without finish_reason (text-only)` for
exactly this shape, surfaces it as a failed turn, and error-retries — the
retries then hit the account-cooldown 429 wall
(`allAccountsCoolingDown`), producing the reported cascade.

The same client-source read established two adjacent facts:

- The client degrades this case to `stop_reason: "end_turn"` on its own — the
  synthesis below matches the client's intended degradation, minus the
  contract-violation warning.
- The client *cannot* parse a mid-stream `{"error":{...}}` SSE frame (ADR
  0010's mid-stream failure terminal) — it counts as a parse error and is
  discarded. Known mid-stream failures therefore still end without a
  `finish_reason` client-side; that path is unchanged (see Consequences).

## Decision

`QoderSSEReparser.finish()` synthesizes a `finish_reason: "stop"` terminal
chunk when the upstream stream ends with **no finish_reason seen at all** and
**assistant content (text/reasoning) was delivered**. Two deliberate
exclusions:

1. **Empty streams** (no assistant payload ever emitted): an empty response is
   a genuine failure, not a completed turn. No terminal is invented; the
   client's empty-response error path stays reachable.
2. **Streams that emitted tool calls**: clients repair truncated tool-call
   `arguments` JSON only on the no-`finish_reason` path (ZCode's StreamAdapter
   repair loop is gated on the absent terminal). A synthesized terminal would
   close those blocks un-repaired and hand the agent invalid JSON. The
   unterminated end is the recovery signal.

Known mid-stream failures (reparser gates, transport drops) never reach
`finish()` — ProxyBridge emits the ADR 0010 error frame and skips the
terminal flush. A real failure is never masked with a success terminal.

The value is `stop`, not `length`: a clean HTTP-level end of body is
indistinguishable from a server that omitted its terminal, and `stop` is what
the client itself synthesizes (`end_turn`) for this case. Claiming `length`
would assert a token-budget truncation we cannot prove.

## Consequences

- Strict OpenAI clients see a well-formed terminal on clean EOF; the ZCode
  warning and the error-retry it triggers disappear for this failure mode.
- Non-streaming aggregation benefits identically: a truncated aggregated
  `chat.completion` now carries `finish_reason: "stop"` instead of an absent
  field (the aggregator consumes the reparser's terminal).
- Tool-call stream truncation intentionally still ends unterminated
  (client-side repair owns it) — locked by
  `testToolCallStreamWithoutFinishDoesNotSynthesize`.
- Known mid-stream failures remain client-invisible in their error detail
  (the ADR 0010 frame is discarded by ZCode's parser); they still terminate
  the stream and the client still reports the missing finish_reason. Making
  the mid-stream error legible to schema-strict clients would require a
  different wire shape (e.g. a chunk-shaped error carrier) — out of scope,
  and masking failures with `stop` was rejected.
- The upstream finish_reason, when present, always wins; synthesis is guarded
  by a per-stream `finishReasonEmitted` flag and cannot double-terminate.
