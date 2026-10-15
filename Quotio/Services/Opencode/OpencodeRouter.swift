//
//  OpencodeRouter.swift
//  Quotio
//
//  Account-aware upstream router for the `opencode/` branch — the sibling
//  of `QoderFailoverRouter`, simplified to a byte-faithful pass-through.
//  Where the Qoder router returns only confirmed-2xx streams, this router
//  returns whatever status upstream produced: 401 → rotate to the next
//  account, 429 → cooldown + rotate, transport failure → next account, and
//  every other HTTP status (2xx, 400, 403, 5xx) is handed back verbatim for
//  ProxyBridge to forward — rotating can't fix a request-level rejection,
//  and upstream's own error body is the most client-faithful answer.
//
//  Credential policy (spec §Credentials):
//    - Quotio-managed (vault) credentials may be refreshed with the console
//      refresh grant; rotated tokens persist back to the vault, never to
//      opencode's store.
//    - Detected system credentials are NEVER refreshed. On expiry they are
//      re-read from their source store (the user re-auths inside opencode,
//      which rewrites the store). Still-expired → mark stale, notify once,
//      skip; a later request that succeeds through the account posts
//      `opencodeAccountRecovered`.
//
//  Upstream impersonation (Task 0 spike): requests carry the released
//  client's User-Agent and the x-opencode-* metadata headers; the session/
//  request IDs use opencode's timestamp-encoded scheme. The free-tier gate
//  validates more than the UA — minimal or synthetic-metadata requests are
//  rejected with 403.
//

import Foundation

/// Errors surfaced to ProxyBridge, mapped to HTTP before any stream byte is
/// written. Tokens and upstream bodies are never embedded.
nonisolated enum OpencodeRouterError: Error, LocalizedError, Equatable {
    case noAccountsAvailable
    case allAccountsCoolingDown(retryAfter: TimeInterval)
    /// Defensive: `processRequest` normally 503s on an empty catalog before
    /// reaching the router.
    case catalogUnavailable
    /// Transport-level failure summary; status + short detail, never tokens.
    case upstream(Int, String)

    var httpStatus: Int {
        switch self {
        case .noAccountsAvailable, .catalogUnavailable: return 503
        case .allAccountsCoolingDown: return 429
        case .upstream(let status, _): return status > 0 ? status : 503
        }
    }

    var retryAfterSeconds: Int? {
        switch self {
        case .allAccountsCoolingDown(let seconds): return max(1, Int(ceil(seconds)))
        case .noAccountsAvailable, .catalogUnavailable, .upstream: return nil
        }
    }

    var errorDescription: String? {
        switch self {
        case .noAccountsAvailable:
            return "No opencode accounts available: sign in via Quotio or opencode."
        case .allAccountsCoolingDown(let seconds):
            return "All opencode accounts are rate-limited; retry after \(Int(ceil(seconds)))s."
        case .catalogUnavailable:
            return "opencode free-model catalog unavailable."
        case .upstream(let status, let detail):
            return "opencode upstream error (\(status)): \(detail)"
        }
    }
}

/// Per-chunk callback handed to a stream `pump` — same contract as
/// `QoderChunkReceiver`.
typealias OpencodeChunkReceiver = @Sendable (Data) async throws -> Bool

/// The stream the router hands back. Unlike `QoderOpenedStream`, the
/// response is NOT 2xx-by-construction: `status` and `headers` carry the
/// verbatim upstream response for ProxyBridge to forward.
nonisolated struct OpencodeOpenedStream: Sendable {
    let status: Int
    let headers: [(String, String)]
    /// Bytes the router already consumed before handing off — currently
    /// always empty (no pre-handoff peek; kept for parity with the Qoder
    /// shape in case a peek is ever needed).
    let bufferedPrefix: Data
    let pump: @Sendable (OpencodeChunkReceiver) async throws -> Void
    /// Tear down the upstream task when the consumer aborts BEFORE pumping
    /// (e.g. the agent socket rejects the response head). `pump`'s defer
    /// cancels on every exit once running; this covers never-pumped streams.
    let cancel: @Sendable () -> Void
}

