import Foundation
import Network
import XCTest
import QuotioApplication
import QuotioDomain
@testable import QuotioInfrastructure

/// Loopback-socket tests for `GatewayListener`: a stub TCP responder stands in
/// for CPA and a raw `NWConnection` plays the agent client.
final class GatewayListenerTests: XCTestCase {

    func testPassthroughReturnsUpstreamBytesVerbatim() async throws {
        let expected = Data("HTTP/1.1 200 OK\r\nX-Marker: upstream-bytes\r\nContent-Length: 5\r\nConnection: close\r\n\r\nhello".utf8)
        let upstream = try await StubTCPServer.start(response: expected)
        let listener = GatewayListener()
        let frontPort = try reserveFreePort()
        try await listener.start(port: frontPort, bindHost: "127.0.0.1", upstreamPort: upstream.port)
        defer { Task { await listener.stop() } }

        let request = Data("GET /v1/usage HTTP/1.1\r\nHost: 127.0.0.1:\(frontPort)\r\nAccept-Encoding: gzip\r\n\r\n".utf8)
        let response = try await roundTrip(port: frontPort, request: request)

        XCTAssertEqual(response, expected)

        let forwardedHead = try await upstream.lastRequestHead()
        XCTAssertTrue(forwardedHead.contains("Connection: close"), forwardedHead)
        XCTAssertTrue(forwardedHead.contains("Host: 127.0.0.1:\(upstream.port)"), forwardedHead)
        XCTAssertTrue(forwardedHead.contains("Content-Length: 0"), forwardedHead)
        XCTAssertFalse(forwardedHead.lowercased().contains("accept-encoding"), forwardedHead)
    }

    func testPOSTBodyForwardedByteExactlyWithRecomputedContentLength() async throws {
        let expected = Data("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok".utf8)
        let upstream = try await StubTCPServer.start(response: expected)
        let listener = GatewayListener()
        let frontPort = try reserveFreePort()
        try await listener.start(port: frontPort, bindHost: "127.0.0.1", upstreamPort: upstream.port)
        defer { Task { await listener.stop() } }

        // Non-UTF8 body bytes prove the body never round-trips through String.
        // The client header is lowercase; the canonical "Content-Length" in the
        // forwarded head proves the field was dropped and recomputed.
        let body = Data([0x00, 0xFF, 0x10, 0x80, 0x41])
        var request = Data("POST /v1/chat/completions HTTP/1.1\r\nHost: x\r\ncontent-length: \(body.count)\r\n\r\n".utf8)
        request.append(body)

        let response = try await roundTrip(port: frontPort, request: request)
        XCTAssertEqual(response, expected)

        let forwarded = try await upstream.lastRequest()
        XCTAssertEqual(forwarded.body, body)
        XCTAssertTrue(forwarded.head.contains("Content-Length: \(body.count)"), forwarded.head)
        XCTAssertFalse(forwarded.head.lowercased().contains("content-length: 99"), forwarded.head)
        XCTAssertEqual(
            forwarded.head.components(separatedBy: "\r\n")
                .filter { $0.lowercased().hasPrefix("content-length:") },
            ["Content-Length: \(body.count)"]
        )
    }

    func testBindFailureOnOccupiedPortThrows() async throws {
        let occupier = try await StubTCPServer.start(response: Data("HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n".utf8))
        let listener = GatewayListener()
        await assertThrows(
            try await listener.start(port: occupier.port, bindHost: "127.0.0.1", upstreamPort: 1)
        )
        let running = await listener.isRunning
        XCTAssertFalse(running)
    }

    func testStopReleasesPort() async throws {
        let upstream = try await StubTCPServer.start(response: Data("HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n".utf8))
        let listener = GatewayListener()
        let frontPort = try reserveFreePort()
        try await listener.start(port: frontPort, bindHost: "127.0.0.1", upstreamPort: upstream.port)
        await listener.stop()

        let running = await listener.isRunning
        XCTAssertFalse(running)

        // A rebinder can take the port — proves the listener let go. The
        // NWListener socket closes asynchronously after cancel(), so poll the
        // rebind rather than asserting it's instant.
        var rebind: StubTCPServer?
        let deadline = Date().addingTimeInterval(5)
        while rebind == nil, Date() < deadline {
            rebind = try? await StubTCPServer.start(response: Data(), boundPort: frontPort)
            if rebind == nil { try await Task.sleep(nanoseconds: 100_000_000) }
        }
        XCTAssertNotNil(rebind, "listener must release the port within 5s of stop()")

    }


    // MARK: - Qoder interception wiring (Task 15)

