//
//  GatewayOAuthAuthorizer.swift
//  QuotioCore
//
//  Dispatching `OAuthAuthorizing`: gateway-native providers route to their
//  gateway authorizers; everything else falls through to the CPA authorizer.
//  Today exactly one gateway provider authorizes this way — `.opencode`.
//

import Foundation
import QuotioApplication
import QuotioDomain

public actor GatewayOAuthAuthorizer: OAuthAuthorizing {
    private let opencode: any OAuthAuthorizing
    private let fallback: any OAuthAuthorizing

    public init(opencode: any OAuthAuthorizing, fallback: any OAuthAuthorizing) {
        self.opencode = opencode
        self.fallback = fallback
    }

    public func begin(
        request: OAuthAuthorizationRequest,
        attemptID: OAuthAttemptID,
        progress: @escaping @Sendable (OAuthPrompt) async -> Void
    ) async throws -> OAuthAuthorizationOutcome {
        if request.providerID.rawValue == QuotaProvider.opencode.rawValue {
            return try await opencode.begin(request: request, attemptID: attemptID, progress: progress)
        }
        return try await fallback.begin(request: request, attemptID: attemptID, progress: progress)
    }

    public func completeManualCode(
        _ code: String,
        providerID: AccountProviderID,
        attemptID: OAuthAttemptID
    ) async throws -> Account {
        if providerID.rawValue == QuotaProvider.opencode.rawValue {
            return try await opencode.completeManualCode(code, providerID: providerID, attemptID: attemptID)
        }
        return try await fallback.completeManualCode(code, providerID: providerID, attemptID: attemptID)
    }

    public func cancel(attemptID: OAuthAttemptID) async {
        await opencode.cancel(attemptID: attemptID)
        await fallback.cancel(attemptID: attemptID)
    }
}
