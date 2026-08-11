//
//  QoderFailoverRouterTests.swift
//  QuotioTests
//
//  Phase 2a tests for the multi-account failover router (ticket #7). These are
//  the most important tests in Phase 2a: the rotation policy (ADR 0005 §3,
//  ADR 0006 §2) is the riskiest logic, and it must work without touching the
//  network.
//
//  The router's three collaborators are mocked:
//    - Gateway: returns a scripted sequence of (status, body) responses per
//      call, so a test can simulate 429 → 200, or 401 → 401 → 200 on the next
//      account, etc.
//    - Vault: an in-memory `MonitorCredentialStore` holding the test's
//      credentials and accounts.
//    - PAT refresher: returns a canned refreshed credential, or throws.
//
//  The metadata store is a real `MonitorMetadataStore` pointed at a temp URL,
//  so disable-state persists across calls within a test. Tests assert the
//  rotation policy via observable side effects (gateway call count, PAT
//  refresher call log, account disable state) rather than byte pumping,
//  because the router's job ends at "return a 2xx stream or throw."
//

import Foundation
import XCTest
@testable import Quotio

// MARK: - Test helpers

/// In-memory credential store for tests. Conforms to the production
/// `MonitorCredentialStore` protocol so the router can't tell it apart from
/// the real Keychain-backed vault.
private actor InMemoryCredentialStore: MonitorCredentialStore {
    private var credentials: [String: MonitorOAuthCredential] = [:]
    private var accountsList: [MonitorAccount] = []

    func seed(_ account: MonitorAccount, _ credential: MonitorOAuthCredential) {
        accountsList.append(account)
        credentials[account.id] = credential
    }

    func accounts() async -> [MonitorAccount] { accountsList }
    func credential(for accountID: String) async -> MonitorOAuthCredential? { credentials[accountID] }
    func reloadLatest(accountID: String) async -> MonitorOAuthCredential? { credentials[accountID] }
    func save(_ credential: MonitorOAuthCredential, metadata account: MonitorAccount) async throws {
        credentials[account.id] = credential
    }
    func delete(accountID: String) async {
        credentials.removeValue(forKey: accountID)
        accountsList.removeAll { $0.id == accountID }
    }
}

/// Mock PAT refresher. Records calls and returns a scripted result per account.
private actor MockPATRefresher: QoderPATRefreshing {
    /// Results to return, keyed by account ID. Each call pops one result; if a
    /// second call comes for the same account without re-seeding, the next
    /// entry is used (lets a test simulate "re-exchange succeeds" or "fails").
    private var results: [String: [Result<MonitorOAuthCredential, Error>]] = [:]
    /// Account IDs that were asked to refresh, in order. Tests assert on this.
    private(set) var callLog: [String] = []

    func seed(_ accountID: String, _ result: Result<MonitorOAuthCredential, Error>) {
        results[accountID, default: []].append(result)
    }

    func refreshCredential(
        _ credential: MonitorOAuthCredential,
        account: MonitorAccount
    ) async throws -> MonitorOAuthCredential {
        callLog.append(account.id)
        if var queue = results[account.id], !queue.isEmpty {
            let result = queue.removeFirst()
            results[account.id] = queue
            return try result.get()
        }
        // No scripted result — default to returning the credential unchanged,
        // so "happy path" tests don't have to seed this.
        return credential
    }
}

/// Mock gateway client. Returns scripted (status, body) sequences per call,
/// recording the credentials it was called with so tests can assert signing.
private actor MockGatewayClient: QoderGatewayClientProtocol {
    struct Response {
        let status: Int
        /// For 2xx, the bytes the pump yields to the caller. The router only
        /// hands the pump back for 2xx; non-2xx consumes status only.
        let body: Data
        /// Optional transport error to throw instead of returning a response.
        /// Used to test the transient-retry path.
        let transportError: Error?
        /// When true, the 2xx stream never yields a chunk (silent stall). Models
        /// the observed live behavior of a quota-exhausted account: HTTP 200 +
        /// headers, then no bytes. The router's peek timeout should fire and
        /// rotate. Mutually exclusive with a non-empty `body`.
        let stalls: Bool
        /// When non-empty, the 2xx stream yields each frame as a separate pull
        /// (one `Data` per call), modeling how the production chunker surfaces
        /// the first complete SSE frame on the first pull and the remainder on
        /// later pulls. Used by the gap #1 regression to prove a healthy
        /// slow-but-arriving first frame is NOT falsely classified as a stall.
        /// Mutually exclusive with `stalls` and a non-empty `body`.
        let trickle: [Data]
        /// Optional HTTP response headers. Used by the Retry-After test (issue
        /// #12) to feed a `Retry-After` value into the router's cooldown path
        /// — the production gateway surfaces headers via `HTTPURLResponse`, and
        /// so does this mock.
        let headerFields: [String: String]

        init(
            status: Int,
            body: Data = Data(),
            transportError: Error? = nil,
            stalls: Bool = false,
            trickle: [Data] = [],
            headerFields: [String: String] = [:]
        ) {
            self.status = status
            self.body = body
            self.transportError = transportError
            self.stalls = stalls
            self.trickle = trickle
            self.headerFields = headerFields
        }
    }

    /// Scripted responses, drained in order across all accounts.
    private var responses: [Response] = []
    private(set) var callCount = 0
    private(set) var receivedCredentials: [QoderCOSYCredentials] = []
    /// The translator-envelope bodies the router signed and shipped, in call
    /// order. Tests inspect these to assert the model the upstream sees.
    private(set) var receivedBodies: [Data] = []

    func seed(_ response: Response) {
        responses.append(response)
    }

    func seed(_ responses: [Response]) {
        self.responses.append(contentsOf: responses)
    }

    func openStream(
        body: Data,
        credentials: QoderCOSYCredentials,
        signerOptions: QoderCOSYSignerOptions
    ) async throws -> QoderGatewayStream {
        callCount += 1
        receivedCredentials.append(credentials)
        receivedBodies.append(body)
        let response: Response
        if !responses.isEmpty {
            response = responses.removeFirst()
        } else {
            // Default: 200 empty stream if a test forgot to script.
            response = Response(status: 200, body: Data(), transportError: nil)
        }
        if let error = response.transportError {
            throw QoderGatewayError.network(error.localizedDescription)
        }
        let http = HTTPURLResponse(
            url: qoderChatGatewayURL,
            statusCode: response.status,
            httpVersion: "HTTP/1.1",
            headerFields: response.headerFields.isEmpty ? nil : response.headerFields
        )!
        let bodyData = response.body
        // A stalled response never yields (silent stall) — the router's peek
        // timeout must fire and rotate. We block on an indefinite `Task.sleep`
        // (the router cancels the peek via its task-group timeout after 2s).
        // Plain `try` (not `try?`): the cancellation throws `CancellationError`,
        // modeling production `AsyncBytes.Iterator.next()` which propagates
        // cancellation. This keeps the mock faithful to the real wire behavior
        // (a stall genuinely cancels a throw, not a swallowed return). The
        // router's peek absorbs the cancellation defensively; even though
        // SE-0304 discards post-return child errors today, the mock exercising
        // the throw path guards against a future refactor that consumes it.
        if response.stalls {
            return QoderGatewayStream(response: http) { () -> Data? in
                try await Task.sleep(nanoseconds: 60 * 1_000_000_000)
                return nil
            }
        }
        // Trickle mode: yield each frame as its own pull. Models the production
        // chunker's first-pull frame-boundary flush + subsequent bulk pulls.
        if !response.trickle.isEmpty {
            let box = MockTrickleBox(response.trickle)
            return QoderGatewayStream(response: http) { () -> Data? in
                await box.next()
            }
        }
        // Yield the scripted body in one pull, then nil (stream end). The router
        // peeks the first chunk via `nextChunk`; ProxyBridge drives the
        // remainder via `pump`. A single pull source models "whole body in one
        // chunk" — the router's peek consumes it, and the remainder pump sees
        // nil immediately. Tests don't need streaming realism; the reparser
        // tests exercise byte pumping separately. The `yielded` flag lives in a
        // Sendable box so the `@Sendable` pull source can mutate it (mirrors the
        // production `AsyncBytesBox` pattern).
        let box = MockYieldBox()
        return QoderGatewayStream(response: http) { () -> Data? in
            if box.consume() || bodyData.isEmpty { return nil }
            return bodyData
        }
    }
}

/// One-shot Sendable flag for the mock gateway's pull source: returns true
/// once (the first pull), false thereafter. Models "yield the scripted body in
/// one chunk, then stream end." Mirrors the production `AsyncBytesBox`
/// single-owner pattern.
private final class MockYieldBox: @unchecked Sendable {
    private var consumed = false
    func consume() -> Bool {
        if consumed { return true }
        consumed = true
        return false
    }
}

/// Sendable box for trickle mode: yields each scripted frame in order across
/// pulls, then nil at stream end. `actor` so the `@Sendable` pull closure can
/// mutate `index` safely.
private actor MockTrickleBox {
    private let frames: [Data]
    private var index = 0

    init(_ frames: [Data]) { self.frames = frames }

    func next() -> Data? {
        guard index < frames.count else { return nil }
        defer { index += 1 }
        return frames[index]
    }
}

// MARK: - Tests

