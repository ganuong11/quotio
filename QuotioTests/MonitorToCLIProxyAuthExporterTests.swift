import XCTest
@testable import Quotio

final class MonitorToCLIProxyAuthExporterTests: XCTestCase {
    func testClaudePayloadUsesFlatCLIProxyFields() throws {
        let account = MonitorAccount.make(
            provider: .claude,
            accountKey: "user@example.com",
            source: .quotioKeychain,
            canDelete: true
        )
        let expires = Date(timeIntervalSince1970: 1_800_000_000)
        let credential = MonitorOAuthCredential(
            accessToken: "access-claude",
            refreshToken: "refresh-claude",
            idToken: nil,
            accountID: "uuid-1",
            expiresAt: expires,
            extra: [:]
        )

        let built = try XCTUnwrap(
            MonitorToCLIProxyAuthExporter.buildAuthFile(account: account, credential: credential)
        )

        XCTAssertEqual(built.filename, "claude-user@example.com.json")
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: built.data) as? [String: Any]
        )
        XCTAssertEqual(json["type"] as? String, "claude")
        XCTAssertEqual(json["email"] as? String, "user@example.com")
        XCTAssertEqual(json["access_token"] as? String, "access-claude")
        XCTAssertEqual(json["refresh_token"] as? String, "refresh-claude")
        XCTAssertEqual(json["disabled"] as? Bool, false)
        XCTAssertNotNil(json["expired"] as? String)
        XCTAssertNil(json["claudeAiOauth"])
    }

    func testCopilotFilenameAndType() throws {
        let account = MonitorAccount.make(
            provider: .copilot,
            accountKey: "octocat",
            source: .quotioKeychain,
            canDelete: true
        )
        let credential = MonitorOAuthCredential(
            accessToken: "gho_test",
            refreshToken: nil,
            idToken: nil,
            accountID: "1",
            expiresAt: nil,
            extra: [:]
        )
        let built = try XCTUnwrap(
            MonitorToCLIProxyAuthExporter.buildAuthFile(account: account, credential: credential)
        )
        XCTAssertEqual(built.filename, "github-copilot-octocat.json")
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: built.data) as? [String: Any]
        )
        XCTAssertEqual(json["type"] as? String, "github-copilot")
        XCTAssertEqual(json["login"] as? String, "octocat")
        XCTAssertEqual(json["username"] as? String, "octocat")
        XCTAssertEqual(json["token_type"] as? String, "bearer")
    }

    func testKiroMapsExtraAndExpiresAt() throws {
        let account = MonitorAccount.make(
            provider: .kiro,
            accountKey: "builder@example.com",
            source: .quotioKeychain,
            canDelete: true
        )
        let expires = Date(timeIntervalSince1970: 1_800_000_000)
        let credential = MonitorOAuthCredential(
            accessToken: "kiro-access",
            refreshToken: "kiro-refresh",
            idToken: nil,
            accountID: "builder@example.com",
            expiresAt: expires,
            extra: [
                "authMethod": "IdC",
                "clientId": "client-abc",
                "clientSecret": "secret-xyz",
                "region": "us-east-1",
            ]
        )
        let built = try XCTUnwrap(
            MonitorToCLIProxyAuthExporter.buildAuthFile(account: account, credential: credential)
        )
        XCTAssertEqual(built.filename, "kiro-builder@example.com.json")
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: built.data) as? [String: Any]
        )
        XCTAssertEqual(json["type"] as? String, "kiro")
        XCTAssertEqual(json["auth_method"] as? String, "IdC")
        XCTAssertEqual(json["client_id"] as? String, "client-abc")
        XCTAssertEqual(json["client_secret"] as? String, "secret-xyz")
        XCTAssertEqual(json["region"] as? String, "us-east-1")
        XCTAssertNotNil(json["expires_at"] as? String)
        XCTAssertNil(json["expired"])
    }

    func testCodexIncludesIdTokenAndAccountID() throws {
        let account = MonitorAccount.make(
            provider: .codex,
            accountKey: "plus@example.com",
            source: .quotioKeychain,
            canDelete: true
        )
        let credential = MonitorOAuthCredential(
            accessToken: "codex-access",
            refreshToken: "codex-refresh",
            idToken: "id-token",
            accountID: "acct-123",
            expiresAt: Date(timeIntervalSince1970: 1_800_000_000),
            extra: [:]
        )
        let built = try XCTUnwrap(
            MonitorToCLIProxyAuthExporter.buildAuthFile(account: account, credential: credential)
        )
        XCTAssertEqual(built.filename, "codex-plus@example.com.json")
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: built.data) as? [String: Any]
        )
        XCTAssertEqual(json["type"] as? String, "codex")
        XCTAssertEqual(json["id_token"] as? String, "id-token")
        XCTAssertEqual(json["account_id"] as? String, "acct-123")
    }

    func testGeminiAndAntigravityAndGrokTypes() throws {
        let cases: [(AIProvider, String, String)] = [
            (.gemini, "gemini-cli-g@example.com.json", "gemini-cli"),
            (.antigravity, "antigravity-g@example.com.json", "antigravity"),
            (.grok, "xai-g@example.com.json", "xai"),
        ]
        for (provider, filename, type) in cases {
            let account = MonitorAccount.make(
                provider: provider,
                accountKey: "g@example.com",
                source: .quotioKeychain,
                canDelete: true
            )
            let credential = MonitorOAuthCredential(
                accessToken: "tok",
                refreshToken: "ref",
                idToken: provider == .grok ? "id" : nil,
                accountID: nil,
                expiresAt: Date(),
                extra: [:]
            )
            let built = try XCTUnwrap(
                MonitorToCLIProxyAuthExporter.buildAuthFile(account: account, credential: credential)
            )
            XCTAssertEqual(built.filename, filename, filename)
            let json = try XCTUnwrap(
                JSONSerialization.jsonObject(with: built.data) as? [String: Any]
            )
            XCTAssertEqual(json["type"] as? String, type, filename)
        }
    }

    func testUnsupportedProviderReturnsNil() {
        let account = MonitorAccount.make(
            provider: .vertex,
            accountKey: "v@example.com",
            source: .quotioKeychain
        )
        let credential = MonitorOAuthCredential(
            accessToken: "x",
            refreshToken: nil,
            idToken: nil,
            accountID: nil,
            expiresAt: nil,
            extra: [:]
        )
        XCTAssertNil(
            MonitorToCLIProxyAuthExporter.buildAuthFile(account: account, credential: credential)
        )
    }

    func testExportWritesMissingAndSkipsExisting() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("quotio-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let existing = """
        {"type":"claude","email":"existing@example.com","access_token":"old","disabled":false}
        """.data(using: .utf8)!
        try existing.write(to: dir.appendingPathComponent("claude-existing@example.com.json"))

        let existingAccount = MonitorAccount.make(
            provider: .claude,
            accountKey: "existing@example.com",
            source: .quotioKeychain,
            canDelete: true
        )
        let newAccount = MonitorAccount.make(
            provider: .claude,
            accountKey: "new@example.com",
            source: .quotioKeychain,
            canDelete: true
        )
        let nativeNoCred = MonitorAccount.make(
            provider: .claude,
            accountKey: "native-missing@example.com",
            source: .nativeCredential
        )

        let credExisting = MonitorOAuthCredential(
            accessToken: "should-not-overwrite",
            refreshToken: "r",
            idToken: nil,
            accountID: nil,
            expiresAt: Date(),
            extra: [:]
        )
        let credNew = MonitorOAuthCredential(
            accessToken: "new-access",
            refreshToken: "new-refresh",
            idToken: nil,
            accountID: nil,
            expiresAt: Date(),
            extra: [:]
        )

        let store = FakeMonitorCredentialStore(accounts: [
            existingAccount, newAccount, nativeNoCred
        ], credentials: [
            existingAccount.id: credExisting,
            newAccount.id: credNew,
        ])

        let result = try await MonitorToCLIProxyAuthExporter.exportMissingAccounts(
            authDir: dir.path,
            store: store,
            accounts: [existingAccount, newAccount, nativeNoCred]
        )

        XCTAssertEqual(result.exported, 1)
        XCTAssertEqual(result.skippedExisting, 1)
        XCTAssertEqual(result.skippedMissingCredential, 1)

        let oldData = try Data(contentsOf: dir.appendingPathComponent("claude-existing@example.com.json"))
        let oldJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: oldData) as? [String: Any])
        XCTAssertEqual(oldJSON["access_token"] as? String, "old")

        let newData = try Data(contentsOf: dir.appendingPathComponent("claude-new@example.com.json"))
        let newJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: newData) as? [String: Any])
        XCTAssertEqual(newJSON["access_token"] as? String, "new-access")
    }

    func testExportSkipsWhenCredentialMissing() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("quotio-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let account = MonitorAccount.make(
            provider: .gemini,
            accountKey: "g@example.com",
            source: .quotioKeychain,
            canDelete: true
        )
        let store = FakeMonitorCredentialStore(accounts: [account], credentials: [:])
        let result = try await MonitorToCLIProxyAuthExporter.exportMissingAccounts(
            authDir: dir.path,
            store: store,
            accounts: [account]
        )
        XCTAssertEqual(result.exported, 0)
        XCTAssertEqual(result.skippedMissingCredential, 1)
    }

    func testExportNativeCodexFromFile() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("quotio-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let nativePath = dir.appendingPathComponent("codex-auth.json")
        let nativeJSON: [String: Any] = [
            "tokens": [
                "access_token": "native-access",
                "refresh_token": "native-refresh",
                "id_token": "native-id",
                "account_id": "acct-native",
            ]
        ]
        try JSONSerialization.data(withJSONObject: nativeJSON).write(to: nativePath)

        let account = MonitorAccount.make(
            provider: .codex,
            accountKey: "native@example.com",
            source: .nativeCredential,
            credentialReference: nativePath.path
        )
        let store = FakeMonitorCredentialStore(accounts: [account], credentials: [:])
        let result = try await MonitorToCLIProxyAuthExporter.exportMissingAccounts(
            authDir: dir.appendingPathComponent("out").path,
            store: store,
            accounts: [account]
        )
        XCTAssertEqual(result.exported, 1)
        let out = try Data(contentsOf: dir.appendingPathComponent("out/codex-native@example.com.json"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: out) as? [String: Any])
        XCTAssertEqual(json["type"] as? String, "codex")
        XCTAssertEqual(json["access_token"] as? String, "native-access")
        XCTAssertEqual(json["account_id"] as? String, "acct-native")
    }

    func testLoadNativeClaudeCredential() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("quotio-native-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("credentials.json")
        let payload: [String: Any] = [
            "claudeAiOauth": [
                "accessToken": "claude-access",
                "refreshToken": "claude-refresh",
                "expiresAt": 1_800_000_000_000.0,
            ]
        ]
        try JSONSerialization.data(withJSONObject: payload).write(to: path)
        let account = MonitorAccount.make(
            provider: .claude,
            accountKey: "c@example.com",
            source: .nativeCredential,
            credentialReference: path.path
        )
        let cred = try XCTUnwrap(MonitorToCLIProxyAuthExporter.loadNativeOAuthCredential(account))
        XCTAssertEqual(cred.accessToken, "claude-access")
        XCTAssertEqual(cred.refreshToken, "claude-refresh")
        XCTAssertNotNil(cred.expiresAt)
    }
}

/// Test double — lives in test file only
actor FakeMonitorCredentialStore: MonitorCredentialStore {
    let accountsList: [MonitorAccount]
    let credentials: [String: MonitorOAuthCredential]

    init(accounts: [MonitorAccount], credentials: [String: MonitorOAuthCredential]) {
        self.accountsList = accounts
        self.credentials = credentials
    }

    func accounts() async -> [MonitorAccount] { accountsList }
    func credential(for accountID: String) async -> MonitorOAuthCredential? { credentials[accountID] }
    func reloadLatest(accountID: String) async -> MonitorOAuthCredential? { credentials[accountID] }
    func save(_ credential: MonitorOAuthCredential, metadata: MonitorAccount) async throws {}
    func delete(accountID: String) async {}
}