    /// Empty-vault Qoder request: the gate intercepts, the failover router
    /// finds zero accounts, and the agent gets an OpenAI-shaped error
    /// envelope — NOT silent passthrough to CPA.
    func testQoderRequestWithEmptyVaultReturns503ErrorEnvelope() async throws {
        let router = QoderFailoverRouter(
            vault: ListenerStubVault(),
            metadata: ListenerStubAccounts(),
            patService: ListenerStubPAT(),
            gateway: ListenerStubGateway(streamFactory: {
                XCTFail("empty vault must never reach the gateway")
                return QoderGatewayStream(
                    response: HTTPURLResponse(url: qoderChatGatewayURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
                ) { nil }
            })
        )
        let listener = GatewayListener()
        await listener.configureRouting(qoderRouter: router)
        let frontPort = try reserveFreePort()
        try await listener.start(port: frontPort, bindHost: "127.0.0.1", upstreamPort: 1)
        defer { Task { await listener.stop() } }

        let body = Data(#"{"model":"qoder/auto","messages":[{"role":"user","content":"hi"}],"stream":false}"#.utf8)
        var request = "POST /v1/chat/completions HTTP/1.1\r\nHost: 127.0.0.1:\(frontPort)\r\n"
        request += "Authorization: Bearer test-key\r\nContent-Length: \(body.count)\r\n\r\n"
        let response = try await roundTrip(
            port: frontPort,
            request: Data(request.utf8) + body
        )
        let head = String(decoding: response.prefix(400), as: UTF8.self)
        XCTAssertTrue(head.hasPrefix("HTTP/1.1 503"), head)
        XCTAssertTrue(head.contains("Content-Type: application/json"), head)
        XCTAssertTrue(String(decoding: response, as: UTF8.self).contains("\"error\""), String(decoding: response, as: UTF8.self))
    }

    /// A primed validator rejects an unauthenticated qoder request before it
    /// reaches the router — same 401 envelope CPA's auth middleware emits.
    func testQoderRequestWithoutConfiguredAPIKeyReturns401() async throws {
        let validator = QoderAccessValidator()
        await validator.reload(keys: ["expected-key"])
        let router = QoderFailoverRouter(
            vault: ListenerStubVault(),
            metadata: ListenerStubAccounts(),
            patService: ListenerStubPAT(),
            gateway: ListenerStubGateway(streamFactory: {
                XCTFail("rejected auth must never reach the gateway")
                return QoderGatewayStream(
                    response: HTTPURLResponse(url: qoderChatGatewayURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
                ) { nil }
            })
        )
        let listener = GatewayListener()
        await listener.configureRouting(qoderRouter: router, accessValidator: validator)
        let frontPort = try reserveFreePort()
        try await listener.start(port: frontPort, bindHost: "127.0.0.1", upstreamPort: 1)
        defer { Task { await listener.stop() } }

        let body = Data(#"{"model":"qoder/auto","messages":[{"role":"user","content":"hi"}],"stream":false}"#.utf8)
        var request = "POST /v1/chat/completions HTTP/1.1\r\nHost: 127.0.0.1:\(frontPort)\r\n"
        request += "Content-Length: \(body.count)\r\n\r\n"
        let response = try await roundTrip(port: frontPort, request: Data(request.utf8) + body)
        XCTAssertTrue(
            String(decoding: response, as: UTF8.self).hasPrefix("HTTP/1.1 401"),
            String(decoding: response.prefix(200), as: UTF8.self)
        )
    }

    /// GET /v1/models is intercepted when a router is wired: CPA's body plus
    /// the Qoder catalog entries, with a recomputed Content-Length.
    func testModelsListMergesQoderCatalog() async throws {
        let cpaBody = Data(#"{"object":"list","data":[{"id":"claude-sonnet-4"}]}"#.utf8)
        let cpaResponse = Data(
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(cpaBody.count)\r\nConnection: close\r\n\r\n".utf8
        ) + cpaBody
        let upstream = try await StubTCPServer.start(response: cpaResponse)
        let router = QoderFailoverRouter(
            vault: ListenerStubVault(),
            metadata: ListenerStubAccounts(),
            patService: ListenerStubPAT(),
            gateway: ListenerStubGateway(streamFactory: {
                QoderGatewayStream(
                    response: HTTPURLResponse(url: qoderChatGatewayURL, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
                ) { nil }
            })
        )
        let listener = GatewayListener()
        await listener.configureRouting(qoderRouter: router)
        let frontPort = try reserveFreePort()
        try await listener.start(port: frontPort, bindHost: "127.0.0.1", upstreamPort: upstream.port)
        defer { Task { await listener.stop() } }

        let response = try await roundTrip(
            port: frontPort,
            request: Data("GET /v1/models HTTP/1.1\r\nHost: 127.0.0.1:\(frontPort)\r\n\r\n".utf8)
        )
        let text = String(decoding: response, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("HTTP/1.1 200"), text)
        XCTAssertTrue(text.contains("claude-sonnet-4"), text)
        XCTAssertTrue(text.contains("qoder"), text)
    }

    /// Listener stop while a Qoder pump is in flight cancels the pump task,
    /// which tears down the upstream stream (Review Focus #2).
    func testListenerStopCancelsInFlightPump() async throws {
        let account = GatewayAccount.make(
            provider: .qoder,
            accountKey: "acct-1",
            displayName: "Account One",
            source: .onboarded
        )
        let credential = GatewayCredential(
            accessToken: "job-token",
            accountID: "user-1",
            extra: ["machineID": "machine-1"]
        )
        let vault = ListenerStubVault()
        await vault.seed(account, credential)

        let spy = PumpSpy()
        let gateway = ListenerStubGateway {
            QoderGatewayStream(
                response: HTTPURLResponse(
                    url: qoderChatGatewayURL,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "text/event-stream"]
                )!,
                onCancel: { Task { await spy.markCancelled() } },
                source: {
                    if await spy.claimFirstPull() {
                        return Data("data: {\"choices\":[{\"delta\":{\"content\":\"hi\"}}]}\n\n".utf8)
                    }
                    // Model a slow upstream: sleep in chunks until the pump
                    // task is cancelled, then end the stream so the pump's
                    // deferred cancel() fires.
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 50_000_000)
                    }
                    return nil
                }
            )
        }
        let router = QoderFailoverRouter(
            vault: vault,
            metadata: ListenerStubAccounts(),
            patService: ListenerStubPAT(),
            gateway: gateway
        )
        let listener = GatewayListener()
        await listener.configureRouting(qoderRouter: router)
        let frontPort = try reserveFreePort()
        try await listener.start(port: frontPort, bindHost: "127.0.0.1", upstreamPort: 1)

        let body = Data(#"{"model":"qoder/auto","messages":[{"role":"user","content":"hi"}],"stream":true}"#.utf8)
        var head = "POST /v1/chat/completions HTTP/1.1\r\nHost: 127.0.0.1:\(frontPort)\r\n"
        head += "Authorization: Bearer test-key\r\nContent-Length: \(body.count)\r\n\r\n"
        let connection = NWConnection(
            host: "127.0.0.1",
            port: NWEndpoint.Port(rawValue: frontPort)!,
            using: .tcp
        )
        try await waitForReady(connection)
        try await send(Data(head.utf8) + body, on: connection)

        async let receivedBytes = receiveBytesUntilClose(connection)

        // Wait until the pump is genuinely in its blocked pull.
        do {
            try await spy.waitForPumpStart()
        } catch {
            connection.cancel()
            let response = try? await receivedBytes
            XCTFail("pump never started; agent received: \(String(decoding: response ?? Data(), as: UTF8.self))")
            await listener.stop()
            return
        }

        await listener.stop()

        // The pump task is cancelled → its blocked source returns nil →
        // pump() exits → deferred stream.cancel() fires the spy.
        try await spy.waitForCancellation()
        connection.cancel()
    }

    // MARK: - Helpers

    /// Picks an ephemeral port via a POSIX socket probe — binding and closing
    /// is synchronous, so the port is genuinely free when we return. Racy in
    /// theory; loopback-only and good enough for tests.
    private func reserveFreePort() throws -> UInt16 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        precondition(fd >= 0)
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = INADDR_ANY
        addr.sin_port = 0
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        precondition(bound == 0)
        var resolved = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &resolved) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        return UInt16(bigEndian: resolved.sin_port)
    }

    private func roundTrip(port: UInt16, request: Data) async throws -> Data {
        let connection = NWConnection(
            host: "127.0.0.1",
            port: NWEndpoint.Port(rawValue: port)!,
            using: .tcp
        )
        try await waitForReady(connection)
        try await send(request, on: connection)
        return try await receiveUntilClose(connection)
    }

    private func watchdog<T: Sendable>(
        _ box: ResumeBox,
        _ cont: CheckedContinuation<T, Error>,
        seconds: UInt64 = 10
    ) {
        Task {
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            box.tryResume(cont, with: .failure(TestTimeoutError()))
        }
    }

    private func waitForReady(_ connection: NWConnection) async throws {
        let box = ResumeBox()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    box.tryResume(cont, with: .success(()))
                case .failed(let error):
                    box.tryResume(cont, with: .failure(error))
                case .cancelled:
                    box.tryResume(cont, with: .failure(CancellationError()))
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
            watchdog(box, cont)
        }
    }

    private func send(_ data: Data, on connection: NWConnection) async throws {
        let box = ResumeBox()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    box.tryResume(cont, with: .failure(error))
                } else {
                    box.tryResume(cont, with: .success(()))
                }
            })
            watchdog(box, cont)
        }
    }

    private func receiveUntilClose(_ connection: NWConnection) async throws -> Data {
        let box = ResumeBox()
        final class Accumulator: @unchecked Sendable {
            var data = Data()
        }
        let accumulated = Accumulator()
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            @Sendable func receive() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                    if let error {
                        box.tryResume(cont, with: .failure(error))
                        return
                    }
                    if let data { accumulated.data.append(data) }
                    if isComplete {
                        box.tryResume(cont, with: .success(accumulated.data))
                    } else {
                        receive()
                    }
                }
            }
            receive()
            watchdog(box, cont)
        }
    }

    private func assertThrows(
        _ expression: @autoclosure () async throws -> Void,
        _ message: String = "expected throw",
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await expression()
            XCTFail(message, file: file, line: line)
        } catch {}
    }
}

