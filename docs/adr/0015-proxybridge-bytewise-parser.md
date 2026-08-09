# Byte-wise HTTP/1.1 request parser in ProxyBridge (no whole-request String)

## Status

Accepted — 2026-08-09. Closes issue #15 (the parser-rewrite half of the
contract-faithfulness gap analysis, `docs/qoder-openai-proxy-gap-analysis.md`
P3). Replaces the hand-written `String`-based scan in
`ProxyBridge.receiveRequest` (`Quotio/Services/Proxy/ProxyBridge.swift`).

## Context

`ProxyBridge.receiveRequest` accumulated request bytes into a `Data`, then on
every `NWConnection.receive` callback converted the *entire* accumulation to a
Swift `String` to search for the `\r\n\r\n` header terminator. Once the body
was framed, the Qoder branch sliced the body back out of the same `String`
into `Data` (the `Data(body.utf8)` at the old ~line 919). Three problems:

1. **Memory doubling on the hot path.** For a large multimodal/tool request the
   whole body lives twice — once as bytes, once as a String — on every receive
   callback, plus a UTF-8 decode pass per callback.
2. **No `Transfer-Encoding: chunked` support.** Only `Content-Length` framed
   the body. A chunked request body (legitimate from some HTTP clients and
   every manually-crafted `curl -T`) was either misframed or stalled until
   `isComplete`.
3. **ADR 0013 Tier 1 caps not actually enforced on the receive path.** The
   header-section and body caps from ADR 0013 were documented but not yet
   wired into `receiveRequest`; the whole-request String conversion was the
   unbounded accumulation vector ADR 0013 §Consequences explicitly flagged as
   the #15 follow-up.

## Decision

**Byte-wise parsing now; defer the real HTTP server abstraction.** Extract a
pure value type, `HTTP1RequestParser`, that scans the `Data` buffer directly
for the header boundary (no whole-buffer String decode), decodes *only* the
header section to `String` after the boundary is found, and frames the body by
either `Content-Length` or `Transfer-Encoding: chunked` (chunked wins per RFC
9112 §6.1). Wire `receiveRequest` to feed bytes to the parser incrementally
and act on its `ParseProgress` (`needsMoreData` / `.complete` / `.error`).

This is the issue's third "considered approach" (incremental byte-wise first,
server abstraction deferred). It is the lowest-risk path: it fixes the three
problems above without introducing a runtime dependency or rewriting the
Network.framework connection plumbing that ProxyBridge already owns.

### Why not a real HTTP server abstraction (Hummingbird / Vapor) now

- The long-term option remains open. ADR 0001 already routes Qoder traffic
  through a Quotio-native translator inside ProxyBridge; replacing the
  NWListener with a Hummingbird/Vapor server is a larger, behavior-changing
  rewrite that would also touch the SSE streaming path (ADR 0011) and the
  mid-stream cancellation wiring (ADR 0012). That belongs in its own issue,
  not bundled into a parser fix.
- A byte-wise parser is the minimum change that closes the memory-doubling
  and chunked-support gaps while leaving every other invariant (target host,
  CPA pass-through byte-for-byte, response SSE streaming) untouched.

### Parser API shape (contract)

`HTTP1RequestParser` is a `nonisolated struct` (Sendable value type, mirroring
`QoderSSEReparser` / `QoderCompletionAggregator`). It owns:

- The accumulated `Data` (bytes received so far).
- A small state machine: `.readingHeader` → `.readingBody` (Content-Length or
  chunked) → done, or `.failed`.
- `mutating func feed(_ chunk: Data) -> ParseProgress` — append bytes, attempt
  to advance, return `.needsMoreData`, `.complete(HTTP1Request)`, or
  `.error(String)`.
- An immutable `HTTP1Request` value: `method`, `path`, `version`, ordered
  case-insensitive `headers`, and `body: Data` (raw body bytes, byte-exact;
  for chunked input this is the *decoded* body — chunk framing stripped).

### Body framing

- **`Content-Length`** — frame exactly N body bytes after the header boundary
  (existing behavior, preserved byte-for-byte for the CPA path).
- **`Transfer-Encoding: chunked`** — RFC 9112 §7.1 framing: chunk-size line
  (hex, optional `;` extensions discarded), CRLF, chunk-data, terminating
  `0\r\n\r\n`. Trailer header fields after the final chunk are accepted but
  discarded (the CPA pass-through reconstructs its own headers; trailers are
  not forwarded). The decoded chunk bodies become the request `body: Data`.
