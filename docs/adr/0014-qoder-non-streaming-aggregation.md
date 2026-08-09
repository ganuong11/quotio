# Non-streaming Chat Completions: aggregate SSE upstream into one JSON

## Status

Accepted — 2026-08-09. Closes issue #9 (deferred from the contract-faithfulness
patch, `docs/qoder-openai-proxy-gap-analysis.md` P1/P2). Reverses the prior
"reject `stream: false`" behavior and corrects the missing-`stream` default.

## Context

The OpenAI Chat Completions schema defines `stream` with a default of `false`
([official spec](https://github.com/openai/openai-openai/blob/c309ca176bc22c6075a0c2c2543f2ac4f307c447/openapi.yaml#L32968-L32977)).
CLIProxyAPI streams only when `stream` is explicitly `true` and otherwise uses
its non-stream handler
([`openai_handlers.go`](https://github.com/router-for-me/CLIProxyAPI/blob/197f520426374e514218ed155933ac546c98d345/sdk/api/handlers/openai/openai_handlers.go#L103-L132)).

Quotio's Qoder path had two bugs at this seam:

1. **Explicit `stream: false` was rejected** with `requestRejected` → HTTP 400
   (`QoderFailoverRouter.swift` gate, now removed).
2. **A *missing* `stream` field was treated as streaming.** The comment claiming
   this matched OpenAI's default was the *opposite* of the spec — OpenAI's
   default is `false`. So the most common OpenAI client shape (no `stream`
   field) was being force-streamed through a path it didn't ask for.

The Qoder gateway itself only speaks SSE (`QoderChatTranslator` hardcodes
`"stream": true` in the upstream envelope), so Quotio cannot simply forward a
non-streaming request as non-streaming upstream.

## Decision

**Keep consuming the SSE upstream; aggregate locally.** For any
`stream != true` request (missing `stream` **or** explicit `false`), Quotio:

1. Opens the gateway stream exactly as the streaming path does (failover, peek,
   rotation policy — all unchanged).
2. Pumps the upstream bytes through the existing `QoderSSEReparser` (the single
   parser of the Qoder envelope — no parallel state machine, per issue #9
   acceptance).
3. Feeds the reparser's OpenAI-shape SSE chunks into a new
   `QoderCompletionAggregator` (pure value type, sibling to the reparser),
   which folds `delta.content`, `delta.tool_calls`, `finish_reason`, and
   `usage` into one `chat.completion` object.
4. Writes the response with `Content-Type: application/json` and an exact
   `Content-Length` *after* aggregation completes (no chunked/trickled body).
5. Branches in `ProxyBridge.forwardQoderRequest` on `opened.streamRequested`,
   a new field on `QoderOpenedStream` carrying the client's intent.

The streaming path is unchanged.

### Why this shape

- **Single parser of the envelope.** The reparser already owns Qoder envelope
  parsing, the upstream-status gate, tool-call repair, and usage capture. The
  aggregator consumes its *output* (`data: {...}\n\n` OpenAI chunks), so there
  is exactly one parser of Qoder's wire format and one definition of "what a
  tool call / usage / finish_reason looks like." A second *Qoder* parser would
  drift.
- **Default-correct.** `streamRequested(in:)` returns true only when
  `stream == true`; missing and `false` both yield `false`. This matches
  OpenAI, not the prior inverted default.
- **Failover unchanged.** Because the upstream stream is identical for both
  modes, the pre-handoff quota/auth peek and the rotation policy apply
  identically. A non-streaming request on an exhausted account still rotates
  cleanly before any byte reaches the agent.

### Known tradeoff — separate accumulator (follow-up #25)

Issue #9's acceptance criteria asked the aggregated response to *"reuse the
same accumulated tool-call state and usage data that the streaming path
already builds — no separate state machine."* The shipped aggregator consumes
the reparser's *output*, which keeps one parser of the Qoder envelope — but it
re-accumulates tool-call `id/type/name/arguments`, `usage`, `id/model/created`,
and `finish_reason` in its own state, rather than reading them off the
reparser. The reparser **already accumulates** most of this (its
`QoderToolCallState.arguments` field comment even says it was retained for
"diagnostic/state-completeness"); it just doesn't expose it, and doesn't
retain concatenated `content`/`reasoning_content`. Consolidating accumulation
onto the reparser is filed as **#25** — it removes the duplicate state machine
without changing wire behavior. This tradeoff is accepted for the initial
ship because the aggregator's output is correct and unit-tested, and the
non-streaming path is net-new (no regression risk).

### Mid-stream failure advantage

A non-streaming response writes its HTTP head only *after* aggregation
completes. So a mid-stream reparser gate or transport drop can still surface as
a **true HTTP error** (today 502 via the existing error path; ADR 0010 will
make it a structured JSON envelope). The streaming path cannot do this — once
the 200 SSE head is written, a mid-stream failure can only truncate. This is a
strict improvement in error fidelity for non-streaming clients.

## Considered Options

- **Reject `stream != true` with a precise 400 (the issue's "minimum
  compatible" fallback).** Rejected: aggregation is the issue's preferred fix,
  and the aggregator is a small, well-tested pure type. Returning 400 for the
  spec's own default would keep Quotio non-conformant.
- **Change the upstream envelope to `"stream": false`.** Rejected: Qoder's
  gateway returns SSE regardless, and we have no evidence a non-streaming
  upstream mode exists or is stable. Keeping the upstream SSE-only means one
  proven upstream path.
- **Build a parallel Qoder→completion parser.** Rejected: drifts from the
  reparser, doubles the surface area, and violates issue #9's "no separate
  state machine" acceptance. The aggregator consumes reparser output.
- **Surface `reasoning_content` on the non-streaming `message`.** Rejected for
  now: the OpenAI non-streaming `message` schema has no standard field for it.
  The aggregator still *ingests* reasoning deltas (so mixed streams parse
  cleanly) but omits them from the output. Revisit if a real non-streaming
  client needs reasoning — gap tracked here, not in a separate issue.

## Consequences

- **Behavior change for clients relying on the old broken default.** A request
  with no `stream` field now gets a JSON `chat.completion` instead of an SSE
  stream. This is the fix issue #9 exists to make; the prior behavior was
  spec-nonconformant.
- **`finish_reason` defaults to `"stop"`** when the upstream truncated before a
  finish frame — a safe fallback rather than omitting the required field.
- **Tool calls** are emitted in ascending `index` order regardless of arrival
  order, for a stable surface.
- **`reasoning_content` is dropped** from the non-streaming response (see
  Options). Streaming behavior is unchanged.
- **Pairs with ADR 0010 (error envelope):** once centralized, the 502 on
  mid-stream failure becomes a structured JSON error.
- **Out of scope, still tracked:** `/v1/models` merge (#10, reverses ADR
  0003 §3), Responses API adapter (#11), dynamic registry (#24).
