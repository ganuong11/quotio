import Foundation
import QuotioApplication
import QuotioDomain
@testable import QuotioInfrastructure
import XCTest

/// `GatewayQuotaOverlay` — merge semantics, routing of gateway-owned IDs, and
/// monitoring-settings injection.
final class GatewayQuotaOverlayTests: XCTestCase {

    // MARK: - Stubs

    actor HostStub {
        var hostSnapshot: QuotaSnapshot
        private(set) var refreshCalls: [QuotaFetchRequest] = []
        private(set) var refreshAllCalls = 0
        private(set) var removedQuotaIDs: [QuotaAccountID] = []
        private(set) var disabledCalls: [(Bool, String)] = []
        private(set) var deleteCalls: [String] = []
        private(set) var updatedSettings: [MonitoringSettings] = []
        private var providers: [MonitoringProvider] = []
        private var settings: MonitoringSettings
        private var continuations: [UUID: AsyncStream<QuotaSnapshot>.Continuation] = [:]

        init(
            snapshot: QuotaSnapshot = QuotaSnapshot(),
            providers: [MonitoringProvider] = [],
            settings: MonitoringSettings = MonitoringSettings(
                revision: "r1", enabledProviders: [], disabledProviders: [],
                automaticallyDiscoverLogins: true, refreshInterval: 60
            )
        ) {
            self.hostSnapshot = snapshot
            self.providers = providers
            self.settings = settings
        }

        func push(_ snapshot: QuotaSnapshot) {
            hostSnapshot = snapshot
            for c in continuations.values { c.yield(snapshot) }
        }

        func waitForSubscribers(_ count: Int) async throws {
            for _ in 0..<100 where continuations.count < count {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(continuations.count, count)
        }

        func setProviders(_ value: [MonitoringProvider]) { providers = value }
    }

    actor DirectoryStub: GatewayAccountDirectory {
        private var accountsList: [GatewayAccount] = []
        private var disabled: Set<String> = []
        private(set) var setDisabledCalls: [(Bool, String)] = []
        private(set) var deleteCalls: [String] = []

        func add(_ account: GatewayAccount) { accountsList.append(account) }
        func accounts() -> [GatewayAccount] { accountsList }
        func disabledAccountIDs() -> Set<String> { disabled }
        func setDisabled(_ flag: Bool, accountID: String) throws {
            setDisabledCalls.append((flag, accountID))
            if flag { disabled.insert(accountID) } else { disabled.remove(accountID) }
        }
        func deleteAccount(accountID: String) throws {
            deleteCalls.append(accountID)
            accountsList.removeAll { $0.id == accountID }
            disabled.remove(accountID)
        }
    }

    actor CredentialsStub: GatewayCredentialRemoving {
        private(set) var removed: [String] = []
        func remove(accountID: String) { removed.append(accountID) }
    }

    actor QuotaStub: QoderQuotaFetching {
        private(set) var rows: [String: ProviderQuota] = [:]
        private(set) var fetchAllCalls = 0
        func setRows(_ value: [String: ProviderQuota]) { rows = value }
        func fetchAllQuotas() -> [String: ProviderQuota] {
            fetchAllCalls += 1
            return rows
        }
        func fetchQuota(accountKey: String) -> ProviderQuota? { rows[accountKey] }
    }

    private func makeOverlay(
        host: HostStub,
        directory: DirectoryStub = DirectoryStub(),
        credentials: CredentialsStub = CredentialsStub(),
        quota: QuotaStub = QuotaStub()
    ) -> GatewayQuotaOverlay {
        GatewayQuotaOverlay(
            wrapping: host,
            quotaService: quota,
            directory: directory,
            credentials: credentials
        )
    }

    private func qoderAccount(key: String = "u1", name: String = "Qoder User") -> GatewayAccount {
        GatewayAccount.make(provider: .qoder, accountKey: key, displayName: name, source: .onboarded)
    }

    // MARK: - Merge

    func testSnapshotMergesGatewayAccountsAndQuotas() async throws {
        let host = HostStub(snapshot: QuotaSnapshot(
            providerNames: [.claude: "Claude"],
            quotas: [.claude: ["a1": ProviderQuota()]],
            accountAliases: [.claude: ["a1": "Host"]]
        ))
        let directory = DirectoryStub()
        let account = qoderAccount()
        await directory.add(account)
        let quota = QuotaStub()
        await quota.setRows(["u1": ProviderQuota(models: [QuotaMetric(name: "m", percentage: 80, resetTime: "")])])

        let overlay = makeOverlay(host: host, directory: directory, quota: quota)
        _ = await overlay.refresh(QuotaFetchRequest(provider: .qoder, mode: .monitor))
        let merged = await overlay.snapshot

        let id = QuotaAccountID(provider: .qoder, accountKey: "u1")
        XCTAssertEqual(merged.accountStates[id]?.connection, .connected)
        XCTAssertEqual(merged.accountStates[id]?.quota, .fresh)
        XCTAssertEqual(merged.quotas[.qoder]?["u1"]?.models.first?.name, "m")
        XCTAssertEqual(merged.providerNames[.qoder], "Qoder")
        XCTAssertEqual(merged.accountAliases[.qoder]?["u1"], "Qoder User")
        XCTAssertEqual(
            merged.accountIDs[.qoder]?["u1"],
            AccountIdentity.make(providerID: AccountProviderID(rawValue: "qoder"), accountKey: "u1").id
        )

        // Host data untouched.
        XCTAssertEqual(merged.providerNames[.claude], "Claude")
        XCTAssertNotNil(merged.quotas[.claude]?["a1"])
    }

    func testDisabledGatewayAccountRendersDisabled() async throws {
        let host = HostStub()
        let directory = DirectoryStub()
        let account = qoderAccount()
        await directory.add(account)
        try await directory.setDisabled(true, accountID: account.id)

        let overlay = makeOverlay(host: host, directory: directory)
        let merged = await overlay.snapshot
        let id = QuotaAccountID(provider: .qoder, accountKey: "u1")
        XCTAssertEqual(merged.accountStates[id]?.connection, .disabled)
    }

    func testStatesEmissionsAreMerged() async throws {
        let host = HostStub()
        let directory = DirectoryStub()
        await directory.add(qoderAccount())
        let overlay = makeOverlay(host: host, directory: directory)

        let collector = SnapshotCollector()
        let collectTask = Task {
            for await snapshot in overlay.states() { await collector.append(snapshot) }
        }
        defer { collectTask.cancel() }
        try await host.waitForSubscribers(1)
        await host.push(QuotaSnapshot(providerNames: [.claude: "Claude"]))

        let merged = try await collector.waitFor {
            $0.providerNames[.claude] == "Claude"
        }
        XCTAssertEqual(merged.providerNames[.qoder], "Qoder")
        XCTAssertEqual(merged.providerNames[.claude], "Claude")
        XCTAssertNotNil(merged.accountStates[QuotaAccountID(provider: .qoder, accountKey: "u1")])
    }

    func testGatewaySideChangeEmitsMergedSnapshot() async throws {
        let host = HostStub()
        let directory = DirectoryStub()
        let account = qoderAccount()
        await directory.add(account)
        let overlay = makeOverlay(host: host, directory: directory)

        let collector = SnapshotCollector()
        let collectTask = Task {
            for await snapshot in overlay.states() { await collector.append(snapshot) }
        }
        defer { collectTask.cancel() }
        let seed = try await collector.waitFor { $0.accountStates.count == 1 }
        XCTAssertEqual(
            seed.accountStates[QuotaAccountID(provider: .qoder, accountKey: "u1")]?.connection,
            .connected
        )

        await overlay.setDisabled(true, accountID: account.id)
        let updated = try await collector.waitFor {
            $0.accountStates[QuotaAccountID(provider: .qoder, accountKey: "u1")]?.connection == .disabled
        }
        XCTAssertEqual(
            updated.accountStates[QuotaAccountID(provider: .qoder, accountKey: "u1")]?.connection,
            .disabled
        )
    }

    /// Buffers stream emissions; `waitFor` polls until a matching snapshot
    /// arrives or ~2s elapse — emissions can queue ahead of the state under test.
    private actor SnapshotCollector {
        private var snapshots: [QuotaSnapshot] = []
        func append(_ snapshot: QuotaSnapshot) { snapshots.append(snapshot) }
        func waitFor(
            _ predicate: @escaping @Sendable (QuotaSnapshot) -> Bool
        ) async throws -> QuotaSnapshot {
            for _ in 0..<200 {
                if let match = snapshots.last(where: predicate) { return match }
                try await Task.sleep(for: .milliseconds(10))
            }
            throw NSError(domain: "GatewayQuotaOverlayTests", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "timed out waiting for merged snapshot",
            ])
        }
    }

