//
//  QoderFailoverRouter.swift
//  Quotio
//
//  Phase 2a (ADR 0001, ADR 0005 §3, ADR 0006 §2): multi-account failover for
//  Qoder chat requests. An actor that holds per-account cooldown state and
//  selects which stored Qoder credential to sign with, applying the rotation
//  policy when the gateway rejects an account.
//
//  **The actor's job ends at "return a confirmed-2xx byte stream or throw."**
//  All rotation / cooldown / re-exchange happens *before* the first response
//  byte — once a gateway stream returns 2xx, ownership of the byte pump passes
//  to ProxyBridge, which runs `QoderSSEReparser` and `onChunk` in its own Task.
//  Mid-stream failures terminate the agent stream; they never rotate (you can't
//  rotate cleanly once the SSE response has begun — ADR 0006 §2 last row).
//
//  Keeping the actor's responsibility at "open the stream" means concurrent
//  requests don't serialize behind each other's active pumps — only the
//  rotation decision is actor-isolated, and that's a fast synchronous pass.
//
//  Rotation policy (ADR 0006 §2):
//    - 429 + quota body            → cooldown this account, rotate to next.
//                                    Honor a server-supplied `Retry-After`
//                                    (delta-seconds) when present, clamped to
//                                    `[cooldownTTL, retryAfterCeiling]` (issue
//                                    #12); fall back to `cooldownTTL` otherwise.
//    - 401/403 (first occurrence)  → one-shot PAT re-exchange (machineID-
//                                    preserving), retry same account.
//    - 401/403 (after re-exchange) → cooldown + rotate. Fresh job tokens can
//                                    take time to propagate to the chat gateway;
//                                    this is not proof the PAT is revoked.
//    - 5xx / network               → retry same account once with short backoff.
//    - Silent stall (HTTP 200, no first chunk within the peek timeout):
//                                    strong-evidence threshold (issue #12). On
//                                    the first N-1 stalls we rotate to the next
//                                    account for request progress but DO NOT
//                                    cool the stalled account down — a slow cold
//                                    start / network delay must not be able to
//                                    cool a healthy account. Only on the Nth
//                                    consecutive stall (`silentStallStrikeThreshold`,
//                                    default 2) is quota applied and the account
//                                    cooled. The counter resets on the next
//                                    clean first frame from that account, and
//                                    also resets whenever cooldown is applied.
//    - SSE statusCodeValue ≠ 200   → cannot rotate mid-stream; ProxyBridge
//                                    terminates. (This path throws here only
//                                    when detected on the initial response.)
//    - All accounts exhausted      → throw → ProxyBridge returns 503.
//

import Foundation

/// Translation outcome ProxyBridge receives from a successful `openStream`.
/// Carries everything ProxyBridge needs to pump the stream and record metadata:
/// the stream pump (closure), the resolved account (for attribution), and the
/// translator result (request IDs for logging). The HTTP response is 2xx by
/// construction here — non-2xx never leaves the router.
nonisolated struct QoderOpenedStream: Sendable {
    /// The leading upstream bytes the router already consumed during its
    /// pre-handoff peek (it pulled the first chunk to detect an in-envelope
    /// quota signal). ProxyBridge must feed these through `QoderSSEReparser`
    /// *before* driving `pump`, or the agent would lose the stream's opening
    /// bytes. Empty when the peek consumed nothing (e.g. stream ended clean
    /// on the first chunk boundary, or production never buffered).
    let bufferedPrefix: Data
    /// Drive the *remaining* upstream byte stream (everything after
    /// `bufferedPrefix`). `onChunk` receives each raw buffer the gateway yields;
    /// return false to stop early. Throws on transport failure.
    let pump: @Sendable (QoderChunkReceiver) async throws -> Void
    let accountID: String
    let translatorResult: QoderTranslationResult
    /// Whether the client asked for a streaming response. True only when the
    /// request body carried `"stream": true`; a missing `stream` field and an
    /// explicit `false` both yield `false` (OpenAI's spec default is `false`,
    /// https://github.com/openai/openai-openapi/blob/c309ca1/openapi.yaml#L32968-L32977).
    /// ProxyBridge branches on this: streaming writes the SSE head + chunks
    /// live; non-streaming aggregates the SSE upstream into one
    /// `chat.completion` JSON via `QoderCompletionAggregator` (issue #9,
    /// ADR 0014). The Qoder gateway stream is SSE either way — the upstream
    /// request always carries `"stream": true` (translator, line ~688); this
    /// flag controls only the *client-facing* shape. No default: every
    /// construction site sets it explicitly from the parsed request body.
    let streamRequested: Bool
}

