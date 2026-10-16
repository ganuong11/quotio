import Foundation
import QuotioDomain
@testable import QuotioInfrastructure
import XCTest

/// Client-level coverage for `QoderGatewayClient`: WAF encoding + COSY
/// headers + byte-stream handoff, all through `StubURLProtocol` (no network).
final class QoderGatewayClientTests: XCTestCase {

    private let credentials = QoderCOSYCredentials(
        userID: "user-1",
        authToken: "job-token",
        name: "Account One",
        email: "a@b.c",
        machineID: "machine-1"
    )

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    private func makeClient() -> QoderGatewayClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return QoderGatewayClient(sessionConfiguration: config)
    }

    func testOpenStreamSendsWAfEncodedBodyWithCosyHeaders() async throws {
        StubURLProtocol.handler = { _ in
            (200, ["Content-Type": "text/event-stream"], Data("data: [DONE]\n\n".utf8))
        }

        let client = makeClient()
        let stream = try await client.openStream(body: Data(#"{"model":"auto"}"#.utf8), credentials: credentials)
        XCTAssertEqual(stream.response.statusCode, 200)

        let recorded = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(recorded.method, "POST")
        XCTAssertEqual(recorded.url, qoderChatGatewayURL)
        XCTAssertEqual(recorded.headers["Accept-Encoding"], "identity")
        XCTAssertEqual(recorded.headers["Accept"], "text/event-stream")
        // COSY signature envelope: Authorization + at least one Cosy-*/Login-*
        // header present proves the signer ran (fixture-level signing behavior
        // is covered by QoderCOSYSignerTests).
        XCTAssertNotNil(recorded.headers["Authorization"])
        XCTAssertTrue(
            recorded.headers.keys.contains { $0.lowercased().hasPrefix("cosy-") || $0.lowercased().hasPrefix("login-") },
            "expected Cosy-* headers, got \(recorded.headers.keys)"
        )
        // Body is WAF-encoded, not the raw JSON.
        XCTAssertFalse(recorded.body.isEmpty)
        XCTAssertNotEqual(recorded.body, Data(#"{"model":"auto"}"#.utf8))
    }

    func testOpenStreamPumpsResponseBytes() async throws {
        let sseBody = Data("data: {\"a\":1}\n\ndata: [DONE]\n\n".utf8)
        StubURLProtocol.handler = { _ in
            (200, ["Content-Type": "text/event-stream"], sseBody)
        }

        let client = makeClient()
        let stream = try await client.openStream(body: Data("{}".utf8), credentials: credentials)

        final class Collector: @unchecked Sendable {
            private let lock = NSLock()
            private var bytes = Data()
            func append(_ d: Data) { lock.lock(); defer { lock.unlock() }; bytes.append(d) }
            var data: Data { lock.lock(); defer { lock.unlock() }; return bytes }
        }
        let collector = Collector()
        try await stream.pump { chunk in
            collector.append(chunk)
            return true
        }
        XCTAssertEqual(collector.data, sseBody)
    }

    func testOpenStreamSurfacesUpstreamStatus() async throws {
        StubURLProtocol.handler = { _ in
            (429, [:], Data("quota".utf8))
        }
        let client = makeClient()
        let stream = try await client.openStream(body: Data("{}".utf8), credentials: credentials)
        // The client preserves the upstream status; rotation policy lives in
        // the router, not here.
        XCTAssertEqual(stream.response.statusCode, 429)
    }

    func testOpenStreamThrowsOnSignerFailureBeforeRequest() async throws {
        StubURLProtocol.handler = { _ in
            XCTFail("no request should be issued when signing fails")
            return (500, [:], Data())
        }
        let client = makeClient()
        do {
            _ = try await client.openStream(
                body: Data("{}".utf8),
                credentials: QoderCOSYCredentials(userID: "", authToken: "x")
            )
            XCTFail("expected throw")
        } catch let error as QoderGatewayError {
            guard case .network = error else {
                return XCTFail("expected .network, got \(error)")
            }
        }
        XCTAssertTrue(StubURLProtocol.requests.isEmpty)
    }

    func testCancelStopsBytePull() async throws {
        StubURLProtocol.handler = { _ in
            (200, ["Content-Type": "text/event-stream"], Data("data: [DONE]\n\n".utf8))
        }
        let client = makeClient()
        let stream = try await client.openStream(body: Data("{}".utf8), credentials: credentials)
        stream.cancel()
        // Idempotent: a second cancel must not throw or hang.
        stream.cancel()
    }
}
