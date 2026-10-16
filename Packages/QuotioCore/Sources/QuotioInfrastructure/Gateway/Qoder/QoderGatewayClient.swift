import Foundation
import QuotioDomain

/// WAF body encoding (`qoderEncodeBody`), which `QoderWAFEncoder` produces and
/// the gateway reverses. ADR 0001.
public nonisolated let qoderChatGatewayURL = URL(
    string: "https://api3.qoder.sh/algo/api/v2/service/pro/sse/agent_chat_generation?Encode=1"
)!


/// Abstracted gateway access so `QoderFailoverRouter` tests can inject a mock
/// returning canned statuses without touching the network. `Sendable` so the
/// router (an actor) can hold it across isolation boundaries.
public nonisolated protocol QoderGatewayClientProtocol: Sendable {
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
    public func openStream(
        body: Data,
        credentials: QoderCOSYCredentials
    ) async throws -> QoderGatewayStream {
        try await openStream(body: body, credentials: credentials, signerOptions: .deferringToRandom)
    }
}

/// Production gateway client. Owns a `URLSession` configured through
/// `ProxyConfigurationService` (mirrors `QoderPATService` / `QoderQuotaFetcher`
/// — respects the user's upstream proxy setting).
public final class QoderGatewayClient: QoderGatewayClientProtocol, @unchecked Sendable {
    private let session: URLSession
    private let url: URL

    public init(
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
                configuration: ProxyURLSessionFactory.makeConfiguration(timeout: 600)
            )
        }
        self.url = url
    }

    public func openStream(
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

    public func nextChunk() async throws -> Data? {
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

    public func next() async throws -> UInt8? {
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
    public nonisolated func cancel() { task.cancel() }
}