    // MARK: - Refresh routing

    func testRefreshForQoderFetchesGatewayQuotas() async throws {
        let host = HostStub()
        let directory = DirectoryStub()
        await directory.add(qoderAccount())
        let quota = QuotaStub()
        await quota.setRows(["u1": ProviderQuota(models: [QuotaMetric(name: "m", percentage: 50, resetTime: "")])])
        let overlay = makeOverlay(host: host, directory: directory, quota: quota)

        _ = await overlay.refresh(QuotaFetchRequest(provider: .qoder, mode: .monitor))

        let calls = await quota.fetchAllCalls
        XCTAssertEqual(calls, 1)
        let merged = await overlay.snapshot
        XCTAssertEqual(merged.quotas[.qoder]?["u1"]?.models.first?.name, "m")
        XCTAssertFalse(merged.refreshingProviders.contains(.qoder))
    }

    func testRefreshForHostProviderSkipsGatewayService() async throws {
        let host = HostStub()
        let quota = QuotaStub()
        let overlay = makeOverlay(host: host, quota: quota)

        _ = await overlay.refresh(QuotaFetchRequest(provider: .claude, mode: .monitor))
        let calls = await quota.fetchAllCalls
        XCTAssertEqual(calls, 0)
    }

    func testRefreshAllIncludesGateway() async throws {
        let host = HostStub()
        let quota = QuotaStub()
        await quota.setRows(["u1": ProviderQuota()])
        let overlay = makeOverlay(host: host, quota: quota)
        _ = await overlay.refreshAll(mode: .monitor, providers: nil, force: true)
        let calls = await quota.fetchAllCalls
        XCTAssertEqual(calls, 1)
    }

