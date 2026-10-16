import XCTest
@testable import QuotioInfrastructure
import QuotioDomain

final class GatewayCredentialVaultTests: XCTestCase {
    private var temporaryDirectory: URL!
    private var vaultService: String!
    private var legacyService: String!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gateway-vault-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        vaultService = "test-gateway-vault-\(UUID().uuidString)"
        legacyService = "test-legacy-monitor-\(UUID().uuidString)"
    }

    override func tearDown() {
        let dir = temporaryDirectory
        let vaultSvc = vaultService
        let legacySvc = legacyService
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            let store = KeychainCredentialDataStore(service: vaultSvc!, canMigrateLegacy: false)
            let reader = ExternalKeychainCredentialReader()
            for account in ["acct-a", "acct-b", "monitor-legacy1", "imported-key"] {
                await store.delete(accountID: account)
                await reader.compareAndSwap(service: legacySvc!, account: account, expectedData: Data(), newData: Data()) // no-op touch
            }
            semaphore.signal()
        }
        semaphore.wait()
        try? FileManager.default.removeItem(at: dir!)
    }

    private func makeStore() -> GatewayAccountStore {
        GatewayAccountStore(url: temporaryDirectory.appendingPathComponent("gateway-accounts-v1.json"))
    }

    private func makeVault() -> GatewayCredentialVault {
        GatewayCredentialVault(
            dataStore: KeychainCredentialDataStore(service: vaultService, canMigrateLegacy: false),
            accounts: makeStore()
        )
    }

    private func account(_ key: String, provider: GatewayProvider = .qoder) -> GatewayAccount {
        GatewayAccount(
            id: "gateway-\(key)",
            provider: provider,
            accountKey: key,
            displayName: "Account \(key)",
            source: .onboarded
        )
    }

    func testStoreThenReadRoundTripsCredential() async throws {
        let vault = makeVault()
        let credential = GatewayCredential(
            accessToken: "at-1",
            refreshToken: "rt-1",
            idToken: nil,
            accountID: nil,
            expiresAt: Date(timeIntervalSince1970: 1_800_000_000),
            extra: ["pat": "pt-redacted-fixture", "machineID": "machine-1"]
        )
        try await vault.store(credential, account: account("acct-a"))
        let loaded = await vault.credential(for: "acct-a")
        try XCTSkipIf(loaded == nil, "The test keychain is unavailable")
        XCTAssertEqual(loaded?.accessToken, "at-1")
        XCTAssertEqual(loaded?.extra["machineID"], "machine-1")
        let accounts = await vault.accounts()
        XCTAssertEqual(accounts.count, 1)
        XCTAssertEqual(accounts.first?.accountKey, "acct-a")
    }

    func testCompareAndSwapRejectsStaleWriter() async throws {
        let vault = makeVault()
        try await vault.store(
            GatewayCredential(accessToken: "v1", extra: [:]),
            account: account("acct-b")
        )
        // Two readers load generation G.
        let first = await vault.credential(for: "acct-b")
        try XCTSkipIf(first == nil, "The test keychain is unavailable")
        let secondVault = makeVault()
        _ = await secondVault.credential(for: "acct-b")

        // First writer commits G→G'; second writer's CAS against G must fail.
        try await vault.store(GatewayCredential(accessToken: "v2", extra: [:]), account: account("acct-b"))
        do {
            try await secondVault.store(GatewayCredential(accessToken: "v3", extra: [:]), account: account("acct-b"))
            XCTFail("stale compareAndSwap should have thrown")
        } catch {
            // expected
        }
        let current = await vault.credential(for: "acct-b")
        XCTAssertEqual(current?.accessToken, "v2")
    }

    func testRemoveDeletesCredentialAndAccount() async throws {
        let vault = makeVault()
        try await vault.store(GatewayCredential(accessToken: "x", extra: [:]), account: account("acct-a"))
        let seededCred = await vault.credential(for: "acct-a")
        try XCTSkipIf(seededCred == nil, "The test keychain is unavailable")
        await vault.remove(accountKey: "acct-a")
        let removed = await vault.credential(for: "acct-a")
        XCTAssertNil(removed)
        let remaining = await vault.accounts()
        XCTAssertTrue(remaining.isEmpty)
    }

    func testAccountStorePersistsDisabledSetByAccountKey() async throws {
        let store = makeStore()
        try await store.saveAccount(account("acct-a"))
        try await store.setDisabled(true, accountKey: "acct-a")
        let reloaded = GatewayAccountStore(url: temporaryDirectory.appendingPathComponent("gateway-accounts-v1.json"))
        let disabled = await reloaded.disabledAccountIDs()
        XCTAssertEqual(disabled, ["acct-a"])
        try await reloaded.setDisabled(false, accountKey: "acct-a")
        let enabled = await reloaded.disabledAccountIDs()
        XCTAssertEqual(enabled, [])
    }

    func testLegacyImportCopiesQoderAndIsIdempotent() async throws {
        // Seed a legacy monitor-auth keychain item + accounts file.
        let legacyStore = KeychainCredentialDataStore(service: legacyService, canMigrateLegacy: false)
        let legacyCredential = GatewayCredential(
            accessToken: "legacy-at",
            refreshToken: "legacy-rt",
            idToken: nil,
            accountID: "monitor-legacy1",
            expiresAt: nil,
            extra: ["pat": "pt-redacted-fixture", "machineID": "m-legacy"]
        )
        let seeded = await legacyStore.save(
            try JSONEncoder().encode(legacyCredential),
            accountID: "monitor-legacy1"
        )
        try XCTSkipIf(seeded == nil, "The test keychain is unavailable")

        let legacyFile = temporaryDirectory.appendingPathComponent("legacy-accounts-v1.json")
        struct LegacyAccount: Codable {
            var id: String; var provider: String; var accountKey: String
            var displayName: String; var source: String; var isDisabled: Bool
        }
        struct LegacyPayload: Codable {
            var accounts: [LegacyAccount]; var disabledAccountIDs: [String]
        }
        let payload = LegacyPayload(
            accounts: [
                LegacyAccount(
                    id: "monitor-legacy1", provider: "qoder", accountKey: "imported-key",
                    displayName: "Imported Qoder", source: "quotioKeychain", isDisabled: false
                ),
                LegacyAccount(
                    id: "monitor-ignored", provider: "codex", accountKey: "ignored-key",
                    displayName: "Codex", source: "quotioKeychain", isDisabled: false
                ),
            ],
            disabledAccountIDs: []
        )
        try JSONEncoder().encode(payload).write(to: legacyFile)

        let vault = makeVault()
        let importer = GatewayLegacyImport(
            legacyAccountsURL: legacyFile,
            legacyServices: [legacyService],
            reader: ExternalKeychainCredentialReader()
        )
        let imported = await importer.run(into: vault)
        XCTAssertEqual(imported, 1)
        let cred = await vault.credential(for: "imported-key")
        XCTAssertEqual(cred?.accessToken, "legacy-at")
        XCTAssertEqual(cred?.extra["pat"], "pt-redacted-fixture")
        let accounts = await vault.accounts()
        XCTAssertEqual(accounts.first?.provider, .qoder)
        XCTAssertEqual(accounts.first?.source, .legacyImport)

        // Second run imports nothing new — idempotent.
        let second = await importer.run(into: vault)
        XCTAssertEqual(second, 0)
        let afterSecond = await vault.accounts()
        XCTAssertEqual(afterSecond.count, 1)

        // Legacy item left in place.
        let legacyRecord = await legacyStore.read(accountID: "monitor-legacy1")
        let legacyDecoded = legacyRecord.flatMap {
            try? JSONDecoder().decode(GatewayCredential.self, from: $0.data)
        }
        XCTAssertEqual(legacyDecoded?.accessToken, "legacy-at")
        XCTAssertEqual(legacyDecoded?.extra["machineID"], "m-legacy")
    }
}
