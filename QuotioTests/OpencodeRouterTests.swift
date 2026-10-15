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
            accountKey: "usr_det", accessToken: "stale-at", refreshToken: "stale-rt",
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
            accountKey: "usr_det", accessToken: "old", refreshToken: "old",
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

    func testRecoveredClearsStale() async throws {
        let authPath = tempDir.appendingPathComponent("auth.json").path
        try #"{"opencode":{"type":"oauth","access":"still-stale","refresh":"x","expires":1000,"accountId":"usr_det"}}"#
            .write(toFile: authPath, atomically: true, encoding: .utf8)
        await seedVaultAccount(key: "usr_vault", accessToken: "vault-at")
                let expiredDetected = DetectedOpencodeCredential(
            accountKey: "usr_det", accessToken: "old", refreshToken: "old",
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
