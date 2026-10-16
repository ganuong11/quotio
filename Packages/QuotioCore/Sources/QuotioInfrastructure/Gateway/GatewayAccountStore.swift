import Foundation
import QuotioDomain

/// Persists gateway account metadata to `gateway-accounts-v1.json` in the
/// identity-scoped Application Support directory. Never writes to the legacy
/// monitor accounts file — that file stays a read-only import source.
public actor GatewayAccountStore {
    private struct Payload: Codable {
        var accounts: [GatewayAccount] = []
        var disabledAccountKeys: Set<String> = []
    }

    private let url: URL

    public init(url: URL) {
        self.url = url
    }

    public init(identity: RuntimeIdentity) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.url = base
            .appendingPathComponent(identity.applicationSupportDirectoryName, isDirectory: true)
            .appendingPathComponent("Gateway", isDirectory: true)
            .appendingPathComponent("gateway-accounts-v1.json")
    }

    public func accounts() -> [GatewayAccount] { load().accounts }
    public func disabledAccountIDs() -> Set<String> { load().disabledAccountKeys }

    public func saveAccount(_ account: GatewayAccount) throws {
        var payload = load()
        payload.accounts.removeAll { $0.accountKey == account.accountKey }
        payload.accounts.append(account)
        try save(payload)
    }

    public func deleteAccount(accountKey: String) throws {
        var payload = load()
        payload.accounts.removeAll { $0.accountKey == accountKey }
        payload.disabledAccountKeys.remove(accountKey)
        try save(payload)
    }

    public func setDisabled(_ disabled: Bool, accountKey: String) throws {
        var payload = load()
        if disabled { payload.disabledAccountKeys.insert(accountKey) }
        else { payload.disabledAccountKeys.remove(accountKey) }
        try save(payload)
    }

    private func load() -> Payload {
        guard let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else { return Payload() }
        return payload
    }

    private func save(_ payload: Payload) throws {
        try SecureAtomicFileWriter.write(try JSONEncoder().encode(payload), to: url)
    }
}
