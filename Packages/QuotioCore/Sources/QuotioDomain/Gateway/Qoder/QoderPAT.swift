import Foundation

public nonisolated struct QoderUserIdentity: Sendable, Equatable {
    public let userID: String
    public let email: String
    public let name: String

    public init(userID: String, email: String, name: String) {
        self.userID = userID
        self.email = email
        self.name = name
    }
}

/// Output of a successful PAT exchange. Caller (onboarding sheet, ticket #4)
/// stores the credential in GatewayCredentialVault and shows the identity for
/// user confirmation per ADR 0006 §3.
public nonisolated struct QoderPATResult: Sendable {
    /// Vault-ready credential shaped per ADR 0002:
    /// accessToken = job token, expiresAt = job-token expiry − 5min buffer,
    /// extra carries the long-lived PAT, the per-account machine ID, and the
    /// job refresh token if one was issued.
    public let credential: GatewayCredential

    /// Resolved identity for the confirmation step. userID == credential.accountID.
    public let identity: QoderUserIdentity

    public init(credential: GatewayCredential, identity: QoderUserIdentity) {
        self.credential = credential
        self.identity = identity
    }
}

/// Errors surfaced to the caller. PATs and tokens are never embedded in
/// messages — only HTTP status and a short, redacted upstream body snippet,
/// per the AGENTS.md rule against logging secrets.
public nonisolated enum QoderPATError: Error {
    /// PAT missing or obviously malformed (`pt-...` prefix expected).
    case invalidPAT
    /// Transport failure (DNS, timeout, cancelled).
    case network(String)
    /// Non-2xx from exchange. Includes status and a ≤200-char body snippet.
    case exchangeFailed(status: Int, snippet: String)
    /// Exchange returned 2xx but the response shape was wrong (missing token).
    case exchangeMalformed
    /// `/userinfo` returned non-2xx. Treated as non-fatal by pi; surfaced here
    /// so the caller can decide. Snippet is ≤200 chars.
    case userInfoFailed(status: Int, snippet: String)
    /// `/userinfo` returned 2xx but no `id` field. userID is load-bearing for
    /// ADR 0006 §3 onboarding confirmation and as the stored `accountID`, so a
    /// credential without it must not be persisted.
    case identityMissing

    public var errorDescription: String? {
        switch self {
        case .invalidPAT:
            return "Qoder PAT is missing or malformed."
        case .network(let detail):
            return "Qoder PAT exchange failed: network error (\(detail))."
        case .exchangeFailed(let status, let snippet):
            return trimmedMessage("Qoder PAT exchange failed: HTTP \(status).", snippet: snippet)
        case .exchangeMalformed:
            return "Qoder PAT exchange returned no job token."
        case .userInfoFailed(let status, let snippet):
            return trimmedMessage("Qoder user-info fetch failed: HTTP \(status).", snippet: snippet)
        case .identityMissing:
            return "Qoder user-info returned no user ID."
        }
    }

    private func trimmedMessage(_ base: String, snippet: String) -> String {
        let capped = String(snippet.prefix(200))
        return capped.isEmpty ? base : "\(base) \(capped)"
    }
}

/// Performs the Qoder PAT-exchange → userinfo sequence against the global
/// `openapi.qoder.sh` endpoints. No CN endpoint is reachable from this service.