final class QoderFailoverRouterTests: XCTestCase {

    // MARK: - Fixtures

    private func makeCredential(
        accountID: String,
        token: String = "jt-active",
        machineID: String = "machine-1",
        pat: String = "pt-test",
        expiresAt: Date = Date().addingTimeInterval(3600)
    ) -> MonitorOAuthCredential {
        MonitorOAuthCredential(
            accessToken: token,
            refreshToken: nil,
            idToken: nil,
            accountID: accountID,
            expiresAt: expiresAt,
            extra: ["pat": pat, "machineID": machineID]
        )
    }

    private func makeAccount(key: String) -> MonitorAccount {
        MonitorAccount.make(
            provider: .qoder,
            accountKey: key,
            displayName: key,
            source: .quotioKeychain
        )
    }

    private func makeBody(model: String = "qoder/auto") -> Data {
        let json: [String: Any] = [
            "model": model,
            "stream": true,
            "messages": [["role": "user", "content": "hi"]],
        ]
        return try! JSONSerialization.data(withJSONObject: json)
    }

    private func makeRouter(
        vault: InMemoryCredentialStore,
        pat: MockPATRefresher,
        gateway: MockGatewayClient,
        metadata: MonitorMetadataStore,
        configuration: QoderFailoverRouterConfiguration = .default,
        translatorLimits: QoderTranslatorLimits = .default
    ) -> QoderFailoverRouter {
        QoderFailoverRouter(
            vault: vault,
            metadata: metadata,
            patService: pat,
            gateway: gateway,
            configuration: configuration,
            translatorLimits: translatorLimits
        )
    }