/// Resume-once box for checked continuations: a watchdog resumes with a
/// timeout error so a stuck Network callback can never hang the test.
private final class ResumeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false

    func tryResume<T>(_ cont: CheckedContinuation<T, Error>, with result: sending Result<T, Error>) {
        lock.lock()
        defer { lock.unlock() }
        guard !resumed else { return }
        resumed = true
        cont.resume(with: result)
    }
}

private struct TestTimeoutError: Error {}

/// File-scope copy of `receiveUntilClose` for call sites that can't capture
/// `self` in an `async let` (XCTestCase is not Sendable).
private func receiveBytesUntilClose(_ connection: NWConnection) async throws -> Data {
    let box = ResumeBox()
    final class Accumulator: @unchecked Sendable {
        var data = Data()
    }
    let accumulated = Accumulator()
    return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
        @Sendable func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
                if let error {
                    box.tryResume(cont, with: .failure(error))
                    return
                }
                if let data { accumulated.data.append(data) }
                if isComplete {
                    box.tryResume(cont, with: .success(accumulated.data))
                } else {
                    receive()
                }
            }
        }
        receive()
        Task {
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            box.tryResume(cont, with: .failure(TestTimeoutError()))
        }
    }
}

/// Minimal TCP responder: accepts one connection, records the request bytes
/// until the declared Content-Length is satisfied, replies with the canned
/// response, then closes.
private final class StubTCPServer: @unchecked Sendable {
    private(set) var port: UInt16 = 0

