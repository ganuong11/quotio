# Tier 1 buffer caps on request headers, request body, and SSE lines

## Context

The gap analysis (`docs/qoder-openai-proxy-gap-analysis.md`, P2 "Bound HTTP and
SSE buffering") flagged three unbounded accumulation points:

1. **Request header accumulation** — `ProxyBridge.receiveRequest`
   (`Quotio/Services/Proxy/ProxyBridge.swift:378-445`) appends to `accumulatedData`
   until `\r\n\r\n` is found, then until `Content-Length` is reached. No cap on
   either: a malicious or buggy client can stream an infinitely long header
   section or claim an arbitrarily large `Content-Length`.
2. **Request body accumulation** — same path; no `MAX_BODY_BYTES`. The whole
   accumulation is also converted to a Swift `String` (line 382) and the body
   sliced back out as `Data` (line 919), doubling memory for large bodies.
3. **SSE line accumulation** — `QoderSSEReparser.feed` does
   `buffer.append(chunk)` (`QoderSSEReparser.swift:153`); if upstream never emits
   a `\n`, a single SSE line grows unbounded.

These are the actual memory-exhaustion vectors. The gap analysis also names
deeper work (byte-wise header parsing, a real HTTP server abstraction, semantic
caps on message/image/tools counts) — that work is split out (#14, #15) and is
not in scope for this contract-faithfulness patch.

## Decision

Add **Tier 1 hot-path caps only**, shared by the Qoder and CPA paths (the caps
live in the shared `receiveRequest` parser and the reparser, so they apply
naturally to both):

- **`MAX_REQUEST_HEADER_BYTES`** — reject the request as `413` if the
  accumulated bytes reach this size before `\r\n\r\n` is found. Headers are
  never legitimately large.
- **`MAX_REQUEST_BODY_BYTES`** — reject as `413` if the body exceeds this size
  before `Content-Length` is satisfied. Sized to cover large multimodal / tool
  payloads with headroom.
- **`MAX_SSE_LINE_BYTES`** — terminate the stream with a structured mid-stream
  error (ADR 0010 envelope as an SSE frame) if a single SSE line exceeds this
  size. Bounds the reparser buffer against a misbehaving upstream.

Over-limit requests return `413` through the ADR 0010 JSON error envelope
(`{"error":{"message":"...","type":"invalid_request_error"}}`); an over-limit
SSE line returns a terminal mid-stream error frame (ADR 0010) rather than
silent truncation.

The body cap is **shared across Qoder and CPA paths**: a body-exhaustion attack
does not care which path it takes, and `receiveRequest` is the single seam both
flow through.

## Considered Options

- **Tier 1 + Tier 2 (semantic caps on message/image/tools) in this patch.**
  Rejected: Tier 2 is defense-in-depth on top of limits the upstream Qoder
  gateway already enforces, lives in the translator (more sites, more regression
  risk), and doubles the patch's surface area. Filed as #14.
- **Tier 1 + Tier 3 (byte-wise header parsing / real HTTP server abstraction).**
  Rejected: Tier 3 is a parser rewrite — exactly the scope creep the
  contract-faithfulness scoping decision ruled out. It is the only path to
  chunked request bodies, which deserves its own consideration. Filed as #15.
- **Qoder-only body cap.** Rejected: the cap lives in the shared parser, and a
  body-exhaustion attack does not care which path it takes. Applying it to both
  is simpler and more honest than gating on the routing branch.

## Consequences

- The three memory-exhaustion vectors are closed with localized, low-risk
  changes that fit the contract-faithfulness scope.
- The exact byte thresholds are tunable constants; conservative defaults are
  chosen so no legitimate CLI-agent request is rejected (large multimodal/tool
  payloads have headroom).
- The whole-request `String` copy (line 382) remains for now — a performance
  nit, not a correctness or DoS hole, tracked by #15.
- Pairs with ADR 0010 (error envelope): the 413 and the mid-stream SSE error
  both flow through the centralized builder.
- Pairs with ADR 0012 (cancellation): an oversized upstream SSE line, once
  detected, can also trigger `QoderGatewayStream.cancel()` to tear down the
  URLSession promptly.
