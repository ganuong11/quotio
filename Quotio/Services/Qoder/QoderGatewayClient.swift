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

/// A handle the gateway client hands back on a 2xx response. The router
/// returns this to ProxyBridge, which calls `pump(into:)` to drive the byte
/// stream through `QoderSSEReparser` and into the agent socket.
///
/// `pump` is async-closure-backed: the production client captures a
/// `URLSession.AsyncBytes` iterator; test mocks inject a closure that yields
/// scripted chunks. This sidesteps the fact that `URLSession.AsyncBytes` is
/// concrete and non-constructible — no type-erasure needed, no Sendable
/// constraint on the iterator (the closure is `@Sendable` and the iterator
/// stays inside it).
nonisolated struct QoderGatewayStream: Sendable {
    let response: HTTPURLResponse
    /// Drive the upstream byte stream. `onChunk` is called with each raw byte
    /// buffer the gateway yields; return false to stop early (e.g. agent
    /// disconnect). Throws on transport failure (the caller terminates).
    let pump: @Sendable (@Sendable (Data) async throws -> Bool) async throws -> Void
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
        // Capture the byte stream inside a @Sendable pump closure. The iterator
        // stays inside the closure (never crosses an isolation boundary on its
        // own), so we don't need AsyncBytes' iterator to be Sendable. Each
        // call to `pump` drains the stream, calling `onChunk` per buffer; the
        // closure returns false to stop early (agent disconnect).
        return QoderGatewayStream(response: http) { onChunk in
            // Buffer into chunks so the reparser sees reasonable frame sizes
            // rather than one byte per await (AsyncBytes iterates byte-by-byte).
            var buffer = Data()
            let flushThreshold = 8192
            var it = rawBytes.makeAsyncIterator()
            while let byte = try await it.next() {
                buffer.append(byte)
                if buffer.count >= flushThreshold {
                    if try await onChunk(buffer) == false { return }
                    buffer.removeAll(keepingCapacity: true)
                }
            }
            if !buffer.isEmpty {
                _ = try await onChunk(buffer)
            }
        }
    }
}
