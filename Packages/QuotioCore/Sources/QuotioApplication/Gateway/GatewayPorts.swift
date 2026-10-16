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
