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
//    - 401/403 (first occurrence)  → one-shot PAT re-exchange (machineID-
//                                    preserving), retry same account.
//    - 401/403 (after re-exchange) → disable account persistently, post a
//                                    reliable user-visible notification, rotate.
//    - 5xx / network               → retry same account once with short backoff.
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
    /// Drive the upstream byte stream. `onChunk` receives each raw buffer the
    /// gateway yields; return false to stop early. Throws on transport failure.
    let pump: @Sendable (@Sendable (Data) async throws -> Bool) async throws -> Void
    let accountID: String
    let translatorResult: QoderTranslationResult
}

/// Errors surfaced to ProxyBridge. ProxyBridge maps each to its wire
/// representation — an HTTP error before any stream byte was written. Tokens /
/// secrets are never embedded; account-cooling and disable state live inside
/// the router, not in error messages.
nonisolated enum QoderFailoverError: Error, LocalizedError {
    /// The request body was rejected by the translator's fail-fast gate
    /// (tools / images / malformed / `stream: false`). Maps to HTTP 400.
    case requestRejected(String)
    /// No Qoder accounts are configured, or all are disabled / cooled down.
    /// Maps to HTTP 503 (no upstream available).
    case noAccountsAvailable
    /// The caller's `Authorization: Bearer <key>` was missing or empty. The
    /// CPA path has CPA enforce the key; the Qoder branch bypasses CPA, so the
    /// router owns it. Maps to HTTP 401.
    case missingProxyAPIKey

    var errorDescription: String? {
        switch self {
        case .requestRejected(let detail):
            return detail
        case .noAccountsAvailable:
            return "No Qoder accounts available: add a PAT or wait for cooldown to clear."
        case .missingProxyAPIKey:
            return "Missing or invalid proxy API key (Authorization: Bearer <key>)."
        }
    }
}

/// Notification posted when a Qoder PAT is revoked (two consecutive 401/403s on
/// the same account, even after re-exchange). ADR 0006 §2 requires the
/// notification be reliable: the user must learn about the revocation via
/// Quotio, not via a failed agent request (the rotation silently keeps the
/// agent working as long as another account exists). `userInfo` carries the
/// account key for the notification body — never the PAT or token.
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

