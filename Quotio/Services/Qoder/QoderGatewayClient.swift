//
//  QoderGatewayClient.swift
//  Quotio
//
//  Phase 2a (ADR 0001): thin URLSession wrapper that ships a WAF-encoded,
//  COSY-signed request body to Qoder's chat/models gateway
//  (`api3.qoder.sh/algo/...`) and returns the streaming response. The
//  `QoderFailoverRouter` (ticket #7) calls this per candidate account; the
//  router owns rotation/cooldown, this owns the wire.
//
//  One method: `openStream`. WAF-encodes the translator envelope, COSY-signs
//  the encoded body, POSTs to the fixed gateway URL with
//  `Accept-Encoding: identity` (ADR 0007 §4 — the WAF encoder breaks under
//  transport compression), and returns the HTTP response plus the byte stream
//  for the caller to pump through `QoderSSEReparser`.
//
//  Protocol-fronted so the router's rotation policy is unit-testable with a
//  mock client returning canned `(status, body)` per call (no real network).
//  The concrete `QoderGatewayClient` is the only production implementation.
//

import Foundation

/// The chat/models gateway endpoint. Hardcoded — `?Encode=1` opts into the
/// WAF body encoding (`qoderEncodeBody`), which `QoderWAFEncoder` produces and
/// the gateway reverses. ADR 0001.
nonisolated let qoderChatGatewayURL = URL(
    string: "https://api3.qoder.sh/algo/api/v2/service/pro/sse/agent_chat_generation?Encode=1"
)!