actor OpencodeRouter {

    /// Stale-account lifecycle notifications. `userInfo` carries
    /// `["accountKey", "displayName"]` — never tokens.
    static let opencodeAccountStale = Notification.Name("dev.quotio.opencode.account-stale")
    static let opencodeAccountRecovered = Notification.Name("dev.quotio.opencode.account-recovered")
    /// 429 → cooldown notification. `userInfo` adds `"retryAfter"`
    /// (seconds until the account leaves cooldown); the Quota tab renders
    /// the account as rate-limited while that window is still open.
    static let opencodeAccountRateLimited = Notification.Name("dev.quotio.opencode.account-rate-limited")

    /// Released-client User-Agent pinned from the Task 0 spike: observed on
    /// the local opencode 1.18.30 (Homebrew) install; the upstream free-tier
    /// gate 403s versions it doesn't recognize (`opencode/1.19.0` failed).
    static let clientUserAgent = "opencode/1.18.30 ai-sdk/provider-utils/4.0.23 runtime/bun/1.3.14"

    /// In-memory cooldown for a rate-limited (429) account.
    private static let cooldownTTL: TimeInterval = 60
    /// Refresh window: credentials expiring within this margin are renewed
    /// proactively rather than burning a 401 round-trip.
    private static let expiryMargin: TimeInterval = 60

    private let catalog: OpencodeModelCatalog
    private let console: OpencodeConsoleClient
    private let upstream: any OpencodeUpstreamClientProtocol
    private let vault: any MonitorCredentialStore
    private let metadata: MonitorMetadataStore
    /// Current detected-credential set, refreshed by the caller's periodic
    /// tick (Task 8) — NOT re-discovered per request.
    private let detectedSnapshot: @Sendable () -> [DetectedOpencodeCredential]

    /// Cooldown end per account key; entries in the future mean "skip".
    private var cooldowns: [String: Date] = [:]
    /// Stale-marked account keys → displayName. Marking suppresses repeat
    /// notifications; the account is still re-checked every request (a re-
    /// authed store entry or re-login can recover it).
    private var staleAccounts: [String: String] = [:]

    init(
        catalog: OpencodeModelCatalog = .shared,
        console: OpencodeConsoleClient = OpencodeConsoleClient(),
        upstream: any OpencodeUpstreamClientProtocol = OpencodeUpstreamClient(),
        vault: any MonitorCredentialStore = MonitorCredentialVault.shared,
        metadata: MonitorMetadataStore = .shared,
        detectedSnapshot: @escaping @Sendable () -> [DetectedOpencodeCredential] = {
            OpencodeCredentialDetector.discover()
        }
    ) {
        self.catalog = catalog
        self.console = console
        self.upstream = upstream
        self.vault = vault
        self.metadata = metadata
        self.detectedSnapshot = detectedSnapshot
    }

    // MARK: - Account candidates

    private struct Candidate {
        enum Source {
            case vault(account: MonitorAccount, credential: MonitorOAuthCredential)
            case detected(DetectedOpencodeCredential)
        }
        let key: String
        let displayName: String
        let source: Source
    }

    /// Open an upstream stream for a gated request, rotating across
    /// accounts per the policy in the header comment.
    func open(requestBody: Data, route: OpencodeRoute) async throws -> OpencodeOpenedStream {
        if catalog.isEmpty { throw OpencodeRouterError.catalogUnavailable }

        let upstreamBody = Self.shapeUpstreamBody(from: requestBody)
        let candidates = await self.candidates()
        guard !candidates.isEmpty else { throw exhaustionError() }

        // Evaluate freshness for EVERY candidate before serving — an expired
        // credential that never reaches the front of the queue must still be
        // stale-marked (and a recovered one un-marked), or the notifications
        // would depend on failover order. Vault creds inside the margin get
        // refreshed proactively here — same work their turn would do anyway.
        var resolved: [(Candidate, ResolvedCredential)] = []
        for candidate in candidates {
            if let credential = await resolveCredential(for: candidate) {
                resolved.append((candidate, credential))
            }
        }
        guard !resolved.isEmpty else { throw exhaustionError() }

        for (candidate, credential) in resolved {
            let url = Self.inferenceURL(route: route, server: credential.server)
            let headers = Self.upstreamHeaders(token: credential.token, orgID: credential.orgID)
            let stream: OpencodeUpstreamStream
            do {
                stream = try await upstream.post(url: url, headers: headers, body: upstreamBody)
            } catch {
                continue   // transport failure → next account
            }
            switch stream.status {
            case 401:
                // Spec: a detected credential that 401s is re-read from its
                // store — a rotated token retries upstream once. Same-token
                // (or still-dead) → the credential is revoked for real:
                // stale-mark and move on.
                if case .detected(let detected) = candidate.source {
                    if let retry = try await retryDetectedAfter401(
                        detected, url: url, body: upstreamBody) {
                        switch retry.status {
                        case 401:
                            markStale(candidate.key, displayName: candidate.displayName)
                            continue
                        case 429:
                            setCooldown(candidate)
                            continue
                        default:
                            return openedStream(retry)
                        }
                    }
                    // Store has nothing better to offer (same token,
                    // expired, or unreadable) → the credential is revoked
                    // for real; surface it.
                    markStale(candidate.key, displayName: candidate.displayName)
                }
                continue   // bad credential on this account → next
            case 429:
                setCooldown(candidate)
                continue
            default:
                return openedStream(stream)
            }
        }
        throw exhaustionError()
    }

    /// Proactively renew vault credentials inside the expiry margin (Task 8
    /// periodic tick). Reuses the request-time freshness path so the same
    /// refresh/persist/stale-marking semantics apply — a request arriving
    /// after the tick then finds ready tokens instead of paying the refresh
    /// latency mid-request.
    func refreshExpiringVaultCredentials() async {
        for candidate in await candidates() {
            if case .vault = candidate.source {
                _ = await resolveCredential(for: candidate)
            }
        }
    }

    private func candidates() async -> [Candidate] {
        let now = Date()
        cooldowns = cooldowns.filter { _, expiry in expiry > now }
        var result: [Candidate] = []
        var vaultKeys = Set<String>()
        let disabledIDs = await metadata.disabledAccountIDs()
        for account in await vault.accounts() {
            guard account.provider == .opencode, !disabledIDs.contains(account.id),
                  let credential = await vault.credential(for: account.id) else { continue }
            let key = account.accountKey
            vaultKeys.insert(key.lowercased())
            guard !cooldowns.keys.contains(key) else { continue }
            result.append(Candidate(
                key: key, displayName: account.displayName,
                source: .vault(account: account, credential: credential)))
        }
        for detected in detectedSnapshot() {
            // Vault (quotio-managed) wins over detected for the same account —
            // same priority ordering as MonitorAccountDiscovery.selectPreferred.
            guard !vaultKeys.contains(detected.accountKey.lowercased()),
                  !cooldowns.keys.contains(detected.accountKey) else { continue }
            // The user's disabled set applies to detected accounts too —
            // the monitor materializes them with the same id formula
            // (MonitorAccountDiscovery.discoverOpencodeCredentials).
            let detectedAccountID = MonitorAccount.make(
                provider: .opencode, accountKey: detected.accountKey,
                source: .nativeCredential, credentialReference: detected.sourcePath).id
            guard !disabledIDs.contains(detectedAccountID) else { continue }
            result.append(Candidate(
                key: detected.accountKey, displayName: detected.email ?? detected.accountKey,
                source: .detected(detected)))
        }
        return result
    }

    // MARK: - Credential freshness

    private struct ResolvedCredential {
        let token: String
        let orgID: String?
        let server: String
    }

    /// Resolve a usable token for the candidate: vault creds may refresh via
    /// the console grant; detected creds only re-read their source store.
    /// Returns nil when the account can't serve (stale-marked + notified).
    /// A stale-marked account whose credential resolves fresh again counts as
    /// recovered — "usable credential" is the signal the notification means;
    /// whether it actually fronts the next request depends on order.
    private func resolveCredential(for candidate: Candidate) async -> ResolvedCredential? {
        let resolved = await resolveCredentialImpl(for: candidate)
        if resolved != nil { markRecovered(candidate.key) }
        return resolved
    }

    private func resolveCredentialImpl(for candidate: Candidate) async -> ResolvedCredential? {
        let margin = Date().addingTimeInterval(Self.expiryMargin)
        switch candidate.source {
        case .vault(let account, var credential):
            guard let expiresAt = credential.expiresAt, expiresAt < margin else {
                return ResolvedCredential(
                    token: credential.accessToken,
                    orgID: credential.extra["orgID"]?.nilIfBlank,
                    server: credential.extra["server"]?.nilIfBlank ?? OpencodeConsoleClient.defaultServer)
            }
            guard let refreshToken = credential.refreshToken?.nilIfBlank else {
                markStale(candidate.key, displayName: candidate.displayName)
                return nil
            }
            do {
                let renewed = try await console.refresh(refreshToken: refreshToken)
                credential.accessToken = renewed.accessToken
                credential.refreshToken = renewed.refreshToken
                credential.expiresAt = Date().addingTimeInterval(TimeInterval(renewed.expiresIn))
                if let orgID = renewed.orgID { credential.extra["orgID"] = orgID }
                try? await vault.save(credential, metadata: account)
                return ResolvedCredential(
                    token: renewed.accessToken,
                    orgID: credential.extra["orgID"]?.nilIfBlank,
                    server: credential.extra["server"]?.nilIfBlank ?? OpencodeConsoleClient.defaultServer)
            } catch {
                if let consoleError = error as? OpencodeConsoleError, consoleError == .invalidGrant {
                    markStale(candidate.key, displayName: candidate.displayName)
                }
                return nil
            }
        case .detected(let detected):
            guard let expiresAt = detected.expiresAt, expiresAt < margin else {
                return ResolvedCredential(
                    token: detected.accessToken, orgID: detected.orgID, server: detected.server)
            }
            // Expired: re-read the source store — NEVER a refresh grant for a
            // detected credential.
            guard let reloaded = OpencodeCredentialDetector.reload(sourcePath: detected.sourcePath),
                  reloaded.expiresAt.map({ $0 > margin }) ?? true else {
                markStale(candidate.key, displayName: candidate.displayName)
                return nil
            }
            return ResolvedCredential(
                token: reloaded.accessToken, orgID: reloaded.orgID, server: reloaded.server)
        }
    }

    /// A detected credential 401'd — re-read its source store. A rotated,
    /// still-fresh token retries upstream once (returns nil when the store
    /// has nothing better to offer: same token, expired, or unreadable —
    /// the caller then treats the credential as revoked). Transport errors
    /// propagate: a flaky network is not evidence of revocation.
    private func retryDetectedAfter401(
        _ detected: DetectedOpencodeCredential,
        url: URL,
        body: Data
    ) async throws -> OpencodeUpstreamStream? {
        guard let reloaded = OpencodeCredentialDetector.reload(sourcePath: detected.sourcePath),
              reloaded.accessToken != detected.accessToken,
              reloaded.expiresAt.map({ $0 > Date().addingTimeInterval(Self.expiryMargin) }) ?? true
        else { return nil }
        let headers = Self.upstreamHeaders(token: reloaded.accessToken, orgID: reloaded.orgID)
        return try await upstream.post(url: url, headers: headers, body: body)
    }

    /// Records a 429 cooldown and notifies the UI so the account renders
    /// as rate-limited. Expiry is passive (cooldownTTL) — no recovery
    /// notification; consumers compare the reported window against now.
    private func setCooldown(_ candidate: Candidate) {
        cooldowns[candidate.key] = Date().addingTimeInterval(Self.cooldownTTL)
        let info: [String: Any] = [
            "accountKey": candidate.key,
            "displayName": candidate.displayName,
            "retryAfter": Self.cooldownTTL,
        ]
        Task { @MainActor in
            NotificationCenter.default.post(
                name: OpencodeRouter.opencodeAccountRateLimited, object: nil, userInfo: info)
        }
    }

    // MARK: - Stale / recovered notifications

    private func markStale(_ key: String, displayName: String) {
        guard staleAccounts[key] == nil else { return }
        staleAccounts[key] = displayName
        let info: [String: String] = ["accountKey": key, "displayName": displayName]
        Task { @MainActor in
            NotificationCenter.default.post(
                name: OpencodeRouter.opencodeAccountStale, object: nil, userInfo: info)
        }
    }

    private func markRecovered(_ key: String) {
        guard let displayName = staleAccounts.removeValue(forKey: key) else { return }
        let info: [String: String] = ["accountKey": key, "displayName": displayName]
        Task { @MainActor in
            NotificationCenter.default.post(
                name: OpencodeRouter.opencodeAccountRecovered, object: nil, userInfo: info)
        }
    }

    private func exhaustionError() -> OpencodeRouterError {
        let now = Date()
        let recoverable = cooldowns.values.filter { $0 > now }
        guard let earliest = recoverable.min() else { return .noAccountsAvailable }
        return .allAccountsCoolingDown(retryAfter: max(1, earliest.timeIntervalSince(now)))
    }

    // MARK: - Stream handoff

    private func openedStream(_ stream: OpencodeUpstreamStream) -> OpencodeOpenedStream {
        let streamRef = stream
        return OpencodeOpenedStream(
            status: stream.status,
            headers: stream.headers,
            bufferedPrefix: Data(),
            pump: { onChunk in
                defer { streamRef.cancel() }
                while true {
                    try Task.checkCancellation()
                    guard let buffer = try await streamRef.source() else { return }
                    if try await onChunk(buffer) == false { return }
                }
            },
            cancel: { streamRef.cancel() }
        )
    }

    // MARK: - Request shaping (pure)

    /// `<origin of credential.server>/inference` + the surface the client
    /// requested — forwarded verbatim, per spec §Routing.
    nonisolated static func inferenceURL(route: OpencodeRoute, server: String) -> URL {
        let origin: String
        if let components = URLComponents(string: server), let scheme = components.scheme {
            var rebuilt = "\(scheme)://\(components.host ?? "opencode.ai")"
            if let port = components.port { rebuilt += ":\(port)" }
            origin = rebuilt
        } else {
            origin = "https://opencode.ai"
        }
        let surface = route == .responses ? "/v1/responses" : "/v1/chat/completions"
        return URL(string: origin + "/inference" + surface)!
    }

    /// Header set proven by the Task 0 spike: the released client's UA and
    /// x-opencode-* metadata. `x-org-id` only when the credential carries one.
    nonisolated static func upstreamHeaders(token: String, orgID: String?) -> [(String, String)] {
        var headers: [(String, String)] = [
            ("Authorization", "Bearer \(token)"),
            ("User-Agent", clientUserAgent),
            ("x-opencode-client", "cli"),
            ("x-opencode-project", "global"),
            ("x-opencode-request", OpencodeRequestIdentity.next("msg")),
            ("x-opencode-session", OpencodeRequestIdentity.next("ses", descending: true)),
        ]
        if let orgID { headers.append(("x-org-id", orgID)) }
        headers.append(("Content-Type", "application/json"))
        return headers
    }

    /// Official `read` tool definition in OpenAI function shape — verified
    /// live (fix pass): this shape returns 200 from the free-tier gate, the
    /// bare `{"name","parameters"}` shape returns a 400 param error, and a
    /// body with no `read` tool returns a 403 FreeTierError. Rebuilt per
    /// call — `[String: Any]` isn't Sendable, so a shared static let would
    /// be a strict-concurrency violation.
    private nonisolated static func readToolDefinition() -> [String: Any] {
        [
            "type": "function",
            "function": [
                "name": "read",
                "description": "Reads a file from the local filesystem.",
                "parameters": [
                    "type": "object",
                    "properties": ["filePath": ["type": "string"]],
                    "required": ["filePath"]
                ]
            ]
        ]
    }

    /// Shape the client body into what a real opencode client sends:
    /// strip the `opencode/` routing prefix from `model`, force
    /// `stream: true`, and ensure a `read` tool is present. The Task 0
    /// spike proved the free-tier gate 403s `stream:false` and bodies
    /// lacking a `read` tool — "indistinguishable from a real opencode
    /// client" means sending both, since the released client always does.
    /// Falls back to the original body on any parse failure (the route
    /// gate already required a parseable model).
    private nonisolated static func shapeUpstreamBody(from body: Data) -> Data {
        guard var json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return body
        }
        if let model = json["model"] as? String,
           model.hasPrefix(OpencodeRouteGate.opencodePrefix) {
            json["model"] = String(model.dropFirst(OpencodeRouteGate.opencodePrefix.count))
        }
        json["stream"] = true
        var tools = (json["tools"] as? [Any]) ?? []
        let hasRead = tools.contains { entry in
            guard let tool = entry as? [String: Any] else { return false }
            return (tool["name"] as? String) == "read"
                || ((tool["function"] as? [String: Any])?["name"] as? String) == "read"
        }
        if !hasRead { tools.append(readToolDefinition()) }
        json["tools"] = tools
        return (try? JSONSerialization.data(withJSONObject: json)) ?? body
    }
}

