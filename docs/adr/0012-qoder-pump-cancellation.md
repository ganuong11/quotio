# The Qoder pump Task is stored and cancelled promptly on agent disconnect

## Context

The Qoder pump (`ProxyBridge.forwardQoderRequest`) moves bytes from the upstream
Qoder gateway SSE stream to the agent `NWConnection` via the reparser. It runs
in an unstructured `Task` so the `for await` over the upstream byte stream does
not block the MainActor.

The gap analysis (`docs/qoder-openai-proxy-gap-analysis.md`, P2 "Propagate
client cancellation explicitly") flagged that the pump Task had no stored handle
and that agent-disconnect cancellation was indirect: the pump stopped only when
a future `sendToAgent` failed, not promptly on disconnect.

On re-verification (this branch, HEAD `8349494`), the gap is confirmed and the
in-file comment had become self-contradictory: the doc-comment at
`ProxyBridge.swift:889-891` claims "the pump Task is captured and cancelled from
the agent connection's stateUpdateHandler," but the inline comment at
`ProxyBridge.swift:921-929` says "No explicit stateUpdateHandler wiring needed
here," and the code matches neither — line 930's `Task { ... }` handle is not
stored anywhere, and the `stateUpdateHandler` at line 330-341 only decrements
`activeConnections`.

The consequence: when a CLI agent disconnects mid-stream, the upstream Qoder
URLSession keeps running until the next `sendToAgent` happens to fail. On a slow
upstream that can be many seconds of wasted Qoder quota. Relying on the async
iterator to observe cancellation is fragile because of SE-0304 (post-return
child-task errors are not rethrown) — also the basis on which the related
"chunker" GAP #1b was disproven (see project memory).

## Decision

Store the pump `Task` handle and cancel it promptly on agent disconnect.

1. **`ProxyBridge` holds a `MainActor`-isolated `[Int: Task<Void, Never>]` keyed
   by `connectionId`** (`pumpTasks`). The handle is stored immediately after the
   Task is created, before its `for await` begins, and removed in the Task's
   cleanup path (defer / on-completion).
2. **The agent connection's `stateUpdateHandler` cancels the pump Task on
   `.cancelled` / `.failed`.** The existing handler already runs on these states
   for the `activeConnections` counter; the cancel call is folded in there
   (NWConnection allows only one `stateUpdateHandler`, already set in
   `handleNewConnection`).
3. **`QoderGatewayStream` exposes an explicit `cancel()`** that cancels its
   underlying URLSession task. The pump's `for await` checks
   `Task.checkCancellation()` so cooperative cancellation propagates to the byte
   source, and the URLSession is torn down rather than relying on iterator
   abandonment.
4. **The misleading comments are corrected** to describe the actual mechanism.

This mirrors how CPA ties execution to the HTTP request context and cancels when
the client disconnects.

## Considered Options

- **Keep the pump unstructured; add `Task.yield()` + `Task.checkCancellation()`
  polling; cancel the URLSession reactively on send failure.** Rejected: only
  cancels on the *next* loop iteration after a failed send, not promptly on
  disconnect — the exact gap. And SE-0304 makes relying on the iterator to
  observe post-return cancellation fragile.
- **Wire `stateUpdateHandler` to call a per-connection closure that cancels the
  URLSession directly, bypassing the pump Task.** Rejected: NWConnection allows
  only one `stateUpdateHandler`, already used for the active-connections counter,
  so this conflates connection-accounting with stream-lifecycle. More invasive
  than storing the Task handle, and loses the natural structured-concurrency
  shape.

## Consequences

- Agent disconnect now promptly tears down the upstream Qoder stream, closing
  the wasted-quota window. This is the load-bearing user-facing fix.
- `pumpTasks` is a new piece of mutable MainActor state on `ProxyBridge`; it
  must be kept consistent (insert on start, remove on every exit path including
  error/cancel). The reparser is per-request and unaffected.
- `QoderGatewayStream.cancel()` becomes a seam the buffer-bounds work can also
  rely on to terminate an oversized upstream.
- The corrected comment removes the trap that let the divergence between comment
  and code persist.
