# Qoder streaming chunks are built from CPA's always-carried template

## Context

The OpenAI streaming chunk schema requires `choices[].delta` and
`choices[].finish_reason` ([`CreateChatCompletionStreamResponse`](https://github.com/openai/openai-openai/blob/c309ca176bc22c6075a0c2c2543f2ac4f307c447/openapi.yaml#L33311-L33445)).
CPA enforces this with a single template every chunk starts from:

```json
{"choices":[{"index":0,"delta":{},"finish_reason":null}]}
```

Quotio's four chunk builders (`buildContentChunk`, `buildReasoningChunk`,
`buildToolCallChunk`, `buildChunk`) each hand-build a `choice` dict that omits
whichever field isn't actively populated: content/reasoning/tool chunks have no
`finish_reason`; finish/usage chunks have no `delta`; the usage chunk carries
`choices: [{index:0}]` instead of the spec-mandated `choices: []`; and the
upstream role-only opener is dropped (locked in by
`testEmptyContentDeltaEmitsNothing`).

Many clients tolerate this, but strict SDK schemas (zod, pydantic with
`required`) reject it. The same class of strict-validator failure already bit
the ZCode agent on sparse tool-call headers
(`QoderSSEReparser.buildToolCallChunk` documents the `function: expected object,
received undefined` failure). The gap analysis
(`docs/qoder-openai-proxy-gap-analysis.md`, P2 "canonical streaming chunk
shape") lists four sub-issues; they share one root cause.

## Decision

Adopt CPA's template approach. Refactor `emitChunk` to **always** stamp `delta`
(default `{}`) and `finish_reason` (default `null`) on every choice, so the
contract is enforced structurally rather than by per-builder discipline.

1. **Always carry `finish_reason`** — `null` on non-terminal chunks, the real
   value on the terminal choice chunk.
2. **Always carry `delta`** — `{}` on terminal/usage choices, populated on
   content/reasoning/tool chunks.
3. **Usage chunk is `choices: []`** — built by a dedicated `buildUsageChunk`,
   separate from `buildChunk`, so the empty-choices rule cannot be missed.
4. **Synthesize `delta.role: "assistant"` once per stream** — on the first
   emission (content, reasoning, or tool), if no explicit opener was sent.
   Mirrors CPA's `message_start` behavior. Fires exactly once; tracked by a
   one-shot flag on the reparser.

## Considered Options

- **Patch each builder individually** (add `finish_reason: null` to three
  builders; add `delta: {}` to two; fix the usage `choices`; add the opener).
  Same wire result, but the contract is enforced by discipline across four
  sites, not by structure. Drift can recur — which is exactly how the divergence
  happened in the first place. Rejected.
- **Adopt the template but keep dropping the role opener.** Closes three of four
  gaps but leaves the strict-schema opener gap open. The ZCode-agent comment
  shows strict validators are a real target. Rejected as a half-measure.

## Consequences

- The contract is enforced in one place (`emitChunk`); a future chunk type
  inherits it for free. The four gap-analysis sub-bullets become consequences of
  one change.
- `testEmptyContentDeltaEmitsNothing` updates: a role-only delta now emits the
  opener (CPA parity) rather than nothing. That test's intent ("no spurious
  *empty* chunks") is preserved — the opener is a *role* chunk, not an empty
  one.
- The role-opener synthesis adds a one-shot flag to the reparser; it must reset
  per stream (the reparser is already per-request, so this is a construction-time
  default).
- Pairs with ADR 0010 (error envelope): the mid-stream SSE error frame also
  flows through a builder and inherits the same contract discipline.
- Pairs with the Q9 decision (`include_usage` gating): the dedicated
  `buildUsageChunk` is the natural emission point for the gated usage chunk.
