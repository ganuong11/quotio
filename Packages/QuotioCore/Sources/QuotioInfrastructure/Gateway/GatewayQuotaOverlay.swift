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
//  Gateway accounts surface as synthesized `Account` rows in `accounts()` —
//  the settings UI renders them and calls disable/delete with their surfaced
//  (`monitor-…`) ID — and as `accountStates`/`accountAliases`/`accountIDs`
//  entries in the quota snapshot. `delete` is offered only for onboarded or
//  legacy-imported records; detected accounts are read-only (the owning CLI
//  still holds the credential).
//

import Foundation
import QuotioApplication
import QuotioDomain

public actor GatewayQuotaOverlay {
    public typealias Host = QuotaCoordinating & AccountManaging & MonitoringSettingsManaging

    /// Mutable holder for NotificationCenter observer tokens — `NSObjectProtocol`
    /// isn't Sendable, so it can't live in actor state read from the
    /// nonisolated deinit. Contents are only mutated during init/deinit.
    private final class ObserverBox: @unchecked Sendable {
        var tokens: [NSObjectProtocol] = []
    }

    private let host: any Host
    private let quotaService: any QoderQuotaFetching
    private let directory: any GatewayAccountDirectory
    private let credentials: any GatewayCredentialRemoving
    /// Synchronous snapshot of OpenCode credentials detected in the native
    /// install (fed by `OpencodeDetectedCache`). Detected accounts surface
    /// read-only — the owning CLI still holds the credential.
    private let detectedOpencode: @Sendable () -> [DetectedOpencodeCredential]

    private var quotaCache: [QuotaProvider: [String: ProviderQuota]] = [:]
    private var refreshing: Set<QuotaProvider> = []
    /// The most recent raw host snapshot; merged output is always derived from it.
    private var hostSnapshot: QuotaSnapshot?
    private var upstreamTask: Task<Void, Never>?
    private var continuations: [UUID: AsyncStream<QuotaSnapshot>.Continuation] = [:]
    /// OpenCode accounts whose credential is stale (router-reported), keyed by
    /// lowercased `accountKey` → displayName. Folds into `accountIssues` on
    /// every merged snapshot until a `…account-recovered` notification clears
    /// the entry.
    private var opencodeStaleAccounts: [String: String] = [:]
    /// Router-reported 429 cooldowns, keyed by lowercased `accountKey` → the
    /// cooldown's expiry. Self-expiring; consumers compare against now.
    private var opencodeRateLimits: [String: Date] = [:]
    /// Sendable box for the observer tokens so the actor's nonisolated
    /// init/deinit can hold them.
    private let notificationObservers = ObserverBox()

    public init(
        wrapping host: any Host,
        quotaService: any QoderQuotaFetching,
        directory: any GatewayAccountDirectory,
        credentials: any GatewayCredentialRemoving,
        detectedOpencode: @escaping @Sendable () -> [DetectedOpencodeCredential] = { [] }
    ) {
        self.host = host
        self.quotaService = quotaService
        self.directory = directory
        self.credentials = credentials
        self.detectedOpencode = detectedOpencode
        notificationObservers.tokens = [
            NotificationCenter.default.addObserver(
                forName: OpencodeRouter.opencodeAccountStale, object: nil, queue: nil
            ) { [weak self] note in
                guard let key = note.userInfo?["accountKey"] as? String,
                      let name = note.userInfo?["displayName"] as? String else { return }
                Task { await self?.markOpencodeStale(key: key, displayName: name) }
            },
            NotificationCenter.default.addObserver(
                forName: OpencodeRouter.opencodeAccountRecovered, object: nil, queue: nil
            ) { [weak self] note in
                guard let key = note.userInfo?["accountKey"] as? String else { return }
                Task { await self?.markOpencodeRecovered(key: key) }
            },
            NotificationCenter.default.addObserver(
                forName: OpencodeRouter.opencodeAccountRateLimited, object: nil, queue: nil
            ) { [weak self] note in
                guard let key = note.userInfo?["accountKey"] as? String else { return }
                let retryAfter = (note.userInfo?["retryAfter"] as? TimeInterval) ?? 0
                Task { await self?.applyOpencodeRateLimit(key: key, retryAfter: retryAfter) }
            },
        ]
    }

    deinit {
        for observer in notificationObservers.tokens {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func markOpencodeStale(key: String, displayName: String) {
        opencodeStaleAccounts[key.lowercased()] = displayName
        Task { await publishMerged() }
    }

    private func markOpencodeRecovered(key: String) {
        guard opencodeStaleAccounts.removeValue(forKey: key.lowercased()) != nil else { return }
        Task { await publishMerged() }
    }

    private func applyOpencodeRateLimit(key: String, retryAfter: TimeInterval) {
        Self.applyOpencodeRateLimit(accountKey: key, retryAfter: retryAfter, to: &opencodeRateLimits)
    }

    // MARK: - OpenCode issue/rate-limit cores (pure statics — testable without
    // constructing the overlay; the instance methods above are thin shells)

    /// Set or clear the stale-credential issue on the matching gateway
    /// account. `issues` keys by the account's own `accountKey` casing.
    public nonisolated static func applyOpencodeIssue(
        accountKey: String,
        stale: Bool,
        to accounts: [GatewayAccount],
        issues: inout [QuotaAccountID: QuotaRefreshIssue],
        now: Date = Date()
    ) {
        guard let account = accounts.first(where: {
            $0.provider == .opencode
                && $0.accountKey.caseInsensitiveCompare(accountKey) == .orderedSame
        }) else { return }
        let id = QuotaAccountID(provider: .opencode, accountKey: account.accountKey)
        if stale {
            issues[id] = QuotaRefreshIssue(
                kind: .failed, occurredAt: now, reason: .stale)
        } else {
            issues.removeValue(forKey: id)
        }
    }

    /// Record a router-reported 429 cooldown for an opencode account.
    public nonisolated static func applyOpencodeRateLimit(
        accountKey: String,
        retryAfter: TimeInterval,
        to limits: inout [String: Date],
        now: Date = Date()
    ) {
        limits[accountKey.lowercased()] = now.addingTimeInterval(retryAfter)
    }

    /// Cooldown expiry for an opencode account still inside its rate-limit
    /// window — nil for unknown keys and expired entries.
    public nonisolated static func opencodeRateLimitUntil(
        accountKey: String,
        in limits: [String: Date],
        now: Date = Date()
    ) -> Date? {
        guard let until = limits[accountKey.lowercased()], until > now else { return nil }
        return until
    }

    // MARK: - Merge

    private static func quotaProvider(for provider: GatewayProvider) -> QuotaProvider {
        QuotaProvider(rawValue: provider.rawValue) ?? .qoder
    }

    /// Detected OpenCode credentials materialized as gateway accounts, minus
    /// those already stored (the managed account wins — same priority as the
    /// router's candidate list).
    private func detectedAccounts(stored: [GatewayAccount]) -> [GatewayAccount] {
        let storedKeys = Set(stored.map { $0.accountKey.lowercased() })
        return detectedOpencode()
            .filter { !storedKeys.contains($0.accountKey.lowercased()) }
            .map {
                GatewayAccount.make(
                    provider: .opencode,
                    accountKey: $0.accountKey,
                    displayName: $0.email ?? $0.suggestedDisplayName,
                    source: .detected,
                    email: $0.email
                )
            }
    }

    /// The `Account.id` a gateway account surfaces as — `monitor-`-prefixed,
    /// matching `AccountIdentity.make(providerID:accountKey:)` so rows rendered
    /// from `accounts()` line up with `accountIDs`/`accountIssues` maps.
    private static func surfaceAccountID(for account: GatewayAccount, provider: QuotaProvider) -> String {
        AccountIdentity.make(
            providerID: AccountProviderID(rawValue: provider.rawValue),
            accountKey: account.accountKey
        ).id
    }

    private static func surfaceAccount(
        for account: GatewayAccount,
        disabled: Bool
    ) -> Account {
        let provider = quotaProvider(for: account.provider)
        let deletable = account.source == .onboarded || account.source == .legacyImport
        return Account.make(
            providerID: AccountProviderID(rawValue: provider.rawValue),
            accountKey: account.accountKey,
            displayName: account.displayName,
            source: .quotioKeychain,
            capabilities: deletable ? [.disable, .delete] : [.disable],
            status: disabled ? .disabled : .ready
        )
    }

    private func merged(_ host: QuotaSnapshot) async -> QuotaSnapshot {
        var snapshot = host
        let stored = await directory.accounts()
        let accounts = stored + detectedAccounts(stored: stored)
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
            snapshot.accountIDs[provider, default: [:]][account.accountKey] =
                Self.surfaceAccountID(for: account, provider: provider)
        }

        for (provider, quotas) in quotaCache {
            snapshot.quotas[provider] = quotas
        }
        for (staleKey, _) in opencodeStaleAccounts {
            Self.applyOpencodeIssue(
                accountKey: staleKey, stale: true,
                to: accounts, issues: &snapshot.accountIssues)
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

    /// Resolve an incoming account ID — either the vault's `GatewayAccount.id`
    /// or the surfaced `Account.id` — to its gateway record.
    private func gatewayAccount(for accountID: String) async -> GatewayAccount? {
        let stored = await directory.accounts()
        return (stored + detectedAccounts(stored: stored)).first { account in
            account.id == accountID
                || Self.surfaceAccountID(
                    for: account,
                    provider: Self.quotaProvider(for: account.provider)
                ) == accountID
        }
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
        var accounts = await host.accounts()
        let disabledIDs = await directory.disabledAccountIDs()
        let stored = await directory.accounts()
        for account in stored + detectedAccounts(stored: stored)
        where QuotaProvider.gatewayNativeProviders.contains(Self.quotaProvider(for: account.provider)) {
            accounts.append(Self.surfaceAccount(
                for: account,
                disabled: disabledIDs.contains(account.id) || account.isDisabled
            ))
        }
        return accounts
    }

    public func setDisabled(_ disabled: Bool, accountID: String) async {
        if let account = await gatewayAccount(for: accountID) {
            try? await directory.setDisabled(disabled, accountID: account.id)
            await publishMerged()
            return
        }
        await host.setDisabled(disabled, accountID: accountID)
    }

    public func delete(accountID: String) async throws {
        if let account = await gatewayAccount(for: accountID) {
            await credentials.remove(accountID: account.id)
            quotaCache[Self.quotaProvider(for: account.provider)]?
                .removeValue(forKey: account.accountKey)
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
