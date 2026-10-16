//
//  OpencodeUpstreamClient.swift
//  Quotio
//
//  Thin URLSession wrapper that POSTs a verbatim request body to the
//  opencode inference endpoint and returns the streaming response —
//  status, headers, and a pull-source of raw bytes. Mirrors
//  `QoderGatewayClient`'s shape: protocol-fronted so `OpencodeRouter`'s
//  rotation policy is unit-testable with a scripted mock; `URLSession
//  .AsyncBytes` is boxed behind a Sendable pull closure for the same
//  single-owner reason.
//
//  Unlike Qoder, non-2xx statuses are NOT errors here: the router applies
//  its rotation policy (401 → next account, 429 → cooldown) and returns
//  every other status verbatim for ProxyBridge to forward upstream-faithful.
//
//  The pull source flushes at SSE frame boundaries on EVERY pull (not just
//  the first — Qoder's 8KB bulk threshold would hold a real event waiting
//  for more bytes and break streaming latency), capped at 8KB for
//  efficiency. Chunking is framing-only: the byte stream is byte-faithful
//  regardless of where chunk boundaries land.
//

import Foundation
import Network

/// Transport-level failures only. HTTP status is never an error here — the
/// router reads `OpencodeUpstreamStream.status` and applies its policy.
public nonisolated enum OpencodeUpstreamError: Error, LocalizedError {
    case network(String)
    case nonHTTPResponse

    public var errorDescription: String? {
        switch self {
        case .network(let detail): return "opencode upstream transport error: \(detail)"
        case .nonHTTPResponse: return "opencode upstream returned a non-HTTP response"
        }
    }
}

/// A handle the upstream client hands back once response HEADERS arrived.
/// `status` may be non-2xx — forwarded verbatim. `source` pulls the next
/// byte buffer; nil at EOF. Single-owner: one iterator per stream.
public nonisolated struct OpencodeUpstreamStream: Sendable {
    public let status: Int
    /// All upstream response headers as (name, value) pairs; the caller
    /// strips hop-by-hop entries before forwarding.
    public let headers: [(String, String)]
    /// Pull the next buffer; nil at stream end. Throws on transport failure.
    public let source: @Sendable () async throws -> Data?
    /// Tear down the upstream URLSession task (agent disconnect / pump end).
    /// Idempotent; no-op for test streams.
    public let cancel: @Sendable () -> Void

    init(
        status: Int,
        headers: [(String, String)],
        source: @escaping @Sendable () async throws -> Data?,
        cancel: @escaping @Sendable () -> Void = {}
    ) {
        self.status = status
        self.headers = headers
        self.source = source
        self.cancel = cancel
    }
}

/// Abstracted upstream access so `OpencodeRouter` tests inject a scripted
/// mock — mirrors `QoderGatewayClientProtocol` / `MockGatewayClient`.
public nonisolated protocol OpencodeUpstreamClientProtocol: Sendable {
    func post(url: URL, headers: [(String, String)], body: Data) async throws -> OpencodeUpstreamStream
}

/// Production upstream client. Owns a `URLSession` configured through
/// `ProxyConfigurationService` (respects the user's upstream proxy setting),
/// mirroring `QoderGatewayClient`'s timeouts for long-lived SSE.
public final class OpencodeUpstreamClient: OpencodeUpstreamClientProtocol, @unchecked Sendable {
    /// User-Agent the router pins on every upstream request so opencode's
    /// edge sees a released client, not a generic fetch client.
    public static let clientUserAgent = "opencode/1.18.30 ai-sdk/provider-utils/4.0.23 runtime/bun/1.3.14"

    private let session: URLSession

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            self.session = URLSession(
                configuration: ProxyURLSessionFactory.makeConfiguration(timeout: 600)
            )
        }
    }

    public func post(url: URL, headers: [(String, String)], body: Data) async throws -> OpencodeUpstreamStream {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        // `Accept-Encoding: identity` keeps the byte stream uncompressed so
        // ProxyBridge can forward it verbatim — the agent's own Accept-
        // Encoding is not necessarily gzip-capable.
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.httpBody = body

        let rawBytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (rawBytes, response) = try await session.bytes(for: request)
        } catch {
            throw OpencodeUpstreamError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw OpencodeUpstreamError.nonHTTPResponse
        }
        let source = OpencodeAsyncBytesSource(rawBytes)
        let taskRef = OpencodeTaskBox(rawBytes.task)
        let headerPairs = http.allHeaderFields.map { (String(describing: $0.key), String(describing: $0.value)) }
        return OpencodeUpstreamStream(
            status: http.statusCode,
            headers: headerPairs,
            source: { () -> Data? in try await source.nextChunk() },
            cancel: { taskRef.cancel() }
        )
    }
}

/// Single-owner Sendable box over a `URLSession.AsyncBytes` iterator. Every
/// pull flushes at a complete SSE frame boundary (`\n\n` / `\r\n\r\n`), the
/// 8KB cap, or EOF — preserving per-event latency for real SSE while staying
/// efficient on bulk bodies. Mirrors `AsyncBytesSource`/`AsyncBytesBox` in
/// `QoderGatewayClient`.
private nonisolated final class OpencodeAsyncBytesSource: @unchecked Sendable {
    private var iterator: URLSession.AsyncBytes.Iterator
    private var carry = Data()

    private static let lfBoundary: [UInt8] = [0x0A, 0x0A]
    private static let crlfBoundary: [UInt8] = [0x0D, 0x0A, 0x0D, 0x0A]
    private static let bulkCap = 8192

    init(_ bytes: URLSession.AsyncBytes) {
        self.iterator = bytes.makeAsyncIterator()
    }

    func nextChunk() async throws -> Data? {
        while let byte = try await iterator.next() {
            carry.append(byte)
            if carry.count >= Self.bulkCap || endsWithFrameBoundary(carry) {
                let out = carry
                carry = Data()
                return out
            }
        }
        guard !carry.isEmpty else { return nil }
        let out = carry
        carry = Data()
        return out
    }

    private func endsWithFrameBoundary(_ buffer: Data) -> Bool {
        let bytes = [UInt8](buffer)
        if bytes.count >= Self.lfBoundary.count,
           Array(bytes.suffix(Self.lfBoundary.count)) == Self.lfBoundary {
            return true
        }
        if bytes.count >= Self.crlfBoundary.count,
           Array(bytes.suffix(Self.crlfBoundary.count)) == Self.crlfBoundary {
            return true
        }
        return false
    }
}

/// Sendable wrapper around the URLSession data task backing a stream's
/// `URLSession.AsyncBytes`, so the `@Sendable` `cancel` closure can hold and
/// cancel it — mirrors `URLSessionTaskBox` in `QoderGatewayClient`.
private nonisolated final class OpencodeTaskBox: @unchecked Sendable {
    private let task: URLSessionTask
    init(_ task: URLSessionTask) { self.task = task }
    nonisolated func cancel() { task.cancel() }
}