    private let listener: NWListener
    private let lock = NSLock()
    private var receivedData = Data()
    private var fulfilledData: Data?
    private var continuation: CheckedContinuation<Data, Never>?

    private init(listener: NWListener, response: Data) {
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            connection.start(queue: .global(qos: .userInitiated))
            self?.receiveLoop(connection: connection, response: response)
        }
    }

    static func start(response: Data, boundPort: UInt16? = nil) async throws -> StubTCPServer {
        let listener: NWListener
        if let boundPort {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            parameters.requiredLocalEndpoint = .hostPort(
                host: "127.0.0.1",
                port: NWEndpoint.Port(rawValue: boundPort)!
            )
            listener = try NWListener(using: parameters)
        } else {
            listener = try NWListener(using: .tcp, on: .any)
        }
        let server = StubTCPServer(listener: listener, response: response)
        try await server.startAndAwaitReady()
        return server
    }

    private func startAndAwaitReady() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let box = ResumeBox()
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    self?.port = self?.listener.port?.rawValue ?? 0
                    box.tryResume(cont, with: .success(()))
                case .failed(let error):
                    box.tryResume(cont, with: .failure(error))
                case .cancelled:
                    box.tryResume(cont, with: .failure(CancellationError()))
                default:
                    break
                }
            }
            listener.start(queue: .global(qos: .userInitiated))
            Task {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                box.tryResume(cont, with: .failure(TestTimeoutError()))
            }
        }
    }

    deinit { listener.cancel() }

    func lastRequest() async throws -> (head: String, body: Data) {
        try await requestWithHeaderSplit()
    }

    func lastRequestHead() async throws -> String {
        try await requestWithHeaderSplit().head
    }

    private func requestWithHeaderSplit() async throws -> (head: String, body: Data) {
        let data: Data = await withCheckedContinuation { cont in
            lock.lock()
            if let fulfilledData {
                lock.unlock()
                cont.resume(returning: fulfilledData)
            } else {
                continuation = cont
                lock.unlock()
            }
        }
        guard let range = data.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: data[..<range.lowerBound], encoding: .utf8) else {
            throw NSError(domain: "test", code: 3)
        }
        return (head, data[(range.upperBound)...])
    }

    private func receiveLoop(connection: NWConnection, response: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1048576) { [weak self] data, _, isComplete, _ in
            guard let self else { return }
            if let data {
                self.lock.lock()
                self.receivedData.append(data)
                let satisfied = self.requestIsComplete()
                self.lock.unlock()
                if satisfied {
                    self.fulfill()
                    connection.send(content: response, completion: .contentProcessed { _ in
                        connection.cancel()
                    })
                    return
                }
            }
            if isComplete {
                self.fulfill()
                connection.send(content: response, completion: .contentProcessed { _ in
                    connection.cancel()
                })
                return
            }
            self.receiveLoop(connection: connection, response: response)
        }
    }

    /// Caller must hold `lock`.
    private func requestIsComplete() -> Bool {
        guard let headerEnd = receivedData.range(of: Data("\r\n\r\n".utf8)) else { return false }
        guard let head = String(data: receivedData[..<headerEnd.lowerBound], encoding: .utf8) else { return true }
        var expectedBody = 0
        for line in head.components(separatedBy: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" {
                expectedBody = Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        return receivedData.count - headerEnd.upperBound >= expectedBody
    }

    private func fulfill() {
        lock.lock()
        let cont = continuation
        continuation = nil
        fulfilledData = receivedData
        let data = receivedData
        lock.unlock()
        cont?.resume(returning: data)
    }
}


