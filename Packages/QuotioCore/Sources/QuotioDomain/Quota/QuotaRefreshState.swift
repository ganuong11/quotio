public enum QuotaRefreshFailureReason: String, Sendable {
    case authentication
    case ownerRefreshRequired = "owner_refresh_required"
    case sourceDisabled = "source_disabled"
    case timeout
    case transient
    case rateLimited = "rate_limited"
    case unavailable
    case credentialStorage = "credential_storage"
    case localCredentialStorage = "local_credential_storage"
    case quotaUnavailable = "quota_unavailable"
    case invalidData = "invalid_data"
    /// A detected/expired credential awaiting re-auth in the owning CLI.
    case stale
}

public enum QuotaRefreshState: Equatable, Sendable {
    case notLoaded
    case fresh
    case refreshing
    case stale
    case failed(QuotaRefreshFailureReason?)
}