- **Both present** — chunked wins (RFC 9112 §6.3 / RFC 9110 §8.6: a sender
  MUST NOT send `Content-Length` alongside chunked; when they coexist,
  `Content-Length` is ignored). The parser discards the `Content-Length`
  value in that case. Disagreeing `Content-Length` values (multiple CL headers
  or a comma-list with differing integers) are rejected as 400 per RFC 9110
  §8.6.

### Interaction with ADR 0013 buffer caps

This parser is where ADR 0013's Tier 1 receive-path caps finally land:

- **`maxHeaderBytes`** — if the header section grows past this without a
  `\r\n\r\n` boundary, the parser returns `.error`, and `receiveRequest`
  surfaces HTTP 413 through the ADR 0010 envelope. The same bound is applied
  to chunked size lines and trailer field lines (a chunk-size line is never
  legitimately larger than a few bytes; an unterminated size line or trailer
  would otherwise grow the accumulation unbounded — the body cap only fires
  once a chunk size parses).
- **`maxBodyBytes`** — applies to both framing modes equally: a Content-Length
  body or an accumulated chunked body past this cap is `.error` → 413. This is
  the whole point of putting the cap on the parser rather than downstream: the
  body-exhaustion vector does not care which framing the client chose.
- The Qoder and CPA paths share the cap (both flow through `receiveRequest`),
  as ADR 0013 §Decision requires.

Concrete defaults: `maxHeaderBytes = 64 KiB` (65536), `maxBodyBytes = 64 MiB`
(67 108 864). Both are injectable via `HTTP1RequestParser(maxHeaderBytes:
maxBodyBytes:)` for tests. Sized with generous headroom over any plausible
CLI-agent request (large multimodal / tool payloads fit comfortably).

### CPA pass-through preservation

The CLIProxyAPI forwarding path (`forwardRequest`) reconstructs the upstream
request by joining `method`/`path`/`version`, filtering a small header
exclusion set, and writing `Content-Length: <body.count>` plus the body bytes.
Behavior is unchanged: the parser produces the same `(method, path, version,
headers, body)` the old code did, and `forwardRequest` keeps overriding
`Connection: close` and recomputing `Content-Length`. The only observable
difference is that chunked input now arrives as a decoded body with the right
Content-Length — which is the fix, not a regression.

## Considered Options

- **Real HTTP server abstraction (Hummingbird / Vapor) now.** Rejected for
  this issue: larger rewrite, touches SSE streaming and cancellation wiring,
  introduces a runtime dependency. Tracked as the long-term option; not filed
  as a separate issue yet because no current requirement forces it.
- **Both — incremental byte-wise now, swap the server abstraction in later.**
  This is what we are doing: the byte-wise parser is a strict improvement on
  its own and leaves the door open. A future server abstraction can replace
  the NWListener plumbing and still consume or supersede this parser.
- **Keep the String scan, just add chunked support.** Rejected: leaves the
  memory-doubling hot-path intact and the ADR 0013 receive-path caps
  unenforceable. The String conversion was the explicit #15 follow-up in ADR
  0013 §Consequences.

## Consequences

- The whole-request `String` conversion on the receive hot path is gone.
  Only the header section (bounded by `maxHeaderBytes`) is decoded to String,
  and only once (after the boundary is found).
- Chunked request bodies (`Transfer-Encoding: chunked`) are supported for the
  first time, on both Qoder and CPA paths.
- ADR 0013 Tier 1 receive-path caps (`maxHeaderBytes`, `maxBodyBytes`) are
  enforced at the parser, the single seam both routing branches flow through.
- `HTTP1RequestParser` is pure and unit-testable (no NWConnection in tests),
  matching the testing posture of `QoderSSEReparser` /
  `QoderCompletionAggregator`. New `HTTP1RequestParserTests` covers Content-
  Length, chunked (multi-chunk, with extensions, empty body), chunked +
  Content-Length precedence, partial feeds, malformed chunk sizes, header-cap
  exceeded, case-insensitive header lookup, and non-UTF8 body byte-preservation.
- The CPA pass-through semantics are byte-identical for non-chunked input;
  chunked input now reaches CPA as a decoded Content-Length body.
- Response-side behavior (SSE streaming, reparser, aggregator) is untouched —
  this issue is request-side only.
- The long-term option of a real HTTP server abstraction remains open and is
  not blocked by this parser.
