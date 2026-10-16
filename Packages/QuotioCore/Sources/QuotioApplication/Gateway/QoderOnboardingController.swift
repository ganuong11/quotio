import Foundation
import QuotioDomain

/// Duplicate-account rejection the PAT service cannot know about (it never
/// sees the vault). Presentation maps this to `qoder.onboarding.duplicate`.
public enum QoderOnboardingError: Error, Sendable, Equatable {
    case duplicateAccount
}

/// Qoder PAT onboarding use case: PAT → job-token exchange + userinfo (via the
/// `QoderPATOnboarding` port) → identity confirmation → vault/store write.
/// Extracted from the legacy view-model so the sheet is pure presentation.
public actor QoderOnboardingController {
    private let onboarding: any QoderPATOnboarding
    private let credentials: any GatewayCredentialStoring

    public init(onboarding: any QoderPATOnboarding, credentials: any GatewayCredentialStoring) {
        self.onboarding = onboarding
        self.credentials = credentials
    }

    /// Step 1: exchange the PAT and resolve the user identity. The result is
    /// shown for confirmation; nothing is persisted here.
    public func exchange(pat: String) async throws -> QoderPATResult {
        try await onboarding.credentials(fromPat: pat)
    }

    /// Step 2: persist the resolved credential as a `.qoder` gateway account.
    /// `accountKey` prefers userID (stable across email changes); `email` is
    /// stored for UI disambiguation. Re-saving the same account key
    /// (case-insensitive) would silently overwrite — reject it.
    public func save(result: QoderPATResult) async throws {
        let identity = result.identity
        let userID = identity.userID.trimmingCharacters(in: .whitespacesAndNewlines)
        let email = identity.email.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = identity.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let accountKey = !userID.isEmpty ? userID : email
        guard !accountKey.isEmpty else { throw QoderPATError.identityMissing }

        let existing = await credentials.accounts()
        if existing.contains(where: {
            $0.provider == .qoder
                && $0.accountKey.caseInsensitiveCompare(accountKey) == .orderedSame
        }) {
            throw QoderOnboardingError.duplicateAccount
        }

        let account = GatewayAccount.make(
            provider: .qoder,
            accountKey: accountKey,
            displayName: !name.isEmpty ? name : (!email.isEmpty ? email : accountKey),
            source: .onboarded,
            email: email.isEmpty ? nil : email
        )
        try await credentials.store(result.credential, account: account)
    }
}
