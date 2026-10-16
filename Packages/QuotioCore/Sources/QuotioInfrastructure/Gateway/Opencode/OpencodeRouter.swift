//
//  OpencodeRouter.swift
//  Quotio
//
//  Account-aware upstream router for the `opencode/` branch — the sibling
//  of `QoderFailoverRouter`, simplified to a byte-faithful pass-through on
//  the same-surface arm. Where the Qoder router returns only confirmed-2xx
//  streams, this router returns whatever status upstream produced: 401 →
//  rotate to the next account, 429 → cooldown + rotate, transport failure →
//  next account, and every other HTTP status (2xx, 400, 403, 5xx) is handed
//  back verbatim for ProxyBridge to forward — rotating can't fix a
//  request-level rejection, and upstream's own error body is the most
//  client-faithful answer.
//
//  Surface dispatch (ADR 0021): each request targets the model's NATIVE
//  upstream surface, resolved from the catalog's models.dev npm mapping.
//  Same-surface requests pass through byte-faithful; a Responses-speaking
//  client on a chat-native model gets its body translated via
//  `OpencodeProtocolMapper` and its stream translated back in ProxyBridge
//  (reusing the Qoder responses adapter); a Chat client on a
//  responses-native model gets the mirror translation
//  (`chatRequestToResponses` + `OpencodeChatSSEAdapter`, Phase 2b). The
//  non-OpenAI native surfaces are refused with 422 `unsupported_surface`
//  before any account work — they cannot be served yet.
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
import QuotioApplication
import QuotioDomain

/// Errors surfaced to ProxyBridge, mapped to HTTP before any stream byte is
/// written. Tokens and upstream bodies are never embedded.
public nonisolated enum OpencodeRouterError: Error, LocalizedError, Equatable {
    case noAccountsAvailable
    case allAccountsCoolingDown(retryAfter: TimeInterval)
    /// Defensive: `processRequest` normally 503s on an empty catalog before
    /// reaching the router.
    case catalogUnavailable
    /// The model's native surface can't be served on the requested client
    /// surface (ADR 0021) — a `messages`/`gemini`/`mistral`-native model
    /// (no client-facing surface). Defensive for `.responses`: Phase 2b
    /// translates that pairing, so dispatch no longer produces it.
    case unsupportedSurface(model: String, surface: OpencodeSurface)
    /// The request itself can't be translated (e.g. Responses server-side
    /// conversation state) — 400, the client must resend differently.
    case unsupportedRequest(String)
    /// Transport-level failure summary; status + short detail, never tokens.
    case upstream(Int, String)

    public var httpStatus: Int {
        switch self {
        case .noAccountsAvailable, .catalogUnavailable: return 503
        case .allAccountsCoolingDown: return 429
        case .unsupportedSurface: return 422
        case .unsupportedRequest: return 400
        case .upstream(let status, _): return status > 0 ? status : 503
        }
    }

    public var retryAfterSeconds: Int? {
        switch self {
        case .allAccountsCoolingDown(let seconds): return max(1, Int(ceil(seconds)))
        default: return nil
        }
    }

    public var errorDescription: String? {
        switch self {
        case .noAccountsAvailable:
            return "No opencode accounts available: sign in via Quotio or opencode."
        case .allAccountsCoolingDown(let seconds):
            return "All opencode accounts are rate-limited; retry after \(Int(ceil(seconds)))s."
        case .catalogUnavailable:
            return "opencode free-model catalog unavailable."
        case .unsupportedSurface(let model, let surface):
            let required: String
            switch surface {
            case .responses: required = "/v1/responses"
            case .messages: required = "/v1/messages (not served)"
            case .gemini, .mistral: required = "a non-OpenAI surface (not served)"
            case .chat: required = "/v1/chat/completions"
            }
            return "Model '\(model)' requires the \(required) surface, which this request cannot use."
        case .unsupportedRequest(let detail):
            return detail
        case .upstream(let status, let detail):
            return "opencode upstream error (\(status)): \(detail)"
        }
    }
}

/// How `open` decided to serve a request (ADR 0021). ProxyBridge reads the
/// plan off the opened stream to pick its relay mode without re-deriving it.
public nonisolated enum OpencodeDispatchPlan: Equatable, Sendable {
    /// Client surface == native surface — upstream bytes relay verbatim
    /// (streaming) or fold into the client's own surface (non-streaming).
    case passthrough(native: OpencodeSurface)
    /// Client speaks Responses, model is chat-native: request translated by
    /// `OpencodeProtocolMapper`, upstream is Chat Completions, the stream is
    /// translated back to Responses events in ProxyBridge.
    case responsesToChat
    /// Client speaks Chat, model is responses-native (Phase 2b): request
    /// translated by `OpencodeProtocolMapper.chatRequestToResponses`,
    /// upstream is Responses, the stream is translated back to
    /// chat.completion.chunk frames via `OpencodeChatSSEAdapter`.
    case chatToResponses
}

