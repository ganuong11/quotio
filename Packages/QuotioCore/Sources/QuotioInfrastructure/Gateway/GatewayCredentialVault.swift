import Foundation
import QuotioApplication
import QuotioDomain

public enum GatewayCredentialError: Error {
    case credentialWriteFailed
}

/// Keychain-backed credential vault for gateway accounts, keyed by
/// `accountKey`. Wraps an injected `KeychainCredentialDataStore` (service
/// resolved at the composition root) plus a `GatewayAccountStore` for
/// metadata. Rotation uses compare-and-swap on the last-read generation so a
/// stale writer can never clobber a fresher credential.
public actor GatewayCredentialVault {
    private let dataStore: KeychainCredentialDataStore
    private let metadata: GatewayAccountStore
    private var loadedGenerations: [String: String] = [:]

    public init(dataStore: KeychainCredentialDataStore, accounts: GatewayAccountStore) {
        self.dataStore = dataStore
        self.metadata = accounts
    }

    public func accounts() async -> [GatewayAccount] {
        await metadata.accounts()
    }

    public func credential(for accountKey: String) async -> GatewayCredential? {
        guard let record = await dataStore.read(accountID: accountKey) else { return nil }
        loadedGenerations[accountKey] = record.generation
        return try? JSONDecoder().decode(GatewayCredential.self, from: record.data)
    }

    /// Returns the raw stored record so callers needing the generation can
    /// chain a `compareAndSwap` without a second read.
    public func record(for accountKey: String) async -> CredentialDataRecord? {
        let record = await dataStore.read(accountID: accountKey)
        loadedGenerations[accountKey] = record?.generation
        return record
    }

    public func store(_ credential: GatewayCredential, account: GatewayAccount) async throws {
        let data = try JSONEncoder().encode(credential)
        let saved: CredentialDataRecord?
        if let expected = loadedGenerations[account.accountKey] {
            saved = await dataStore.compareAndSwap(
                data,
                accountID: account.accountKey,
                expectedGeneration: expected
            )
        } else {
            saved = await dataStore.save(data, accountID: account.accountKey)
        }
        guard let saved else { throw GatewayCredentialError.credentialWriteFailed }
        loadedGenerations[account.accountKey] = saved.generation
        try await metadata.saveAccount(account)
    }

    public func remove(accountKey: String) async {
        await dataStore.delete(accountID: accountKey)
        loadedGenerations.removeValue(forKey: accountKey)
        try? await metadata.deleteAccount(accountKey: accountKey)
    }
}