/// Errors from the gateway client. Transport failures surface as `.network`
/// (the router retries same-account on these per ADR 0006 §2). A non-2xx HTTP
/// status is NOT an error here — the router reads the status from the returned
/// `HTTPURLResponse` and applies the rotation policy itself, because the policy
/// (429 → rotate, 401 → re-exchange, 5xx → retry) is the router's job, not the
/// client's.
nonisolated enum QoderGatewayError: Error, LocalizedError {
    case network(String)
    case nonHTTPResponse

    var errorDescription: String? {
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
typealias QoderChunkReceiver = @Sendable (Data) async throws -> Bool

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
/// Cancellation (ADR 0012): the stream owns the upstream URLSession data task's
/// lifetime while a reader is attached. `cancel()` tears that task down so an
/// agent disconnect (or any other cooperative cancellation of the pump Task)
/// does not leave the URLSession pulling bytes nobody is consuming — which
/// would waste Qoder quota until the iterator is GC'd. The pump loop checks
/// `Task.checkCancellation()` each iteration so cancelling the pump Task throws
/// promptly out of the awaiting `source()` pull, and `pump` calls `cancel()`
/// on every exit path (normal completion, early-stop, error, cancellation).
nonisolated final class QoderGatewayStream: @unchecked Sendable {
    let response: HTTPURLResponse

    /// Pull the next buffer from the upstream byte stream. Returns `nil` at
    /// stream end. Throws on transport failure. Single-owner: each call
    /// advances the same underlying iterator, so a peek via `nextChunk`
    /// consumes bytes the subsequent `pump` will not see again.
    private let source: @Sendable () async throws -> Data?

    /// Tears down the upstream URLSession task. nil for test streams that have
    /// no real task to cancel (the production client always sets it). Guarded
    /// by `cancelLock` so concurrent `cancel()` calls (e.g. pump-exit + an
    /// explicit disconnect-driven cancel racing) are safe; the closure itself
    /// is idempotent in production (URLSessionTask.cancel() is a no-op on an
    /// already-completed task) but the lock keeps the boolean state coherent.
    private let onCancel: @Sendable () -> Void
    private let cancelLock = NSLock()
    private var cancelled: Bool = false

    init(
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
    convenience init(
        response: HTTPURLResponse,
        source: @escaping @Sendable () async throws -> Data?
    ) {
        self.init(response: response, onCancel: {}, source: source)
    }

    /// Pull the next buffer for the router's pre-handoff peek. Returns the next
    /// chunk, or nil at stream end.
    nonisolated func nextChunk() async throws -> Data? {
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
    /// is called to tear down the upstream URLSession task so its byte stream
    /// does not outlive the reader.
    nonisolated func pump(_ onChunk: QoderChunkReceiver) async throws {
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

    /// Tear down the upstream URLSession task (ADR 0012). Idempotent: safe to
    /// call from `pump`'s defer and again from a disconnect path. The
    /// production `onCancel` cancels the URLSession data task backing
    /// `URLSession.AsyncBytes`; a test stream passes a no-op or a spy.
    nonisolated func cancel() {
        cancelLock.lock()
        defer { cancelLock.unlock() }
        guard !cancelled else { return }
        cancelled = true
        onCancel()
    }
}

/// Abstracted gateway access so `QoderFailoverRouter` tests can inject a mock
/// returning canned statuses without touching the network. `Sendable` so the
/// router (an actor) can hold it across isolation boundaries.
nonisolated protocol QoderGatewayClientProtocol: Sendable {
    func openStream(
        body: Data,
        credentials: QoderCOSYCredentials,
        signerOptions: QoderCOSYSignerOptions
    ) async throws -> QoderGatewayStream
}

/// Convenience defaulting `signerOptions` to `.deferringToRandom`. Protocol
/// methods can't carry default arguments, so the default lives in this
/// extension; call sites that go through the protocol type should pass the
/// argument explicitly (the router does).
extension QoderGatewayClientProtocol {
    func openStream(
        body: Data,
        credentials: QoderCOSYCredentials
    ) async throws -> QoderGatewayStream {
        try await openStream(body: body, credentials: credentials, signerOptions: .deferringToRandom)
    }
}

/// Production gateway client. Owns a `URLSession` configured through
/// `ProxyConfigurationService` (mirrors `QoderPATService` / `QoderQuotaFetcher`
/// — respects the user's upstream proxy setting).
final class QoderGatewayClient: QoderGatewayClientProtocol, @unchecked Sendable {
    private let session: URLSession
    private let url: URL

    init(
        url: URL = qoderChatGatewayURL,
        sessionConfiguration: URLSessionConfiguration? = nil
    ) {
        if let sessionConfiguration {
            self.session = URLSession(configuration: sessionConfiguration)
        } else {
            // `timeoutIntervalForRequest` governs inactivity, not total stream
            // length — a 600s idle ceiling lets long chats breathe while still
            // catching a wedged gateway. Mirrors the proxy-config reuse pattern
            // in `QoderPATService` / `QoderQuotaFetcher`.
            self.session = URLSession(
                configuration: ProxyConfigurationService.createProxiedConfigurationStatic(timeout: 600)
            )
        }
        self.url = url
    }

    func openStream(
        body: Data,
        credentials: QoderCOSYCredentials,
        signerOptions: QoderCOSYSignerOptions = .deferringToRandom
    ) async throws -> QoderGatewayStream {
        // WAF-encode the translator envelope, then COSY-sign the encoded bytes.
        // Signature order is load-bearing: the signer hashes the WAF-encoded
        // body, so encode first, sign second.
        let encodedBody = QoderWAFEncoder.encode(body)
        let headers: QoderCOSYHeaders
        do {
            headers = try QoderCOSYSigner.sign(
                body: encodedBody,
                requestURL: url.absoluteString,
                credentials: credentials,
                options: signerOptions
            )
        } catch {
            // Signer errors (empty userID/authToken, crypto failures) propagate
            // as network-class errors so the router does NOT retry them — a
            // signing failure is deterministic and retrying won't help.
            throw QoderGatewayError.network(error.localizedDescription)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        // ADR 0007 §4: `Accept-Encoding: identity` is mandatory — the WAF
        // encoder's `=` → `$` substitution breaks under gzip/deflate transport
        // compression. The gateway honors this and sends the body uncompressed.
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Apply the COSY signature envelope (`Authorization` + every Cosy-*/Login-*
        // header). `allHeaders` is `[String: String]`; URLRequest dedupes case.
        for (name, value) in headers.allHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.httpBody = Data(encodedBody.utf8)

        let response: URLResponse
        let rawBytes: URLSession.AsyncBytes
        do {
            // `URLSession.bytes(for:)` returns `(bytes, response)` — note the
            // order is reversed from the type tuple below.
            (rawBytes, response) = try await session.bytes(for: request)
        } catch {
            throw QoderGatewayError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw QoderGatewayError.nonHTTPResponse
        }
        // Capture the byte stream behind a single-owner pull source. The
        // iterator and the chunker's first-pull flag live inside a Sendable box
        // (`AsyncBytesSource`) so the pull closure can mutate them across
        // `@Sendable` boundaries without the compiler's "mutation of captured
        // var in concurrently-executing code" error; single-owner is guaranteed
        // because only this closure holds the box and pull calls are serialized
        // by the router/ProxyBridge handoff contract (peek completes before
        // pump begins). The router pulls the first buffer via `nextChunk` to
        // peek for an in-envelope quota signal; ProxyBridge drives the remainder
        // via `pump`. Both go through this one closure, so bytes the peek
        // consumed are not replayed.
        //
        // The first pull flushes at the first complete SSE frame (see
        // `QoderGatewayChunker`); later pulls flush at ~8KB so the reparser sees
        // reasonable frame sizes rather than one byte per await (AsyncBytes
        // iterates byte-by-byte). This decouples the router's 2s peek timeout
        // from the bulk threshold — without it the peek would measure
        // time-to-8KB and false-rotate healthy slow-first-byte requests.
        let source = AsyncBytesSource(rawBytes)
        // ADR 0012: capture the underlying URLSession data task so the stream's
        // `cancel()` can tear it down when the pump ends or is cancelled
        // (agent disconnect). `URLSession.AsyncBytes.task` is the handle backing
        // the byte iterator; cancelling it resolves any in-flight `next()` pull
        // and closes the upstream socket promptly rather than letting the
        // URLSession keep pulling bytes nobody will read. Wrapped in a Sendable
        // box because the `onCancel` closure is `@Sendable` and `URLSessionTask`
        // is not `Sendable`-guaranteed across all SDKs.
        let taskRef = URLSessionTaskBox(rawBytes.task)
        return QoderGatewayStream(
            response: http,
            onCancel: { taskRef.cancel() },
            source: { () -> Data? in try await source.nextChunk() }
        )
    }
}

/// Single-owner Sendable box holding a `URLSession.AsyncBytes` iterator plus the
/// `QoderGatewayChunker`'s first-pull flag. The production `QoderGatewayClient`
/// creates one per stream and confines all pulls to the `nextChunk` closure.
/// `nonisolated` so the pull source (called from the router's actor and
/// ProxyBridge's Task) isn't forced onto the MainActor. `@unchecked Sendable`
/// because the iterator isn't Sendable, but access is serialized by the
/// stream's single-owner contract (peek completes before pump begins).
private nonisolated final class AsyncBytesSource: @unchecked Sendable {
    private let iteratorBox: AsyncBytesBox
    /// Chunker first-pull flag. `true` until the first `nextChunk` call returns.
    private var firstPull = true

    init(_ bytes: URLSession.AsyncBytes) {
        self.iteratorBox = AsyncBytesBox(bytes)
    }

    func nextChunk() async throws -> Data? {
        try await QoderGatewayChunker.nextChunk(
            nextByte: { [iteratorBox] in try await iteratorBox.next() },
            firstPull: &firstPull
        )
    }
}

/// Single-owner Sendable box holding a `URLSession.AsyncBytes` iterator. The
/// production `QoderGatewayClient` creates one per stream (inside
/// `AsyncBytesSource`) and confines all `next()` calls to the pull-source
/// closure. `nonisolated` so the pull-source closure isn't forced onto the
/// MainActor. `@unchecked Sendable` because the iterator isn't Sendable, but
/// access is serialized by the stream's single-owner contract (peek completes
/// before pump begins).
private nonisolated final class AsyncBytesBox: @unchecked Sendable {
    private var iterator: URLSession.AsyncBytes.Iterator

    init(_ bytes: URLSession.AsyncBytes) {
        self.iterator = bytes.makeAsyncIterator()
    }

    func next() async throws -> UInt8? {
        try await iterator.next()
    }
}

/// Sendable wrapper around the URLSession data task backing a stream's
/// `URLSession.AsyncBytes`, so the `@Sendable` `onCancel` closure stored on
/// `QoderGatewayStream` can hold and cancel it (ADR 0012). `URLSessionTask` is
/// not formally `Sendable`, but `cancel()` is documented as thread-safe and
/// idempotent (Apple's URLSession docs: "the task need not be running on the
/// same queue as the one used to create the task"). The box is read-only after
/// init — only the underlying task's mutable state changes on `cancel()`.
/// `@unchecked Sendable` mirrors the sibling boxes above.
private nonisolated final class URLSessionTaskBox: @unchecked Sendable {
    private let task: URLSessionTask
    init(_ task: URLSessionTask) { self.task = task }

    /// Cancel the underlying URLSession task. Safe to call multiple times and
    /// from any queue; `URLSessionTask.cancel()` is a no-op on an already-
    /// completed/cancelled task.
    nonisolated func cancel() { task.cancel() }
}
