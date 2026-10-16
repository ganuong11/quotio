import Foundation
import QuotioDomain

/// The PAT-refresh seam the failover router depends on. Production conformance
/// is `QoderPATService` in Infrastructure; tests inject a mock returning canned
/// credentials or throwing. Kept to the single method the router calls so the
/// surface stays narrow.
public protocol QoderPATRefreshing: Sendable {
    func refreshCredential(
        _ credential: GatewayCredential,
        account: GatewayAccount
    ) async throws -> GatewayCredential
}

/// PAT exchange for onboarding — PAT → job token → identity. Implemented by
/// `QoderPATService`; separate from `QoderPATRefreshing` so the onboarding UI
/// doesn't see the refresh path.
public protocol QoderPATOnboarding: Sendable {
    func credentials(fromPat pat: String) async throws -> QoderPATResult
}

/// Credential-vault surface the failover router needs. Conformed to by
/// `GatewayCredentialVault`; tests inject in-memory stores.
public protocol GatewayCredentialStoring: Sendable {
    func accounts() async -> [GatewayAccount]
    func credential(for accountID: String) async -> GatewayCredential?
    func store(_ credential: GatewayCredential, account: GatewayAccount) async throws
}

/// Account-metadata surface the failover router needs (disabled set +
/// revocation marking). Conformed to by `GatewayAccountStore`.
public protocol GatewayAccountStoring: Sendable {
    func disabledAccountIDs() async -> Set<String>
    func setDisabled(_ disabled: Bool, accountID: String) async throws
}