    // MARK: - removeQuota / AccountManaging routing

    func testRemoveQuotaForGatewayAccountDeletesFromVault() async throws {
        let host = HostStub()
        let directory = DirectoryStub()
        let account = qoderAccount()
        await directory.add(account)
        let credentials = CredentialsStub()
        let overlay = makeOverlay(host: host, directory: directory, credentials: credentials)

        await overlay.removeQuota(
            for: QuotaAccountID(provider: .qoder, accountKey: "u1"),
            mode: .monitor
        )

        let removed = await credentials.removed
        XCTAssertEqual(removed, [account.id])
        let hostRemoved = await host.removedQuotaIDs
        XCTAssertTrue(hostRemoved.isEmpty)
    }

    func testRemoveQuotaForHostAccountForwards() async throws {
        let host = HostStub()
        let overlay = makeOverlay(host: host)
        let id = QuotaAccountID(provider: .claude, accountKey: "a1")
        await overlay.removeQuota(for: id, mode: .monitor)
        let hostRemoved = await host.removedQuotaIDs
        XCTAssertEqual(hostRemoved, [id])
    }

    func testSetDisabledForGatewayIDRoutesToStore() async throws {
        let host = HostStub()
        let directory = DirectoryStub()
        let account = qoderAccount()
        await directory.add(account)
        let overlay = makeOverlay(host: host, directory: directory)

        await overlay.setDisabled(true, accountID: account.id)

        let calls = await directory.setDisabledCalls
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls.first?.0, true)
        let hostCalls = await host.disabledCalls
        XCTAssertTrue(hostCalls.isEmpty)
    }

    func testSetDisabledForHostIDForwards() async throws {
        let host = HostStub()
        let overlay = makeOverlay(host: host)
        await overlay.setDisabled(true, accountID: "host-acct")
        let hostCalls = await host.disabledCalls
        XCTAssertEqual(hostCalls.count, 1)
    }

    func testDeleteGatewayIDRoutesToVault() async throws {
        let host = HostStub()
        let directory = DirectoryStub()
        let account = qoderAccount()
        await directory.add(account)
        let credentials = CredentialsStub()
        let overlay = makeOverlay(host: host, directory: directory, credentials: credentials)

        try await overlay.delete(accountID: account.id)

        let removed = await credentials.removed
        XCTAssertEqual(removed, [account.id])
        let hostDeletes = await host.deleteCalls
        XCTAssertTrue(hostDeletes.isEmpty)
    }

    func testAccountsMergesGatewayAccounts() async throws {
        let host = HostStub()
        let directory = DirectoryStub()
        let account = qoderAccount()
        await directory.add(account)
        let overlay = makeOverlay(host: host, directory: directory)

        let accounts = await overlay.accounts()
        let surfaced = try XCTUnwrap(accounts.first { $0.providerID.rawValue == "qoder" })
        XCTAssertEqual(surfaced.accountKey, "u1")
        XCTAssertEqual(surfaced.displayName, "Qoder User")
        XCTAssertTrue(surfaced.canDelete)
        XCTAssertEqual(surfaced.status, .ready)
    }

    func testSurfacedAccountIDRoutesDisableAndDelete() async throws {
        let host = HostStub()
        let directory = DirectoryStub()
        let account = qoderAccount()
        await directory.add(account)
        let credentials = CredentialsStub()
        let overlay = makeOverlay(host: host, directory: directory, credentials: credentials)

        let surfacedID = AccountIdentity.make(
            providerID: AccountProviderID(rawValue: "qoder"), accountKey: "u1"
        ).id
        await overlay.setDisabled(true, accountID: surfacedID)
        let disableCalls = await directory.setDisabledCalls
        XCTAssertEqual(disableCalls.map(\.1), [account.id])
        try await overlay.delete(accountID: surfacedID)
        let removed = await credentials.removed
        XCTAssertEqual(removed, [account.id])
        let hostDeletes = await host.deleteCalls
        XCTAssertTrue(hostDeletes.isEmpty)
    }

    func testDetectedGatewayAccountCannotBeDeleted() async throws {
        let host = HostStub()
        let directory = DirectoryStub()
        await directory.add(GatewayAccount.make(
            provider: .opencode, accountKey: "oc", source: .detected
        ))
        let overlay = makeOverlay(host: host, directory: directory)
        let accounts = await overlay.accounts()
        let surfaced = try XCTUnwrap(accounts.first { $0.providerID.rawValue == "opencode" })
        XCTAssertFalse(surfaced.canDelete)
    }

    // MARK: - MonitoringSettingsManaging

    func testMonitoringProvidersAppendsGatewayDescriptors() async throws {
        let host = HostStub(providers: [
            MonitoringProvider(id: .claude, displayName: "Claude", actions: ["authorize_native"], inputs: []),
        ])
        let overlay = makeOverlay(host: host)
        let providers = try await overlay.monitoringProviders()

        XCTAssertEqual(providers.map(\.id), [.claude, .qoder, .opencode])
        let opencode = providers.first { $0.id == .opencode }
        XCTAssertTrue(opencode?.actions.contains("authorize_native") == true)
    }

    func testMonitoringSettingsReportsGatewayProvidersEnabled() async throws {
        let host = HostStub(settings: MonitoringSettings(
            revision: "r1",
            enabledProviders: ["claude"],
            disabledProviders: ["qoder"],
            automaticallyDiscoverLogins: true,
            refreshInterval: 60
        ))
        let overlay = makeOverlay(host: host)
        let settings = try await overlay.monitoringSettings()

        XCTAssertTrue(settings.enabledProviders.contains("qoder"))
        XCTAssertTrue(settings.enabledProviders.contains("opencode"))
        XCTAssertFalse(settings.disabledProviders.contains("qoder"))
        XCTAssertTrue(settings.enabledProviders.contains("claude"))
    }

    func testUpdateMonitoringSettingsStripsGatewayIDs() async throws {
        let host = HostStub()
        let overlay = makeOverlay(host: host)
        _ = try await overlay.updateMonitoringSettings(MonitoringSettings(
            revision: "r1",
            enabledProviders: ["claude", "qoder"],
            disabledProviders: ["opencode"],
            automaticallyDiscoverLogins: true,
            refreshInterval: 30
        ))

        let forwarded = await host.updatedSettings
        XCTAssertEqual(forwarded.first?.enabledProviders, ["claude"])
        XCTAssertEqual(forwarded.first?.disabledProviders, [])
    }
}

