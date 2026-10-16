import Foundation

public nonisolated enum QoderGatewayError: Error {
    case network(String)
    case nonHTTPResponse

    public var errorDescription: String? {
        switch self {
        case .network(let detail):
            return "Qoder gateway transport error: \(detail)"
        case .nonHTTPResponse:
            return "Qoder gateway returned a non-HTTP response"
        }
    }
}

/// Per-chunk callback handed to a stream `pump`. Receives one raw upstream
/// buffer; returns false to stop the pump early (e.g. agent disconnect). Named
/// so the nested `@Sendable` closure type is spelled once and reads clearly at
/// every call site (gateway stream, opened stream, ProxyBridge pump driver).
public typealias QoderChunkReceiver = @Sendable (Data) async throws -> Bool

/// A handle the gateway client hands back on a 2xx response. The router peeks
/// the leading bytes via `nextChunk` to detect a quota-exhaustion (or auth)
/// signal that the gateway carries *inside* the SSE stream despite an HTTP 200
/// status — before deciding to hand the stream off. Once the router confirms
/// the first chunk is clean, it returns the stream to ProxyBridge, which drives
/// the remainder via `pump` through `QoderSSEReparser` into the agent socket.
///
/// Both `nextChunk` and `pump` draw from the **same** underlying byte source so
/// bytes the peek consumed are not replayed to ProxyBridge (the router hands
/// the consumed prefix alongside the stream — see `QoderOpenedStream`). The
/// source is a single-owner pull closure (`source`) that yields the next buffer
/// on each call, so there is exactly one iterator in flight per stream
/// regardless of how many times `nextChunk` / `pump` are called.
///
/// Cancellation (ADR 0012): the stream owns the upstream upstream byte task's
/// lifetime while a reader is attached. `cancel()` tears that task down so an
/// agent disconnect (or any other cooperative cancellation of the pump Task)
/// does not leave the stream source pulling bytes nobody is consuming — which
/// would waste Qoder quota until the iterator is GC'd. The pump loop checks
/// `Task.checkCancellation()` each iteration so cancelling the pump Task throws
/// promptly out of the awaiting `source()` pull, and `pump` calls `cancel()`
/// on every exit path (normal completion, early-stop, error, cancellation).
public nonisolated final class QoderGatewayStream: @unchecked Sendable {
    public let response: HTTPURLResponse

    /// Pull the next buffer from the upstream byte stream. Returns `nil` at
    /// stream end. Throws on transport failure. Single-owner: each call
    /// advances the same underlying iterator, so a peek via `nextChunk`
    /// consumes bytes the subsequent `pump` will not see again.
    private let source: @Sendable () async throws -> Data?

    /// Tears down the upstream upstream task. nil for test streams that have
    /// no real task to cancel (the production client always sets it). Guarded
    /// by `cancelLock` so concurrent `cancel()` calls (e.g. pump-exit + an
    /// explicit disconnect-driven cancel racing) are safe; the closure itself
    /// is idempotent in production (task.cancel() on a byte task is a no-op on an
    /// already-completed task) but the lock keeps the boolean state coherent.
    private let onCancel: @Sendable () -> Void
    private let cancelLock = NSLock()
    private var cancelled: Bool = false

    public init(
        response: HTTPURLResponse,
        onCancel: @escaping @Sendable () -> Void = {},
        source: @escaping @Sendable () async throws -> Data?
    ) {
        self.response = response
        self.onCancel = onCancel
        self.source = source
    }

    /// Convenience keeping `source` as the trailing closure at call sites that
    /// don't supply `onCancel` (test mocks). Mirrors the pre-ADR-0012 signature
    /// `init(response:source:)` so existing `QoderGatewayStream(response:) { ... }`
    /// constructions compile unchanged.
    public convenience init(
        response: HTTPURLResponse,
        source: @escaping @Sendable () async throws -> Data?
    ) {
        self.init(response: response, onCancel: {}, source: source)
    }

    /// Pull the next buffer for the router's pre-handoff peek. Returns the next
    /// chunk, or nil at stream end.
    public nonisolated func nextChunk() async throws -> Data? {
        try await source()
    }

    /// Push-drive the remaining stream. `onChunk` is called with each raw byte
    /// buffer the gateway yields; return false to stop early (e.g. agent
    /// disconnect). Throws on transport failure. Thin adapter over `source` —
    /// one iterator, shared with any prior `nextChunk` peek.
    ///
    /// Cancellation (ADR 0012): checks `Task.checkCancellation()` at the top of
    /// each iteration so cancelling the surrounding pump Task throws promptly
    /// out of the next `source()` pull (rather than waiting for the pull to
    /// resolve on its own). On every exit path — normal end, early-stop
    /// (`onChunk` returned false), thrown error, or cancellation — `cancel()`
    /// is called to tear down the upstream upstream task so its byte stream
    /// does not outlive the reader.
    public nonisolated func pump(_ onChunk: QoderChunkReceiver) async throws {
        defer { cancel() }
        while true {
            // Surface cooperative cancellation before pulling the next buffer:
            // without this the pump can block inside `source()` (a slow
            // upstream) for a long time after the agent has disconnected.
            try Task.checkCancellation()
            guard let buffer = try await source() else { return }
            if try await onChunk(buffer) == false { return }
        }
    }

    /// Tear down the upstream task (ADR 0012). Idempotent: safe to
    /// call from `pump`'s defer and again from a disconnect path. The
    /// production `onCancel` cancels the upstream byte task backing
    /// `AsyncBytes`-style source; a test stream passes a no-op or a spy.
    public nonisolated func cancel() {
        cancelLock.lock()
        defer { cancelLock.unlock() }
        guard !cancelled else { return }
        cancelled = true
        onCancel()
    }
}

/// Abstracted gateway access so `QoderFailoverRouter` tests can inject a mock
