import Foundation
import QuotioApplication
import QuotioDomain

/// One-time import of `qoder`/`opencode` account records from the legacy
/// monitor vault (`dev.quotio.desktop.monitor-auth` + the legacy accounts
/// file) into the gateway vault. Legacy items are left in place — this is a
/// copy, not a move.
public actor GatewayLegacyImport {
    private struct LegacyAccount: Codable {
        var id: String
        var provider: String
        var accountKey: String
        var displayName: String
        var isDisabled: Bool?
        var email: String?
    }

    private struct LegacyPayload: Codable {
        var accounts: [LegacyAccount]
        var disabledAccountIDs: [String]?
    }

    private let legacyAccountsURL: URL
    private let legacyServices: [String]
    private let reader: ExternalKeychainCredentialReader

    public init(
        legacyAccountsURL: URL,
        legacyServices: [String],
        reader: ExternalKeychainCredentialReader
    ) {
        self.legacyAccountsURL = legacyAccountsURL
        self.legacyServices = legacyServices
        self.reader = reader
    }

    /// Imports any not-yet-present qoder/opencode accounts. Returns the number
    /// of accounts imported on this run. Idempotent: accountKeys already in
    /// the vault are skipped.
    @discardableResult
    public func run(into vault: GatewayCredentialVault) async -> Int {
        guard let data = try? Data(contentsOf: legacyAccountsURL),
              let payload = try? JSONDecoder().decode(LegacyPayload.self, from: data) else { return 0 }

        let existing = await vault.accounts().map { $0.accountKey }
        var imported = 0
        for legacy in payload.accounts where GatewayProvider(rawValue: legacy.provider) != nil {
            guard !existing.contains(legacy.accountKey) else { continue }
            var record: ExternalCredentialRecord?
            for service in legacyServices {
                if let found = await reader.read(service: service, account: legacy.id) {
                    record = found
                    break
                }
            }
            guard let record,
                  let credential = try? JSONDecoder().decode(GatewayCredential.self, from: record.data)
            else { continue }

            let provider = GatewayProvider(rawValue: legacy.provider)!
            let account = GatewayAccount(
                id: "gateway-" + GatewayIdentity.fingerprint("\(provider.rawValue)|\(legacy.accountKey.lowercased())"),
                provider: provider,
                accountKey: legacy.accountKey,
                displayName: legacy.displayName,
                source: .legacyImport,
                isDisabled: legacy.isDisabled ?? false,
                email: legacy.email
            )
            do {
                try await vault.store(credential, account: account)
                imported += 1
            } catch {
                // A partial import simply doesn't count — a later run retries it.
            }
        }
        return imported
    }
}
