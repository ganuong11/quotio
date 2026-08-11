//
//  QoderPATServiceTests.swift
//  QuotioTests
//
//  Tests for ADR 0017: every PAT→job-token exchange (quota polling via
//  `credentials(fromPat:)`, failover re-exchange via `refreshCredential`) is
//  paced through one gate so multi-account bursts cannot hammer
//  `openapi.qoder.sh/api/v1/jobToken/exchange` past its rate limit.
//
//  `MockURLProtocol` is the only URLProtocol stub in the suite (introduced
//  here); it serves canned exchange/userinfo responses and records the
//  monotonic time of each exchange POST via a lock-protected recorder so
//  tests can assert spacing without a data race.
//

import XCTest
@testable import Quotio

/// Thread-safe recorder for exchange POST timestamps. URLProtocol callbacks
/// fire on URLSession work threads; with concurrent requests those callbacks
/// overlap, so a bare `nonisolated(unsafe) static var` would race. The NSLock
/// makes append/read safe. Monotonic clock (`systemUptime`) avoids wall-clock
/// skew during the test.
private final class ExchangeRecorder {
    private let lock = NSLock()
    private var _timestamps: [TimeInterval] = []

    func record() {
        lock.lock()
        _timestamps.append(ProcessInfo.processInfo.systemUptime)
        lock.unlock()
    }

    func snapshot() -> [TimeInterval] {
        lock.lock()
        defer { lock.unlock() }
        return _timestamps
    }

    func reset() {
        lock.lock()
        _timestamps = []
        lock.unlock()
    }
}

/// Serves canned Qoder OpenAPI responses and records exchange POST times.
private final class MockURLProtocol: URLProtocol {
    /// Immutable reference to a thread-safe mutable recorder. `nonisolated(unsafe)`
    /// on a `let` whose object is internally locked is race-free.
    nonisolated(unsafe) static let recorder = ExchangeRecorder()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        if url.path.hasSuffix("/jobToken/exchange") {
            Self.recorder.record()
            respond(with: ["token": "jt-TEST", "refresh_token": "jr-TEST", "expires_in": 86_400_000])
        } else if url.path.hasSuffix("/userinfo") {
            respond(with: ["id": "user-1", "email": "test@example.com", "name": "Test"])
        } else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
        }
    }

    override func stopLoading() {}

    private func respond(with json: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: json)
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

final class QoderPATServiceTests: XCTestCase {

    override func setUp() {
        super.setUp()
        MockURLProtocol.recorder.reset()
    }

    private func makeService(minExchangeInterval: TimeInterval) -> QoderPATService {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return QoderPATService(minExchangeInterval: minExchangeInterval, session: session)
    }

    /// Mirrors `QoderFailoverRouterTests.makeCredential` (that file :253-260):
    /// a credential whose job token has already expired, carrying a stored PAT.
    private func makeStaleCredential() -> MonitorOAuthCredential {
        MonitorOAuthCredential(
            accessToken: "jt-stale",
            refreshToken: nil,
            idToken: nil,
            accountID: "user-1",
            expiresAt: Date().addingTimeInterval(-3600),
            extra: ["pat": "pt-STALE", "machineID": "machine-1"]
        )
    }

    private func makeAccount() -> MonitorAccount {
        MonitorAccount.make(
            provider: .qoder,
            accountKey: "acc-1",
            displayName: "Acc 1",
            source: .quotioKeychain
        )
    }

    // MARK: - Pacing

    func testSequentialExchangesAreSpacedByMinInterval() async throws {
        let service = makeService(minExchangeInterval: 0.3)
        _ = try await service.credentials(fromPat: "pt-TESTPAT")
        _ = try await service.credentials(fromPat: "pt-TESTPAT")

        let timestamps = MockURLProtocol.recorder.snapshot()
        XCTAssertEqual(timestamps.count, 2)
        // The load-bearing invariant: successive exchange *starts* are ≥ the
        // interval apart. 0.2s headroom under the 0.3s interval tolerates
        // Task.sleep jitter without masking a missing gate.
        XCTAssertGreaterThanOrEqual(
            timestamps[1] - timestamps[0],
            0.2,
            "second exchange must wait for the pace slot"
        )
    }

    func testConcurrentExchangeBurstIsSpaced() async throws {
        // Five accounts whose tokens expire together: a synchronized quota-
        // poll burst. Each start must be spaced by the interval, not clustered.
        // Five callers (not two) exercises actor reentrancy hard enough that a
        // naive check-then-sleep gate (which lets two callers sleep to the same
        // deadline and start together) fails reliably.
        let service = makeService(minExchangeInterval: 0.15)
        async let a = service.credentials(fromPat: "pt-A")
        async let b = service.credentials(fromPat: "pt-B")
        async let c = service.credentials(fromPat: "pt-C")
        async let d = service.credentials(fromPat: "pt-D")
        async let e = service.credentials(fromPat: "pt-E")
        _ = try await a
        _ = try await b
        _ = try await c
        _ = try await d
        _ = try await e

        let timestamps = MockURLProtocol.recorder.snapshot().sorted()
        XCTAssertEqual(timestamps.count, 5)
        // Every adjacent pair must be spaced; a naive gate clusters at least
        // one pair below the interval.
        for i in 1..<timestamps.count {
            XCTAssertGreaterThanOrEqual(
                timestamps[i] - timestamps[i - 1],
                0.10,
                "exchange \(i) started too soon after exchange \(i - 1)"
            )
        }
    }

    /// Pins the shared-funnel CONTRACT: `credentials(fromPat:)` (quota polling
    /// + onboarding) and `refreshCredential` (failover router) both route
    /// through `QoderPATService.shared`, so one gate covers both. This test
    /// proves the two public entry points share the same pacing slot *within
    /// one service instance*; it does NOT prove the production quota fetcher
    /// and router actors share it (they do, via `.shared`, but that is a
    /// wiring fact, not something this test exercises).
    func testCredentialsAndRefreshCredentialSharePaceGate() async throws {
        let service = makeService(minExchangeInterval: 0.2)
        // Hoist the Sendable arguments out of the `async let` so `self` (the
        // non-Sendable XCTestCase) isn't captured by the child task — Swift 6
        // strict concurrency otherwise flags a data-race risk.
        let stale = makeStaleCredential()
        let account = makeAccount()
        async let poll = service.credentials(fromPat: "pt-POLL")
        async let refresh = service.refreshCredential(stale, account: account)
        _ = try await poll
        _ = try await refresh

        let timestamps = MockURLProtocol.recorder.snapshot().sorted()
        XCTAssertEqual(timestamps.count, 2)
        XCTAssertGreaterThanOrEqual(
            timestamps[1] - timestamps[0],
            0.15,
            "credentials and refreshCredential must draw from the same pace gate"
        )
    }
}