/// Generator for the `msg_`/`ses_` request and session IDs the upstream gate
/// expects — ports opencode's timestamp-encoded scheme observed in the
/// Task 0 capture: `prefix_` + 6-byte hex(timestamp*0x1000 + counter,
/// bitwise-inverted for sessions so they sort newest-first) + 14 random
/// base62 chars.
private nonisolated enum OpencodeRequestIdentity {
    private static let b62 = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var lastTimestamp: Int64 = 0
        private var counter: Int64 = 0
        func next(_ timestamp: Int64) -> Int64 {
            lock.lock()
            defer { lock.unlock() }
            if timestamp != lastTimestamp { lastTimestamp = timestamp; counter = 0 }
            counter += 1
            return counter
        }
    }
    private static let counter = Counter()

    static func next(_ prefix: String, descending: Bool = false) -> String {
        let timestamp = Int64(Date().timeIntervalSince1970 * 1000)
        var value = UInt64(bitPattern: timestamp &* 0x1000 &+ counter.next(timestamp))
        if descending { value = ~value }
        var hex = ""
        for i in 0..<6 {
            hex += String(format: "%02x", (value >> UInt64(40 - 8 * i)) & 0xff)
        }
        var bytes = [UInt8](repeating: 0, count: 14)
        _ = SecRandomCopyBytes(kSecRandomDefault, 14, &bytes)
        return "\(prefix)_\(hex)\(String(bytes.map { b62[Int($0) % 62] }))"
    }
}

/// Lock-protected cache for the detected-credential snapshot the router
/// reads per request (the `detectedSnapshot` closure must be synchronous —
/// `OpencodeRouter.open` can't suspend to disk mid-candidate-enumeration).
/// QuotaViewModel's periodic tick calls `refresh()`; `snapshot()` is the
/// cheap synchronous read wired into the router.
nonisolated final class OpencodeDetectedCache: @unchecked Sendable {
    private let lock = NSLock()
    private var credentials: [DetectedOpencodeCredential] = []

    /// Re-run filesystem discovery and swap the snapshot.
    func refresh() {
        let found = OpencodeCredentialDetector.discover()
        lock.lock()
        credentials = found
        lock.unlock()
    }

    func snapshot() -> [DetectedOpencodeCredential] {
        lock.lock()
        defer { lock.unlock() }
        return credentials
    }
}