// MARK: - HostStub protocol conformances

extension GatewayQuotaOverlayTests.HostStub: QuotaCoordinating {
    var snapshot: QuotaSnapshot { hostSnapshot }
    func states() -> AsyncStream<QuotaSnapshot> {
        AsyncStream { continuation in
            let id = UUID()
            continuations[id] = continuation
            continuation.yield(hostSnapshot)
            continuation.onTermination = { _ in
                Task { await self.drop(id: id) }
            }
        }
    }

    private func drop(id: UUID) { continuations.removeValue(forKey: id) }

    func bootstrap(mode: QuotaOperatingMode) -> QuotaSnapshot { hostSnapshot }
    func refresh(_ request: QuotaFetchRequest) -> QuotaSnapshot {
        refreshCalls.append(request)
        return hostSnapshot
    }
    func refreshAll(mode: QuotaOperatingMode, providers: Set<QuotaProvider>?, force: Bool) -> QuotaSnapshot {
        refreshAllCalls += 1
        return hostSnapshot
    }
    func removeQuota(for account: QuotaAccountID, mode: QuotaOperatingMode) {
        removedQuotaIDs.append(account)
    }
    func cancel(provider: QuotaProvider) {}
    func cancelForTermination() {}
}

extension GatewayQuotaOverlayTests.HostStub: AccountManaging {
    func registerDetectedNativeAccounts() {}
    func rescanNativeAccounts(for provider: QuotaProvider) {}
    func authorizeNativeSource(_ source: NativeSourcePermission) throws {}
    func accounts() -> [Account] { [] }
    func setDisabled(_ disabled: Bool, accountID: String) {
        disabledCalls.append((disabled, accountID))
    }
    func delete(accountID: String) throws {
        deleteCalls.append(accountID)
    }
    func renameResolvedAccount(id: String, userLabel: String?) throws {}
    func setSourceEnabled(_ enabled: Bool, sourceID: String) throws {}
    func unlinkSource(sourceID: String) throws {}
    func saveAPIKey(
        providerID: AccountProviderID,
        label: String,
        apiKey: String,
        existingAccountID: String?,
        fields: [String: String]
    ) throws {}
}

extension GatewayQuotaOverlayTests.HostStub: MonitoringSettingsManaging {
    func monitoringProviders() throws -> [MonitoringProvider] { providers }
    func monitoringSettings() throws -> MonitoringSettings { settings }
    func updateMonitoringSettings(_ settings: MonitoringSettings) throws -> MonitoringSettings {
        updatedSettings.append(settings)
        self.settings = settings
        return settings
    }
}