/// Errors surfaced to ProxyBridge. ProxyBridge maps each to its wire
/// representation — an HTTP error before any stream byte was written. Tokens /
/// secrets are never embedded; account-cooling and disable state live inside
/// the router, not in error messages.
nonisolated enum QoderFailoverError: Error, LocalizedError {
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
    var httpStatus: Int {
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
    var retryAfterSeconds: TimeInterval? {
        switch self {
        case .allAccountsCoolingDown(let seconds): return seconds
        case .requestRejected, .noAccountsAvailable, .missingProxyAPIKey: return nil
        }
    }

    var errorDescription: String? {
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

/// Notification posted when PAT refresh returns a failure classified as
/// permanent (invalid PAT, a non-429 exchange/user-info status, malformed
/// exchange, or missing identity). ADR 0006 §2 requires the notification be reliable: the user must
/// learn about the revocation via Quotio, not via a failed agent request. A
/// gateway auth response alone does not post this notification because newly
/// exchanged tokens can take time to propagate. `userInfo` carries the account
/// key for the notification body — never the PAT or token.
nonisolated extension Notification.Name {
    static let qoderPATRevoked = Notification.Name("dev.quotio.qoder.pat-revoked")
}

/// The PAT-refresh seam the router depends on. Production conformance is
/// `QoderPATService`; tests inject a mock that returns canned credentials or
/// throws. Kept to the single method the router calls so the surface stays
/// narrow.
nonisolated protocol QoderPATRefreshing: Sendable {
    func refreshCredential(
        _ credential: MonitorOAuthCredential,
        account: MonitorAccount
    ) async throws -> MonitorOAuthCredential
}

/// Failover tuning (issue #12). All values default to the pre-issue behavior;
/// production wires `.default` from the single call site in `QuotaViewModel`,
/// tests inject overrides via `Configuration(silentStallStrikeThreshold: 1, …)`
/// to exercise the strike/Retry-After paths deterministically.
nonisolated struct QoderFailoverRouterConfiguration: Sendable {
    /// How long a quota-exhausted account stays in cooldown. Short on purpose:
    /// quota windows on Qoder are per-minute, and the cooldown only needs to
    /// outlive a burst. ADR 0005 consequence note flags persistent cooldown as
    /// a follow-up; in-memory is the tracer.
    let cooldownTTL: TimeInterval
    /// Consecutive silent-stall strikes before a cooldown is applied (issue #12
    /// acceptance criterion: a single slow-but-healthy first frame must NOT
    /// cool the account). Default 2: one stall rotates for progress, the second
    /// consecutive stall treats the account as quota-exhausted.
    let silentStallStrikeThreshold: Int
    /// Floor applied to a server-supplied `Retry-After` so a sub-second hint
    /// doesn't under-cool an exhausted account. Equal to `cooldownTTL`.
    let retryAfterFloor: TimeInterval
    /// Ceiling applied to a server-supplied `Retry-After` so a misbehaving
    /// server can't park an account indefinitely. RFC 7231 §7.1.3 permits
    /// arbitrarily large values; 300s keeps a single bad hint bounded.
    let retryAfterCeiling: TimeInterval
    /// How many times to attempt a transient (`.network` or endpoint 429) PAT
    /// re-exchange before cooling the account down. A genuine revocation
    /// (`.invalidPAT`, `.exchangeFailed(401/403)`) disables on the first try
    /// without burning this budget — a malformed PAT won't fix itself on retry.
    /// This is the *total* attempt count (not retries-on-top-of-initial): at
    /// the default of 2, the router tries re-exchange twice before cooldown.
    /// Transient exhaustion never changes persistent account enablement.
    let reexchangeRetryCount: Int

    init(
        cooldownTTL: TimeInterval = 60,
        silentStallStrikeThreshold: Int = 2,
        retryAfterFloor: TimeInterval? = nil,
        retryAfterCeiling: TimeInterval = 300,
        reexchangeRetryCount: Int = 2
    ) {
        self.cooldownTTL = cooldownTTL
        self.silentStallStrikeThreshold = silentStallStrikeThreshold
        // Floor defaults to cooldownTTL when not explicitly provided so callers
        // overriding `cooldownTTL` don't have to also override the floor.
        self.retryAfterFloor = retryAfterFloor ?? cooldownTTL
        self.retryAfterCeiling = retryAfterCeiling
        self.reexchangeRetryCount = max(0, reexchangeRetryCount)
    }

    /// Default production policy (mirrors the pre-issue #12 constants).
    static let `default` = QoderFailoverRouterConfiguration()
}

actor QoderFailoverRouter {

    /// How long to back off before retrying the same account on a transient
    /// (5xx / network) error. ADR 0006 §2.
    private static let transientBackoff: UInt64 = 250_000_000  // 250ms in nanoseconds

    /// Per-account cooldown end times. An entry present and in the future means
    /// "skip this account when selecting candidates." Expired entries are lazy-
    /// evicted on read. In-memory only — lost on restart.
    private var cooldowns: [String: Date] = [:]

    /// Per-account consecutive silent-stall strike count (issue #12). A stall
    /// (HTTP 200, no first chunk within the peek timeout) is weak quota
    /// evidence — a slow cold start looks identical. We rotate immediately on
    /// each stall for request progress, but only apply a cooldown once the
    /// threshold is reached. Reset to 0 on the next clean first frame from this
    /// account (see `confirmStreamAndHandOff`) and whenever a cooldown is
    /// applied (see `applyCooldown`). In-memory only — lost on restart.
    private var silentStallStrikes: [String: Int] = [:]

    private let vault: any MonitorCredentialStore
    private let metadata: MonitorMetadataStore
    private let patService: any QoderPATRefreshing
    private let gateway: any QoderGatewayClientProtocol
    private let configuration: QoderFailoverRouterConfiguration
    /// Tier 2 translator caps (issue #14). Default `.default`; tests inject
    /// tighter values to exercise the rejection paths without crafting huge
    /// request bodies.
    private let translatorLimits: QoderTranslatorLimits

    init(
        vault: any MonitorCredentialStore,
        metadata: MonitorMetadataStore = .shared,
        patService: any QoderPATRefreshing,
        gateway: any QoderGatewayClientProtocol,
        configuration: QoderFailoverRouterConfiguration = .default,
        translatorLimits: QoderTranslatorLimits = .default
    ) {
        self.vault = vault
        self.metadata = metadata
        self.patService = patService
        self.gateway = gateway
        self.configuration = configuration
        self.translatorLimits = translatorLimits
    }

    // MARK: - Public entry point

    /// Open a confirmed-2xx gateway stream for a Qoder chat request, applying
    /// the rotation policy across all enabled Qoder accounts. Throws
    /// `QoderFailoverError` if no account can serve the request.
    ///
    /// `proxyAPIKey` is the `Bearer` key from the agent's request — used in
    /// the session-ID derivation (ADR 0005 §1) and validated non-empty here.
    /// As of issue #21 / ADR 0008, API-key authentication against CPA's
    /// `config_access` provider is owned by `QoderAccessValidator` in
    /// `ProxyBridge.forwardQoderRequest` BEFORE this method is reached, so by
    /// the time we get here `proxyAPIKey` is either the CPA-authenticated
    /// principal or a legacy fallback value. The `guard !proxyAPIKey.isEmpty`
    /// below stays as a safety net: it fires for a credential-less request on
    /// the open-access legacy paths (`.notConfigured` / validator-nil fallback
    /// with an empty Bearer suffix), which keeps the pre-issue-#21 behavior of
    /// rejecting credential-less Qoder requests (session-ID material is
    /// required); this method's logic is otherwise unchanged.
    ///
    /// `userID` (resolved from the chosen credential) feeds the session-ID
    /// derivation; the translator hashes `(userID, model, proxyAPIKey)` into
    /// `session_id` for prompt-cache affinity.
    func openStream(
        requestBody: Data,
        proxyAPIKey: String
    ) async throws -> QoderOpenedStream {
        guard !proxyAPIKey.isEmpty else {
            throw QoderFailoverError.missingProxyAPIKey
        }

        // Translate once per request (account-independent except for userID,
        // which we patch in per-candidate below). The fail-fast gates (tools,
        // images, malformed body) run here, before any account is touched.
        // Extract the model and strip the `qoder/` routing prefix per ADR 0003
        // §1: "The prefix is stripped before the ID is sent upstream
        // (`qoder/auto` → `auto`)." ProxyBridge gates on the prefix; the
        // registry and the translator both want the bare ID.
        guard let rawModel = QoderFailoverRouter.extractModelID(from: requestBody) else {
            throw QoderFailoverError.requestRejected(
                "Qoder: request body missing a 'model' field."
            )
        }
        let modelID: String
        let bodyForTranslator: Data
        if rawModel.hasPrefix("qoder/") {
            modelID = String(rawModel.dropFirst("qoder/".count))
            // Re-emit the body with the prefix stripped from the `model` field
            // so the translator and the upstream gateway see the bare ID. ADR
            // 0003 §1.
            bodyForTranslator = QoderFailoverRouter.replaceModel(in: requestBody, with: modelID)
        } else {
            // Defensive: ProxyBridge only routes `qoder/`-prefixed requests
            // here, so an unprefixed model is unexpected but not fatal — pass
            // through unchanged and let the registry fall back to default.
            modelID = rawModel
            bodyForTranslator = requestBody
        }
        // Parse the client's streaming intent once. OpenAI's spec defaults
        // `stream` to `false`; both missing and explicit `false` are
        // non-streaming. The gateway stream is SSE either way (the translator
        // hardcodes `"stream": true` upstream); this flag controls only the
        // client-facing shape, branched on by ProxyBridge (issue #9, ADR 0014).
        let clientWantsStream = QoderFailoverRouter.streamRequested(in: requestBody)

        let modelConfig = QoderModelRegistry.resolve(modelID)

        // Enumerate enabled, non-cooled-down Qoder accounts in priority order.
        // Primary (user-designated, or first-enabled) first.
        let candidates = try await enabledQoderAccounts()
        guard !candidates.isEmpty else {
            throw await exhaustionError()
        }

        for account in candidates {
            // Refresh the job token if expired before signing. A 401 from the
            // gateway is the other path that triggers re-exchange; this pro-
            // actively avoids the round-trip when we already know the token is
            // stale.
            guard let credential = await resolveFreshCredential(for: account) else {
                continue
            }

            do {
                let stream = try await attempt(
                    account: account,
                    credential: credential,
                    requestBody: bodyForTranslator,
                    proxyAPIKey: proxyAPIKey,
                    modelID: modelID,
                    modelConfig: modelConfig,
                    streamRequested: clientWantsStream
                )
                return stream
            } catch let failure as QoderAccountFailure {
                let action = decideAction(for: failure, account: account)
                switch action {
                case .reexchangeAndRetry:
                    // Re-exchange with a transient-retry budget, then retry the
                    // same account. `isPermanent` selects the terminal policy:
                    // proven revocations persistently disable; recoverable
                    // failures enter the in-memory cooldown.
                    var isPermanent = false
                    if let refreshed = await reexchangeWithRetry(
                        for: account,
                        credential: credential,
                        isPermanent: &isPermanent
                    ) {
                        do {
                            let stream = try await attempt(
                                account: account,
                                credential: refreshed,
                                requestBody: bodyForTranslator,
                                proxyAPIKey: proxyAPIKey,
                                modelID: modelID,
                                modelConfig: modelConfig,
                                streamRequested: clientWantsStream
                            )
                            return stream
                        } catch let failure2 as QoderAccountFailure {
                            // Second failure on the same account after re-
                            // exchange. Auth and quota responses cool + rotate;
                            // a fresh token may not have propagated to api3 yet.
                            // A silent stall is deliberately
                            // NOT cooled here, consistent with the two-strike
                            // weak-evidence policy in `decideAction`: a single
                            // stall right after a fresh token (cold start, slow
                            // first byte) must not be able to cool the account.
                            // We still bump the strike counter so a *pattern*
                            // of stalls on this account accrues — but a
                            // post-reexchange stall alone won't trip the
                            // threshold unless strikes already accumulated.
                            if failure2.isAuthFailure {
                                // A newly exchanged job token can take a short
                                // time to propagate from openapi.qoder.sh to the
                                // api3 chat gateway. A repeated auth response in
                                // that window is not proof the PAT is revoked:
                                // cool down and let the agent retry after the
                                // refreshed token has propagated.
                                applyCooldown(accountID: account.id)
                            } else if failure2.isQuota {
                                applyCooldown(
                                    accountID: account.id,
                                    retryAfterSeconds: failure2.retryAfterSeconds
                                )
                            } else if failure2.isSilentStall {
                                let prior = silentStallStrikes[account.id, default: 0]
                                let strikes = prior + 1
                                silentStallStrikes[account.id] = strikes
                                if strikes >= configuration.silentStallStrikeThreshold {
                                    applyCooldown(accountID: account.id)
                                }
                            }
                            continue
                        }
                        // Other errors fall through to the next account.
                    } else {
                        // Re-exchange failed. Proven permanent failures (revoked
                        // PAT, malformed exchange) disable + notify. Transient
                        // exhaustion (network or endpoint 429) is temporary: put
                        // the account in the existing in-memory cooldown and
                        // rotate, preserving the user's enabled state on disk.
                        if isPermanent {
                            await disableAndNotifyRevoked(account: account)
                        } else {
                            applyCooldown(accountID: account.id)
                        }
                        continue
                    }
                case .cooldownAndRotate:
                    applyCooldown(
                        accountID: account.id,
                        retryAfterSeconds: failure.retryAfterSeconds
                    )
                    continue
                case .rotateWithoutCooldown:
                    // Issue #12: silent stall below the strike threshold. The
                    // strike bump already happened in `decideAction`; here we
                    // just rotate without cooling so a slow-but-healthy first
                    // frame doesn't trip the account out for `cooldownTTL`.
                    continue
                case .retrySameOnce:
                    // Transient (5xx/network). Retry the same account once
                    // with a short backoff, then rotate if it fails again.
                    try? await Task.sleep(nanoseconds: Self.transientBackoff)
                    do {
                        let stream = try await attempt(
                            account: account,
                            credential: credential,
                            requestBody: bodyForTranslator,
                            proxyAPIKey: proxyAPIKey,
                            modelID: modelID,
                            modelConfig: modelConfig,
                            streamRequested: clientWantsStream
                        )
                        return stream
                    } catch {
                        // Second transient failure — give up on this account
                        // this round and rotate. No cooldown (transient, not
                        // quota).
                        continue
                    }
                }
            }
        }

        // Every candidate failed.
        throw await exhaustionError()
    }

    // MARK: - Per-account attempt

    /// Sign + ship one attempt with `credential`. Returns the opened stream on
    /// 2xx; throws `QoderAccountFailure` on a rotation-eligible status; re-
    /// throws `QoderGatewayError` (network) for the transient path.
    private func attempt(
        account: MonitorAccount,
        credential: MonitorOAuthCredential,
        requestBody: Data,
        proxyAPIKey: String,
        modelID: String,
        modelConfig: QoderModelConfig,
        streamRequested: Bool
    ) async throws -> QoderOpenedStream {
        let userID = credential.accountID ?? ""
        guard !userID.isEmpty else {
            // Credential persisted without an accountID — shouldn't happen
            // (QoderPATService refuses to persist without one), but skip
            // rather than fail the whole request.
            throw QoderAccountFailure(kind: .auth, status: nil)
        }

        let translatorResult: QoderTranslationResult
        do {
            translatorResult = try QoderChatTranslator.translate(
                body: requestBody,
                userID: userID,
                proxyAPIKey: proxyAPIKey,
                modelConfig: modelConfig,
                limits: translatorLimits
            )
        } catch let error as QoderTranslatorError {
            // Fail-fast gates (Tier 2 semantic caps from issue #14, or a
            // malformed body). Map to a rejected request, surfacing the
            // translator's chosen HTTP status (400 for malformed/count caps,
            // 413 for byte-size caps) so the agent sees the precise OpenAI
            // error. Not account-specific, so throw the terminal error, not a
            // rotation-eligible one.
            throw QoderFailoverError.requestRejected(
                error.localizedDescription, status: error.httpStatus
            )
        }

        let cosyCredentials = QoderCOSYCredentials(
            userID: userID,
            authToken: credential.accessToken,
            name: account.displayName,
            email: "",
            machineID: credential.extra["machineID"] ?? ""
        )

        let stream: QoderGatewayStream
        do {
            stream = try await gateway.openStream(
                body: translatorResult.envelopeJSON,
                credentials: cosyCredentials,
                signerOptions: .deferringToRandom
            )
        } catch let error as QoderGatewayError {
            // Transport failure — transient path. The caller decides whether
            // to retry or rotate.
            throw QoderAccountFailure(kind: .transient, status: nil, detail: error.localizedDescription)
        }

        // Read the HTTP status and apply the rotation policy. Non-2xx is
        // rotation-eligible directly. For 2xx we must ALSO peek the first SSE
        // chunk: Qoder's gateway returns HTTP 200 even when an account is
        // quota-exhausted, carrying the signal *inside* the stream (either as
        // an envelope with `statusCodeValue != 200`, or as a silent stall
        // where no content frame ever arrives). The peek happens before any
        // byte reaches the agent, so rotation here is still clean — this is
        // NOT the "mid-stream, cannot rotate" case from ADR 0006 §2 (that
        // applies only once ProxyBridge has written the 200 head to the agent).
        let status = stream.response.statusCode
        if (200..<300).contains(status) {
            return try await confirmStreamAndHandOff(
                stream: stream,
                account: account,
                translatorResult: translatorResult,
                streamRequested: streamRequested
            )
        }

        switch status {
        case 429:
            // Capture a server-supplied cooldown hint. RFC 7231 §7.1.3 allows
            // `Retry-After` as either delta-seconds or an HTTP-date; we honor
            // delta-seconds and best-effort HTTP-date (issue #12). Absent or
            // unparseable → nil → `applyCooldown` falls back to the default.
            let retryAfter = QoderFailoverRouter.retryAfterSeconds(
                from: stream.response,
                capturedAt: Date()
            )
            throw QoderAccountFailure(
                kind: .quota, status: status, retryAfterSeconds: retryAfter
            )
        case 401, 403:
            throw QoderAccountFailure(kind: .auth, status: status)
        case 500...599:
            throw QoderAccountFailure(kind: .transient, status: status)
        default:
            // 4xx other than 429/401/403 (e.g. 400 bad request, 404, 413, 422)
            // is a request-level rejection, not an account-level one — rotating
            // accounts won't fix a malformed envelope. Surface it as a terminal
            // request rejection, passing the gateway's status through so
            // ProxyBridge returns the real status (400/404/413/422/...) to the
            // agent rather than collapsing them all to 400.
            throw QoderFailoverError.requestRejected(
                "Qoder gateway returned HTTP \(status) (non-rotatable).", status: status
            )
        }
    }

    // MARK: - Pre-handoff peek (in-envelope quota/auth detection)

    /// How long to wait for the first SSE chunk before declaring a silent
    /// stall. Qoder normally emits the opening frame near-instantly; a
    /// persistent stall on an account the dashboard reports as exhausted is
    /// quota, not a transient network blip. Tuned to avoid false-rotating on a
    /// genuinely slow first byte (e.g. a cold model load) while still bounding
    /// the user-visible hang the pre-fix bug produced (15s+ agent timeouts).
    private static let firstChunkTimeout: UInt64 = 2_000_000_000  // 2s in ns

    /// Peek the first chunk of a 2xx gateway stream before handing it off to
    /// ProxyBridge. Returns the opened stream (carrying the consumed prefix) on
    /// a clean first chunk; throws `QoderAccountFailure` so the existing
    /// rotation policy applies when the quota/auth signal rides inside the
    /// stream.
    ///
    /// Three branches:
    ///  1. First chunk carries a non-200 `statusCodeValue` envelope → classify
    ///     by that status and throw (429→quota, 401/403→auth, 5xx→transient).
    ///  2. No chunk within `firstChunkTimeout` (silent stall, the live symptom
    ///     on exhausted accounts) → throw `.silentStall`. The account is NOT
    ///     cooled down on a single occurrence — a slow-but-healthy first frame
    ///     is indistinguishable from a stall, so we rotate for progress but
    ///     only apply a cooldown once `silentStallStrikeThreshold` consecutive
    ///     stalls accumulate (issue #12). See `decideAction`.
    ///  3. First chunk is clean (content, or a benign non-envelope line, or the
    ///     stream ended on `[DONE]`) → reset this account's silent-stall strike
    ///     counter (a clean frame is positive evidence the account is healthy)
    ///     and hand off, carrying the consumed bytes as `bufferedPrefix` so
    ///     ProxyBridge doesn't lose them.
    ///
    /// Rotation here is clean: ProxyBridge has not yet written anything to the
    /// agent socket (the 200 SSE head is written only after `openStream`
    /// returns). ADR 0006 §2's "cannot rotate mid-stream" rule applies further
    /// down the pipe, not at this seam.
    private func confirmStreamAndHandOff(
        stream: QoderGatewayStream,
        account: MonitorAccount,
        translatorResult: QoderTranslationResult,
        streamRequested: Bool
    ) async throws -> QoderOpenedStream {
        let firstChunk: Data?
        do {
            firstChunk = try await withThrowingTaskGroup(of: Data?.self) { group in
                // The peek task absorbs cancellation locally and returns nil.
                // Today, once this group's body returns normally after
                // `cancelAll()`, Swift (SE-0304 "Proposal history") *discards*
                // errors thrown by the cancelled child rather than rethrowing
                // them — so the outer `catch` below never sees a cancellation
                // error and the `.quota` branch fires correctly. The local
                // catch here is defensive: the discard rule is subtle and
                // *not* type-enforced. If a future refactor adds a second
                // `group.next()` (or `waitForAll()`) to consume the peek task's
                // result, a `CancellationError`/`URLError(.cancelled)` from the
                // cancelled `nextChunk()` would escape through that consumption
                // and land in the outer catch → misclassified `.transient`.
                // Absorbing cancellation at the source keeps that refactor safe.
                // A real (non-cancellation) transport drop still throws and is
                // caught by the outer catch as `.transient`.
                group.addTask {
                    do {
                        return try await stream.nextChunk()
                    } catch is CancellationError {
                        return nil
                    } catch let urlError as URLError where urlError.code == .cancelled {
                        return nil
                    }
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: Self.firstChunkTimeout)
                    return nil
                }
                // `group.next()` returns `Data??` (optional element wrapping the
                // optional payload). Unwrap the outer layer; the inner is the
                // real signal (nil = stream ended or timeout).
                if let result = try await group.next() {
                    group.cancelAll()
                    return result
                }
                group.cancelAll()
                return nil
            }
        } catch {
            // nextChunk threw (transport drop mid-peek) — transient path.
            throw QoderAccountFailure(kind: .transient, status: nil, detail: error.localizedDescription)
        }

        // Branch 2: silent stall. The gateway returned 200 but never yielded a
        // first chunk within the timeout. Weak quota evidence — a slow cold
        // start looks identical. Throw `.silentStall` so `decideAction` applies
        // the two-strike threshold: rotate now, cool only on the Nth
        // consecutive stall. Issue #12.
        guard let prefix = firstChunk, !prefix.isEmpty else {
            throw QoderAccountFailure(kind: .silentStall, status: 429, detail: "silent stall")
        }

        // Branch 1: probe the prefix for a non-200 in-envelope signal. Reuses
        // the reparser's proven parse path — feeds the bytes through a
        // throwaway reparser and catches `.upstreamStatus`. A malformed line
        // (`.malformedSSELine`) is swallowed: the first chunk may be a partial
        // SSE frame split across TCP segments, and the reparser will re-buffer
        // it correctly once ProxyBridge feeds the full stream. Only a definite
        // non-200 status trips rotation here.
        if let signal = QoderFailoverRouter.probeForUpstreamStatus(in: prefix) {
            switch signal {
            case 429:
                throw QoderAccountFailure(kind: .quota, status: signal)
            case 401, 403:
                throw QoderAccountFailure(kind: .auth, status: signal)
            case 500...599:
                throw QoderAccountFailure(kind: .transient, status: signal)
            default:
                // Other non-200 codes inside the envelope are request-level
                // rejections, same as the HTTP-status path — rotating accounts
                // won't fix a malformed envelope. Pass the in-envelope status
                // through so ProxyBridge returns it verbatim to the agent.
                throw QoderFailoverError.requestRejected(
                    "Qoder upstream returned status \(signal) (non-rotatable).", status: signal
                )
            }
        }

        // Branch 3: clean. A real first frame is positive evidence the account
        // is healthy, so reset its silent-stall strike counter (issue #12).
        // Then hand off, carrying the consumed prefix so ProxyBridge feeds it
        // through the reparser before driving the remainder. Wrap `stream.pump`
        // in an explicit closure: `QoderGatewayStream` is a class, so a bare
        // method reference would carry `Self` and fail the `@Sendable` closure
        // conformance the `QoderOpenedStream.pump` field requires. The class
        // itself is `@unchecked Sendable`.
        silentStallStrikes.removeValue(forKey: account.id)
        let streamRef = stream
        return QoderOpenedStream(
            bufferedPrefix: prefix,
            pump: { onChunk in try await streamRef.pump(onChunk) },
            accountID: account.id,
            translatorResult: translatorResult,
            streamRequested: streamRequested
        )
    }

    /// Pure probe: does `chunk` contain an SSE frame whose envelope carries a
    /// non-200 `statusCodeValue`? Returns the status code if so, nil otherwise.
    /// Nonisolated + pure so it's trivially testable and callable from the
    /// actor-isolated peek path without a hop.
    ///
    /// Mirrors the parse the reparser will do later, but only extracts the
    /// status — we deliberately don't consume the bytes here (ProxyBridge still
    /// needs them). Implemented locally rather than by feeding the reparser and
    /// catching `.upstreamStatus`, because the reparser is a `mutating struct`
    /// that would have to be constructed and discarded per probe; a focused
    /// extractor is clearer and avoids the throw-as-control-flow smell.
    private nonisolated static func probeForUpstreamStatus(in chunk: Data) -> Int? {
        guard let text = String(data: chunk, encoding: .utf8) else { return nil }
        // Normalize CRLF so `firstIndex(of: "\n")` splits reliably.
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
                             .replacingOccurrences(of: "\r", with: "\n")
        for rawLine in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("data:") else { continue }
            let dataStr = String(line.dropFirst("data:".count)).trimmingCharacters(in: .whitespaces)
            guard !dataStr.isEmpty, dataStr != "[DONE]" else { continue }
            guard let lineData = dataStr.data(using: .utf8),
                  let envelope = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let statusCodeValue = envelope["statusCodeValue"] as? Int,
                  statusCodeValue != 200 else {
                continue
            }
            return statusCodeValue
        }
        return nil
    }

    // MARK: - Decision policy

    /// Internal failure classification. `status` is the upstream HTTP code
    /// when available; nil for transport-level failures (network).
    /// `retryAfterSeconds` carries a server-supplied cooldown hint from a 429's
    /// `Retry-After` header (delta-seconds); nil means "no hint, use the
    /// default cooldown." See `applyCooldown` for the clamping rule.
    private struct QoderAccountFailure: Error {
        enum Kind { case quota, auth, transient, silentStall }
        let kind: Kind
        let status: Int?
        var detail: String?
        var retryAfterSeconds: TimeInterval?

        var isAuthFailure: Bool { kind == .auth }
        var isQuota: Bool { kind == .quota }
        var isSilentStall: Bool { kind == .silentStall }
    }

    private enum FailureAction {
        case reexchangeAndRetry
        case cooldownAndRotate
        case retrySameOnce
        /// Rotate to the next account for request progress, but do NOT apply a
        /// cooldown yet (issue #12). Used for a silent stall below the
        /// configured strike threshold — see `openStream` for the strike bump
        /// and threshold check.
        case rotateWithoutCooldown
    }

    private func decideAction(
        for failure: QoderAccountFailure,
        account: MonitorAccount
    ) -> FailureAction {
        switch failure.kind {
        case .quota:
            return .cooldownAndRotate
        case .auth:
            // Auth failures reach this decision only before the one-shot
            // re-exchange. The nested retry handles the post-exchange response
            // directly and cools on repeated auth while the token propagates.
            return .reexchangeAndRetry
        case .transient:
            return .retrySameOnce
        case .silentStall:
            // Issue #12 two-strike evidence threshold. Bump the consecutive
            // strike count; if we've now hit the threshold, treat it as quota
            // (cool + rotate). Otherwise rotate for progress without cooling,
            // so a single slow-but-healthy first frame can't cool the account.
            let prior = silentStallStrikes[account.id, default: 0]
            let strikes = prior + 1
            silentStallStrikes[account.id] = strikes
            if strikes >= configuration.silentStallStrikeThreshold {
                return .cooldownAndRotate
            }
            return .rotateWithoutCooldown
        }
    }

    // MARK: - Credential resolution & re-exchange

    /// Load the stored credential and proactively refresh the job token if
    /// it's past (or near) expiry. Returns nil if the credential is missing
    /// or unreadable (skip the account rather than failing the request).
    private func resolveFreshCredential(for account: MonitorAccount) async -> MonitorOAuthCredential? {
        guard var credential = await vault.credential(for: account.id) else {
            return nil
        }
        // Proactive rotation: if the token is already expired at attempt time,
        // re-exchange before signing (avoids a wasted 401 round-trip). Uses
        // the machineID-preserving entry point.
        if let expiresAt = credential.expiresAt, expiresAt > Date() {
            return credential  // still valid
        }
        // Expired — re-exchange. If that fails, the account isn't usable this
        // round; the caller skips to the next candidate.
        if let refreshed = await reexchange(for: account, credential: credential) {
            credential = refreshed
        }
        return credential
    }

    /// One-shot PAT re-exchange preserving machineID. Persists the refreshed
    /// credential through the Vault's CAS path so the quota fetcher and any
    /// concurrent router calls see the new token. Returns nil on failure.
    private func reexchange(
        for account: MonitorAccount,
        credential: MonitorOAuthCredential
    ) async -> MonitorOAuthCredential? {
        do {
            let refreshed = try await patService.refreshCredential(credential, account: account)
            try? await vault.save(refreshed, metadata: account)
            return refreshed
        } catch {
            return nil
        }
    }

    /// PAT re-exchange with a transient-retry budget. Distinguishes a
    /// recoverable transport failure (`QoderPATError.network` — DNS, timeout,
    /// TLS, cancelled) from a permanent revocation (`.invalidPAT`,
    /// `.exchangeFailed(401/403)`, `.exchangeMalformed`, `.identityMissing`):
    /// transient failures are retried up to `reexchangeRetryCount` times; a
    /// permanent failure returns nil on the first try without burning the
    /// budget, since a malformed PAT won't fix itself on retry.
    ///
    /// Returns the refreshed credential on success, or nil if every attempt
    /// failed. The caller (the reactive `.reexchangeAndRetry` site in
    /// `openStream`) disables only proven permanent failures; transient
    /// exhaustion enters the existing in-memory cooldown.
    ///
    /// `isPermanent` is exposed so the caller can choose persistent disable vs.
    /// cooldown without re-classifying.
    private func reexchangeWithRetry(
        for account: MonitorAccount,
        credential: MonitorOAuthCredential,
        isPermanent: inout Bool
    ) async -> MonitorOAuthCredential? {
        isPermanent = false
        var current = credential
        let attempts = max(1, configuration.reexchangeRetryCount)
        // Total attempts = `attempts`. A permanent failure short-circuits
        // immediately (a malformed PAT won't fix itself on retry).
        for attempt in 0..<attempts {
            do {
                let refreshed = try await patService.refreshCredential(current, account: account)
                try? await vault.save(refreshed, metadata: account)
                return refreshed
            } catch {
                if Self.isPermanentReexchangeFailure(error) {
                    isPermanent = true
                    return nil
                }
                // Transient — retry if budget remains.
                current = credential  // refreshCredential is idempotent on cred
                _ = attempt  // loop counter; kept for debuggability
            }
        }
        return nil
    }

    /// Classify a PAT-service error as permanent (won't fix itself on retry).
    /// Transient (returns false):
    ///   - `.network` — transport failure (DNS, timeout, TLS, cancelled).
    ///   - `.exchangeFailed(429)` — the exchange endpoint itself is rate-
    ///     limiting us. This is the root cause of the "No Qoder accounts
    ///     available while the real accounts still have quota" bug: heavy quota
    ///     polling can trip `openapi.qoder.sh`'s rate limit on the exchange
    ///     endpoint, and classifying it as permanent disabled every account
    ///     that needed a job-token rotation, with no recheck.
    ///   - `.userInfoFailed(429)` — same, on the userinfo endpoint.
    /// Permanent (returns true): `.invalidPAT`, `.exchangeFailed(401/403)` (a
    /// real revocation), `.exchangeMalformed`, `.identityMissing`. These won't
    /// fix themselves on retry.
    private nonisolated static func isPermanentReexchangeFailure(_ error: Error) -> Bool {
        if let patError = error as? QoderPATError {
            switch patError {
            case .network:
                return false
            case .exchangeFailed(let status, _), .userInfoFailed(let status, _):
                // 429 (rate limited) is transient; other 4xx from the exchange
                // or userinfo endpoints indicate a real auth problem.
                return status != 429
            case .invalidPAT, .exchangeMalformed, .identityMissing:
                return true
            }
        }
        // Unknown error type — treat as transient (safer for the account).
        return false
    }

    // MARK: - Cooldown / disable / notify

    /// Apply a cooldown to `accountID`. Issue #12: if the caller carries a
    /// server-supplied `Retry-After` hint (delta-seconds, from a 429), use it
    /// clamped to `[retryAfterFloor, retryAfterCeiling]` — the floor (= the
    /// default `cooldownTTL`) prevents a sub-second hint from under-cooling an
    /// exhausted account, and the ceiling (default 300s) prevents a misbehaving
    /// server from parking the account indefinitely. Absent/unparseable hint
    /// → `cooldownTTL`. Resets the silent-stall strike counter so a cooled
    /// account gets a fresh two-strike budget when it returns.
    private func applyCooldown(accountID: String, retryAfterSeconds: TimeInterval? = nil) {
        let ttl: TimeInterval
        if let retry = retryAfterSeconds {
            ttl = min(max(retry, configuration.retryAfterFloor), configuration.retryAfterCeiling)
        } else {
            ttl = configuration.cooldownTTL
        }
        cooldowns[accountID] = Date().addingTimeInterval(ttl)
        silentStallStrikes.removeValue(forKey: accountID)
    }

    /// Parse an HTTP `Retry-After` header into seconds (issue #12). RFC 7231
    /// §7.1.3 permits two forms:
    ///   - delta-seconds (a non-negative integer, e.g. `"120"`)
    ///   - HTTP-date (e.g. `"Wed, 21 Oct 2015 07:28:00 GMT"`)
    /// Delta-seconds is the common case and what the gateway emits today; we
    /// parse it directly. HTTP-date is best-effort via `parseHTTPDate`.
    /// Returns nil on a missing/empty header or any parse failure (including
    /// negative delta-seconds). Successful parses are capped at 86,400s (24h)
    /// as a sanity ceiling before `applyCooldown`'s `[floor, ceiling]` clamp
    /// narrows the practical range further. A past HTTP-date clamps to 0
    /// (the floor in `applyCooldown` is what keeps a 0 from under-cooling).
    /// Nonisolated + pure so it's trivially testable and callable from the
    /// actor-isolated attempt path without a hop.
    nonisolated static func retryAfterSeconds(
        from response: HTTPURLResponse,
        capturedAt now: Date
    ) -> TimeInterval? {
        // `value(forHTTPHeaderField:)` is case-insensitive per RFC, matching
        // both `Retry-After` and `retry-after`.
        guard let raw = response.value(forHTTPHeaderField: "Retry-After")?.trimmingCharacters(in: .whitespaces),
              !raw.isEmpty else {
            return nil
        }
        // Delta-seconds.
        if let seconds = TimeInterval(raw), seconds >= 0, seconds.isFinite {
            return min(seconds, 86_400)  // cap absurd hints at 24h pre-clamp
        }
        // HTTP-date (best effort).
        if let date = QoderFailoverRouter.parseHTTPDate(raw) {
            let delta = date.timeIntervalSince(now)
            return delta > 0 ? min(delta, 86_400) : 0
        }
        return nil
    }

    /// Best-effort parse of an RFC 7231 §7.1.1 IMF-fixdate (the HTTP-date form
    /// permitted in `Retry-After`). `DateFormatter` is not thread-safe, so a
    /// fresh instance is constructed per parse — this is a rare path (delta-
    /// seconds is the gateway's actual format and is handled by `retryAfterSeconds`
    /// directly), and the cost is irrelevant at call rates of ~zero. A fresh
    /// per-call formatter also keeps the function pure and `Sendable`-safe with
    /// no synchronization machinery. Nonisolated + pure.
    private nonisolated static func parseHTTPDate(_ string: String) -> Date? {
        let formatter = DateFormatter()
        // en_US_POSIX + GMT = the exact IMF-fixdate locale/zone the RFC
        // mandates; any other locale would mis-parse fixed-format dates.
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        // The trailing `GMT` is literal text, so it MUST be quoted (`'GMT'`);
        // an unquoted `G` is the era designator pattern letter, which would
        // both corrupt `string(from:)` output and fail to parse real headers.
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter.date(from: string)
    }

    /// Persistently disable the account (so it's skipped on subsequent
    /// requests too) and post the reliable revocation notification. Reserved
    /// for proven permanent failures; transient re-exchange exhaustion uses an
    /// in-memory cooldown instead. ADR 0006 §2: "the user must learn via
    /// Quotio's notification, not via a failed agent request." The notification
    /// carries the account key (display name) — never the PAT or token.
    private func disableAndNotifyRevoked(account: MonitorAccount) async {
        try? await metadata.setDisabled(true, accountID: account.id)
        Task { @MainActor in
            NotificationCenter.default.post(
                name: .qoderPATRevoked,
                object: nil,
                userInfo: ["accountKey": account.accountKey, "displayName": account.displayName]
            )
        }
    }

    // MARK: - Account enumeration

    /// List enabled Qoder accounts not currently in cooldown. Order: primary
    /// (first-enabled — there's no user-designated-primary concept yet in the
    /// Vault) first, then the rest. Stable order so cooldown + rotation
    /// produces predictable behavior.
    private func enabledQoderAccounts() async throws -> [MonitorAccount] {
        let disabledIDs = await metadata.disabledAccountIDs()
        let now = Date()
        // Lazy-evict expired cooldowns while we filter.
        cooldowns = cooldowns.filter { _, expiresAt in expiresAt > now }

        let all = await vault.accounts()
        return all
            .filter { $0.provider == .qoder }
            .filter { !disabledIDs.contains($0.id) }
            .filter { !cooldowns.keys.contains($0.id) }
    }

    /// Decide which exhaustion error to throw when no candidate can serve the
    /// request. The two cases carry different HTTP semantics:
    ///
    /// - **429 `allAccountsCoolingDown`** (self-healing): at least one Qoder
    ///   account is in `cooldowns` (in-memory, 1–5 min TTL) and *not* in
    ///   `disabledAccountIDs` (persistent). Retrying after the earliest
    ///   cooldown expiry will succeed, so we surface an OpenAI-shaped rate-
    ///   limit response with `Retry-After` and let the agent back off.
    /// - **503 `noAccountsAvailable`** (needs user action): no Qoder accounts
    ///   exist, or all are persistently disabled (revoked PAT). Waiting won't
    ///   help, so 503 + the existing "add a PAT" message stays.
    ///
    /// `Retry-After` = seconds until the earliest *recoverable* cooldown
    /// expires, clamped to ≥1s (a sub-second remainder would round to 0 and
    /// tell the agent "retry immediately," re-tripping the limit). Cooldowns
    /// on accounts that are *also* disabled are ignored — a disabled account
    /// won't recover when its cooldown lifts.
    private func exhaustionError() async -> QoderFailoverError {
        let disabledIDs = await metadata.disabledAccountIDs()
        let now = Date()
        // Only cooldowns on enabled accounts are recoverable. A disabled-
        // and-cooled account won't serve a request when the cooldown lifts.
        let recoverableExpiries = cooldowns.filter { id, expiresAt in
            expiresAt > now && !disabledIDs.contains(id)
        }
        if recoverableExpiries.isEmpty {
            return .noAccountsAvailable
        }
        let earliest = recoverableExpiries.values.min() ?? now
        let seconds = max(1, earliest.timeIntervalSince(now))
        return .allAccountsCoolingDown(retryAfterSeconds: seconds)
    }

    // MARK: - Body parsing helpers (nonisolated, pure)

    /// Extract the `model` field from the request body. Returns the raw value
    /// (e.g. `"qoder/auto"`); prefix-stripping happens in `openStream` before
    /// the registry and translator see it.
    private nonisolated static func extractModelID(from body: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let model = json["model"] as? String,
              !model.isEmpty else {
            return nil
        }
        return model
    }

    /// Return a copy of the body with its top-level `model` field replaced.
    /// Used to strip the `qoder/` routing prefix (ADR 0003 §1) before the body
    /// reaches the translator and the upstream gateway. Falls back to the
    /// original body on any parse/serialization failure — the unprefixed
    /// gateway request is best-effort, and a malformed body fails fast at the
    /// translator's parse gate regardless.
    private nonisolated static func replaceModel(in body: Data, with newModel: String) -> Data {
        guard var json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              json["model"] != nil else {
            return body
        }
        json["model"] = newModel
        guard let rewritten = try? JSONSerialization.data(withJSONObject: json) else {
            return body
        }
        return rewritten
    }

    /// Whether the client asked for a streaming response. True only when the
    /// request body carries `"stream": true`. A missing `stream` field and an
    /// explicit `false` both yield `false` — OpenAI's Chat Completions schema
    /// defaults `stream` to `false`
    /// (https://github.com/openai/openai-openapi/blob/c309ca1/openapi.yaml#L32968-L32977).
    /// This corrects the prior behavior, which treated a missing field as
    /// streaming (the opposite of the spec default). Non-streaming requests
    /// are now served by aggregating the SSE upstream into one
    /// `chat.completion` JSON (issue #9, ADR 0014); they are NOT rejected.
        private nonisolated static func streamRequested(in body: Data) -> Bool {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let stream = json["stream"] as? Bool else {
            return false
        }
        return stream
    }
}
