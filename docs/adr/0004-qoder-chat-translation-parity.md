# Qoder chat translation: full parity with pi-provider-qoder, OpenAI SSE re-encode

## Context

Under ADR 0001, Quotio translates Qoder's bespoke chat protocol inside
`ProxyBridge`. The pi-provider-qoder TypeScript extension (526-line `stream.ts`,
162-line `transform.ts`, 235-line `thinking-parser.ts`) is the reference
implementation of that translation. CLI agents consuming the proxy expect
OpenAI-shape SSE (`data: {"choices":[{"delta":{...}}]}`), not Qoder's envelope.

## Decision

Port the full Qoder↔OpenAI translation surface from pi-provider-qoder to Swift:

- **Message & tool transform** — OpenAI-shape messages/tools in, Qoder's
  bespoke request envelope (`request_id`, `session_id`, `chat_record_id`,
  `chat_task`, `session_type`, `agent_id`, `model_config`, `business`, etc.) out.
  System prompt is injected as a leading `role: "system"` message because
  Qoder's server ignores the top-level `system:` field.
- **WAF body encoding** — port `qoderEncodeBody` (base64 → rearrange →
  custom-alphabet substitution). Mandatory for the gateway.
- **COSY signing** — port `buildAuthHeaders` (RSA-encrypt AES key, AES-CBC
  user-info blob, MD5 over `payloadB64\nkey\ntimestamp\nbody\nsigPath`,
  ~15 `Cosy-*` headers).
- **SSE response parse** — Qoder's `envelope.body` JSON-in-JSON, with
  `reasoning_content` / `content` / `tool_calls` delta state machines.
- **Thinking-tag parser** — port the streaming `<think>`/`<thinking>`/
  `<reasoning>`/`<thought>` tag splitter (handles tag-split-across-delta).
- **OpenAI SSE re-encode** — emit `delta.content`, `delta.reasoning_content`
  (where supported), `delta.tool_calls`, `finish_reason`, and final `usage`.
  Pass Qoder's OpenAI-shape `usage` through unchanged (no cache-read
  subtraction — that was pi-ai's Anthropic-convention adaptation, irrelevant
  here).
- **Stable request hashing** — port `stableHash` and `stableChatRecordID`
  (sha256 over model + messages + tools + maxTokens) for prompt-cache affinity.

"Parity" means the Qoder↔OpenAI translation logic, **not** pi-ai's
`AssistantMessageEventStream` SDK contract — that intermediate event model is
skipped (one fewer layer).

## Considered Options

- **β Thin-slice MVP (text-only, fail-fast on tools/images).** Rejected: user
  chose full parity with eyes open after seeing the ~900-line scope.
- **γ Non-streaming.** Rejected: coding agents need token-by-token streaming.

## Consequences

- Phase 2's bulk is the ~900-line Swift port. Realistic estimate: weeks, not
  days. Tracer-bullet framing does not change the size — Phase 2 is now a
  substantial milestone, not a thin slice.
- Quotio now owns three pieces of upstream-protocol code it previously had none
  of: WAF encoder, COSY signer, SSE re-encoder. Each is a future drift surface.
- `thinking-parser.ts`'s cross-delta buffering and the tool-call index state
  machine are the two trickiest ports; they need their own test fixtures.
- Cache semantics are simpler than pi-provider-qoder's: pass Qoder's OpenAI-shape
  `usage` through verbatim. Do not subtract `cached_tokens` (that was an
  adaptation for pi-ai's Anthropic convention, which we do not have).
