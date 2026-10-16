//
//  GatewayQuotaOverlay.swift
//  QuotioCore
//
//  Decorator in front of `QuotioCLIBackend` for the three surfaces that need to
//  see gateway-native accounts (Qoder today; OpenCode when its tasks land):
//
//    - `QuotaCoordinating`  — merges gateway accounts, quota rows, provider
//      names, aliases/IDs, and refresh state into every `QuotaSnapshot`,
//      including each emission of `states()`; routes gateway refreshes to
//      `GatewayQuotaService` and `removeQuota` to the vault.
//    - `AccountManaging`    — `setDisabled`/`delete` for gateway-owned account
//      IDs route to `GatewayAccountStore`/vault (the host doesn't know these
//      accounts and would silently no-op).
//    - `MonitoringSettingsManaging` — appends gateway `MonitoringProvider`
//      descriptors and reports them enabled; strips gateway IDs before
//      forwarding settings updates to the host.
//
//  Gateway accounts surface through the quota snapshot (`accountStates`,
//  `accountAliases`, `accountIDs`) rather than `accounts()` — the settings UI
//  derives its rows from the snapshot's `accountIDs` map, which the overlay
//  points at `GatewayAccount.id`, making disable/delete routing reachable.
//

import Foundation
import QuotioApplication
import QuotioDomain