// MARK: - Qoder wiring test doubles

/// Minimal in-memory credential store for listener-level tests (the router's
/// `GatewayCredentialStoring` seam).
private actor ListenerStubVault: GatewayCredentialStoring {
    private var accountsList: [GatewayAccount] = []
    private var credentials: [String: GatewayCredential] = [:]

    func seed(_ account: GatewayAccount, _ credential: GatewayCredential) {
        accountsList.append(account)
        credentials[account.id] = credential
    }

    func accounts() async -> [GatewayAccount] { accountsList }
    func credential(for accountID: String) async -> GatewayCredential? { credentials[accountID] }
    func store(_ credential: GatewayCredential, account: GatewayAccount) async throws {
        credentials[account.id] = credential
    }
}

private actor ListenerStubAccounts: GatewayAccountStoring {
    private var disabled: Set<String> = []
    func disabledAccountIDs() async -> Set<String> { disabled }
    func setDisabled(_ disabled: Bool, accountID: String) async throws {
        if disabled { self.disabled.insert(accountID) } else { self.disabled.remove(accountID) }
    }
}

private actor ListenerStubPAT: QoderPATRefreshing {
    func refreshCredential(
        _ credential: GatewayCredential,
        account: GatewayAccount
    ) async throws -> GatewayCredential { credential }
}

private actor ListenerStubGateway: QoderGatewayClientProtocol {
    private let streamFactory: @Sendable () -> QoderGatewayStream
    init(streamFactory: @escaping @Sendable () -> QoderGatewayStream) {
        self.streamFactory = streamFactory
    }
    func openStream(
        body: Data,
        credentials: QoderCOSYCredentials,
        signerOptions: QoderCOSYSignerOptions
    ) async throws -> QoderGatewayStream {
        streamFactory()
    }
}

/// Tiny box letting a background reader hand the received bytes to the test.
private actor ReceiveBox {
    private var bytes = Data()
    func store(_ data: Data) { bytes = data }
    func snapshot() -> Data { bytes }
}

/// Tracks the mock stream's lifecycle: the router peeks the first pull, the
/// pump blocks in the second pull, and `cancel()` must eventually fire.
/// Actor because the pull source is `async` and the cancel hook is `sync` —
/// `markCancelled` is reached via `Task { await spy.markCancelled() }`.
private actor PumpSpy {
    private var pulls = 0
    private var cancelledFlag = false

    /// Returns true for the first pull (the router's peek); the pump's own
    /// pulls get false.
    func claimFirstPull() -> Bool {
        pulls += 1
        return pulls == 1
    }

    func markCancelled() { cancelledFlag = true }

    /// Resolves once the second pull is entered — the point at which the pump
    /// is genuinely in-flight (the first pull is the router's peek).
    func waitForPumpStart() async throws {
        try await poll { pulls >= 2 }
    }

    func waitForCancellation() async throws {
        try await poll { cancelledFlag }
    }

    private func poll(_ ready: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(10)
        while !ready() {
            if Date() > deadline { throw TestTimeoutError() }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}
