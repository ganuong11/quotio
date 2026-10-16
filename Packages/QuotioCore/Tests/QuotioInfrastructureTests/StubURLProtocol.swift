//
//  StubURLProtocol.swift
//  QuotioTests
//
//  Shared URLProtocol stub for HTTP-level tests. `QoderPATServiceTests` keeps
//  its own file-scoped variant; this one is generalized (per-request handler,
//  recorded requests incl. drained body) for the opencode test files.
//

import Foundation
import XCTest

final class StubURLProtocol: URLProtocol {

    struct RecordedRequest: Sendable {
        let method: String
        let url: URL
        let headers: [String: String]
        let body: Data
    }

    typealias Handler = @Sendable (RecordedRequest) throws -> (status: Int, headers: [String: String], body: Data)

    private final class Store: @unchecked Sendable {
        private let lock = NSLock()
        private var _handler: Handler?
        private var _requests: [RecordedRequest] = []

        var handler: Handler? {
            get { lock.lock(); defer { lock.unlock() }; return _handler }
            set { lock.lock(); defer { lock.unlock() }; _handler = newValue }
        }
        var requests: [RecordedRequest] {
            lock.lock(); defer { lock.unlock() }; return _requests
        }
        func record(_ r: RecordedRequest) {
            lock.lock(); defer { lock.unlock() }; _requests.append(r)
        }
        func reset() {
            lock.lock(); defer { lock.unlock() }; _handler = nil; _requests = []
        }
    }

    nonisolated(unsafe) private static let store = Store()

    static var handler: Handler? {
        get { store.handler }
        set { store.handler = newValue }
    }
    static var requests: [RecordedRequest] { store.requests }
    static func reset() { store.reset() }

    static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }

    static func json(_ object: Any, status: Int = 200, headers: [String: String] = [:]) -> (status: Int, headers: [String: String], body: Data) {
        var h = ["Content-Type": "application/json"]
        h.merge(headers) { _, new in new }
        return (status, h, try! JSONSerialization.data(withJSONObject: object))
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = request.httpBody ?? Self.drain(request.httpBodyStream)
        let recorded = RecordedRequest(
            method: request.httpMethod ?? "GET",
            url: request.url!,
            headers: request.allHTTPHeaderFields ?? [:],
            body: body
        )
        Self.store.record(recorded)
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        do {
            let (status, headers, data) = try handler(recorded)
            let response = HTTPURLResponse(
                url: recorded.url,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: headers
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private static func drain(_ stream: InputStream?) -> Data {
        guard let stream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            guard n > 0 else { break }
            data.append(buffer, count: n)
        }
        return data
    }
}