public actor GatewayQuotaOverlay {
    public typealias Host = QuotaCoordinating & AccountManaging & MonitoringSettingsManaging

    private let host: any Host
    private let quotaService: any QoderQuotaFetching
    private let directory: any GatewayAccountDirectory
    private let credentials: any GatewayCredentialRemoving

    private var quotaCache: [QuotaProvider: [String: ProviderQuota]] = [:]
    private var refreshing: Set<QuotaProvider> = []
    /// The most recent raw host snapshot; merged output is always derived from it.
    private var hostSnapshot: QuotaSnapshot?
    private var upstreamTask: Task<Void, Never>?
    private var continuations: [UUID: AsyncStream<QuotaSnapshot>.Continuation] = [:]

    public init(
        wrapping host: any Host,
        quotaService: any QoderQuotaFetching,
        directory: any GatewayAccountDirectory,
        credentials: any GatewayCredentialRemoving
    ) {
        self.host = host
        self.quotaService = quotaService
        self.directory = directory
        self.credentials = credentials
    }

    // MARK: - Merge

    private static func quotaProvider(for provider: GatewayProvider) -> QuotaProvider {
        QuotaProvider(rawValue: provider.rawValue) ?? .qoder
    }

    private func merged(_ host: QuotaSnapshot) async -> QuotaSnapshot {
        var snapshot = host
        let accounts = await directory.accounts()
        let disabledIDs = await directory.disabledAccountIDs()

        for account in accounts {
            let provider = Self.quotaProvider(for: account.provider)
            guard QuotaProvider.gatewayNativeProviders.contains(provider) else { continue }
            let id = QuotaAccountID(provider: provider, accountKey: account.accountKey)
            let disabled = disabledIDs.contains(account.id) || account.isDisabled

            snapshot.accountStates[id] = AccountMonitoringState(
                connection: disabled ? .disabled : .connected,
                quota: quotaCache[provider]?[account.accountKey] != nil ? .fresh : .notLoaded
            )
            snapshot.providerNames[provider] = provider.rawValue == "qoder" ? "Qoder" : "OpenCode"
            snapshot.accountAliases[provider, default: [:]][account.accountKey] = account.displayName
            snapshot.accountIDs[provider, default: [:]][account.accountKey] = account.id
        }

        for (provider, quotas) in quotaCache {
            snapshot.quotas[provider] = quotas
        }
        snapshot.refreshingProviders.formUnion(refreshing)
        return snapshot
    }

    private func publishMerged() async {
        guard let hostSnapshot else { return }
        let merged = await merged(hostSnapshot)
        for continuation in continuations.values {
            continuation.yield(merged)
        }
    }

    private func currentMerged() async -> QuotaSnapshot {
        let host = await host.snapshot
        hostSnapshot = host
        return await merged(host)
    }

    // MARK: - QuotaCoordinating

    public nonisolated func states() -> AsyncStream<QuotaSnapshot> {
        AsyncStream { continuation in
            let id = UUID()
            Task {
                await self.register(continuation, id: id)
            }
            continuation.onTermination = { _ in
                Task { await self.unregister(id: id) }
            }
        }
    }

    private func register(_ continuation: AsyncStream<QuotaSnapshot>.Continuation, id: UUID) {
        continuations[id] = continuation
        startUpstreamIfNeeded()
        Task {
            let merged = await currentMerged()
            continuation.yield(merged)
        }
    }

    private func unregister(id: UUID) {
        continuations.removeValue(forKey: id)
        if continuations.isEmpty {
            upstreamTask?.cancel()
            upstreamTask = nil
        }
    }

    private func startUpstreamIfNeeded() {
        guard upstreamTask == nil else { return }
        upstreamTask = Task { [host] in
            let stream = await host.states()
            for await snapshot in stream {
                if Task.isCancelled { break }
                await self.accept(hostSnapshot: snapshot)
            }
        }
    }

    private func accept(hostSnapshot snapshot: QuotaSnapshot) async {
        hostSnapshot = snapshot
        await publishMerged()
    }

    public var snapshot: QuotaSnapshot {
        get async { await currentMerged() }
    }

    public func bootstrap(mode: QuotaOperatingMode) async -> QuotaSnapshot {
        let host = await host.bootstrap(mode: mode)
        hostSnapshot = host
        await publishMerged()
        return await merged(host)
    }

    public func refresh(_ request: QuotaFetchRequest) async -> QuotaSnapshot {
        var host = await host.refresh(request)
        if QuotaProvider.gatewayNativeProviders.contains(request.provider) {
            refreshing.insert(request.provider)
            hostSnapshot = host
            await publishMerged()

            quotaCache[request.provider] = await quotaService.fetchAllQuotas()
            refreshing.remove(request.provider)
            host = await self.host.snapshot
        }
        hostSnapshot = host
        await publishMerged()
        return await merged(host)
    }

    public func refreshAll(
        mode: QuotaOperatingMode,
        providers: Set<QuotaProvider>?,
        force: Bool
    ) async -> QuotaSnapshot {
        var host = await host.refreshAll(mode: mode, providers: providers, force: force)
        let targets = (providers ?? QuotaProvider.gatewayNativeProviders)
            .intersection(QuotaProvider.gatewayNativeProviders)
        if !targets.isEmpty {
            refreshing.formUnion(targets)
            hostSnapshot = host
            await publishMerged()

            quotaCache[.qoder] = await quotaService.fetchAllQuotas()
            refreshing.subtract(targets)
            host = await self.host.snapshot
        }
        hostSnapshot = host
        await publishMerged()
        return await merged(host)
    }

    public func removeQuota(for account: QuotaAccountID, mode: QuotaOperatingMode) async {
        guard QuotaProvider.gatewayNativeProviders.contains(account.provider) else {
            await host.removeQuota(for: account, mode: mode)
            return
        }
        let accounts = await directory.accounts()
        if let match = accounts.first(where: {
            Self.quotaProvider(for: $0.provider) == account.provider
                && $0.accountKey == account.accountKey
        }) {
            await credentials.remove(accountID: match.id)
        }
        quotaCache[account.provider]?.removeValue(forKey: account.accountKey)
        await publishMerged()
    }

    public func cancel(provider: QuotaProvider) async {
        refreshing.remove(provider)
        await host.cancel(provider: provider)
    }

    public func cancelForTermination() async {
        upstreamTask?.cancel()
        for continuation in continuations.values {
            continuation.finish()
        }
        continuations.removeAll()
        await host.cancelForTermination()
    }

    // MARK: - AccountManaging

    private func isGatewayAccountID(_ accountID: String) async -> Bool {
        await directory.accounts().contains { $0.id == accountID }
    }

    public func registerDetectedNativeAccounts() async {
        await host.registerDetectedNativeAccounts()
    }

    public func rescanNativeAccounts(for provider: QuotaProvider) async {
        await host.rescanNativeAccounts(for: provider)
    }

    public func rescanAllNativeAccounts() async {
        await host.rescanAllNativeAccounts()
    }

    public func nativeDiscoverySnapshot() async -> NativeDiscoverySnapshot {
        await host.nativeDiscoverySnapshot()
    }

    public func authorizeNativeSource(_ source: NativeSourcePermission) async throws {
        try await host.authorizeNativeSource(source)
    }

    public func addLocalAccount(
        provider: QuotaProvider,
        kind: String,
        configDirectory: String,
        entryKey: String?,
        label: String?
    ) async throws {
        try await host.addLocalAccount(
            provider: provider, kind: kind, configDirectory: configDirectory,
            entryKey: entryKey, label: label
        )
    }

    public func accountStorageProblem() async -> AccountStorageProblem? {
        await host.accountStorageProblem()
    }

    public func authorizeAccountStorage() async throws {
        try await host.authorizeAccountStorage()
    }

    public func accounts() async -> [Account] {
        await host.accounts()
    }

    public func setDisabled(_ disabled: Bool, accountID: String) async {
        if await isGatewayAccountID(accountID) {
            try? await directory.setDisabled(disabled, accountID: accountID)
            await publishMerged()
            return
        }
        await host.setDisabled(disabled, accountID: accountID)
    }

    public func delete(accountID: String) async throws {
        if await isGatewayAccountID(accountID) {
            await credentials.remove(accountID: accountID)
            await publishMerged()
            return
        }
        try await host.delete(accountID: accountID)
    }

    public func renameResolvedAccount(id: String, userLabel: String?) async throws {
        try await host.renameResolvedAccount(id: id, userLabel: userLabel)
    }

    public func setSourceEnabled(_ enabled: Bool, sourceID: String) async throws {
        try await host.setSourceEnabled(enabled, sourceID: sourceID)
    }

    public func unlinkSource(sourceID: String) async throws {
        try await host.unlinkSource(sourceID: sourceID)
    }

    public func saveAPIKey(
        providerID: AccountProviderID,
        label: String,
        apiKey: String,
        existingAccountID: String?,
        fields: [String: String]
    ) async throws {
        try await host.saveAPIKey(
            providerID: providerID, label: label, apiKey: apiKey,
            existingAccountID: existingAccountID, fields: fields
        )
    }

    // MARK: - MonitoringSettingsManaging

    private static let gatewayProviderDescriptors: [MonitoringProvider] = [
        MonitoringProvider(id: .qoder, displayName: "Qoder", actions: [], inputs: []),
        MonitoringProvider(id: .opencode, displayName: "OpenCode", actions: ["authorize_native"], inputs: []),
    ]

    public func monitoringProviders() async throws -> [MonitoringProvider] {
        var providers = try await host.monitoringProviders()
        let existing = Set(providers.map(\.id))
        providers.append(contentsOf: Self.gatewayProviderDescriptors.filter { !existing.contains($0.id) })
        return providers
    }

    public func monitoringSettings() async throws -> MonitoringSettings {
        var settings = try await host.monitoringSettings()
        for provider in QuotaProvider.gatewayNativeProviders {
            settings.enabledProviders.insert(provider.rawValue)
            settings.disabledProviders.remove(provider.rawValue)
        }
        return settings
    }

    public func updateMonitoringSettings(_ settings: MonitoringSettings) async throws -> MonitoringSettings {
        var stripped = settings
        for provider in QuotaProvider.gatewayNativeProviders {
            stripped.enabledProviders.remove(provider.rawValue)
            stripped.disabledProviders.remove(provider.rawValue)
        }
        var updated = try await host.updateMonitoringSettings(stripped)
        for provider in QuotaProvider.gatewayNativeProviders {
            updated.enabledProviders.insert(provider.rawValue)
            updated.disabledProviders.remove(provider.rawValue)
        }
        return updated
    }
}

extension GatewayQuotaOverlay: QuotaCoordinating {}
extension GatewayQuotaOverlay: AccountManaging {}
extension GatewayQuotaOverlay: MonitoringSettingsManaging {}
