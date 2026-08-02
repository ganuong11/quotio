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
            headerFields: nil
        )!
        let bodyData = response.body
        return QoderGatewayStream(response: http) { onChunk in
            // Yield the scripted body in one chunk. Tests don't need streaming
            // realism — the router just hands the pump to ProxyBridge, which
            // is exercised separately by the reparser tests.
            if !bodyData.isEmpty {
                _ = try await onChunk(bodyData)
            }
        }
    }
}

private extension MockGatewayClient.Response {
    init(status: Int, body: Data = Data()) {
        self.init(status: status, body: body, transportError: nil)
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
        metadata: MonitorMetadataStore
    ) -> QoderFailoverRouter {
        QoderFailoverRouter(
            vault: vault,
            metadata: metadata,
            patService: pat,
            gateway: gateway
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

    func testRejectsStreamFalseBody() async throws {
        let vault = InMemoryCredentialStore()
        let account = makeAccount(key: "user@example.com")
        await vault.seed(account, makeCredential(accountID: account.id))
        let router = makeRouter(
            vault: vault,
            pat: MockPATRefresher(),
            gateway: MockGatewayClient(),
            metadata: makeMetadataStore()
        )
        let json: [String: Any] = [
            "model": "qoder/auto", "stream": false,
            "messages": [["role": "user", "content": "hi"]],
        ]
        let body = try JSONSerialization.data(withJSONObject: json)
        do {
            _ = try await router.openStream(requestBody: body, proxyAPIKey: "key")
            XCTFail("expected requestRejected")
        } catch let error as QoderFailoverError {
            if case .requestRejected = error {} else {
                XCTFail("expected requestRejected, got \(error)")
            }
        }
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

    // MARK: - All accounts exhausted → throw

    func testAllAccounts429ThrowsNoAccountsAvailable() async throws {
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
            XCTFail("expected noAccountsAvailable after all accounts 429")
        } catch let error as QoderFailoverError {
            if case .noAccountsAvailable = error {} else {
                XCTFail("expected noAccountsAvailable, got \(error)")
            }
        }
        let callCount = await gateway.callCount
        XCTAssertEqual(callCount, 2, "each account attempted once")
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

    func testTranslatorToolsGateRejectsWith400() async throws {
        let vault = InMemoryCredentialStore()
        let account = makeAccount(key: "user@example.com")
        await vault.seed(account, makeCredential(accountID: account.id))
        let gateway = MockGatewayClient()
        let router = makeRouter(
            vault: vault, pat: MockPATRefresher(), gateway: gateway,
            metadata: makeMetadataStore()
        )
        // tools non-empty → translator throws toolsNotSupported → router maps
        // to requestRejected (HTTP 400), no account is contacted.
        let json: [String: Any] = [
            "model": "qoder/auto",
            "stream": true,
            "messages": [["role": "user", "content": "hi"]],
            "tools": [["type": "function", "function": ["name": "x", "parameters": [:]]]],
        ]
        let body = try JSONSerialization.data(withJSONObject: json)
        do {
            _ = try await router.openStream(requestBody: body, proxyAPIKey: "key")
            XCTFail("expected requestRejected for tools")
        } catch let error as QoderFailoverError {
            if case .requestRejected = error {} else {
                XCTFail("expected requestRejected, got \(error)")
            }
        }
        let callCount = await gateway.callCount
        XCTAssertEqual(callCount, 0, "tools gate must trip before any gateway call")
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
}
