import Foundation
import QuotioApplication
import QuotioDomain

public enum GatewayCredentialError: Error {
    case credentialWriteFailed
}

/// Keychain-backed credential vault for gateway accounts, keyed by
/// `accountID`. Wraps an injected `KeychainCredentialDataStore` (service
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

    public func credential(for accountID: String) async -> GatewayCredential? {
        guard let record = await dataStore.read(accountID: accountID) else { return nil }
        loadedGenerations[accountID] = record.generation
        return try? JSONDecoder().decode(GatewayCredential.self, from: record.data)
    }

    /// Returns the raw stored record so callers needing the generation can
    /// chain a `compareAndSwap` without a second read.
    public func record(for accountID: String) async -> CredentialDataRecord? {
        let record = await dataStore.read(accountID: accountID)
        loadedGenerations[accountID] = record?.generation
        return record
    }

    public func store(_ credential: GatewayCredential, account: GatewayAccount) async throws {
        let data = try JSONEncoder().encode(credential)
        let saved: CredentialDataRecord?
        if let expected = loadedGenerations[account.id] {
            saved = await dataStore.compareAndSwap(
                data,
                accountID: account.id,
                expectedGeneration: expected
            )
        } else {
            saved = await dataStore.save(data, accountID: account.id)
        }
        guard let saved else { throw GatewayCredentialError.credentialWriteFailed }
        loadedGenerations[account.id] = saved.generation
        try await metadata.saveAccount(account)
    }

    public func remove(accountID: String) async {
        await dataStore.delete(accountID: accountID)
        loadedGenerations.removeValue(forKey: accountID)
        try? await metadata.deleteAccount(accountID: accountID)
    }
}

extension GatewayCredentialVault: GatewayCredentialStoring {}
extension GatewayCredentialVault: GatewayCredentialRemoving {}
