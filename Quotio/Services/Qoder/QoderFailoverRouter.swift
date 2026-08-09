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
    /// (tools / images / malformed body). Maps to HTTP 400. (`stream: false`
    /// is no longer rejected — non-streaming is served by aggregation, issue
    /// #9 / ADR 0014.)
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
                    modelConfig: modelConfig,
                    streamRequested: clientWantsStream
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
                                modelConfig: modelConfig,
                                streamRequested: clientWantsStream
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
    ///     on exhausted accounts) → throw `.quota`. The account is cooled down
    ///     and the next candidate is tried immediately.
    ///  3. First chunk is clean (content, or a benign non-envelope line, or the
    ///     stream ended on `[DONE]`) → hand off, carrying the consumed bytes as
    ///     `bufferedPrefix` so ProxyBridge doesn't lose them.
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
        // first chunk within the timeout — the observed shape of an exhausted
        // account. Classify as quota so the account is cooled down and the next
        // candidate is tried right away.
        guard let prefix = firstChunk, !prefix.isEmpty else {
            throw QoderAccountFailure(kind: .quota, status: 429, detail: "silent stall")
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
                // won't fix a malformed envelope.
                throw QoderFailoverError.requestRejected(
                    "Qoder upstream returned status \(signal) (non-rotatable)."
                )
            }
        }

        // Branch 3: clean. Hand off, carrying the consumed prefix so ProxyBridge
        // feeds it through the reparser before driving the remainder. Wrap
        // `stream.pump` in an explicit closure: `QoderGatewayStream` is a class,
        // so a bare method reference would carry `Self` and fail the
        // `@Sendable` closure conformance the `QoderOpenedStream.pump` field
        // requires. The class itself is `@unchecked Sendable`.
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