/// Per-chunk callback handed to a stream `pump` — same contract as
/// `QoderChunkReceiver`.
public typealias OpencodeChunkReceiver = @Sendable (Data) async throws -> Bool

/// The stream the router hands back. Unlike `QoderOpenedStream`, the
/// response is NOT 2xx-by-construction: `status` and `headers` carry the
/// verbatim upstream response for ProxyBridge to forward. `plan` tells the
/// bridge which relay mode serves the request (ADR 0021).
public nonisolated struct OpencodeOpenedStream: Sendable {
    public let status: Int
    public let headers: [(String, String)]
    public let plan: OpencodeDispatchPlan
    /// Bytes the router already consumed before handing off — currently
    /// always empty (no pre-handoff peek; kept for parity with the Qoder
    /// shape in case a peek is ever needed).
    public let bufferedPrefix: Data
    public let pump: @Sendable (OpencodeChunkReceiver) async throws -> Void
    /// Tear down the upstream task when the consumer aborts BEFORE pumping
    /// (e.g. the agent socket rejects the response head). `pump`'s defer
    /// cancels on every exit once running; this covers never-pumped streams.
    public let cancel: @Sendable () -> Void
}

public actor OpencodeRouter {

    /// Stale-account lifecycle notifications. `userInfo` carries
    /// `["accountKey", "displayName"]` — never tokens.
    public static let opencodeAccountStale = Notification.Name("dev.quotio.opencode.account-stale")
    public static let opencodeAccountRecovered = Notification.Name("dev.quotio.opencode.account-recovered")
    /// 429 → cooldown notification. `userInfo` adds `"retryAfter"`
    /// (seconds until the account leaves cooldown); the Quota tab renders
    /// the account as rate-limited while that window is still open.
    public static let opencodeAccountRateLimited = Notification.Name("dev.quotio.opencode.account-rate-limited")

    /// Released-client User-Agent pinned from the Task 0 spike: observed on
    /// the local opencode 1.18.30 (Homebrew) install; the upstream free-tier
    /// gate 403s versions it doesn't recognize (`opencode/1.19.0` failed).
    public static let clientUserAgent = OpencodeUpstreamClient.clientUserAgent

    /// In-memory cooldown for a rate-limited (429) account.
    private static let cooldownTTL: TimeInterval = 60
    /// Refresh window: credentials expiring within this margin are renewed
    /// proactively rather than burning a 401 round-trip.
    private static let expiryMargin: TimeInterval = 60

    private let catalog: OpencodeModelCatalog
    private let console: OpencodeConsoleClient
    private let upstream: any OpencodeUpstreamClientProtocol
    private let vault: any GatewayCredentialStoring
    private let metadata: GatewayAccountStoring
    /// Current detected-credential set, refreshed by the caller's periodic
    /// tick (Task 8) — NOT re-discovered per request.
    private let detectedSnapshot: @Sendable () -> [DetectedOpencodeCredential]

    /// Cooldown end per account key; entries in the future mean "skip".
    private var cooldowns: [String: Date] = [:]
    /// Stale-marked account keys → displayName. Marking suppresses repeat
    /// notifications; the account is still re-checked every request (a re-
    /// authed store entry or re-login can recover it).
    private var staleAccounts: [String: String] = [:]

    public init(
        catalog: OpencodeModelCatalog,
        console: OpencodeConsoleClient,
        upstream: any OpencodeUpstreamClientProtocol = OpencodeUpstreamClient(),
        vault: any GatewayCredentialStoring,
        metadata: any GatewayAccountStoring,
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
            case vault(account: GatewayAccount, credential: GatewayCredential)
            case detected(DetectedOpencodeCredential)
        }
        let key: String
        let displayName: String
        let source: Source
    }

    /// Open an upstream stream for a gated request, rotating across
    /// accounts per the policy in the header comment. Surface dispatch
    /// (ADR 0021) happens before any account work: the model's native
    /// surface decides the upstream URL and, when it differs from the
    /// client's surface, the request body is translated first.
    public func open(requestBody: Data, route: OpencodeRoute) async throws -> OpencodeOpenedStream {
        if catalog.isEmpty { throw OpencodeRouterError.catalogUnavailable }

        let strippedModel = Self.strippedModel(in: requestBody)
        let nativeSurface = catalog.surface(for: strippedModel)
        let clientStreams = Self.streamRequested(in: requestBody)

        let plan: OpencodeDispatchPlan
        let bodyForShaping: Data
        switch (route, nativeSurface) {
        case (.chat, .chat), (.responses, .responses):
            plan = .passthrough(native: nativeSurface)
            bodyForShaping = requestBody
        case (.responses, .chat):
            plan = .responsesToChat
            do {
                bodyForShaping = try OpencodeProtocolMapper.responsesRequestToChat(requestBody)
            } catch {
                // Both mapper errors (stateful conversation) and the reused
                // translator's malformed-request diagnostics are the
                // client's to fix — 400, not an upstream-flavored 502.
                throw OpencodeRouterError.unsupportedRequest(
                    (error as? OpencodeMapperError)?.errorDescription
                        ?? "request could not be translated to the chat completions surface.")
            }
        case (.chat, .responses):
            // Phase 2b: translate the chat body to the responses surface.
            plan = .chatToResponses
            do {
                bodyForShaping = try OpencodeProtocolMapper.chatRequestToResponses(requestBody)
            } catch {
                // The mapper's malformed-request diagnostics are the
                // client's to fix — 400, not an upstream-flavored 502.
                throw OpencodeRouterError.unsupportedRequest(
                    (error as? OpencodeMapperError)?.errorDescription
                        ?? "request could not be translated to the responses surface.")
            }
        default:
            // messages/gemini/mistral-native — no client-facing surface.
            throw OpencodeRouterError.unsupportedSurface(model: strippedModel, surface: nativeSurface)
        }

        // Usage the upstream must emit: a Responses client always expects it
        // on response.completed, and aggregation needs it for stream:false —
        // the chat surface only streams usage when asked (issue #19 rule).
        let upstreamBody = Self.shapeUpstreamBody(
            from: bodyForShaping,
            target: nativeSurface,
            includeUsage: route == .responses || !clientStreams)

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
            let url = Self.inferenceURL(surface: nativeSurface, server: credential.server)
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
                            return openedStream(retry, plan: plan)
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
                return openedStream(stream, plan: plan)
            }
        }
        throw exhaustionError()
    }

    /// Proactively renew vault credentials inside the expiry margin (Task 8
    /// periodic tick). Reuses the request-time freshness path so the same
    /// refresh/persist/stale-marking semantics apply — a request arriving
    /// after the tick then finds ready tokens instead of paying the refresh
    /// latency mid-request.
    public func refreshExpiringVaultCredentials() async {
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
            // same priority ordering as GatewayAccountDiscovery.selectPreferred.
            guard !vaultKeys.contains(detected.accountKey.lowercased()),
                  !cooldowns.keys.contains(detected.accountKey) else { continue }
            // The user's disabled set applies to detected accounts too —
            // the monitor materializes them with the same id formula
            // (GatewayAccountDiscovery.discoverOpencodeCredentials).
            let detectedAccountID = GatewayAccount.make(
                provider: .opencode, accountKey: detected.accountKey,
                source: .detected).id
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
                try? await vault.store(credential, account: account)
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

    private func openedStream(
        _ stream: OpencodeUpstreamStream, plan: OpencodeDispatchPlan
    ) -> OpencodeOpenedStream {
        let streamRef = stream
        return OpencodeOpenedStream(
            status: stream.status,
            headers: stream.headers,
            plan: plan,
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

    /// `<origin of credential.server>/inference` + the model's NATIVE
    /// surface path (ADR 0021 — the client's requested surface decides the
    /// wire protocol we speak to the agent, not the upstream URL).
    /// `messages` is the Phase 5 seam (unreachable today: dispatch 422s
    /// messages-native models first); gemini/mistral share the chat path.
    public nonisolated static func inferenceURL(surface: OpencodeSurface, server: String) -> URL {
        let origin: String
        if let components = URLComponents(string: server), let scheme = components.scheme {
            var rebuilt = "\(scheme)://\(components.host ?? "opencode.ai")"
            if let port = components.port { rebuilt += ":\(port)" }
            origin = rebuilt
        } else {
            origin = "https://opencode.ai"
        }
        let path: String
        switch surface {
        case .responses: path = "/v1/responses"
        case .messages: path = "/v1/messages"
        case .chat, .gemini, .mistral: path = "/v1/chat/completions"
        }
        return URL(string: origin + "/inference" + path)!
    }

    /// Header set proven by the Task 0 spike: the released client's UA and
    /// x-opencode-* metadata. `x-org-id` only when the credential carries one.
    public nonisolated static func upstreamHeaders(token: String, orgID: String?) -> [(String, String)] {
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

    /// The request's `model` with the `opencode/` routing prefix stripped —
    /// the id the catalog knows. Empty when unparseable (the route gate has
    /// already required a parseable model by this point).
    public nonisolated static func strippedModel(in body: Data) -> String {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let model = json["model"] as? String else { return "" }
        return model.hasPrefix(OpencodeRouteGate.opencodePrefix)
            ? String(model.dropFirst(OpencodeRouteGate.opencodePrefix.count)) : model
    }

    /// Whether the CLIENT asked to stream (`stream == true`; OpenAI's spec
    /// default is false). The upstream is always streamed — the free-tier
    /// gate 403s `stream:false` — so this only decides how ProxyBridge
    /// serves the agent: relay SSE verbatim or aggregate into one body.
    public nonisolated static func streamRequested(in body: Data) -> Bool {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let stream = json["stream"] as? Bool else { return false }
        return stream
    }

    /// Real opencode parameter schemas for the six tool names the free-tier
    /// gate inspects — hand-derived from `sst/opencode` tag `v1.18.30`
    /// (`packages/opencode/src/tool/{read,shell,write,edit,glob,grep}.ts`;
    /// the shell tool's exposed ID stays "bash" until 2.0). The gate 403s
    /// gated-named tools whose `parameters.properties` is missing/empty;
    /// degenerate client definitions are substituted with these so the body
    /// matches a real client's. Rebuilt per call — `[String: Any]` isn't
    /// Sendable. Bump together with `clientUserAgent`.
    private nonisolated static func gatedToolSchema(name: String) -> [String: Any]? {
        switch name {
        case "read":
            return [
                "type": "object",
                "properties": [
                    "filePath": [
                        "type": "string",
                        "description": "The absolute path to the file or directory to read",
                    ],
                    "offset": [
                        "type": "integer",
                        "description": "The line number to start reading from (1-indexed)",
                    ],
                    "limit": [
                        "type": "integer",
                        "description": "The maximum number of lines to read (defaults to 2000)",
                    ],
                ],
                "required": ["filePath"],
            ]
        case "bash":
            return [
                "type": "object",
                "properties": [
                    "command": ["type": "string", "description": "The command to execute"],
                    "timeout": ["type": "integer", "description": "Optional timeout in milliseconds"],
                    "workdir": [
                        "type": "string",
                        "description": "The working directory to run the command in. "
                            + "Defaults to the current directory. Use this instead of 'cd' commands.",
                    ],
                ],
                "required": ["command"],
            ]
        case "write":
            return [
                "type": "object",
                "properties": [
                    "content": ["type": "string", "description": "The content to write to the file"],
                    "filePath": [
                        "type": "string",
                        "description": "The absolute path to the file to write to "
                            + "(must be absolute, not relative)",
                    ],
                ],
                "required": ["content", "filePath"],
            ]
        case "edit":
            return [
                "type": "object",
                "properties": [
                    "filePath": [
                        "type": "string",
                        "description": "The absolute path to the file to modify",
                    ],
                    "oldString": ["type": "string", "description": "The text to replace"],
                    "newString": [
                        "type": "string",
                        "description": "The text to replace it with (must be different from oldString)",
                    ],
                    "replaceAll": [
                        "type": "boolean",
                        "description": "Replace all occurrences of oldString (default false)",
                    ],
                ],
                "required": ["filePath", "oldString", "newString"],
            ]
        case "glob":
            return [
                "type": "object",
                "properties": [
                    "pattern": [
                        "type": "string",
                        "description": "The glob pattern to match files against",
                    ],
                    "path": [
                        "type": "string",
                        "description": "The directory to search in. If not specified, "
                            + "the current working directory will be used.",
                    ],
                ],
                "required": ["pattern"],
            ]
        case "grep":
            return [
                "type": "object",
                "properties": [
                    "pattern": [
                        "type": "string",
                        "description": "The regex pattern to search for in file contents",
                    ],
                    "path": [
                        "type": "string",
                        "description": "The directory to search in. Defaults to the current "
                            + "working directory.",
                    ],
                    "include": [
                        "type": "string",
                        "description": "File pattern to include in the search "
                            + "(e.g. \"*.js\", \"*.{ts,tsx}\")",
                    ],
                ],
                "required": ["pattern"],
            ]
        default:
            return nil
        }
    }

    /// Injected `read` tool in the TARGET surface's shape — verified live
    /// (fix pass): the free-tier gate 403s bodies without a `read` tool and
    /// 400s the wrong tool envelope for the surface (chat nests under
    /// `function`, responses is flat). Rebuilt per call (Sendable, same as
    /// the schemas).
    private nonisolated static func readToolDefinition(target: OpencodeSurface) -> [String: Any] {
        let parameters = gatedToolSchema(name: "read")!
        let description = "Read a file or directory from the local filesystem."
        switch target {
        case .responses:
            return [
                "type": "function",
                "name": "read",
                "description": description,
                "parameters": parameters,
            ]
        case .chat, .messages, .gemini, .mistral:
            return [
                "type": "function",
                "function": [
                    "name": "read",
                    "description": description,
                    "parameters": parameters,
                ],
            ]
        }
    }

    /// Shape the (possibly translated) body into what a real opencode client
    /// sends on the TARGET surface: strip the `opencode/` routing prefix
    /// from `model`, force `stream: true` (the gate 403s `stream:false`),
    /// optionally request upstream usage (a Responses client always expects
    /// it and aggregation needs it — the chat surface only emits usage when
    /// asked), normalize gated-named tools whose schema is degenerate, and
    /// ensure a `read` tool is present in the surface's shape. Falls back
    /// to the given body on any parse failure (the route gate already
    /// required a parseable model).
    private nonisolated static func shapeUpstreamBody(
        from body: Data, target: OpencodeSurface, includeUsage: Bool
    ) -> Data {
        guard var json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return body
        }
        if let model = json["model"] as? String,
           model.hasPrefix(OpencodeRouteGate.opencodePrefix) {
            json["model"] = String(model.dropFirst(OpencodeRouteGate.opencodePrefix.count))
        }
        json["stream"] = true
        if includeUsage, target == .chat {
            var options = (json["stream_options"] as? [String: Any]) ?? [:]
            options["include_usage"] = true
            json["stream_options"] = options
        }
        // Upstream conformance: the zen/responses surface enforces
        // `max_output_tokens >= 16` (verified live — a 1-token connectivity
        // probe 400'd with "The number must be `>= 16`"; ZCode's probe sends
        // exactly that). Raise sub-minimum caps, never lower; chat-native
        // upstreams accept 1, so no floor there.
        if target == .responses, let cap = json["max_output_tokens"] as? Int, cap < 16 {
            json["max_output_tokens"] = 16
        }
        // Same conformance class: always-reasoning zen models reject
        // `reasoning.effort "none"` (supported: minimal…max, verified live
        // on muse-spark). Clamp `none` to `minimal` — the closest
        // representable intent to "disabled". Only the responses target;
        // the chat surface accepts `none`.
        if target == .responses,
           let reasoning = json["reasoning"] as? [String: Any],
           (reasoning["effort"] as? String) == "none" {
            var clamped = reasoning
            clamped["effort"] = "minimal"
            json["reasoning"] = clamped
        }
        var tools = (json["tools"] as? [Any]) ?? []
        normalizeGatedToolSchemas(&tools)
        let hasRead = tools.contains { entry in
            guard let tool = entry as? [String: Any] else { return false }
            return (tool["name"] as? String) == "read"
                || ((tool["function"] as? [String: Any])?["name"] as? String) == "read"
        }
        if !hasRead { tools.append(readToolDefinition(target: target)) }
        json["tools"] = tools
        return (try? JSONSerialization.data(withJSONObject: json)) ?? body
    }

    /// Free-tier gate conformance (ADR 0021 plan, Phase 3): a tool whose
    /// resolved name is one of the six gated names and whose parameters are
    /// missing or empty gets the real opencode schema substituted — the
    /// gate 403s such definitions from non-opencode clients. Client tools
    /// with real schemas (and unknown names) pass untouched. Both wire
    /// shapes are handled: chat (`function` nesting) and responses (flat).
    private nonisolated static func normalizeGatedToolSchemas(_ tools: inout [Any]) {
        for index in tools.indices {
            guard var tool = tools[index] as? [String: Any] else { continue }
            if var function = tool["function"] as? [String: Any],
               let name = function["name"] as? String,
               let schema = gatedToolSchema(name: name),
               schemaIsDegenerate(function["parameters"]) {
                function["parameters"] = schema
                tool["function"] = function
                tools[index] = tool
            } else if let name = tool["name"] as? String,
                      let schema = gatedToolSchema(name: name),
                      schemaIsDegenerate(tool["parameters"]) {
                tool["parameters"] = schema
                tools[index] = tool
            }
        }
    }

    /// Missing parameters or an empty `properties` map — what the gate 403s.
    private nonisolated static func schemaIsDegenerate(_ raw: Any?) -> Bool {
        guard let parameters = raw as? [String: Any] else { return true }
        return (parameters["properties"] as? [String: Any] ?? [:]).isEmpty
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

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
