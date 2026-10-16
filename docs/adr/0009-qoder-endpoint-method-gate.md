# Qoder branch is gated by method + path + model prefix, not model alone

## Context

ADR 0001 put COSY signing in `ProxyBridge`; ADR 0003 §1 made the Qoder routing
discriminator a body-`model:` prefix test (`qoder/...`). The discriminator was
intentionally minimal: a single prefix check, no method or path awareness. That
was correct while the Qoder path understood *only* Chat Completions and was the
sole native Qoder surface.

The gap analysis (`docs/qoder-openai-proxy-gap-analysis.md`, P1
"endpoint/method") flagged the consequence: a body carrying `model: "qoder/..."`
on `/v1/completions`, `/v1/responses`, `/v1/embeddings`, or any non-POST method
is still intercepted by the prefix test and then mishandled — the translator
and gateway client only know Chat Completions, so the request is rejected or
misinterpreted inside the Qoder path. Worse, falling such a request through to
CPA is unsafe: CPA does not know `qoder/` models (ADR 0003 keeps them out of
its registry), and a virtual-model / fallback rule could forward the unknown
model to an unrelated provider, producing genuinely wrong behavior rather than
a clean error.

## Decision

The Qoder branch is selected by an **allowlist** of the full request shape, not
the model prefix alone:

```
isQoderBound = model.hasPrefix("qoder/")
            && method == "POST"
            && path == "/v1/chat/completions"
```

A request whose body model is `qoder/...` but does **not** match the allowlist
is rejected with a Qoder-owned `404` OpenAI error envelope:

```json
{ "error": { "message": "Qoder models are only supported on POST /v1/chat/completions",
             "type": "invalid_request_error", "param": null, "code": null } }
```

It does **not** fall through to CPA. Rationale: CPA cannot correctly serve a
`qoder/` model and may misroute it via fallback; a Qoder-owned 404 is
unambiguous and matches how CPA itself rejects unknown routes.

## Considered Options

- **Body-prefix-only gate (status quo).** Rejected: intercepts `qoder/` on
  every endpoint/method, then mishandles it inside a chat-only translator.
  This is the bug the gap analysis identifies.
- **Body-prefix gate + non-chat fall-through to CPA.** Rejected: CPA doesn't
  know `qoder/` models (ADR 0003), and fallback rules can forward the unknown
  model to an unrelated provider. Falling through reintroduces the
  misinterpretation risk; rejecting closes it.
- **Reject with 400 instead of 404.** Considered. 400 fits "malformed request";
  404 fits "unknown route for this model." Chose 404 because from the client's
  perspective the combination `qoder/ + /v1/completions` is an unknown *route*,
  matching CPA's own convention for unknown endpoints. Easily flipped later if
  client telemetry shows confusion.

## Consequences

- The Qoder path now owns a small rejection surface for every endpoint/method
  it does not support. The unsupported list must stay honest: as #10
  (`/v1/models` merge) and #11 (`/v1/responses` adapter) land, the allowlist
  gains entries (`|| path == "/v1/responses"`, etc.) pointing at their own
  handlers, not at `QoderChatTranslator`.
- `GET /v1/models` with no body (and therefore no model prefix) is unaffected —
  it never matched `isQoderBound` and continues to CPA. #10 will intercept it
  separately at the path level, independent of this gate.
- A route-matrix test (method × path × body-model × content-type) is the
  natural acceptance test and closes a gap-analysis testing gap.
- This refines ADR 0003 §1's discriminator without contradicting it: the prefix
  test remains, but is now one of three conjuncts rather than the sole
  condition.
