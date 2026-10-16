import CryptoKit
import Foundation

/// Providers routed by the Swift gateway front door. Deliberately a narrow
/// enum — the gateway owns exactly two provider namespaces.
public enum GatewayProvider: String, Codable, Sendable, CaseIterable {
    case qoder
    case opencode
}

/// Where a gateway account's credential came from.
public enum GatewayAccountSource: String, Codable, Sendable {
    /// Onboarded through Quotio (PAT entry, device OAuth).
    case onboarded
    /// Copied from the legacy monitor vault during the one-time import.
    case legacyImport
    /// Detected from the provider's own local credential files.
    case detected
}

/// One onboarded gateway account. The vault keys credentials by `accountKey`
/// (stable identity chosen at onboarding), not by `id` — `id` exists for UI
/// list identity only.
public struct GatewayAccount: Identifiable, Codable, Hashable, Sendable {
    public let id: String
    public var provider: GatewayProvider
    public var accountKey: String
    public var displayName: String
    public var source: GatewayAccountSource
    public var isDisabled: Bool
    public var email: String?

    public init(
        id: String,
        provider: GatewayProvider,
        accountKey: String,
        displayName: String,
        source: GatewayAccountSource,
        isDisabled: Bool = false,
        email: String? = nil
    ) {
        self.id = id
        self.provider = provider
        self.accountKey = accountKey
        self.displayName = displayName
        self.source = source
        self.isDisabled = isDisabled
        self.email = email
    }

    public static func make(
        provider: GatewayProvider,
        accountKey: String,
        displayName: String? = nil,
        source: GatewayAccountSource,
        email: String? = nil
    ) -> GatewayAccount {
        let normalized = accountKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let seed = "\(provider.rawValue)|\(normalized.lowercased())"
        let digest = SHA256.hash(data: Data(seed.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
            .prefix(20)
        return GatewayAccount(
            id: "gateway-\(digest)",
            provider: provider,
            accountKey: normalized,
            displayName: displayName ?? normalized,
            source: source,
            email: email
        )
    }
}

/// Stored credential envelope. Field names match the legacy monitor credential
/// JSON byte-for-byte so a legacy item decodes directly.
public struct GatewayCredential: Codable, Sendable {
    public var accessToken: String
    public var refreshToken: String?
    public var idToken: String?
    public var accountID: String?
    public var expiresAt: Date?
    public var extra: [String: String]

    public init(
        accessToken: String,
        refreshToken: String? = nil,
        idToken: String? = nil,
        accountID: String? = nil,
        expiresAt: Date? = nil,
        extra: [String: String] = [:]
    ) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.idToken = idToken
        self.accountID = accountID
        self.expiresAt = expiresAt
        self.extra = extra
    }
}
