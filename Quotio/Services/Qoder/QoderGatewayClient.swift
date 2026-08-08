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
nonisolated final class QoderGatewayStream: @unchecked Sendable {
    let response: HTTPURLResponse

    /// Pull the next buffer from the upstream byte stream. Returns `nil` at
    /// stream end. Throws on transport failure. Single-owner: each call
    /// advances the same underlying iterator, so a peek via `nextChunk`
    /// consumes bytes the subsequent `pump` will not see again.
    private let source: @Sendable () async throws -> Data?

    init(
        response: HTTPURLResponse,
        source: @escaping @Sendable () async throws -> Data?
    ) {
        self.response = response
        self.source = source
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
    nonisolated func pump(_ onChunk: QoderChunkReceiver) async throws {
        while let buffer = try await source() {
            if try await onChunk(buffer) == false { return }
        }
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
        // iterator lives inside a Sendable box so the pull closure can mutate
        // it across `@Sendable` boundaries without the compiler's
        // "mutation of captured var in concurrently-executing code" error;
        // single-owner is guaranteed because only this closure holds the box
        // and pull calls are serialized by the router/ProxyBridge handoff
        // contract (peek completes before pump begins). The router pulls the
        // first buffer via `nextChunk` to peek for an in-envelope quota signal;
        // ProxyBridge then drives the remainder via `pump`. Both go through
        // this one closure, so bytes the peek consumed are not replayed. We
        // buffer into ~8KB chunks so the reparser sees reasonable frame sizes
        // rather than one byte per await (AsyncBytes iterates byte-by-byte).
        let iteratorBox = AsyncBytesBox(rawBytes)
        return QoderGatewayStream(response: http) { () -> Data? in
            var buffer = Data()
            let flushThreshold = 8192
            while let byte = try await iteratorBox.next() {
                buffer.append(byte)
                if buffer.count >= flushThreshold {
                    return buffer
                }
            }
            return buffer.isEmpty ? nil : buffer
        }
    }
}

/// Single-owner Sendable box holding a `URLSession.AsyncBytes` iterator. The
/// production `QoderGatewayClient` creates one per stream and confines all
/// `next()` calls to the pull source closure. `@unchecked Sendable` because
/// `URLSession.AsyncBytes.Iterator` is not itself Sendable, but access is
/// serialized by the stream's single-owner contract (the router's peek
/// completes before ProxyBridge's pump begins; they never race).
/// Single-owner box holding a `URLSession.AsyncBytes` iterator. `nonisolated`
/// so the pull-source closure (called from the router's actor and ProxyBridge's
/// Task) isn't forced onto the MainActor. `@unchecked Sendable` because the
/// iterator isn't Sendable, but access is serialized by the stream's
/// single-owner contract (peek completes before pump begins).
private nonisolated final class AsyncBytesBox: @unchecked Sendable {
    private var iterator: URLSession.AsyncBytes.Iterator

    init(_ bytes: URLSession.AsyncBytes) {
        self.iterator = bytes.makeAsyncIterator()
    }

    func next() async throws -> UInt8? {
        try await iterator.next()
    }
}
