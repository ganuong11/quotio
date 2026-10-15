//
//  OpencodeRouterTests.swift
//  QuotioTests
//

import Foundation
import XCTest
@testable import Quotio

// MARK: - test helpers

private actor InMemoryCredentialStore: MonitorCredentialStore {
    private var credentials: [String: MonitorOAuthCredential] = [:]
    private var accountsList: [MonitorAccount] = []

    func seed(_ account: MonitorAccount, _ credential: MonitorOAuthCredential) {
        accountsList.append(account)
        credentials[account.id] = credential
    }

    func stored(_ accountID: String) -> MonitorOAuthCredential? { credentials[accountID] }
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

/// Scripted upstream client — records each call, drains a response queue.
private actor MockUpstream: OpencodeUpstreamClientProtocol {
    struct Call: Sendable {
        let url: String
        let headers: [(String, String)]
        let body: Data
    }
    private var queue: [Result<OpencodeUpstreamStream, Error>] = []
    private(set) var calls: [Call] = []

    func seed(_ result: Result<OpencodeUpstreamStream, Error>) { queue.append(result) }

    func post(url: URL, headers: [(String, String)], body: Data) async throws -> OpencodeUpstreamStream {
        calls.append(Call(url: url.absoluteString, headers: headers, body: body))
        guard !queue.isEmpty else { throw URLError(.badServerResponse) }
        return try queue.removeFirst().get()
    }
}

private final class PullBox: @unchecked Sendable {
    private var chunks: [Data]
    init(_ chunks: [Data]) { self.chunks = chunks }
    func next() -> Data? { chunks.isEmpty ? nil : chunks.removeFirst() }
}

private func cannedStream(status: Int, body: String = "", headers: [(String, String)] = []) -> OpencodeUpstreamStream {
    let box = PullBox(body.isEmpty ? [] : [Data(body.utf8)])
    return OpencodeUpstreamStream(status: status, headers: headers) { box.next() }
}

private final class DataBox: @unchecked Sendable {
    private(set) var data = Data()
    func append(_ d: Data) { data.append(d) }
}

final class OpencodeRouterTests: XCTestCase {

    private var tempDir: URL!
    private var catalog: OpencodeModelCatalog!
    private var store: InMemoryCredentialStore!
    private var upstream: MockUpstream!

    override func setUp() async throws {
        try await super.setUp()
        StubURLProtocol.reset()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        catalog = OpencodeModelCatalog(session: StubURLProtocol.makeSession(), storageDirectory: tempDir)
        // populate the free set so the defensive catalog check passes
        let snapshot = Data(#"{"fetchedAt":756000000,"models":[{"id":"big-pickle","displayName":"Big Pickle"}]}"#.utf8)
        try snapshot.write(to: tempDir.appendingPathComponent("catalog-v1.json"))
        await catalog.loadPersisted()
        store = InMemoryCredentialStore()
        upstream = MockUpstream()
    }

    override func tearDownWithError() throws {
        StubURLProtocol.reset()
        try? FileManager.default.removeItem(at: tempDir)
        try super.tearDownWithError()
    }

    private func makeRouter(detected: @escaping @Sendable () -> [DetectedOpencodeCredential] = { [] }) -> OpencodeRouter {
        OpencodeRouter(
            catalog: catalog,
            console: OpencodeConsoleClient(session: StubURLProtocol.makeSession()),
            upstream: upstream,
            vault: store,
            metadata: MonitorMetadataStore(url: tempDir.appendingPathComponent("accounts-test.json")),
            detectedSnapshot: detected
        )
    }

    @discardableResult
    private func seedVaultAccount(
        key: String = "usr_1", accessToken: String = "at-1",
        refreshToken: String? = "rt-1",
        expiresAt: Date = Date().addingTimeInterval(3600),
        orgID: String? = nil, server: String? = nil
    ) async -> MonitorAccount {
        var extra: [String: String] = [:]
        if let orgID { extra["orgID"] = orgID }
        if let server { extra["server"] = server }
        let account = MonitorAccount.make(
            provider: .opencode, accountKey: key,
            source: .quotioKeychain, credentialReference: "keychain", canDelete: true)
        let credential = MonitorOAuthCredential(
            accessToken: accessToken, refreshToken: refreshToken,
            accountID: key, expiresAt: expiresAt, extra: extra)
        await store.seed(account, credential)
        return account
    }

    private let chatBody = Data(#"{"model":"opencode/big-pickle","messages":[{"role":"user","content":"hi"}]}"#.utf8)

    // MARK: - tests

    func testNoAccounts() async {
        let router = makeRouter()
        await XCTAssertThrowsErrorAsync(try await router.open(requestBody: chatBody, route: .chat)) { error in
            XCTAssertEqual(error as? OpencodeRouterError, .noAccountsAvailable)
        }
    }

    func testForwardsStrippedModelWithHeaders() async throws {
        await seedVaultAccount(accessToken: "at-secret", orgID: "org-9")
                await upstream.seed(.success(cannedStream(status: 200, body: "ok")))
        let router = makeRouter()
        let opened = try await router.open(requestBody: chatBody, route: .chat)
        XCTAssertEqual(opened.status, 200)

        let calls = await upstream.calls
        let call = try XCTUnwrap(calls.first)
        XCTAssertEqual(call.url, "https://opencode.ai/inference/v1/chat/completions")
        let headers = Dictionary(uniqueKeysWithValues: call.headers.map { ($0.0.lowercased(), $0.1) })
        XCTAssertEqual(headers["authorization"], "Bearer at-secret")
        XCTAssertTrue(headers["user-agent"]?.hasPrefix("opencode/") ?? false)
        XCTAssertEqual(headers["x-opencode-client"], "cli")
        XCTAssertEqual(headers["x-opencode-request"]?.hasPrefix("msg_"), true)
        XCTAssertEqual(headers["x-opencode-session"]?.hasPrefix("ses_"), true)
        XCTAssertEqual(headers["x-org-id"], "org-9")
        XCTAssertEqual(headers["content-type"], "application/json")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: call.body) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "big-pickle")
    }

    func testResponsesRouteURL() async throws {
        await seedVaultAccount()
                await upstream.seed(.success(cannedStream(status: 200, body: "ok")))
        let router = makeRouter()
        _ = try await router.open(requestBody: chatBody, route: .responses)
        let responseCalls = await upstream.calls
        XCTAssertEqual(responseCalls.first?.url, "https://opencode.ai/inference/v1/responses")
    }

    func testExpiredVaultCredentialRefreshedBeforeSend() async throws {
        await seedVaultAccount(accessToken: "old-at", refreshToken: "old-rt",
                             expiresAt: Date().addingTimeInterval(-10))
                StubURLProtocol.handler = { _ in
            StubURLProtocol.json(["access_token": "new-at", "refresh_token": "new-rt", "expires_in": 3600])
        }
        await upstream.seed(.success(cannedStream(status: 200, body: "ok")))
        let router = makeRouter()
        _ = try await router.open(requestBody: chatBody, route: .chat)

        let calls = await upstream.calls
        let call = try XCTUnwrap(calls.first)
        let headers = Dictionary(uniqueKeysWithValues: call.headers.map { ($0.0.lowercased(), $0.1) })
        XCTAssertEqual(headers["authorization"], "Bearer new-at")
        // refresh request hit the console token endpoint with the refresh grant
        let refreshCall = StubURLProtocol.requests.first {
            $0.url.absoluteString.contains("/auth/device/token")
        }
        XCTAssertNotNil(refreshCall)
        let refreshBody = String(data: refreshCall!.body, encoding: .utf8) ?? ""
        XCTAssertTrue(refreshBody.contains("refresh_token"))
        // rotated tokens persisted back to the vault
        let saved = await store.stored((await store.accounts()).first!.id)
        XCTAssertEqual(saved?.accessToken, "new-at")
    }

    func testDetectedExpiredCredentialRereadsStoreAndNeverRefreshes() async throws {
        // auth.json now holds a FRESH credential (user re-authed in opencode)
        let authPath = tempDir.appendingPathComponent("auth.json").path
        try #"{"opencode":{"type":"oauth","access":"fresh-at","refresh":"fresh-rt","expires":4102444800000,"accountId":"usr_det"}}"#
            .write(toFile: authPath, atomically: true, encoding: .utf8)
        let expiredDetected = DetectedOpencodeCredential(
            accountKey: "usr_det", kind: .oauth, accessToken: "stale-at", refreshToken: "stale-rt",
            expiresAt: Date().addingTimeInterval(-10), orgID: nil,
            server: OpencodeConsoleClient.defaultServer,
            sourcePath: authPath + "#opencode", email: nil)
        await upstream.seed(.success(cannedStream(status: 200, body: "ok")))
        let router = makeRouter { [expiredDetected] }
        _ = try await router.open(requestBody: chatBody, route: .chat)

        let calls = await upstream.calls
        let call = try XCTUnwrap(calls.first)
        let headers = Dictionary(uniqueKeysWithValues: call.headers.map { ($0.0.lowercased(), $0.1) })
        XCTAssertEqual(headers["authorization"], "Bearer fresh-at")
        // NEVER a refresh grant for a detected credential
        XCTAssertTrue(StubURLProtocol.requests.isEmpty)
    }

    func testDetectedStillExpiredMarksStaleAndRotates() async throws {
        // file still holds the expired credential — nothing new to load
        let authPath = tempDir.appendingPathComponent("auth.json").path
        try #"{"opencode":{"type":"oauth","access":"still-stale","refresh":"x","expires":1000,"accountId":"usr_det"}}"#
            .write(toFile: authPath, atomically: true, encoding: .utf8)
        await seedVaultAccount(key: "usr_vault", accessToken: "vault-at")
                let expiredDetected = DetectedOpencodeCredential(
            accountKey: "usr_det", kind: .oauth, accessToken: "old", refreshToken: "old",
            expiresAt: Date(timeIntervalSince1970: 1000), orgID: nil,
            server: OpencodeConsoleClient.defaultServer,
            sourcePath: authPath + "#opencode", email: nil)
        await upstream.seed(.success(cannedStream(status: 200, body: "ok")))

        let stale = expectation(description: "stale notification")
        let observer = NotificationCenter.default.addObserver(
            forName: OpencodeRouter.opencodeAccountStale, object: nil, queue: nil) { note in
            if (note.userInfo?["accountKey"] as? String) == "usr_det" { stale.fulfill() }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        let router = makeRouter { [expiredDetected] }
        _ = try await router.open(requestBody: chatBody, route: .chat)
        await fulfillment(of: [stale], timeout: 5)

        // the vault account served the request
        let calls = await upstream.calls
        let call = try XCTUnwrap(calls.first)
        let headers = Dictionary(uniqueKeysWithValues: call.headers.map { ($0.0.lowercased(), $0.1) })
        XCTAssertEqual(headers["authorization"], "Bearer vault-at")
    }

    func testUpstreamErrorStatusPassedThrough() async throws {
        await seedVaultAccount()
                await upstream.seed(.success(cannedStream(status: 400, body: #"{"error":"bad"}"#)))
        let router = makeRouter()
        let opened = try await router.open(requestBody: chatBody, route: .chat)
        XCTAssertEqual(opened.status, 400)
        let box = DataBox()
        try await opened.pump { @Sendable chunk in box.append(chunk); return true }
        XCTAssertEqual(String(data: box.data, encoding: .utf8), #"{"error":"bad"}"#)
    }

    func test401RotatesToNextAccount() async throws {
        await seedVaultAccount(key: "usr_a", accessToken: "at-a")
        await seedVaultAccount(key: "usr_b", accessToken: "at-b")
                await upstream.seed(.success(cannedStream(status: 401, body: "unauthorized")))
        await upstream.seed(.success(cannedStream(status: 200, body: "ok")))
        let router = makeRouter()
        let opened = try await router.open(requestBody: chatBody, route: .chat)
        XCTAssertEqual(opened.status, 200)
        let rotatedCalls = await upstream.calls
        XCTAssertEqual(rotatedCalls.count, 2)
        let second = rotatedCalls[1]
        let headers = Dictionary(uniqueKeysWithValues: second.headers.map { ($0.0.lowercased(), $0.1) })
        XCTAssertEqual(headers["authorization"], "Bearer at-b")
    }

    func test429CooldownsAccount() async throws {
        await seedVaultAccount(key: "usr_a", accessToken: "at-a")
        await seedVaultAccount(key: "usr_b", accessToken: "at-b")
                await upstream.seed(.success(cannedStream(status: 429, body: "limited")))
        await upstream.seed(.success(cannedStream(status: 200, body: "ok")))
        let router = makeRouter()
        _ = try await router.open(requestBody: chatBody, route: .chat)
        // second request: cooled-down account A must be skipped entirely
        await upstream.seed(.success(cannedStream(status: 200, body: "ok")))
        _ = try await router.open(requestBody: chatBody, route: .chat)
        let cooledCalls = await upstream.calls
        XCTAssertEqual(cooledCalls.count, 3)
        let third = cooledCalls[2]
        let headers = Dictionary(uniqueKeysWithValues: third.headers.map { ($0.0.lowercased(), $0.1) })
        XCTAssertEqual(headers["authorization"], "Bearer at-b")
    }

    /// A 429 cooldown notifies the UI so the account can be shown as
    /// rate-limited (Quota tab connection-status card).
    func test429PostsRateLimitedNotification() async throws {
        await seedVaultAccount(key: "usr_a", accessToken: "at-a")
        await seedVaultAccount(key: "usr_b", accessToken: "at-b")
        await upstream.seed(.success(cannedStream(status: 429, body: "limited")))
        await upstream.seed(.success(cannedStream(status: 200, body: "ok")))

        let limited = expectation(description: "rate-limited notification")
        let observer = NotificationCenter.default.addObserver(
            forName: OpencodeRouter.opencodeAccountRateLimited, object: nil, queue: nil) { note in
            if (note.userInfo?["accountKey"] as? String) == "usr_a" { limited.fulfill() }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        let router = makeRouter()
        _ = try await router.open(requestBody: chatBody, route: .chat)
        await fulfillment(of: [limited], timeout: 5)
    }

    func testRecoveredClearsStale() async throws {
        let authPath = tempDir.appendingPathComponent("auth.json").path
        try #"{"opencode":{"type":"oauth","access":"still-stale","refresh":"x","expires":1000,"accountId":"usr_det"}}"#
            .write(toFile: authPath, atomically: true, encoding: .utf8)
        await seedVaultAccount(key: "usr_vault", accessToken: "vault-at")
                let expiredDetected = DetectedOpencodeCredential(
            accountKey: "usr_det", kind: .oauth, accessToken: "old", refreshToken: "old",
            expiresAt: Date(timeIntervalSince1970: 1000), orgID: nil,
            server: OpencodeConsoleClient.defaultServer,
            sourcePath: authPath + "#opencode", email: nil)

        let stale = expectation(description: "stale")
        let recovered = expectation(description: "recovered")
        let observer = NotificationCenter.default.addObserver(
            forName: OpencodeRouter.opencodeAccountStale, object: nil, queue: nil) { note in
            if (note.userInfo?["accountKey"] as? String) == "usr_det" { stale.fulfill() }
        }
        let observer2 = NotificationCenter.default.addObserver(
            forName: OpencodeRouter.opencodeAccountRecovered, object: nil, queue: nil) { note in
            if (note.userInfo?["accountKey"] as? String) == "usr_det" { recovered.fulfill() }
        }
        defer {
            NotificationCenter.default.removeObserver(observer)
            NotificationCenter.default.removeObserver(observer2)
        }

        let router = makeRouter { [expiredDetected] }
        await upstream.seed(.success(cannedStream(status: 200, body: "ok")))
        _ = try await router.open(requestBody: chatBody, route: .chat)
        await fulfillment(of: [stale], timeout: 5)

        // user re-authed in opencode: the store now carries a fresh token
        try #"{"opencode":{"type":"oauth","access":"fresh-at","refresh":"r","expires":4102444800000,"accountId":"usr_det"}}"#
            .write(toFile: authPath, atomically: true, encoding: .utf8)
        await upstream.seed(.success(cannedStream(status: 200, body: "ok")))
        _ = try await router.open(requestBody: chatBody, route: .chat)
        await fulfillment(of: [recovered], timeout: 5)
    }

    // MARK: - Final review fixes

    /// Free-tier gate (Task 0 spike): `stream:true` is required and the
    /// tools array must contain a `read` tool — the released client always
    /// sends both. A bare `{"model","messages"}` request must be shaped, not
    /// forwarded verbatim.
    func testInjectsReadToolAndStreamTrue() async throws {
        await seedVaultAccount()
        await upstream.seed(.success(cannedStream(status: 200, body: "ok")))
        let router = makeRouter()
        _ = try await router.open(requestBody: chatBody, route: .chat)

        let calls = await upstream.calls
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(calls.first).body) as? [String: Any])
        XCTAssertEqual(json["stream"] as? Bool, true)
        let tools = try XCTUnwrap(json["tools"] as? [[String: Any]])
        XCTAssertTrue(tools.contains {
            (($0["function"] as? [String: Any])?["name"] as? String) == "read"
        }, "expected an injected OpenAI-function-shape `read` tool")
    }

    /// A client that already sends a `read` tool is not touched; sibling
    /// client tools survive alongside.
    func testPreservesExistingReadToolAndClientTools() async throws {
        await seedVaultAccount()
        await upstream.seed(.success(cannedStream(status: 200, body: "ok")))
        let body = Data(#"{"model":"opencode/big-pickle","messages":[],"tools":[{"type":"function","function":{"name":"read","parameters":{"type":"object","properties":{"custom":{"type":"string"}},"required":["custom"]}}},{"type":"function","function":{"name":"bash","parameters":{"type":"object"}}}]}"#.utf8)
        let router = makeRouter()
        _ = try await router.open(requestBody: body, route: .chat)

        let calls = await upstream.calls
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(calls.first).body) as? [String: Any])
        let tools = try XCTUnwrap(json["tools"] as? [[String: Any]])
        let names = tools.compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
        XCTAssertEqual(names.filter { $0 == "read" }.count, 1, "read tool must not be duplicated")
        XCTAssertTrue(names.contains("bash"))
        // the client's own read def is preserved, not replaced
        let readTool = tools.first {
            (($0["function"] as? [String: Any])?["name"] as? String) == "read"
        }
        let params = (readTool?["function"] as? [String: Any])?["parameters"] as? [String: Any]
        XCTAssertNotNil((params?["properties"] as? [String: Any])?["custom"])
    }

    /// A detected account the user disabled in the monitor UI must not
    /// serve — the disabled set applies to detected candidates too.
    func testDisabledDetectedAccountIsSkipped() async throws {
        let detected = DetectedOpencodeCredential(
            accountKey: "usr_det", kind: .oauth, accessToken: "det-at", refreshToken: nil,
            expiresAt: Date().addingTimeInterval(3600), orgID: nil,
            server: OpencodeConsoleClient.defaultServer,
            sourcePath: "/tmp/x#opencode", email: nil)
        let metadata = MonitorMetadataStore(url: tempDir.appendingPathComponent("accounts-test.json"))
        let detectedAccountID = MonitorAccount.make(
            provider: .opencode, accountKey: detected.accountKey,
            source: .nativeCredential, credentialReference: detected.sourcePath).id
        try await metadata.setDisabled(true, accountID: detectedAccountID)
        await upstream.seed(.success(cannedStream(status: 200, body: "ok")))
        let router = OpencodeRouter(
            catalog: catalog,
            console: OpencodeConsoleClient(session: StubURLProtocol.makeSession()),
            upstream: upstream,
            vault: store,
            metadata: metadata,
            detectedSnapshot: { [detected] }
        )
        await XCTAssertThrowsErrorAsync(try await router.open(requestBody: chatBody, route: .chat)) { error in
            XCTAssertEqual(error as? OpencodeRouterError, .noAccountsAvailable)
        }
        let calls = await upstream.calls
        XCTAssertTrue(calls.isEmpty, "disabled detected account must not reach upstream")
    }

    /// Spec: a detected credential that 401s is re-read from its store —
    /// a rotated token retries once upstream.
    func testDetected401ReloadsStoreAndRetries() async throws {
        // store carries the ROTATED token (user re-authed in opencode)
        let authPath = tempDir.appendingPathComponent("auth.json").path
        try #"{"opencode":{"type":"oauth","access":"rotated-at","refresh":"r","expires":4102444800000,"accountId":"usr_det"}}"#
            .write(toFile: authPath, atomically: true, encoding: .utf8)
        // snapshot still holds the old (revoked-but-unexpired) token
        let detected = DetectedOpencodeCredential(
            accountKey: "usr_det", kind: .oauth, accessToken: "revoked-at", refreshToken: "old",
            expiresAt: Date().addingTimeInterval(3600), orgID: nil,
            server: OpencodeConsoleClient.defaultServer,
            sourcePath: authPath + "#opencode", email: nil)
        await upstream.seed(.success(cannedStream(status: 401, body: "unauthorized")))
        await upstream.seed(.success(cannedStream(status: 200, body: "ok")))
        let router = makeRouter { [detected] }
        let opened = try await router.open(requestBody: chatBody, route: .chat)
        XCTAssertEqual(opened.status, 200)

        let calls = await upstream.calls
        XCTAssertEqual(calls.count, 2)
        let second = calls[1]
        let headers = Dictionary(uniqueKeysWithValues: second.headers.map { ($0.0.lowercased(), $0.1) })
        XCTAssertEqual(headers["authorization"], "Bearer rotated-at")
    }

    /// A detected credential that 401s AND whose store still holds the
    /// same token is revoked for real — stale-mark it. (Vault candidates
    /// are enumerated before detected, so the vault's own 401 is consumed
    /// first; both failing → exhaustion, not a served stream.)
    func testDetected401SameTokenMarksStale() async throws {
        let authPath = tempDir.appendingPathComponent("auth.json").path
        // store still holds the same revoked token
        try #"{"opencode":{"type":"oauth","access":"revoked-at","refresh":"r","expires":4102444800000,"accountId":"usr_det"}}"#
            .write(toFile: authPath, atomically: true, encoding: .utf8)
        let detected = DetectedOpencodeCredential(
            accountKey: "usr_det", kind: .oauth, accessToken: "revoked-at", refreshToken: "r",
            expiresAt: Date().addingTimeInterval(3600), orgID: nil,
            server: OpencodeConsoleClient.defaultServer,
            sourcePath: authPath + "#opencode", email: nil)
        await upstream.seed(.success(cannedStream(status: 401, body: "unauthorized")))

        let stale = expectation(description: "stale notification")
        let observer = NotificationCenter.default.addObserver(
            forName: OpencodeRouter.opencodeAccountStale, object: nil, queue: nil) { note in
            if (note.userInfo?["accountKey"] as? String) == "usr_det" { stale.fulfill() }
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        let router = makeRouter { [detected] }
        await XCTAssertThrowsErrorAsync(try await router.open(requestBody: chatBody, route: .chat)) { error in
            XCTAssertEqual(error as? OpencodeRouterError, .noAccountsAvailable)
        }
        await fulfillment(of: [stale], timeout: 5)
        // exactly one upstream attempt — no doomed retry with the same token
        let calls = await upstream.calls
        XCTAssertEqual(calls.count, 1)
    }
}

/// XCTAssertThrowsError doesn't compose with async; small local helper.
private func XCTAssertThrowsErrorAsync<T>(
    _ expression: @autoclosure () async throws -> T,
    _ message: String = "",
    file: StaticString = #filePath, line: UInt = #line,
    _ errorHandler: (Error) -> Void
) async {
    do {
        _ = try await expression()
        XCTFail("expected error", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}