actor QoderFailoverRouter {
    /// How long a quota-exhausted account stays in cooldown. Short on purpose:
    /// quota windows on Qoder are per-minute, and the cooldown only needs to
    /// outlive a burst. ADR 0005 consequence note flags persistent cooldown as
    /// a follow-up; in-memory is the tracer.
    private static let cooldownTTL: TimeInterval = 60

    /// How long to back off before retrying the same account on a transient
    /// (5xx / network) error. ADR 0006 §2.
    private static let transientBackoff: UInt64 = 250_000_000  // 250ms in nanoseconds

    /// Per-account cooldown end times. An entry present and in the future means
    /// "skip this account when selecting candidates." Expired entries are lazy-
    /// evicted on read. In-memory only — lost on restart.
    private var cooldowns: [String: Date] = [:]

    /// Accounts we've already done a one-shot 401 re-exchange for within the
    /// current `openStream` call. Cleared per-call (not persistent) — the
    /// "one re-exchange" rule is per-failure-event, not per-account-lifetime.
    /// Implemented as a local in `openStream`, see implementation.

    private let vault: any MonitorCredentialStore
    private let metadata: MonitorMetadataStore
    private let patService: any QoderPATRefreshing
    private let gateway: any QoderGatewayClientProtocol

    init(
        vault: any MonitorCredentialStore,
        metadata: MonitorMetadataStore = .shared,
        patService: any QoderPATRefreshing,
        gateway: any QoderGatewayClientProtocol
    ) {
        self.vault = vault
        self.metadata = metadata
        self.patService = patService
        self.gateway = gateway
    }

    // MARK: - Public entry point

    /// Open a confirmed-2xx gateway stream for a Qoder chat request, applying
    /// the rotation policy across all enabled Qoder accounts. Throws
    /// `QoderFailoverError` if no account can serve the request.
    ///
    /// `proxyAPIKey` is the `Bearer` key from the agent's request — used in
    /// the session-ID derivation (ADR 0005 §1) and validated non-empty here
    /// (CPA is bypassed for Qoder, so we own key validation).
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
        // Reject `stream: false` up front — the gateway stream is SSE-only in
        // Phase 2a, and the SSEReparser assumes a stream. Phase 2b does not
        // lift this.
        if QoderFailoverRouter.isNonStreaming(body: requestBody) {
            throw QoderFailoverError.requestRejected(
                "Qoder: stream:false is not supported (Phase 2a is SSE-only)."
            )
        }
        let modelConfig = QoderModelRegistry.resolve(modelID)

        // Enumerate enabled, non-cooled-down Qoder accounts in priority order.
        // Primary (user-designated, or first-enabled) first.
        let candidates = try await enabledQoderAccounts()
        guard !candidates.isEmpty else {
            throw QoderFailoverError.noAccountsAvailable
        }

        // Track accounts that already burned their one-shot 401 re-exchange
        // within this call. The set is per-call: a future request gets a fresh
        // one-shot budget per account.
        var reexchangedAccounts: Set<String> = []

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
                    modelConfig: modelConfig
                )
                return stream
            } catch let failure as QoderAccountFailure {
                let action = decideAction(
                    for: failure,
                    account: account,
                    reexchangedAccounts: &reexchangedAccounts
                )
                switch action {
                case .reexchangeAndRetry:
                    // One-shot re-exchange, then retry the same account.
                    if let refreshed = await reexchange(for: account, credential: credential) {
                        reexchangedAccounts.insert(account.id)
                        do {
                            let stream = try await attempt(
                                account: account,
                                credential: refreshed,
                                requestBody: bodyForTranslator,
                                proxyAPIKey: proxyAPIKey,
                                modelID: modelID,
                                modelConfig: modelConfig
                            )
                            return stream
                        } catch let failure2 as QoderAccountFailure {
                            // Second failure on the same account after re-
                            // exchange. If it's another 401/403, the PAT is
                            // revoked — disable + notify + rotate.
                            if failure2.isAuthFailure {
                                await disableAndNotifyRevoked(account: account)
                            } else if failure2.isQuota {
                                applyCooldown(accountID: account.id)
                            }
                            continue
                        }
                        // Other errors fall through to the next account.
                    } else {
                        // Re-exchange itself failed (PAT invalid/revoked, or
                        // network). Disable + notify so the user learns, then
                        // rotate.
                        await disableAndNotifyRevoked(account: account)
                        continue
                    }
                case .cooldownAndRotate:
                    applyCooldown(accountID: account.id)
                    continue
                case .disableNotifyAndRotate:
                    await disableAndNotifyRevoked(account: account)
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
                            modelConfig: modelConfig
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
        throw QoderFailoverError.noAccountsAvailable
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
        modelConfig: QoderModelConfig
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
                modelConfig: modelConfig
            )
        } catch let error as QoderTranslatorError {
            // Fail-fast gates (tools / images / malformed). Map to a rejected
            // request — ProxyBridge returns HTTP 400. Not account-specific, so
            // throw the terminal error, not a rotation-eligible one.
            throw QoderFailoverError.requestRejected(error.localizedDescription)
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

        // Read the HTTP status and apply the rotation policy. 2xx hands off to
        // ProxyBridge; non-2xx is rotation-eligible (except where noted).
        let status = stream.response.statusCode
        if (200..<300).contains(status) {
            return QoderOpenedStream(
                pump: stream.pump,
                accountID: account.id,
                translatorResult: translatorResult
            )
        }

        switch status {
        case 429:
            throw QoderAccountFailure(kind: .quota, status: status)
        case 401, 403:
            throw QoderAccountFailure(kind: .auth, status: status)
        case 500...599:
            throw QoderAccountFailure(kind: .transient, status: status)
        default:
            // 4xx other than 429/401/403 (e.g. 400 bad request, 404, 422) is
            // a request-level rejection, not an account-level one — rotating
            // accounts won't fix a malformed envelope. Surface it as a
            // terminal request rejection so ProxyBridge returns the real
            // status to the agent.
            throw QoderFailoverError.requestRejected(
                "Qoder gateway returned HTTP \(status) (non-rotatable)."
            )
        }
    }

    // MARK: - Decision policy

    /// Internal failure classification. `status` is the upstream HTTP code
    /// when available; nil for transport-level failures (network).
    private struct QoderAccountFailure: Error {
        enum Kind { case quota, auth, transient }
        let kind: Kind
        let status: Int?
        var detail: String?

        var isAuthFailure: Bool { kind == .auth }
        var isQuota: Bool { kind == .quota }
    }

    private enum FailureAction {
        case reexchangeAndRetry
        case cooldownAndRotate
        case disableNotifyAndRotate
        case retrySameOnce
    }

    private nonisolated func decideAction(
        for failure: QoderAccountFailure,
        account: MonitorAccount,
        reexchangedAccounts: inout Set<String>
    ) -> FailureAction {
        switch failure.kind {
        case .quota:
            return .cooldownAndRotate
        case .auth:
            // The one-shot 401 re-exchange is per-call per-account: if we
            // haven't already tried re-exchanging for this account during
            // this `openStream`, do so; otherwise the PAT is revoked.
            if reexchangedAccounts.contains(account.id) {
                return .disableNotifyAndRotate
            }
            return .reexchangeAndRetry
        case .transient:
            return .retrySameOnce
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

    // MARK: - Cooldown / disable / notify

    private func applyCooldown(accountID: String) {
        cooldowns[accountID] = Date().addingTimeInterval(Self.cooldownTTL)
    }

    /// Persistently disable the account (so it's skipped on subsequent
    /// requests too) and post the reliable revocation notification. ADR 0006
    /// §2: "the user must learn via Quotio's notification, not via a failed
    /// agent request." The notification carries the account key (display
    /// name) — never the PAT or token.
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

    /// Whether the request asked for a non-streaming response. Phase 2a is
    /// SSE-only (the SSEReparser assumes a stream); reject `stream: false`
    /// (or absent stream with explicit `false`) up front. A missing `stream`
    /// field defaults to streaming (matches OpenAI's server default).
    private nonisolated static func isNonStreaming(body: Data) -> Bool {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let stream = json["stream"] as? Bool else {
            return false
        }
        return stream == false
    }
}
