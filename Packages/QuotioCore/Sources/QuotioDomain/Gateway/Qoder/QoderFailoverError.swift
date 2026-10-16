import Foundation

public nonisolated enum QoderFailoverError: Error {
    /// The request body was rejected by the translator's fail-fast gate
    /// (Tier 2 semantic caps from issue #14, or a malformed body). `status`
    /// is the HTTP code to surface: 400 for malformed/count caps,
    /// 413 for byte-size caps (image, tool schema). Defaults to 400 for
    /// callers that don't carry a translator error (e.g. missing model field).
    /// (`stream: false` is no longer rejected — non-streaming is served by
    /// aggregation, issue #9 / ADR 0014.)
    case requestRejected(_ detail: String, status: Int = 400)
    /// No Qoder accounts are configured, or all are *persistently* disabled
    /// (revoked PAT). Not self-healing — the user must add/re-enable an
    /// account. Maps to HTTP 503 (no upstream available).
    case noAccountsAvailable
    /// Every Qoder account is temporarily rate-limited (chat-path 429 from
    /// `api3.qoder.sh`, in cooldown). Self-healing: the agent should retry
    /// after `retryAfterSeconds`. Maps to HTTP 429 + `Retry-After` header +
    /// OpenAI `rate_limit_error` body (the type/code mapping lives in
    /// `QoderOpenAIError.body`, which already handled 429).
    case allAccountsCoolingDown(retryAfterSeconds: TimeInterval?)
    /// The caller's `Authorization: Bearer <key>` was missing or empty. The
    /// CPA path has CPA enforce the key; the Qoder branch bypasses CPA, so the
    /// router owns it. Maps to HTTP 401.
    case missingProxyAPIKey

    /// The HTTP status ProxyBridge should send for this error.
    public var httpStatus: Int {
        switch self {
        case .requestRejected(_, let status): return status
        case .noAccountsAvailable: return 503
        case .allAccountsCoolingDown: return 429
        case .missingProxyAPIKey: return 401
        }
    }

    /// Seconds the agent should wait before retrying, for the rate-limit case.
    /// Nil for every other case (no retry hint to send). ProxyBridge feeds this
    /// into the `Retry-After` header. Single source of truth so the catch site
    /// doesn't switch on the case again.
    public var retryAfterSeconds: TimeInterval? {
        switch self {
        case .allAccountsCoolingDown(let seconds): return seconds
        case .requestRejected, .noAccountsAvailable, .missingProxyAPIKey: return nil
        }
    }

    public var errorDescription: String? {
        switch self {
        case .requestRejected(let detail, _):
            return detail
        case .noAccountsAvailable:
            return "No Qoder accounts available: add a PAT or wait for cooldown to clear."
        case .allAccountsCoolingDown(let seconds):
            if let seconds = seconds {
                return "All Qoder accounts are rate-limited; retry after \(Int(ceil(seconds)))s."
            }
            return "All Qoder accounts are rate-limited; retry later."
        case .missingProxyAPIKey:
            return "Missing or invalid proxy API key (Authorization: Bearer <key>)."
        }
    }
}