    private func makeMetadataStore() -> MonitorMetadataStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("qoder-router-test-\(UUID().uuidString).json")
        return MonitorMetadataStore(url: url)
    }

    // MARK: - Pre-stream rejections (HTTP 400 mapping)

    func testRejectsMissingProxyAPIKey() async throws {
        let vault = InMemoryCredentialStore()
        let router = makeRouter(
            vault: vault,
            pat: MockPATRefresher(),
            gateway: MockGatewayClient(),
            metadata: makeMetadataStore()
        )
        do {
            _ = try await router.openStream(requestBody: makeBody(), proxyAPIKey: "")
            XCTFail("expected missingProxyAPIKey")
        } catch let error as QoderFailoverError {
            if case .missingProxyAPIKey = error {} else {
                XCTFail("expected missingProxyAPIKey, got \(error)")
            }
        }
    }

    func testRejectsNoAccountsAvailable() async throws {
        let vault = InMemoryCredentialStore()
        let router = makeRouter(
            vault: vault,
            pat: MockPATRefresher(),
            gateway: MockGatewayClient(),
            metadata: makeMetadataStore()
        )
        do {
            _ = try await router.openStream(requestBody: makeBody(), proxyAPIKey: "key")
            XCTFail("expected noAccountsAvailable")
        } catch let error as QoderFailoverError {
            if case .noAccountsAvailable = error {} else {
                XCTFail("expected noAccountsAvailable, got \(error)")
            }
        }
    }

    // MARK: - Tier 2 translator caps surfacing (issue #14)

    /// End-to-end: a translator Tier 2 cap rejection (byte-size → 413) flows
    /// through the router's `attempt` catch as `QoderFailoverError.requestRejected`
    /// carrying the translator's 413 status, which ProxyBridge forwards. Uses
    /// tight injected limits so the test body is tiny. This is the contract
    /// proof that the catch path (not just the translator in isolation)
    /// surfaces the right status.
    func testTranslatorImageSizeCapSurfacesAs413() async throws {
        let vault = InMemoryCredentialStore()
        let account = makeAccount(key: "primary@example.com")
        await vault.seed(account, makeCredential(accountID: account.id))
        let gateway = MockGatewayClient()  // never reached — translator rejects first
        let router = makeRouter(
            vault: vault, pat: MockPATRefresher(), gateway: gateway,
            metadata: makeMetadataStore(),
            translatorLimits: QoderTranslatorLimits(
                maxMessages: 500, maxImageBytes: 100, maxTools: 128, maxToolSchemaBytes: 1024
            )
        )
        // One over-cap image (101 decoded bytes > 100-byte cap).
        let payload = Data(repeating: 0x41, count: 101).base64EncodedString()
        let body: [String: Any] = [
            "model": "qoder/auto",
            "stream": true,
            "messages": [[
                "role": "user",
                "content": [["type": "image_url", "image_url": ["url": "data:image/png;base64,\(payload)"]]],
            ] as [String: Any]],
        ]
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        do {
            _ = try await router.openStream(requestBody: bodyData, proxyAPIKey: "key")
            XCTFail("expected requestRejected")
        } catch let error as QoderFailoverError {
            guard case .requestRejected(_, let status) = error else {
                return XCTFail("expected requestRejected, got \(error)")
            }
            XCTAssertEqual(status, 413, "image-size cap must surface as 413, got \(status)")
        }
        // The gateway was never called — the translator rejected pre-stream.
        let callCount = await gateway.callCount
        XCTAssertEqual(callCount, 0, "translator cap must reject before any gateway call")
    }

    /// End-to-end: a translator count cap (messages → 400) surfaces as 400.
    func testTranslatorMessageCountCapSurfacesAs400() async throws {
        let vault = InMemoryCredentialStore()
        let account = makeAccount(key: "primary@example.com")
        await vault.seed(account, makeCredential(accountID: account.id))
        let gateway = MockGatewayClient()
        let router = makeRouter(
            vault: vault, pat: MockPATRefresher(), gateway: gateway,
            metadata: makeMetadataStore(),
            translatorLimits: QoderTranslatorLimits(
                maxMessages: 1, maxImageBytes: 1024, maxTools: 128, maxToolSchemaBytes: 1024
            )
        )
        // Two user messages > 1-message cap.
        let body: [String: Any] = [
            "model": "qoder/auto",
            "stream": true,
            "messages": [
                ["role": "user", "content": "a"],
                ["role": "user", "content": "b"],
            ],
        ]
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        do {
            _ = try await router.openStream(requestBody: bodyData, proxyAPIKey: "key")
            XCTFail("expected requestRejected")
        } catch let error as QoderFailoverError {
            guard case .requestRejected(_, let status) = error else {
                return XCTFail("expected requestRejected, got \(error)")
            }
            XCTAssertEqual(status, 400, "message-count cap must surface as 400, got \(status)")
        }
        let callCount = await gateway.callCount
        XCTAssertEqual(callCount, 0, "translator cap must reject before any gateway call")
    }

    // MARK: - Non-rotatable upstream status surfacing (issue #14 S2)

    /// A non-rotatable 4xx from the gateway (e.g. 413) surfaces with the real
    /// status, not the historical hard-coded 400. Guards the S2 fix: the
    /// default-arm `requestRejected` must pass `status` through.
    func testNonRotatable413FromGatewaySurfacesAs413() async throws {
        let vault = InMemoryCredentialStore()
        let account = makeAccount(key: "primary@example.com")
        await vault.seed(account, makeCredential(accountID: account.id))
        let gateway = MockGatewayClient()
        await gateway.seed(.init(status: 413, body: Data()))
        let router = makeRouter(
            vault: vault, pat: MockPATRefresher(), gateway: gateway,
            metadata: makeMetadataStore()
        )
        do {
            _ = try await router.openStream(requestBody: makeBody(), proxyAPIKey: "key")
            XCTFail("expected requestRejected")
        } catch let error as QoderFailoverError {
            guard case .requestRejected(_, let status) = error else {
                return XCTFail("expected requestRejected, got \(error)")
            }
            XCTAssertEqual(status, 413, "gateway 413 must surface as 413, not collapsed to 400")
        }
    }

    /// A non-rotatable 422 surfaces as 422 (spot-check a second non-429/401/403
    /// status to confirm the pass-through is general, not 413-specific).
    func testNonRotatable422FromGatewaySurfacesAs422() async throws {
        let vault = InMemoryCredentialStore()
        let account = makeAccount(key: "primary@example.com")
        await vault.seed(account, makeCredential(accountID: account.id))
        let gateway = MockGatewayClient()
        await gateway.seed(.init(status: 422, body: Data()))
        let router = makeRouter(
            vault: vault, pat: MockPATRefresher(), gateway: gateway,
            metadata: makeMetadataStore()
        )
        do {
            _ = try await router.openStream(requestBody: makeBody(), proxyAPIKey: "key")
            XCTFail("expected requestRejected")
        } catch let error as QoderFailoverError {
            guard case .requestRejected(_, let status) = error else {
                return XCTFail("expected requestRejected, got \(error)")
            }
            XCTAssertEqual(status, 422)
        }
    }

    // MARK: - Stream intent (issue #9, ADR 0014)

    /// `QoderOpenedStream.streamRequested` must reflect the client's `stream`
    /// field per the OpenAI spec default: missing or `false` → non-streaming,
    /// only explicit `true` → streaming. None of these are rejected; the
    /// gateway stream opens normally and ProxyBridge branches on the flag.
    func testCarriesStreamIntent() async throws {
        // Three cases in one test: each opens a fresh stream with a different
        // `stream` field shape. Inlined (not a helper closure) so this test's
        // `self` helper calls stay synchronous under Swift 6 sending checks.
        let vault = InMemoryCredentialStore()
        let account = makeAccount(key: "user@example.com")
        await vault.seed(account, makeCredential(accountID: account.id))

        // Case 1: explicit `stream: true` → streaming.
        let gwTrue = MockGatewayClient()
        await gwTrue.seed(.init(status: 200, body: Data("data: [DONE]\n\n".utf8)))
        let routerTrue = makeRouter(vault: vault, pat: MockPATRefresher(), gateway: gwTrue, metadata: makeMetadataStore())
        let bodyTrue = try JSONSerialization.data(withJSONObject: [
            "model": "qoder/auto", "stream": true,
            "messages": [["role": "user", "content": "hi"]],
        ])
        let openedTrue = try await routerTrue.openStream(requestBody: bodyTrue, proxyAPIKey: "key")
        XCTAssertTrue(openedTrue.streamRequested, "stream:true must be streaming")

        // Case 2: explicit `stream: false` → non-streaming (previously rejected; issue #9).
        let gwFalse = MockGatewayClient()
        await gwFalse.seed(.init(status: 200, body: Data("data: [DONE]\n\n".utf8)))
        let routerFalse = makeRouter(vault: vault, pat: MockPATRefresher(), gateway: gwFalse, metadata: makeMetadataStore())
        let bodyFalse = try JSONSerialization.data(withJSONObject: [
            "model": "qoder/auto", "stream": false,
            "messages": [["role": "user", "content": "hi"]],
        ])
        let openedFalse = try await routerFalse.openStream(requestBody: bodyFalse, proxyAPIKey: "key")
        XCTAssertFalse(openedFalse.streamRequested, "stream:false must be non-streaming")

        // Case 3: missing `stream` → non-streaming (OpenAI spec default is
        // `false`; previously mis-defaulted to streaming).
        let gwMissing = MockGatewayClient()
        await gwMissing.seed(.init(status: 200, body: Data("data: [DONE]\n\n".utf8)))
        let routerMissing = makeRouter(vault: vault, pat: MockPATRefresher(), gateway: gwMissing, metadata: makeMetadataStore())
        let bodyMissing = try JSONSerialization.data(withJSONObject: [
            "model": "qoder/auto",
            "messages": [["role": "user", "content": "hi"]],
        ])
        let openedMissing = try await routerMissing.openStream(requestBody: bodyMissing, proxyAPIKey: "key")
        XCTAssertFalse(openedMissing.streamRequested, "missing stream must be non-streaming (OpenAI default)")
    }

    // MARK: - Happy path: first account, first attempt

    func testSucceedsOnFirstAccountFirstAttempt() async throws {
        let vault = InMemoryCredentialStore()
        let account = makeAccount(key: "primary@example.com")
        await vault.seed(account, makeCredential(accountID: account.id))
        let gateway = MockGatewayClient()
        await gateway.seed(.init(status: 200, body: Data("data: [DONE]\n\n".utf8)))
        let pat = MockPATRefresher()
        let router = makeRouter(
            vault: vault, pat: pat, gateway: gateway,
            metadata: makeMetadataStore()
        )

        let opened = try await router.openStream(requestBody: makeBody(), proxyAPIKey: "key")
        XCTAssertEqual(opened.accountID, account.id)
        let callCount = await gateway.callCount
        XCTAssertEqual(callCount, 1, "first account attempted exactly once on success")
        let refreshCalls = await pat.callLog
        XCTAssertTrue(refreshCalls.isEmpty, "no PAT refresh on a clean 200")
    }

    // MARK: - 429 → cooldown + rotate

    func test429RotatesToNextAccount() async throws {
        let vault = InMemoryCredentialStore()
        let primary = makeAccount(key: "primary@example.com")
        let secondary = makeAccount(key: "secondary@example.com")
        await vault.seed(primary, makeCredential(accountID: primary.id, token: "jt-primary"))
        await vault.seed(secondary, makeCredential(accountID: secondary.id, token: "jt-secondary"))
        let gateway = MockGatewayClient()
        // primary 429, secondary 200.
        await gateway.seed([
            .init(status: 429),
            .init(status: 200, body: Data("data: [DONE]\n\n".utf8)),
        ])
        let router = makeRouter(
            vault: vault, pat: MockPATRefresher(), gateway: gateway,
            metadata: makeMetadataStore()
        )

        let opened = try await router.openStream(requestBody: makeBody(), proxyAPIKey: "key")
        XCTAssertEqual(opened.accountID, secondary.id, "should rotate to secondary after 429")
        let callCount = await gateway.callCount
        XCTAssertEqual(callCount, 2, "two attempts: primary (429) then secondary (200)")

        // Cooldown applied: a second request should skip the cooled-down
        // primary and go straight to secondary.
        await gateway.seed(.init(status: 200, body: Data("data: [DONE]\n\n".utf8)))
        let opened2 = try await router.openStream(requestBody: makeBody(), proxyAPIKey: "key")
        XCTAssertEqual(opened2.accountID, secondary.id, "primary should be in cooldown")
    }

    // MARK: - Quota exhausted: HTTP 200 with non-2xx inside the stream

    // Regression for the reported bug: "doesn't switch to other qoder account
    // even when the current account quota is full (100%)". Observed against the
    // live gateway with three 100%-quota accounts: the gateway returns HTTP 200
    // + the SSE response head, and the quota-exhaustion signal arrives *inside*
    // the stream — either as an envelope with `statusCodeValue != 200`, or as
    // a silent stall where the first SSE frame never carries chat content. The
    // router currently treats any HTTP 2xx as success at `openStream` time and
    // hands the stream to ProxyBridge; ProxyBridge then either trips the
    // reparser's `statusCodeValue` gate (→ mid-stream abort, no rotation) or
    // blocks forever on a pump that never yields content (→ agent timeout).
    //
    // The two tests below model both observed failure shapes. They are RED
    // today and document the gap; the fix makes the router detect quota
    // exhaustion on the *first* SSE chunk (before any byte reaches the agent)
    // and rotate instead of handing off.

    /// Shape 1: HTTP 200, but the first streamed SSE frame's envelope carries
    /// `statusCodeValue: 429`. The router must rotate to the next account
    /// instead of handing a 200-quota-error stream to the agent.
    func testQuotaExhaustedInEnvelopeRotatesToNextAccount() async throws {
        let vault = InMemoryCredentialStore()
        let primary = makeAccount(key: "primary@example.com")
        let secondary = makeAccount(key: "secondary@example.com")
        await vault.seed(primary, makeCredential(accountID: primary.id, token: "jt-primary"))
        await vault.seed(secondary, makeCredential(accountID: secondary.id, token: "jt-secondary"))

        // Primary: HTTP 200, but the streamed SSE frame is a quota-exhaustion
        // envelope. Secondary: HTTP 200 with a clean `[DONE]`.
        let quotaEnvelope = """
        data: {"statusCodeValue":429,"body":"\\"quota exceeded\\""}

        """.data(using: .utf8)!

        let gateway = MockGatewayClient()
        await gateway.seed([
            .init(status: 200, body: quotaEnvelope),
            .init(status: 200, body: Data("data: [DONE]\n\n".utf8)),
        ])
        let router = makeRouter(
            vault: vault, pat: MockPATRefresher(), gateway: gateway,
            metadata: makeMetadataStore()
        )

        let opened = try await router.openStream(requestBody: makeBody(), proxyAPIKey: "key")
        XCTAssertEqual(opened.accountID, secondary.id, "should rotate to secondary after in-envelope 429")
        let callCount = await gateway.callCount
        XCTAssertEqual(callCount, 2, "two attempts: primary (envelope-429) then secondary (200)")
    }

    /// Shape 2 (the live symptom): HTTP 200 + SSE headers, then the gateway
    /// never yields a content frame — the agent blocks until its read timeout.
    /// Observed against a real 100%-quota account ("ss aa"). The router's peek
    /// must time out (2s) and rotate to the next account instead of handing
    /// off a stalled stream.
    func testSilentStallRotatesToNextAccount() async throws {
        let vault = InMemoryCredentialStore()
        let primary = makeAccount(key: "primary@example.com")
        let secondary = makeAccount(key: "secondary@example.com")
        await vault.seed(primary, makeCredential(accountID: primary.id, token: "jt-primary"))
        await vault.seed(secondary, makeCredential(accountID: secondary.id, token: "jt-secondary"))

        let gateway = MockGatewayClient()
        await gateway.seed([
            .init(status: 200, stalls: true),  // primary: 200 then silence
            .init(status: 200, body: Data("data: [DONE]\n\n".utf8)),  // secondary: clean
        ])
        let router = makeRouter(
            vault: vault, pat: MockPATRefresher(), gateway: gateway,
            metadata: makeMetadataStore()
        )

        let opened = try await router.openStream(requestBody: makeBody(), proxyAPIKey: "key")
        XCTAssertEqual(opened.accountID, secondary.id, "should rotate to secondary after a silent stall on primary")
        let callCount = await gateway.callCount
        XCTAssertEqual(callCount, 2, "two attempts: primary (stall) then secondary (200)")
    }

    // MARK: - Silent stall two-strike threshold (issue #12)

    /// Regression for issue #12: a single silent stall must rotate to the next
    /// account for request progress, but must NOT cool the stalled account
    /// down. A slow-but-healthy first frame (cold model load, network delay) is
    /// indistinguishable from a genuine stall at this layer; cooling on a
    /// single occurrence was false-cooling healthy accounts. The default
    /// threshold is 2: one stall rotates without cooling; only a second
    /// consecutive stall applies cooldown.
    ///
    /// This test exercises the default-threshold path: primary stalls once,
    /// rotates to secondary (clean). The next request must still consider
    /// primary eligible (no cooldown was applied) — primary returns a clean
    /// 200 and is served, which also resets its strike counter.
    func testSingleSilentStallRotatesButDoesNotCoolDown() async throws {
        let vault = InMemoryCredentialStore()
        let primary = makeAccount(key: "primary@example.com")
        let secondary = makeAccount(key: "secondary@example.com")
        await vault.seed(primary, makeCredential(accountID: primary.id, token: "jt-primary"))
        await vault.seed(secondary, makeCredential(accountID: secondary.id, token: "jt-secondary"))

        let gateway = MockGatewayClient()
        let router = makeRouter(
            vault: vault, pat: MockPATRefresher(), gateway: gateway,
            metadata: makeMetadataStore()
        )

        // Request 1: primary stalls, secondary serves. Primary is rotated-to-
        // next but NOT cooled (single strike below the default threshold of 2).
        await gateway.seed([
            .init(status: 200, stalls: true),
            .init(status: 200, body: Data("data: [DONE]\n\n".utf8)),
        ])
        let opened1 = try await router.openStream(requestBody: makeBody(), proxyAPIKey: "key")
        XCTAssertEqual(opened1.accountID, secondary.id, "should rotate to secondary after the stall")

        // Request 2: primary must still be a candidate (no cooldown applied).
        // First-enabled ordering means primary is tried first; a clean 200
        // here also proves the strike counter was healthy enough to retry.
        await gateway.seed(.init(status: 200, body: Data("data: [DONE]\n\n".utf8)))
        let opened2 = try await router.openStream(requestBody: makeBody(), proxyAPIKey: "key")
        XCTAssertEqual(
            opened2.accountID, primary.id,
            "primary must NOT be in cooldown after a single silent stall (issue #12)"
        )
    }

    /// Companion to the regression above: once the consecutive-stall threshold
    /// is reached, the account IS cooled. Uses `silentStallStrikeThreshold: 1`
    /// so a single stall trips the threshold — this keeps the test to one ~2s
    /// peek (the default threshold of 2 would need two peeks = ~4s).
    func testRepeatedSilentStallsApplyCooldown() async throws {
        let vault = InMemoryCredentialStore()
        let primary = makeAccount(key: "primary@example.com")
        let secondary = makeAccount(key: "secondary@example.com")
        await vault.seed(primary, makeCredential(accountID: primary.id, token: "jt-primary"))
        await vault.seed(secondary, makeCredential(accountID: secondary.id, token: "jt-secondary"))

        let gateway = MockGatewayClient()
        // Threshold 1: the first stall trips the threshold and cools primary.
        let router = makeRouter(
            vault: vault, pat: MockPATRefresher(), gateway: gateway,
            metadata: makeMetadataStore(),
            configuration: QoderFailoverRouterConfiguration(silentStallStrikeThreshold: 1)
        )

        // Request 1: primary stalls → threshold reached → cooled → rotate to
        // secondary (clean).
        await gateway.seed([
            .init(status: 200, stalls: true),
            .init(status: 200, body: Data("data: [DONE]\n\n".utf8)),
        ])
        let opened1 = try await router.openStream(requestBody: makeBody(), proxyAPIKey: "key")
        XCTAssertEqual(opened1.accountID, secondary.id)

        // Request 2: primary is now in cooldown → secondary is served. The
        // default cooldownTTL (60s) is far longer than this test's wall clock,
        // so the cooldown is observably in effect without any sleep.
        await gateway.seed(.init(status: 200, body: Data("data: [DONE]\n\n".utf8)))
        let opened2 = try await router.openStream(requestBody: makeBody(), proxyAPIKey: "key")
        XCTAssertEqual(
            opened2.accountID, secondary.id,
            "primary must be in cooldown once the stall threshold is reached"
        )
    }

    // MARK: - Retry-After honored (issue #12)

    /// A 429 carrying a `Retry-After: <seconds>` header must cool the account
    /// for that long, clamped to `[cooldownTTL, retryAfterCeiling]`. This test
    /// makes the honor-vs-ignore distinction observable: `cooldownTTL` is the
    /// fallback AND the floor, set to 0.1s; `Retry-After: 5` would, if honored,
    /// keep primary out for ~5s. After sleeping 0.3s (well past the 0.1s
    /// fallback but far inside the honored 5s window), primary must STILL be
    /// skipped — which is only true if the header was honored. If Retry-After
    /// were ignored, the 0.1s fallback would have elapsed and primary would be
    /// re-served.
    func test429RetryAfterExtendsCooldownBeyondDefault() async throws {
        let vault = InMemoryCredentialStore()
        let primary = makeAccount(key: "primary@example.com")
        let secondary = makeAccount(key: "secondary@example.com")
        await vault.seed(primary, makeCredential(accountID: primary.id, token: "jt-primary"))
        await vault.seed(secondary, makeCredential(accountID: secondary.id, token: "jt-secondary"))

        let gateway = MockGatewayClient()
        let router = makeRouter(
            vault: vault, pat: MockPATRefresher(), gateway: gateway,
            metadata: makeMetadataStore(),
            // cooldownTTL is the cooldown floor AND the no-header fallback.
            // 0.1s is short enough that the 0.3s sleep below clears the
            // fallback but NOT the honored Retry-After: 5 window.
            configuration: QoderFailoverRouterConfiguration(cooldownTTL: 0.1)
        )

        // Request 1: primary 429 with Retry-After: 5 → cooled for ~5s, rotate
        // to secondary (clean).
        await gateway.seed([
            .init(status: 429, headerFields: ["Retry-After": "5"]),
            .init(status: 200, body: Data("data: [DONE]\n\n".utf8)),
        ])
        let opened1 = try await router.openStream(requestBody: makeBody(), proxyAPIKey: "key")
        XCTAssertEqual(opened1.accountID, secondary.id)

        // Sleep past the 0.1s fallback but well inside the honored 5s window.
        // 0.3s gives 3x margin over the 0.1s fallback to avoid CI flake while
        // staying far below the 5s honored duration.
        try await Task.sleep(nanoseconds: 300_000_000)  // 0.3s

        // Request 2: primary must STILL be cooled — only true if Retry-After
        // was honored (the 0.1s fallback has elapsed by now).
        await gateway.seed(.init(status: 200, body: Data("data: [DONE]\n\n".utf8)))
        let opened2 = try await router.openStream(requestBody: makeBody(), proxyAPIKey: "key")
        XCTAssertEqual(
            opened2.accountID, secondary.id,
            "Retry-After: 5 must keep primary in cooldown past the 0.1s fallback window"
        )
    }

    /// The `Retry-After` value is clamped to `retryAfterCeiling`. With
    /// `Retry-After: 9999` and `retryAfterCeiling: 0.2`, the cooldown is clamped
    /// to ~0.2s. After sleeping 0.4s (past the clamped 0.2s ceiling but far
    /// inside the raw 9999s), primary must be ELIGIBLE again — which is only
    /// true if the ceiling was applied. If the raw 9999s were used, primary
    /// would still be cooled.
    func test429RetryAfterIsClampedToCeiling() async throws {
        let vault = InMemoryCredentialStore()
        let primary = makeAccount(key: "primary@example.com")
        let secondary = makeAccount(key: "secondary@example.com")
        await vault.seed(primary, makeCredential(accountID: primary.id, token: "jt-primary"))
        await vault.seed(secondary, makeCredential(accountID: secondary.id, token: "jt-secondary"))

        let gateway = MockGatewayClient()
        let router = makeRouter(
            vault: vault, pat: MockPATRefresher(), gateway: gateway,
            metadata: makeMetadataStore(),
            // cooldownTTL: 0.05 is the floor; retryAfterCeiling: 0.2 is the
            // load-bearing clamp. A raw Retry-After: 9999 would be used as-is
            // if the ceiling weren't applied.
            configuration: QoderFailoverRouterConfiguration(
                cooldownTTL: 0.05,
                retryAfterCeiling: 0.2
            )
        )

        // Primary 429 with an absurd Retry-After: 9999 → clamped to 0.2s
        // ceiling.
        await gateway.seed([
            .init(status: 429, headerFields: ["Retry-After": "9999"]),
            .init(status: 200, body: Data("data: [DONE]\n\n".utf8)),
        ])
        let opened1 = try await router.openStream(requestBody: makeBody(), proxyAPIKey: "key")
        XCTAssertEqual(opened1.accountID, secondary.id)

        // Sleep past the clamped 0.2s ceiling (0.4s = 2x margin) but far
        // inside the raw 9999s. If the ceiling were not applied, primary would
        // still be cooled here.
        try await Task.sleep(nanoseconds: 400_000_000)  // 0.4s

        // Request 2: primary must be eligible again — only true if the ceiling
        // clamped the 9999s down to ~0.2s.
        await gateway.seed(.init(status: 200, body: Data("data: [DONE]\n\n".utf8)))
        let opened2 = try await router.openStream(requestBody: makeBody(), proxyAPIKey: "key")
        XCTAssertEqual(
            opened2.accountID, primary.id,
            "Retry-After: 9999 must be clamped to the 0.2s ceiling so primary re-enters rotation"
        )
    }

    /// When a 429 carries no `Retry-After` (or an unparseable one), the router
    /// falls back to the default cooldown. Regression guard for the fallback
    /// path so the Retry-After wiring can't accidentally over-cool every 429.
    /// Uses cooldownTTL: 0.5s (not the prior flake-prone 0.05s) so the in-
    /// cooldown assertion has a comfortable margin, then sleeps 0.7s to confirm
    /// the cooldown clears.
    func test429WithoutRetryAfterUsesDefaultCooldown() async throws {
        let vault = InMemoryCredentialStore()
        let primary = makeAccount(key: "primary@example.com")
        let secondary = makeAccount(key: "secondary@example.com")
        await vault.seed(primary, makeCredential(accountID: primary.id, token: "jt-primary"))
        await vault.seed(secondary, makeCredential(accountID: secondary.id, token: "jt-secondary"))

        let gateway = MockGatewayClient()
        let router = makeRouter(
            vault: vault, pat: MockPATRefresher(), gateway: gateway,
            metadata: makeMetadataStore(),
            // 0.5s default: long enough that the in-cooldown assertion below is
            // not flake-prone, short enough that the clearing sleep stays
            // bounded. Avoids the prior 0.05s TTL where the immediate follow-up
            // could race the cooldown.
            configuration: QoderFailoverRouterConfiguration(cooldownTTL: 0.5)
        )

        // No Retry-After header → default cooldown (0.5s) applies.
        await gateway.seed([
            .init(status: 429),
            .init(status: 200, body: Data("data: [DONE]\n\n".utf8)),
        ])
        let opened1 = try await router.openStream(requestBody: makeBody(), proxyAPIKey: "key")
        XCTAssertEqual(opened1.accountID, secondary.id)

        // Immediate follow-up: primary is still cooled (the 0.5s default hasn't
        // elapsed). This proves the fallback path applies a cooldown even
        // without Retry-After.
        await gateway.seed(.init(status: 200, body: Data("data: [DONE]\n\n".utf8)))
        let opened2 = try await router.openStream(requestBody: makeBody(), proxyAPIKey: "key")
        XCTAssertEqual(opened2.accountID, secondary.id, "default cooldown applies when Retry-After is absent")

        // After the 0.5s default elapses, primary is eligible again. 0.7s gives
        // a 0.2s margin over the 0.5s TTL to avoid CI timing flake.
        try await Task.sleep(nanoseconds: 700_000_000)  // 0.7s
        await gateway.seed(.init(status: 200, body: Data("data: [DONE]\n\n".utf8)))
        let opened3 = try await router.openStream(requestBody: makeBody(), proxyAPIKey: "key")
        XCTAssertEqual(opened3.accountID, primary.id, "primary eligible again after the short default cooldown elapses")
    }

    // MARK: - Healthy slow first byte must NOT falsely rotate (gap #1)

    /// Gap #1 regression: a healthy account whose first SSE frame is small (well
    /// under 8KB) must surface to the router's peek and be accepted — NOT
    /// falsely classified as a silent stall. Pre-fix, the production chunker
    /// buffered the first pull to 8KB, so a small first frame stayed invisible
    /// to the peek until 8KB accumulated; combined with the 2s peek timeout,
    /// healthy slow-first-byte requests (reasoning models, long context — TTFT
    /// routinely 2-11s) were mis-rotated to `.quota`. The fix flushes the first
    /// pull at the SSE frame boundary, so the peek sees the frame immediately.
    ///
    /// This models the gateway as the production chunker now sees it: the first
    /// complete SSE frame arrives as the first pull (small), then the remainder.
    /// The router should accept primary on the first attempt (callCount = 1).
    func testHealthyFirstFrameDoesNotFalselyRotate() async throws {
        let vault = InMemoryCredentialStore()
        let primary = makeAccount(key: "primary@example.com")
        let secondary = makeAccount(key: "secondary@example.com")
        await vault.seed(primary, makeCredential(accountID: primary.id, token: "jt-primary"))
        await vault.seed(secondary, makeCredential(accountID: secondary.id, token: "jt-secondary"))

        // A small healthy opening frame (~80 bytes, far below 8KB) carrying a
        // status-200 envelope, then the closing [DONE] frame. The router's peek
        // must see the first frame as a clean chunk and hand off — not rotate.
        let openingFrame = """
        data: {"statusCodeValue":200,"body":"{\\"id\\":\\"test\\",\\"model\\":\\"qoder/auto\\"}"}

        """.data(using: .utf8)!
        let gateway = MockGatewayClient()
        await gateway.seed([
            .init(status: 200, trickle: [openingFrame, Data("data: [DONE]\n\n".utf8)]),
        ])
        let router = makeRouter(
            vault: vault, pat: MockPATRefresher(), gateway: gateway,
            metadata: makeMetadataStore()
        )

        let opened = try await router.openStream(requestBody: makeBody(), proxyAPIKey: "key")
        XCTAssertEqual(opened.accountID, primary.id, "healthy first frame should be accepted, not rotated away")
        let callCount = await gateway.callCount
        XCTAssertEqual(callCount, 1, "should not attempt the secondary — primary was healthy")
    }

    // MARK: - All accounts exhausted → throw

    /// When all accounts return 429 (rate-limited on the chat path), the
    /// router now throws `.allAccountsCoolingDown` (HTTP 429 + Retry-After),
    /// not `.noAccountsAvailable` (HTTP 503). The 503 was wrong for a self-
    /// healing condition: OpenAI agents won't auto-back-off a 503, and the
    /// `server_error` body type gave no retry hint. A 429 with a `Retry-After`
    /// header and `rate_limit_error` body lets the agent wait and retry.
    func testAllAccounts429ThrowsAllAccountsCoolingDown() async throws {
        let vault = InMemoryCredentialStore()
        let a = makeAccount(key: "a@example.com")
        let b = makeAccount(key: "b@example.com")
        await vault.seed(a, makeCredential(accountID: a.id))
        await vault.seed(b, makeCredential(accountID: b.id))
        let gateway = MockGatewayClient()
        await gateway.seed([.init(status: 429), .init(status: 429)])
        let router = makeRouter(
            vault: vault, pat: MockPATRefresher(), gateway: gateway,
            metadata: makeMetadataStore()
        )
        do {
            _ = try await router.openStream(requestBody: makeBody(), proxyAPIKey: "key")
            XCTFail("expected allAccountsCoolingDown after all accounts 429")
        } catch let error as QoderFailoverError {
            guard case .allAccountsCoolingDown(let retryAfter) = error else {
                return XCTFail("expected .allAccountsCoolingDown, got \(error)")
            }
            XCTAssertNotNil(retryAfter, "Retry-After must be populated when accounts are cooling")
            XCTAssertGreaterThan(retryAfter ?? 0, 0, "Retry-After must be positive")
            XCTAssertEqual(error.httpStatus, 429, "429 case must map to HTTP 429, not 503")
        }
        let callCount = await gateway.callCount
        XCTAssertEqual(callCount, 2, "each account attempted once")
    }

    /// When all accounts are persistently *disabled* (revoked PAT, not just
    /// rate-limited), the router must still throw `.noAccountsAvailable`
    /// (HTTP 503), NOT `.allAccountsCoolingDown` (429). A 429 would make the
    /// agent retry forever against accounts that need human intervention.
    /// This guards the classifier in `exhaustionError()`.
    func testAllAccountsDisabledThrows503Not429() async throws {
        let vault = InMemoryCredentialStore()
        let a = makeAccount(key: "a@example.com")
        let b = makeAccount(key: "b@example.com")
        await vault.seed(a, makeCredential(accountID: a.id))
        await vault.seed(b, makeCredential(accountID: b.id))
        let metadata = makeMetadataStore()
        try await metadata.setDisabled(true, accountID: a.id)
        try await metadata.setDisabled(true, accountID: b.id)
        let gateway = MockGatewayClient()
        // Gateway never reached — both accounts are filtered pre-attempt.
        let router = makeRouter(
            vault: vault, pat: MockPATRefresher(), gateway: gateway,
            metadata: metadata
        )
        do {
            _ = try await router.openStream(requestBody: makeBody(), proxyAPIKey: "key")
            XCTFail("expected noAccountsAvailable when all accounts disabled")
        } catch let error as QoderFailoverError {
            guard case .noAccountsAvailable = error else {
                return XCTFail("expected .noAccountsAvailable (503) for disabled accounts, got \(error)")
            }
            XCTAssertEqual(error.httpStatus, 503, "disabled accounts must surface as 503, not 429")
            XCTAssertNil(error.retryAfterSeconds, "503 must not carry a Retry-After hint")
        }
    }

    /// The `Retry-After` value on `.allAccountsCoolingDown` reflects the
    /// earliest cooldown expiry, not the latest. With two accounts returning
    /// 429 with different `Retry-After` hints (60s floor vs 120s), the thrown
    /// error carries ~60s — the agent can retry as soon as the first account
    /// is available, not after both clear.
    func testRetryAfterReflectsEarliestCooldown() async throws {
        let vault = InMemoryCredentialStore()
        let a = makeAccount(key: "a@example.com")
        let b = makeAccount(key: "b@example.com")
        await vault.seed(a, makeCredential(accountID: a.id))
        await vault.seed(b, makeCredential(accountID: b.id))
        let gateway = MockGatewayClient()
        // a returns 429 with Retry-After: 5 → clamped to the 60s floor.
        // b returns 429 with Retry-After: 120 → honored (between floor and ceiling).
        await gateway.seed([
            .init(status: 429, headerFields: ["Retry-After": "5"]),
            .init(status: 429, headerFields: ["Retry-After": "120"]),
        ])
        let router = makeRouter(
            vault: vault, pat: MockPATRefresher(), gateway: gateway,
            metadata: makeMetadataStore()
        )
        do {
            _ = try await router.openStream(requestBody: makeBody(), proxyAPIKey: "key")
            XCTFail("expected allAccountsCoolingDown")
        } catch let error as QoderFailoverError {
            guard case .allAccountsCoolingDown(let retryAfter) = error else {
                return XCTFail("expected .allAccountsCoolingDown, got \(error)")
            }
            // Earliest cooldown is the floor (60s), not the 120s ceiling.
            XCTAssertLessThanOrEqual(retryAfter ?? 0, 65,
                "Retry-After should reflect the earliest (~60s floor), not the latest (120s)")
            XCTAssertGreaterThanOrEqual(retryAfter ?? 0, 55,
                "Retry-After should be near the 60s floor")
        }
    }

    // MARK: - 401 → one-shot re-exchange, then retry same account

    func test401TriggersOneShotReexchangeThenSucceeds() async throws {
        let vault = InMemoryCredentialStore()
        let account = makeAccount(key: "user@example.com")
        let originalMachineID = "machine-original"
        await vault.seed(
            account,
            makeCredential(accountID: account.id, token: "jt-stale", machineID: originalMachineID)
        )
        let gateway = MockGatewayClient()
        // First attempt 401 (stale token), re-exchange succeeds, retry → 200.
        await gateway.seed([
            .init(status: 401),
            .init(status: 200, body: Data("data: [DONE]\n\n".utf8)),
        ])
        let pat = MockPATRefresher()
        await pat.seed(
            account.id,
            .success(makeCredential(
                accountID: account.id, token: "jt-fresh", machineID: originalMachineID
            ))
        )
        let router = makeRouter(
            vault: vault, pat: pat, gateway: gateway,
            metadata: makeMetadataStore()
        )

        let opened = try await router.openStream(requestBody: makeBody(), proxyAPIKey: "key")
        XCTAssertEqual(opened.accountID, account.id, "should stay on same account after re-exchange")
        let callCount = await gateway.callCount
        XCTAssertEqual(callCount, 2, "401 then 200 on the same account")
        let refreshCalls = await pat.callLog
        XCTAssertEqual(refreshCalls, [account.id], "one re-exchange for this account")

        // The refreshed credential passed to the gateway should preserve the
        // original machineID (the divergence from QoderQuotaFetcher).
        let receivedCreds = await gateway.receivedCredentials
        XCTAssertEqual(receivedCreds.last?.machineID, originalMachineID)
    }

    func test401AfterReexchangeDisablesAndRotates() async throws {
        let vault = InMemoryCredentialStore()
        let primary = makeAccount(key: "primary@example.com")
        let secondary = makeAccount(key: "secondary@example.com")
        await vault.seed(primary, makeCredential(accountID: primary.id))
        await vault.seed(secondary, makeCredential(accountID: secondary.id))
        let gateway = MockGatewayClient()
        // primary 401, re-exchange "succeeds" (returns same cred), retry 401
        // again → PAT revoked: disable primary, rotate to secondary → 200.
        await gateway.seed([
            .init(status: 401),
            .init(status: 401),
            .init(status: 200, body: Data("data: [DONE]\n\n".utf8)),
        ])
        let pat = MockPATRefresher()
        await pat.seed(primary.id, .success(makeCredential(accountID: primary.id, token: "jt-rotated")))
        let metadata = makeMetadataStore()
        let router = makeRouter(
            vault: vault, pat: pat, gateway: gateway,
            metadata: metadata
        )

        let opened = try await router.openStream(requestBody: makeBody(), proxyAPIKey: "key")
        XCTAssertEqual(opened.accountID, secondary.id, "should rotate to secondary after revoked PAT")
        let callCount = await gateway.callCount
        XCTAssertEqual(callCount, 3, "primary×2 (401+401 after re-exchange) then secondary×1")

        // Primary is now persistently disabled.
        let disabled = await metadata.disabledAccountIDs()
        XCTAssertTrue(disabled.contains(primary.id), "primary should be disabled after revoked PAT")
    }

    // MARK: - Re-exchange failure: retry, then cool down or disable

    /// Regression: transient re-exchange exhaustion must NOT persistently disable
    /// the account. The PAT service distinguishes `.network` (DNS, timeout, TLS —
    /// recoverable) from `.invalidPAT` / `.exchangeFailed(401/403)` (revoked —
    /// permanent). After the transient retry budget is exhausted, the router
    /// applies an in-memory cooldown and rotates; a user-enabled account therefore
    /// remains enabled across Quotio restarts.
    func testTransientReexchangeFailureRetriesBeforeCoolingDown() async throws {
        let vault = InMemoryCredentialStore()
        let primary = makeAccount(key: "primary@example.com")
        let secondary = makeAccount(key: "secondary@example.com")
        await vault.seed(primary, makeCredential(accountID: primary.id))
        await vault.seed(secondary, makeCredential(accountID: secondary.id))
        let gateway = MockGatewayClient()
        // primary 401, re-exchange fails twice (network), so primary enters an
        // in-memory cooldown; rotation → secondary 200.
        await gateway.seed([
            .init(status: 401),
            .init(status: 200, body: Data("data: [DONE]\n\n".utf8)),
        ])
        let pat = MockPATRefresher()
        // Two consecutive transient failures exhaust the retry budget, so the
        // account is cooled down without changing persistent metadata.
        await pat.seed(primary.id, .failure(QoderPATError.network("timeout")))
        await pat.seed(primary.id, .failure(QoderPATError.network("timeout")))
        let metadata = makeMetadataStore()
        let router = makeRouter(
            vault: vault, pat: pat, gateway: gateway,
            metadata: metadata
        )

        let opened = try await router.openStream(requestBody: makeBody(), proxyAPIKey: "key")
        XCTAssertEqual(opened.accountID, secondary.id, "should rotate to secondary after primary re-exchange retries exhausted")
        let disabled = await metadata.disabledAccountIDs()
        XCTAssertFalse(disabled.contains(primary.id), "transient exhaustion must not persistently disable the account")

        // Exactly two re-exchange attempts (the retry budget), not one.
        let refreshCalls = await pat.callLog.filter { $0 == primary.id }
        XCTAssertEqual(refreshCalls.count, 2, "re-exchange retried up to the configured budget before cooling down")
    }

    /// A transient re-exchange failure followed by a success on retry keeps the
    /// account alive — it is NOT disabled, and the request succeeds on the same
    /// account. This is the core bug-fix path: the network blip is absorbed.
    func testTransientReexchangeFailureThenSuccessKeepsAccount() async throws {
        let vault = InMemoryCredentialStore()
        let account = makeAccount(key: "user@example.com")
        await vault.seed(account, makeCredential(accountID: account.id, token: "jt-stale"))
        let gateway = MockGatewayClient()
        // 401 (stale) → re-exchange fails once (network) → re-exchange retried,
        // succeeds → retry → 200.
        await gateway.seed([
            .init(status: 401),
            .init(status: 200, body: Data("data: [DONE]\n\n".utf8)),
        ])
        let pat = MockPATRefresher()
        await pat.seed(account.id, .failure(QoderPATError.network("timeout")))
        await pat.seed(account.id, .success(makeCredential(accountID: account.id, token: "jt-fresh")))
        let metadata = makeMetadataStore()
        let router = makeRouter(
            vault: vault, pat: pat, gateway: gateway,
            metadata: metadata
        )

        let opened = try await router.openStream(requestBody: makeBody(), proxyAPIKey: "key")
        XCTAssertEqual(opened.accountID, account.id, "should stay on the same account after re-exchange retry succeeded")
        let disabled = await metadata.disabledAccountIDs()
        XCTAssertFalse(disabled.contains(account.id), "account must NOT be disabled when re-exchange eventually succeeded")
    }

    /// A real revocation (PAT service throws `.invalidPAT`) disables on the
    /// first try, without burning the retry budget — a malformed PAT won't fix
    /// itself on retry. This guards the transient classifier from over-retrying
    /// permanent failures.
    func testRevocationReexchangeFailureDisablesImmediately() async throws {
        let vault = InMemoryCredentialStore()
        let primary = makeAccount(key: "primary@example.com")
        let secondary = makeAccount(key: "secondary@example.com")
        await vault.seed(primary, makeCredential(accountID: primary.id))
        await vault.seed(secondary, makeCredential(accountID: secondary.id))
        let gateway = MockGatewayClient()
        await gateway.seed([
            .init(status: 401),
            .init(status: 200, body: Data("data: [DONE]\n\n".utf8)),
        ])
        let pat = MockPATRefresher()
        // A single permanent failure — no retry.
        await pat.seed(primary.id, .failure(QoderPATError.invalidPAT))
        let metadata = makeMetadataStore()
        let router = makeRouter(
            vault: vault, pat: pat, gateway: gateway,
            metadata: metadata
        )

        let opened = try await router.openStream(requestBody: makeBody(), proxyAPIKey: "key")
        XCTAssertEqual(opened.accountID, secondary.id)
        let disabled = await metadata.disabledAccountIDs()
        XCTAssertTrue(disabled.contains(primary.id), "real revocation disables immediately")
        let refreshCalls = await pat.callLog.filter { $0 == primary.id }
        XCTAssertEqual(refreshCalls.count, 1, "permanent failures must not burn the retry budget")
    }

    /// With a single account, transient re-exchange exhaustion is temporary
    /// routing unavailability: return HTTP-429 semantics with a retry delay, and
    /// leave persistent metadata untouched. This prevents a manually enabled
    /// account from being written back as disabled on the next client request.
    func testTransientReexchangeExhaustionReturnsCooldownWithoutPersistentDisable() async throws {
        let vault = InMemoryCredentialStore()
        let account = makeAccount(key: "user@example.com")
        await vault.seed(account, makeCredential(accountID: account.id))
        let gateway = MockGatewayClient()
        await gateway.seed([.init(status: 401)])
        let pat = MockPATRefresher()
        await pat.seed(account.id, .failure(QoderPATError.network("timeout")))
        await pat.seed(account.id, .failure(QoderPATError.network("timeout")))
        let metadata = makeMetadataStore()
        let router = makeRouter(
            vault: vault, pat: pat, gateway: gateway,
            metadata: metadata,
            configuration: QoderFailoverRouterConfiguration(
                cooldownTTL: 0.05,
                reexchangeRetryCount: 2
            )
        )

        do {
            _ = try await router.openStream(requestBody: makeBody(), proxyAPIKey: "key")
            XCTFail("expected allAccountsCoolingDown after transient exhaustion")
        } catch let error as QoderFailoverError {
            guard case .allAccountsCoolingDown(let retryAfter) = error else {
                return XCTFail("expected allAccountsCoolingDown, got \(error)")
            }
            XCTAssertNotNil(retryAfter)
            XCTAssertGreaterThan(retryAfter ?? 0, 0)
        }

        let disabled = await metadata.disabledAccountIDs()
        XCTAssertFalse(disabled.contains(account.id), "transient exhaustion must not persist a disabled ID")
    }

    /// In-memory cooldowns self-heal without a metadata mutation. Once the TTL
    /// expires, the same account is eligible again and can serve a later request.
    func testTransientReexchangeCooldownExpiresAndAccountBecomesEligibleAgain() async throws {
        let vault = InMemoryCredentialStore()
        let account = makeAccount(key: "user@example.com")
        await vault.seed(account, makeCredential(accountID: account.id))
        let gateway = MockGatewayClient()
        await gateway.seed([
            .init(status: 401),
            .init(status: 200, body: Data("data: [DONE]\n\n".utf8)),
        ])
        let pat = MockPATRefresher()
        await pat.seed(account.id, .failure(QoderPATError.network("timeout")))
        await pat.seed(account.id, .failure(QoderPATError.network("timeout")))
        let metadata = makeMetadataStore()
        let router = makeRouter(
            vault: vault, pat: pat, gateway: gateway,
            metadata: metadata,
            configuration: QoderFailoverRouterConfiguration(
                cooldownTTL: 0.05,
                reexchangeRetryCount: 2
            )
        )

        do {
            _ = try await router.openStream(requestBody: makeBody(), proxyAPIKey: "key")
            XCTFail("expected cooldown on the first request")
        } catch let error as QoderFailoverError {
            guard case .allAccountsCoolingDown = error else {
                return XCTFail("expected allAccountsCoolingDown, got \(error)")
            }
        }

        try await Task.sleep(nanoseconds: 100_000_000)

        let opened = try await router.openStream(requestBody: makeBody(), proxyAPIKey: "key")
        XCTAssertEqual(opened.accountID, account.id)
        let disabled = await metadata.disabledAccountIDs()
        XCTAssertFalse(disabled.contains(account.id))
    }

    /// Regression: when the PAT exchange endpoint itself is rate-limited (HTTP
    /// 429 from `openapi.qoder.sh/api/v1/jobToken/exchange`), the PAT service
    /// throws `.exchangeFailed(status: 429)`. A 429 is *transient* (retry after
    /// a cool-down), not a permanent revocation — but the classifier lumps
    /// every `.exchangeFailed` into "permanent," so the router disables the
    /// account on the first try with no recheck. This is the root cause of the
    /// user-facing "No Qoder accounts available" while the real accounts still
    /// have quota: heavy quota polling trips the exchange endpoint's rate
    /// limit, every account that needs a job-token rotation disables, and the
    /// chat path finds zero candidates.
    func testExchangeRateLimit429IsTransientNotPermanent() async throws {
        let vault = InMemoryCredentialStore()
        let primary = makeAccount(key: "primary@example.com")
        let secondary = makeAccount(key: "secondary@example.com")
        await vault.seed(primary, makeCredential(accountID: primary.id))
        await vault.seed(secondary, makeCredential(accountID: secondary.id))
        let gateway = MockGatewayClient()
        // primary 401 (stale token) → re-exchange hits 429 → must retry, not
        // disable immediately. Rotation → secondary 200.
        await gateway.seed([
            .init(status: 401),
            .init(status: 200, body: Data("data: [DONE]\n\n".utf8)),
        ])
        let pat = MockPATRefresher()
        // A 429 from the exchange endpoint is transient: retry up to the
        // budget, then cool down without changing persistent account state.
        await pat.seed(primary.id, .failure(QoderPATError.exchangeFailed(status: 429, snippet: "rate limited")))
        await pat.seed(primary.id, .failure(QoderPATError.exchangeFailed(status: 429, snippet: "rate limited")))
        let metadata = makeMetadataStore()
        let router = makeRouter(
            vault: vault, pat: pat, gateway: gateway,
            metadata: metadata,
            configuration: QoderFailoverRouterConfiguration(reexchangeRetryCount: 2)
        )

        let opened = try await router.openStream(requestBody: makeBody(), proxyAPIKey: "key")
        XCTAssertEqual(opened.accountID, secondary.id, "should rotate to secondary after primary re-exchange retries exhausted")

        let disabled = await metadata.disabledAccountIDs()
        XCTAssertFalse(disabled.contains(primary.id), "exchange 429 must cool down without persisting a disabled ID")
    }

    // MARK: - 5xx / network transient: retry same account once

    func test5xxRetriesSameAccountOnceThenSucceeds() async throws {
        let vault = InMemoryCredentialStore()
        let account = makeAccount(key: "user@example.com")
        await vault.seed(account, makeCredential(accountID: account.id))
        let gateway = MockGatewayClient()
        await gateway.seed([
            .init(status: 503),
            .init(status: 200, body: Data("data: [DONE]\n\n".utf8)),
        ])
        let router = makeRouter(
            vault: vault, pat: MockPATRefresher(), gateway: gateway,
            metadata: makeMetadataStore()
        )

        let opened = try await router.openStream(requestBody: makeBody(), proxyAPIKey: "key")
        XCTAssertEqual(opened.accountID, account.id)
        let callCount = await gateway.callCount
        XCTAssertEqual(callCount, 2, "503 then 200 on the same account (one retry)")
    }

    func test5xxTwiceRotatesWithoutCooldown() async throws {
        let vault = InMemoryCredentialStore()
        let a = makeAccount(key: "a@example.com")
        let b = makeAccount(key: "b@example.com")
        await vault.seed(a, makeCredential(accountID: a.id))
        await vault.seed(b, makeCredential(accountID: b.id))
        let gateway = MockGatewayClient()
        // a: 503, 503 (two transient failures → rotate, no cooldown applied).
        // b: 200.
        await gateway.seed([
            .init(status: 503),
            .init(status: 503),
            .init(status: 200, body: Data("data: [DONE]\n\n".utf8)),
        ])
        let router = makeRouter(
            vault: vault, pat: MockPATRefresher(), gateway: gateway,
            metadata: makeMetadataStore()
        )

        let opened = try await router.openStream(requestBody: makeBody(), proxyAPIKey: "key")
        XCTAssertEqual(opened.accountID, b.id)

        // No cooldown on transient failures — a is still eligible next round.
        await gateway.seed(.init(status: 200, body: Data("data: [DONE]\n\n".utf8)))
        let opened2 = try await router.openStream(requestBody: makeBody(), proxyAPIKey: "key")
        // First-enabled (a, seeded first) should be tried first now that it's
        // not cooled down.
        XCTAssertEqual(opened2.accountID, a.id, "transient failure should not apply cooldown")
    }

    // MARK: - Account filtering: disabled + non-Qoder accounts skipped

    func testDisabledAccountsAreSkipped() async throws {
        let vault = InMemoryCredentialStore()
        let disabled = makeAccount(key: "disabled@example.com")
        let enabled = makeAccount(key: "enabled@example.com")
        await vault.seed(disabled, makeCredential(accountID: disabled.id))
        await vault.seed(enabled, makeCredential(accountID: enabled.id))
        let metadata = makeMetadataStore()
        try await metadata.setDisabled(true, accountID: disabled.id)
        let gateway = MockGatewayClient()
        await gateway.seed(.init(status: 200, body: Data("data: [DONE]\n\n".utf8)))
        let router = makeRouter(
            vault: vault, pat: MockPATRefresher(), gateway: gateway,
            metadata: metadata
        )

        let opened = try await router.openStream(requestBody: makeBody(), proxyAPIKey: "key")
        XCTAssertEqual(opened.accountID, enabled.id, "disabled account must be skipped")
    }

    func testNonQoderAccountsAreSkipped() async throws {
        let vault = InMemoryCredentialStore()
        // A non-Qoder account in the vault should not be a routing candidate.
        let codex = MonitorAccount.make(
            provider: .codex, accountKey: "codex@example.com", source: .quotioKeychain
        )
        let qoder = makeAccount(key: "qoder@example.com")
        await vault.seed(codex, makeCredential(accountID: codex.id))
        await vault.seed(qoder, makeCredential(accountID: qoder.id))
        let gateway = MockGatewayClient()
        await gateway.seed(.init(status: 200, body: Data("data: [DONE]\n\n".utf8)))
        let router = makeRouter(
            vault: vault, pat: MockPATRefresher(), gateway: gateway,
            metadata: makeMetadataStore()
        )

        let opened = try await router.openStream(requestBody: makeBody(), proxyAPIKey: "key")
        XCTAssertEqual(opened.accountID, qoder.id, "only qoder accounts are candidates")
    }

    // MARK: - Fail-fast gates from the translator

    /// Phase 2b: the tools fail-fast gate was lifted (ADR 0007 §3). A tools-
    /// bearing request now flows through to the gateway with the transformed
    /// tools in the envelope, instead of being rejected with HTTP 400. This
    /// test is the inverse of the old 2a "tools gate rejects with 400" test.
    func testToolsBearingRequestFlowsToGateway() async throws {
        let vault = InMemoryCredentialStore()
        let account = makeAccount(key: "user@example.com")
        await vault.seed(account, makeCredential(accountID: account.id))
        let gateway = MockGatewayClient()
        await gateway.seed(.init(status: 200, body: Data("data: [DONE]\n\n".utf8)))
        let router = makeRouter(
            vault: vault, pat: MockPATRefresher(), gateway: gateway,
            metadata: makeMetadataStore()
        )
        let json: [String: Any] = [
            "model": "qoder/auto",
            "stream": true,
            "messages": [["role": "user", "content": "hi"]],
            "tools": [["type": "function", "function": ["name": "x", "parameters": [:]]]],
        ]
        let body = try JSONSerialization.data(withJSONObject: json)
        // Should NOT throw — tools are supported in Phase 2b.
        _ = try await router.openStream(requestBody: body, proxyAPIKey: "key")
        let callCount = await gateway.callCount
        XCTAssertEqual(callCount, 1, "tools-bearing request must reach the gateway (gate lifted)")
        // The envelope the gateway received carries the transformed tool.
        let bodies = await gateway.receivedBodies
        let lastBody = try XCTUnwrap(bodies.last)
        let env = try JSONSerialization.jsonObject(with: lastBody) as? [String: Any]
        let tools = env?["tools"] as? [[String: Any]]
        XCTAssertEqual(tools?.count, 1)
        XCTAssertEqual((tools?[0]["function"] as? [String: Any])?["name"] as? String, "x")
    }

    // MARK: - Prefix stripping (ADR 0003 §1 regression guard)

    /// Regression: the `qoder/` routing prefix must be stripped before the
    /// body reaches the translator/upstream gateway (ADR 0003 §1). Before the
    /// fix, every known model fell through to `.defaultUnknown` because the
    /// registry was fed `"qoder/auto"` instead of `"auto"`, and the unprefixed
    /// ID never reached the gateway envelope. This test inspects the envelope
    /// body the gateway received and asserts the resolved model key is bare.
    func testQoderPrefixIsStrippedBeforeTranslation() async throws {
        let vault = InMemoryCredentialStore()
        let account = makeAccount(key: "user@example.com")
        await vault.seed(account, makeCredential(accountID: account.id))
        let gateway = MockGatewayClient()
        await gateway.seed(.init(status: 200, body: Data("data: [DONE]\n\n".utf8)))
        let router = makeRouter(
            vault: vault, pat: MockPATRefresher(), gateway: gateway,
            metadata: makeMetadataStore()
        )

        _ = try await router.openStream(requestBody: makeBody(model: "qoder/auto"), proxyAPIKey: "key")

        let receivedBodies = await gateway.receivedBodies
        XCTAssertEqual(receivedBodies.count, 1)
        // The envelope's model_config.key is the prefix-stripped ID the
        // upstream gateway sees. If the prefix weren't stripped, this would
        // be "" (defaultUnknown) or "qoder/auto" (translator fallback).
        let envelope = try JSONSerialization.jsonObject(with: receivedBodies[0]) as? [String: Any]
        let modelConfig = envelope?["model_config"] as? [String: Any]
        XCTAssertEqual(modelConfig?["key"] as? String, "auto",
                       "qoder/ prefix must be stripped before the upstream gateway")
    }

    // MARK: - Retry-After header parsing (issue #12)

    /// Direct unit tests for `QoderFailoverRouter.retryAfterSeconds` — the
    /// parse function the 429 path depends on. These are cheap and
    /// deterministic (no real-time sleeps, no actor hops, no network), so they
    /// cover the parse matrix the end-to-end Retry-After tests can only spot-
    /// check. `retryAfterSeconds` is `nonisolated static` and internal (not
    /// private) so the tests can reach it directly.

    /// Build an `HTTPURLResponse` carrying the given `Retry-After` header
    /// value, mirroring how the mock gateway and production surface the
    /// header to the router.
    private func makeResponse(retryAfter: String?) -> HTTPURLResponse {
        HTTPURLResponse(
            url: qoderChatGatewayURL,
            statusCode: 429,
            httpVersion: "HTTP/1.1",
            headerFields: retryAfter.map { ["Retry-After": $0] }
        )!
    }

    /// Delta-seconds (the gateway's actual format) parses to that many seconds.
    func testRetryAfterParsesDeltaSeconds() {
        XCTAssertEqual(
            QoderFailoverRouter.retryAfterSeconds(
                from: makeResponse(retryAfter: "120"), capturedAt: Date()
            ),
            120
        )
        XCTAssertEqual(
            QoderFailoverRouter.retryAfterSeconds(
                from: makeResponse(retryAfter: "0"), capturedAt: Date()
            ),
            0
        )
    }

    /// An HTTP-date (RFC 7231 §7.1.1 IMF-fixdate) parses to the delta from
    /// `capturedAt` to the advertised date.
    func testRetryAfterParsesHTTPDate() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)  // deterministic
        // 300s in the future relative to `now`.
        let future = now.addingTimeInterval(300)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        // Trailing `GMT` is literal — must be quoted (`'GMT'`) or `G` (the era
        // designator pattern letter) corrupts the output. Mirrors production's
        // `parseHTTPDate`.
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        let dateStr = formatter.string(from: future)
        let parsed = QoderFailoverRouter.retryAfterSeconds(
            from: makeResponse(retryAfter: dateStr), capturedAt: now
        )
        XCTAssertEqual(parsed ?? -1, 300, accuracy: 1.0)
    }

    /// A past HTTP-date clamps to 0 (the floor in `applyCooldown` is what
    /// keeps a 0 from under-cooling). Documented behavior in `retryAfterSeconds`.
    func testRetryAfterPastHTTPDateClampsToZero() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let past = now.addingTimeInterval(-60)  // 60s ago
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        let dateStr = formatter.string(from: past)
        let parsed = QoderFailoverRouter.retryAfterSeconds(
            from: makeResponse(retryAfter: dateStr), capturedAt: now
        )
        XCTAssertEqual(parsed, 0, "past HTTP-date should clamp to 0")
    }

    /// Negative delta-seconds is invalid per RFC and must yield nil (not 0,
    /// not abs(value)). This distinguishes "garbage" from "valid 0".
    func testRetryAfterNegativeReturnsNil() {
        XCTAssertNil(
            QoderFailoverRouter.retryAfterSeconds(
                from: makeResponse(retryAfter: "-5"), capturedAt: Date()
            )
        )
    }

    /// Non-numeric, non-date garbage yields nil rather than throwing or
    /// returning a sentinel. This is the path that makes the 429 fallback
    /// to the default cooldown.
    func testRetryAfterGarbageReturnsNil() {
        XCTAssertNil(
            QoderFailoverRouter.retryAfterSeconds(
                from: makeResponse(retryAfter: "not-a-duration"), capturedAt: Date()
            )
        )
    }

    /// Absent header (nil) yields nil — the no-`Retry-After` fallback path.
    func testRetryAfterAbsentReturnsNil() {
        XCTAssertNil(
            QoderFailoverRouter.retryAfterSeconds(
                from: makeResponse(retryAfter: nil), capturedAt: Date()
            )
        )
    }
}
