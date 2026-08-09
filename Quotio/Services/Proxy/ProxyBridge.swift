//
//  ProxyBridge.swift
//  Quotio - TCP Proxy Bridge for Connection Management
//
//  This proxy sits between CLI tools and CLIProxyAPI to solve the stale
//  connection issue. By forcing "Connection: close" on every request,
//  we prevent HTTP keep-alive connections from becoming stale after idle periods.
//
//  Additionally handles Model Fallback: when a virtual model is detected,
//  resolves it to real models and automatically retries on quota exhaustion.
//
//  Architecture:
//    CLI Tools → ProxyBridge (user port) → CLIProxyAPI (internal port)
//

import Foundation
import Network

// MARK: - Fallback Context

/// Context for tracking fallback state during request processing
struct FallbackContext: Sendable {
    let virtualModelName: String?
    let fallbackEntries: [FallbackEntry]
    let currentIndex: Int
    /// Original request body, as parsed bytes (issue #15: no String
    /// round-trip on the receive hot path; the body reaches us as `Data`
    /// from `HTTP1RequestParser` and stays `Data` through the fallback
    /// retry path).
    let originalBody: Data
    let wasLoadedFromCache: Bool
    let attempts: [FallbackAttempt]
    let triedSanitization: Bool

    /// Whether this request has fallback enabled
    nonisolated var hasFallback: Bool { !fallbackEntries.isEmpty }

    /// Whether there are more fallbacks to try
    nonisolated var hasMoreFallbacks: Bool { currentIndex + 1 < fallbackEntries.count }

    /// Get next fallback context
    nonisolated func next() -> FallbackContext {
        FallbackContext(
            virtualModelName: virtualModelName,
            fallbackEntries: fallbackEntries,
            currentIndex: currentIndex + 1,
            originalBody: originalBody,
            wasLoadedFromCache: false,
            attempts: attempts,
            triedSanitization: false
        )
    }

    /// Append a new attempt entry
    nonisolated func appendingAttempt(_ attempt: FallbackAttempt) -> FallbackContext {
        FallbackContext(
            virtualModelName: virtualModelName,
            fallbackEntries: fallbackEntries,
            currentIndex: currentIndex,
            originalBody: originalBody,
            wasLoadedFromCache: wasLoadedFromCache,
            attempts: attempts + [attempt],
            triedSanitization: triedSanitization
        )
    }

    /// Mark that sanitization has been attempted for this context
    nonisolated func withSanitizationAttempted() -> FallbackContext {
        FallbackContext(
            virtualModelName: virtualModelName,
            fallbackEntries: fallbackEntries,
            currentIndex: currentIndex,
            originalBody: originalBody,
            wasLoadedFromCache: wasLoadedFromCache,
            attempts: attempts,
            triedSanitization: true
        )
    }

    /// Current fallback entry
    nonisolated var currentEntry: FallbackEntry? {
        guard currentIndex < fallbackEntries.count else { return nil }
        return fallbackEntries[currentIndex]
    }

    /// Empty context for non-fallback requests
    nonisolated static let empty = FallbackContext(
        virtualModelName: nil,
        fallbackEntries: [],
        currentIndex: 0,
        originalBody: Data(),
        wasLoadedFromCache: false,
        attempts: [],
        triedSanitization: false
    )
}

/// A lightweight TCP proxy that forwards requests to CLIProxyAPI while
/// ensuring fresh connections by forcing "Connection: close" on all requests.
@MainActor
@Observable
final class ProxyBridge {
    
    // MARK: - Properties
    
    private var listener: NWListener?
    private let stateQueue = DispatchQueue(label: "dev.quotio.desktop.proxy-bridge-state")
    
    /// The port this proxy listens on (user-facing port)
    private(set) var listenPort: UInt16 = 8080
    
    /// The port CLIProxyAPI runs on (internal port)
    private(set) var targetPort: UInt16 = 18080
    
    /// Target host (always localhost)
    private let targetHost = "127.0.0.1"
    
    /// Whether the proxy bridge is currently running
    private(set) var isRunning = false
    
    /// Last error message
    private(set) var lastError: String?
    
    /// Statistics: total requests forwarded
    private(set) var totalRequests: Int = 0
    
    /// Statistics: active connections count
    private(set) var activeConnections: Int = 0

    /// ADR 0012: pump Task handles for in-flight Qoder streams, keyed by the
    /// agent connection's `connectionId`. Stored on the MainActor so the agent
    /// connection's `stateUpdateHandler` can cancel the pump promptly on
    /// `.cancelled` / `.failed` (agent disconnect) without waiting for the next
    /// `sendToAgent` to fail on a slow upstream. Insertion happens immediately
    /// after `Task { ... }` creation in `forwardQoderRequest`, before its
    /// `for await` begins; removal happens on every exit path (success, error,
    /// cancellation) via the task body's MainActor-hopped cleanup. A missing
    /// entry is a no-op for cancel (e.g. Qoder disabled, or the request was
    /// pre-stream rejected before any pump Task was created).
    private(set) var pumpTasks: [Int: Task<Void, Never>] = [:]
    
    /// Maximum concurrent connections to prevent resource exhaustion
    private let maxActiveConnections = 100
    
    /// Connection timeout in seconds (for target connection setup)
    private let connectionTimeoutSeconds: UInt64 = 10
    
    /// Callback for request metadata extraction (for RequestTracker)
    var onRequestCompleted: ((RequestMetadata) -> Void)?

    /// Qoder failover router (ADR 0001, ADR 0005 §3). When non-nil, requests
    /// whose body `model:` starts with `qoder/` are routed here instead of the
    /// CPA forwarding path. Set by `QuotaViewModel` at proxy start; nil in
    /// tests and when the Qoder branch is not configured. The CPA forwarding
    /// path (`forwardRequest`) is untouched regardless of this property.
    var qoderRouter: QoderFailoverRouter?

    // MARK: - Request Metadata

    /// Metadata extracted from proxied requests
    struct RequestMetadata: Sendable {
        let timestamp: Date
        let method: String
        let path: String
        let provider: String?
        let model: String?
        let resolvedModel: String?  // Actual model used after fallback resolution
        let resolvedProvider: String?  // Actual provider used after fallback resolution
        let statusCode: Int?
        let durationMs: Int
        let requestSize: Int
        let responseSize: Int
        let fallbackAttempts: [FallbackAttempt]
        let fallbackStartedFromCache: Bool
        let responseSnippet: String?
        // Token usage fields (ADR 0005 §2). Populated by the Qoder branch from
        // the SSE final chunk's `usage` block; nil on the CPA path (CPA's own
        // /usage endpoint is the source of truth for non-Qoder traffic, so
        // leaving these nil avoids double-counting). OpenAI semantics: the
        // Qoder `usage.prompt_tokens` already includes cached tokens — pass
        // through unchanged (do NOT replicate pi's subtraction).
        let inputTokens: Int?
        let outputTokens: Int?
        let cacheReadTokens: Int?
        let cacheWriteTokens: Int?
        let reasoningTokens: Int?

        /// Convenience initializer for CPA-path callers that don't have token
        /// data — keeps the existing call site in `recordCompletion` compiling
        /// unchanged (all token fields default to nil).
        init(
            timestamp: Date,
            method: String,
            path: String,
            provider: String?,
            model: String?,
            resolvedModel: String?,
            resolvedProvider: String?,
            statusCode: Int?,
            durationMs: Int,
            requestSize: Int,
            responseSize: Int,
            fallbackAttempts: [FallbackAttempt],
            fallbackStartedFromCache: Bool,
            responseSnippet: String?,
            inputTokens: Int? = nil,
            outputTokens: Int? = nil,
            cacheReadTokens: Int? = nil,
            cacheWriteTokens: Int? = nil,
            reasoningTokens: Int? = nil
        ) {
            self.timestamp = timestamp
            self.method = method
            self.path = path
            self.provider = provider
            self.model = model
            self.resolvedModel = resolvedModel
            self.resolvedProvider = resolvedProvider
            self.statusCode = statusCode
            self.durationMs = durationMs
            self.requestSize = requestSize
            self.responseSize = responseSize
            self.fallbackAttempts = fallbackAttempts
            self.fallbackStartedFromCache = fallbackStartedFromCache
            self.responseSnippet = responseSnippet
            self.inputTokens = inputTokens
            self.outputTokens = outputTokens
            self.cacheReadTokens = cacheReadTokens
            self.cacheWriteTokens = cacheWriteTokens
            self.reasoningTokens = reasoningTokens
        }
    }
    
    // MARK: - Initialization
    
    init() {}
    
    // MARK: - Configuration
    
    /// Configure the proxy ports
    /// - Parameters:
    ///   - listenPort: The port to listen on (user-facing)
    ///   - targetPort: The port CLIProxyAPI runs on
    func configure(listenPort: UInt16, targetPort: UInt16) {
        self.listenPort = listenPort
        self.targetPort = targetPort
    }
    
    /// Calculate internal port from user port (offset by 10000)
    /// This is nonisolated so it can be called from static contexts
    nonisolated static func internalPort(from userPort: UInt16) -> UInt16 {
        // Use offset of 10000, but cap at valid port range
        // For high ports (55536+), use a smaller offset to stay within valid range
        let preferredPort = UInt32(userPort) + 10000
        if preferredPort <= 65535 {
            return UInt16(preferredPort)
        }
        // Fallback: use modular offset within high port range (49152-65535)
        let highPortBase: UInt16 = 49152
        let offset = userPort % 1000
        return highPortBase + offset
    }
    
    // MARK: - Lifecycle
    
    /// Starts the proxy bridge
    func start() {
        guard !isRunning else {
            return
        }

        lastError = nil

        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true

            guard let port = NWEndpoint.Port(rawValue: listenPort) else {
                lastError = "Invalid port: \(listenPort)"
                return
            }

            listener = try NWListener(using: parameters, on: port)

            listener?.stateUpdateHandler = { [weak self] state in
                guard let weakSelf = self else { return }
                Task { @MainActor in
                    weakSelf.handleListenerState(state)
                }
            }

            listener?.newConnectionHandler = { [weak self] connection in
                guard let weakSelf = self else { return }
                Task { @MainActor in
                    weakSelf.handleNewConnection(connection)
                }
            }

            listener?.start(queue: .global(qos: .userInitiated))

        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Stops the proxy bridge
    func stop() {
        stateQueue.sync {
            listener?.cancel()
            listener = nil
        }

        isRunning = false
    }
    
    // MARK: - State Handling

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            isRunning = true
        case .failed(let error):
            isRunning = false
            lastError = error.localizedDescription
        case .cancelled:
            isRunning = false
        default:
            break
        }
    }

    // MARK: - Connection Handling

    private func handleNewConnection(_ connection: NWConnection) {
        if activeConnections >= maxActiveConnections {
            connection.cancel()
            return
        }

        activeConnections += 1
        totalRequests += 1

        let connectionId = totalRequests
        let startTime = Date()

        connection.stateUpdateHandler = { [weak self] state in
            guard let weakSelf = self else { return }
            if case .cancelled = state {
                Task { @MainActor in
                    weakSelf.activeConnections -= 1
                    // ADR 0012: agent socket went away — cancel the in-flight
                    // Qoder pump so the upstream URLSession tears down promptly
                    // instead of draining until the next sendToAgent happens to
                    // fail. NWConnection allows only one stateUpdateHandler, so
                    // the disconnect-driven cancel is folded in here alongside
                    // the active-connections accounting.
                    weakSelf.cancelPumpTask(for: connectionId)
                }
            } else if case .failed = state {
                Task { @MainActor in
                    weakSelf.activeConnections -= 1
                    weakSelf.cancelPumpTask(for: connectionId)
                }
            }
        }
        
        connection.start(queue: .global(qos: .userInitiated))
        
        // Start receiving request. The parser is owned per-connection (a fresh
        // value type per request — ProxyBridge forces Connection: close on the
        // upstream so it processes exactly one request per agent connection).
        receiveRequest(
            from: connection,
            connectionId: connectionId,
            startTime: startTime,
            parser: HTTP1RequestParser()
        )
    }
    
    // MARK: - Request Receiving (Iterative)

    /// Receives HTTP request data iteratively to avoid stack overflow.
    ///
    /// Drives `HTTP1RequestParser` (issue #15, ADR 0015) — bytes are fed to
    /// the byte-wise parser on every NWConnection receive callback. The
    /// parser returns one of:
    ///   - `.needsMoreData` → keep reading (recurse via async dispatch to
    ///     avoid stack growth).
    ///   - `.complete(HTTP1Request)` → call `processRequest` with the parsed
    ///     request. The body arrives as `Data` — no whole-request String
    ///     conversion on this hot path. A small String decode of just the
    ///     header section happens inside the parser, bounded by
    ///     `maxHeaderBytes` (ADR 0013 Tier 1 cap).
    ///   - `.error(...)` → surface as the corresponding HTTP error via
    ///     `sendError`. Header/body cap violations → 413 (ADR 0013); other
    ///     parse errors → 400. Routed through the ADR 0010 envelope.
    private nonisolated func receiveRequest(
        from connection: NWConnection,
        connectionId: Int,
        startTime: Date,
        parser: HTTP1RequestParser
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1048576) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }

            if error != nil {
                connection.cancel()
                return
            }

            guard let data = data, !data.isEmpty else {
                if isComplete {
                    connection.cancel()
                }
                return
            }

            // Feed the byte-wise parser. `parser` is a value type — copy it
            // locally, mutate, then pass the updated copy into the next
            // receive iteration (or use it to drive processRequest).
            var localParser = parser
            let progress = localParser.feed(data)

            switch progress {
            case .needsMoreData:
                if isComplete {
                    // Socket closed mid-request: terminate rather than wait.
                    connection.cancel()
                    return
                }
                // Async dispatch to break recursion stack (preserved from the
                // prior implementation). Bind the parser value to a `let`
                // before capture — it's a value type, so each iteration owns
                // its own copy (no shared mutable state across the dispatch).
                let nextParser = localParser
                DispatchQueue.global(qos: .userInitiated).async {
                    self.receiveRequest(
                        from: connection,
                        connectionId: connectionId,
                        startTime: startTime,
                        parser: nextParser
                    )
                }

            case .complete(let request):
                self.processRequest(
                    request: request,
                    connection: connection,
                    connectionId: connectionId,
                    startTime: startTime
                )

            case .error(let parseError):
                // ADR 0013 Tier 1 cap violations → 413; everything else → 400.
                // Both routed through the ADR 0010 JSON envelope by sendError.
                let statusCode: Int
                switch parseError {
                case .headerTooLarge, .bodyTooLarge:
                    statusCode = 413
                default:
                    statusCode = 400
                }
                self.sendError(to: connection, statusCode: statusCode, message: parseError.localizedDescription)
            }
        }
    }

    // MARK: - Request Processing

    /// Process a parsed HTTP/1.1 request (issue #15, ADR 0015). The body
    /// arrives here as `Data` from `HTTP1RequestParser` — no whole-request
    /// String conversion on the receive hot path. The Qoder branch consumes
    /// the body bytes directly; the CPA branch decodes the body to String
    /// once at forwarding time (single decode, cold path — not on every
    /// receive callback as the prior parser did).
    private nonisolated func processRequest(
        request: HTTP1Request,
        connection: NWConnection,
        connectionId: Int,
        startTime: Date
    ) {
        let method = request.method
        let path = request.path
        let httpVersion = request.version
        // Map the parser's `[(name: String, value: String)]` onto the tuple
        // shape downstream code already uses. Preserve original casing and
        // arrival order (the parser does both).
        let headers: [(String, String)] = request.headers.map { ($0.name, $0.value) }
        let body = request.body

        // Request size for `RequestMetadata` accounting: wire-accurate count
        // of the consumed request bytes = header section (request line +
        // headers + `\r\n\r\n`) + body bytes. The parser surfaces the header
        // byte count directly (issue #15 W4) so we don't lose this metric vs.
        // the prior `data.count` (whole-request) implementation. For chunked
        // input, `body.count` is the *decoded* body size — the chunk framing
        // is not counted, matching the framing semantics a client sees.
        let requestSize = request.headerBytes + body.count

        let metadata = extractMetadata(method: method, path: path, body: body)

        // Qoder branch (ADR 0001, gated per ADR 0009 / issue #20): a request
        // whose body `model:` starts with `qoder/` is intercepted here and
        // routed direct to api3.qoder.sh, bypassing CPA entirely — but only
        // for an allowlisted (method, path) combination. A qoder/ model on a
        // non-allowlisted surface (e.g. /v1/completions, a GET) is `.rejected`
        // with a Qoder-owned 404 (QoderOpenAIError → model_not_found); it does
        // NOT fall through to CPA, which cannot correctly serve a qoder/ model
        // (ADR 0009). The branch is still gated on `qoderRouter` being wired
        // (QuotaViewModel sets it at proxy start); a qoder/ request with no
        // router falls through to CPA, which will 404 — preferable to silently
        // swallowing it (existing behavior preserved).
        //
        // `QoderRouteGate.resolve` (issue #20, ADR 0009) is the single source
        // of truth for the conjunctive allowlist (model prefix AND method AND
        // path). It strips the query string before path comparison, so a
        // `POST /v1/chat/completions?timeout=30` still matches. The router
        // read happens inside the MainActor Task below (alongside the rest of
        // the request setup) because `qoderRouter` is MainActor-isolated and
        // `processRequest` is `nonisolated`.
        let route = QoderRouteGate.resolve(method: method, path: path, model: metadata.model)

        // Check for virtual model and create fallback context
        Task { @MainActor [weak self] in
            guard let self = self else { return }

            // Qoder branch: route to the failover router and return — the CPA
            // path (fallback + forwardRequest) does not run for qoder/ models.
            // `.notQoder` (no qoder/ prefix) skips this branch entirely; the
            // `qoderRouter == nil` fall-through to CPA is preserved (see above).
            if route != .notQoder, let router = self.qoderRouter {
                // ADR 0009 / issue #20: qoder/ model on a non-allowlisted
                // method/path is rejected with a Qoder-owned 404. The error
                // flows through `QoderOpenAIError.body` (ADR 0010), which maps
                // 404 → type `invalid_request_error`, code `model_not_found`.
                guard route != .rejected else {
                    self.sendError(
                        to: connection,
                        statusCode: 404,
                        message: "Qoder models are only supported on POST /v1/chat/completions and POST /v1/responses."
                    )
                    return
                }

                // Issue #11: Responses API path (route == .responses).
                // Synthesize the Chat body here (pre-router) so the
                // router/translator/COSY path is byte-identical to Chat. Parse
                // errors become a 400 — the Responses body didn't carry
                // model/input/etc. Chat (route == .chat) requests keep their
                // body byte-identical (only the synthesized body + the flag
                // differ).
                //
                // Issue #15: the body reaches this branch as `Data` straight
                // from the parser — no `Data(body.utf8)` round-trip here, no
                // whole-request String conversion upstream. The synthesized
                // Chat body is also `Data`.
                let effectiveBody: Data
                let responsesMode: Bool
                if route == .responses {
                    do {
                        effectiveBody = try QoderResponsesTranslator.synthesizeChatBody(from: body)
                        responsesMode = true
                    } catch {
                        self.sendError(to: connection, statusCode: 400, message: error.localizedDescription)
                        return
                    }
                } else {
                    effectiveBody = body
                    responsesMode = false
                }
                self.forwardQoderRequest(
                    router: router,
                    method: method,
                    path: path,
                    headers: headers,
                    body: effectiveBody,
                    originalConnection: connection,
                    connectionId: connectionId,
                    startTime: startTime,
                    requestSize: requestSize,
                    requestModel: metadata.model ?? "",
                    responsesMode: responsesMode
                )
                return
            }

            let fallbackContext = self.createFallbackContext(body: body)
            let resolvedBody: Data

            if fallbackContext.hasFallback, let entry = fallbackContext.currentEntry {
                // Replace model in body with resolved model
                resolvedBody = self.replaceModelInBody(body, with: entry.modelId)
            } else {
                resolvedBody = body
            }

            let targetPortValue = self.targetPort
            let targetHostValue = self.targetHost

            self.forwardRequest(
                method: method,
                path: path,
                version: httpVersion,
                headers: headers,
                body: resolvedBody,
                originalConnection: connection,
                connectionId: connectionId,
                startTime: startTime,
                requestSize: requestSize,
                metadata: metadata,
                targetPort: targetPortValue,
                targetHost: targetHostValue,
                fallbackContext: fallbackContext
            )
        }
    }


    // MARK: - Fallback Support

    /// Create fallback context if the request uses a virtual model
    private func createFallbackContext(body: Data) -> FallbackContext {
        let settings = FallbackSettingsManager.shared

        // Check if fallback is enabled
        guard settings.isEnabled else {
            return .empty
        }

        // Extract model from body (JSON). Issue #15: body arrives as `Data`
        // from the parser; no `.data(using: .utf8)` round-trip.
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let model = json["model"] as? String else {
            return .empty
        }

        // Check if this is a virtual model
        guard settings.isVirtualModel(model) else {
            return .empty
        }

        guard let virtualModel = settings.findVirtualModel(name: model) else {
            return .empty
        }

        let entries = virtualModel.sortedEntries
        guard !entries.isEmpty else {
            return .empty
        }

        // Get cached entry ID and find its current index (handles reordering correctly)
        var startIndex = 0
        var wasLoadedFromCache = false
        if settings.isRouteCachingEnabled,
           let cachedEntryId = settings.getCachedEntryId(for: model) {
            if let cachedIndex = entries.firstIndex(where: { $0.id == cachedEntryId }) {
                startIndex = cachedIndex
                wasLoadedFromCache = true
            }
        }

        var attempts: [FallbackAttempt] = []
        if wasLoadedFromCache, startIndex < entries.count {
            let cachedEntry = entries[startIndex]
            attempts.append(FallbackAttempt(entry: cachedEntry, outcome: .skipped, reason: .cachedRoute))
        }

        return FallbackContext(
            virtualModelName: model,
            fallbackEntries: entries,
            currentIndex: startIndex,
            originalBody: body,
            wasLoadedFromCache: wasLoadedFromCache,
            attempts: attempts,
            triedSanitization: false
        )
    }

    // MARK: - Request Body Transformation

    private nonisolated func replaceModelInBody(
        _ body: Data,
        with newModel: String
    ) -> Data {
        // Issue #15: body is `Data` (from the parser). The JSON rewrite path
        // stays byte-oriented end to end; no String round-trip.
        guard var json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              json["model"] != nil else {
            return body
        }

        json["model"] = newModel

        guard let newData = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]) else {
            return body
        }

        return newData
    }

    private nonisolated func sanitizeThinkingBlocks(_ body: Data, targetModelId: String) -> Data {
        guard var json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              var messages = json["messages"] as? [[String: Any]] else {
            return body
        }

        var modified = false

        for i in messages.indices {
            guard let content = messages[i]["content"] as? [[String: Any]] else { continue }

            let filteredContent = content.filter { block in
                guard let blockType = block["type"] as? String else { return true }
                if blockType == "thinking" || blockType == "redacted_thinking" {
                    modified = true
                    return false
                }
                return true
            }

            if filteredContent.count != content.count {
                if filteredContent.isEmpty {
                    messages[i]["content"] = [["type": "text", "text": "[reasoning omitted]"]]
                } else {
                    messages[i]["content"] = filteredContent
                }
            }
        }

        guard modified else { return body }

        json["messages"] = messages
        json["model"] = targetModelId

        guard let newData = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]) else {
            return body
        }

        return newData
    }

    /// Check why a response should trigger fallback (if any)
    private nonisolated func fallbackReason(responseData: Data) -> FallbackTriggerReason? {
        return FallbackFormatConverter.fallbackReason(responseData: responseData)
    }

    private nonisolated func responseBodySnippet(from responseData: Data, limit: Int = 512) -> String? {
        guard let responseString = String(data: responseData.prefix(4096), encoding: .utf8) else {
            return nil
        }
        let parts = responseString.components(separatedBy: "\r\n\r\n")
        let body = parts.dropFirst().joined(separator: "\r\n\r\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else {
            return nil
        }
        return String(body.prefix(limit))
    }
    
    // MARK: - Metadata Extraction

    /// Extract the `model` field from a JSON request body, if any. Shared by
    /// `extractMetadata` (telemetry + routing) and — via its result — the
    /// Qoder route gate (issue #20, ADR 0009). Content-type-agnostic by
    /// construction: it takes only the body bytes and never reads headers, so
    /// the gate sees the same model regardless of the client's declared
    /// Content-Type. Pinned by `QoderRouteGateTests`
    /// `.testContentTypeIsImmaterialToGateInput`.
    nonisolated static func extractModel(from body: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            return nil
        }
        return json["model"] as? String
    }

    private nonisolated func extractMetadata(method: String, path: String, body: Data) -> (provider: String?, model: String?, method: String, path: String) {
        // Detect provider from path
        var provider: String?
        if path.contains("/anthropic/") || path.contains("/claude") {
            provider = "claude"
        } else if path.contains("/gemini/") || path.contains("/google/") {
            provider = "gemini"
        } else if path.contains("/openai/") || path.contains("/chat/completions") {
            provider = "openai"
        } else if path.contains("/copilot/") {
            provider = "copilot"
        } else if path.contains("codewhisperer") || path.contains("kiro") {
            provider = "kiro"
        }

        // Extract model from JSON body. Issue #15: body is `Data` (from the
        // parser); no `.data(using: .utf8)` round-trip.
        let model = Self.extractModel(from: body)
        if let modelValue = model {
            // Infer provider from model name if not already detected
            if provider == nil {
                if FallbackFormatConverter.isClaudeModel(modelValue) {
                    provider = "claude"
                } else if modelValue.hasPrefix("gemini") || modelValue.hasPrefix("models/gemini") {
                    provider = "gemini"
                } else if modelValue.hasPrefix("gpt") || modelValue.hasPrefix("o1") || modelValue.hasPrefix("o3") {
                    provider = "openai"
                } else if modelValue.contains("kiro") || modelValue.contains("codewhisperer") {
                    provider = "kiro"
                }
            }
        }

        return (provider, model, method, path)
    }
    
    // MARK: - Request Forwarding

    private nonisolated func forwardRequest(
        method: String,
        path: String,
        version: String,
        headers: [(String, String)],
        body: Data,
        originalConnection: NWConnection,
        connectionId: Int,
        startTime: Date,
        requestSize: Int,
        metadata: (provider: String?, model: String?, method: String, path: String),
        targetPort: UInt16,
        targetHost: String,
        fallbackContext: FallbackContext
    ) {
        // Create connection to CLIProxyAPI
        guard let port = NWEndpoint.Port(rawValue: targetPort) else {
            sendError(to: originalConnection, statusCode: 500, message: "Invalid target port")
            return
        }

        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(targetHost), port: port)

        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.enableKeepalive = true
        tcpOptions.keepaliveIdle = 30
        tcpOptions.keepaliveInterval = 5
        tcpOptions.keepaliveCount = 3
        let parameters = NWParameters(tls: nil, tcp: tcpOptions)

        let targetConnection = NWConnection(to: endpoint, using: parameters)

        let timeoutSeconds = self.connectionTimeoutSeconds

        // Use class-based wrapper for thread-safe cancellation flag
        final class TimeoutState: @unchecked Sendable {
            var cancelled = false
        }
        let timeoutState = TimeoutState()

        DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(Int(timeoutSeconds))) { [weak targetConnection] in
            guard !timeoutState.cancelled else { return }
            guard let conn = targetConnection, conn.state != .ready else { return }
            conn.cancel()
        }

        // Capture for closure
        let capturedFallbackContext = fallbackContext
        let capturedHeaders = headers
        let capturedMethod = method
        let capturedPath = path
        let capturedVersion = version

        targetConnection.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }

            switch state {
            case .ready:
                timeoutState.cancelled = true
                // Build the forwarded request. Issue #15: the request line and
                // header section are built as a String (small, ASCII-only,
                // bounded by the header cap) and converted to Data ONCE; the
                // body is appended as raw bytes — no body String round-trip,
                // no `Data(body.utf8)`. The body can carry non-UTF8 bytes
                // (binary payloads) without corruption.
                var forwardedHeader = "\(capturedMethod) \(capturedPath) \(capturedVersion)\r\n"

                // Forward headers, excluding ones we'll override or that break error detection
                let excludedHeaders: Set<String> = ["connection", "content-length", "host", "transfer-encoding", "accept-encoding"]
                for (name, value) in capturedHeaders {
                    if !excludedHeaders.contains(name.lowercased()) {
                        forwardedHeader += "\(name): \(value)\r\n"
                    }
                }

                // Add our headers
                forwardedHeader += "Host: \(targetHost):\(targetPort)\r\n"
                forwardedHeader += "Connection: close\r\n"  // KEY: Force fresh connections
                forwardedHeader += "Content-Length: \(body.count)\r\n"
                forwardedHeader += "\r\n"

                guard let headerData = forwardedHeader.data(using: .utf8) else {
                    self.sendError(to: originalConnection, statusCode: 500, message: "Failed to encode request")
                    targetConnection.cancel()
                    return
                }

                // Concatenate header bytes + raw body bytes. The body is
                // forwarded byte-exact (Content-Length was set to body.count).
                var requestData = Data()
                requestData.append(headerData)
                requestData.append(body)

                targetConnection.send(content: requestData, completion: .contentProcessed { error in
                    if error != nil {
                        targetConnection.cancel()
                        originalConnection.cancel()
                    } else {
                        // Start receiving response
                        self.receiveResponse(
                            from: targetConnection,
                            to: originalConnection,
                            connectionId: connectionId,
                            startTime: startTime,
                            requestSize: requestSize,
                            metadata: metadata,
                            responseData: Data(),
                            fallbackContext: capturedFallbackContext,
                            headers: capturedHeaders,
                            method: capturedMethod,
                            path: capturedPath,
                            version: capturedVersion,
                            targetPort: targetPort,
                            targetHost: targetHost
                        )
                    }
                })

            case .failed:
                timeoutState.cancelled = true
                self.sendError(to: originalConnection, statusCode: 502, message: "Bad Gateway - Cannot connect to proxy")
                targetConnection.cancel()

            default:
                break
            }
        }

        targetConnection.start(queue: .global(qos: .userInitiated))
    }

    // MARK: - Qoder Branch (ADR 0001)

    /// ADR 0012: cancel and remove the pump Task stored for `connectionId`.
    /// Called from the agent connection's `stateUpdateHandler` on `.cancelled`
    /// / `.failed` (agent disconnect). Remove-then-cancel: pop the handle first
    /// so the body's own `defer { removeValue }` (which races this call on the
    /// same MainActor) finds nothing to remove — both paths are idempotent and
    /// a second cancel is a no-op on a completed Task. Missing entry is a
    /// no-op (Qoder disabled, pre-stream rejection, or already cleaned up).
    /// MainActor-isolated: matches `pumpTasks`'s isolation, and the handler
    /// hops to MainActor before calling this.
    private func cancelPumpTask(for connectionId: Int) {
        guard let task = pumpTasks.removeValue(forKey: connectionId) else { return }
        task.cancel()
    }

    /// Forward a `qoder/<id>` request through the failover router, bypassing
    /// CPA. Mirrors the shape of `forwardRequest` (CPA path) but the upstream
    /// is the router's HTTPS stream to api3.qoder.sh, not an NWConnection to
    /// localhost. The agent-facing socket stays NWConnection (unchanged).
    ///
    /// Lifecycle:
    ///   1. `router.openStream(...)` — all rotation/cooldown/re-exchange is
    ///      decided here, *before* the first response byte. On throw, send a
    ///      true HTTP error (400/503) to the agent — no stream has started.
    ///   2. On opened stream: write `HTTP/1.1 200` + `text/event-stream`
    ///      headers to the agent, then pump upstream bytes through a local
    ///      `QoderSSEReparser` and forward each re-encoded OpenAI chunk to the
    ///      agent socket.
    ///   3. On stream end: call `finish()` on the reparser, capture usage,
    ///      record metadata + `onRequestCompleted`.
    ///   4. Mid-stream failure (transport drop, reparser gate): terminate —
    ///      never rotate (the 200 SSE response already began; ADR 0006 §2).
    ///
    /// Cancellation (ADR 0012): the pump runs in an unstructured `Task` whose
    /// handle is stored in `pumpTasks[connectionId]` immediately after creation.
    /// The agent connection's single `stateUpdateHandler` (set in
    /// `handleNewConnection`) cancels that handle on `.cancelled` / `.failed`,
    /// which cooperatively unblocks the pump's awaiting `source()` pull (via
    /// `Task.checkCancellation()` inside `QoderGatewayStream.pump`) and the
    /// stream's `cancel()` tears down the upstream URLSession task. So a dropped
    /// agent socket no longer leaks the upstream byte stream until the next
    /// `sendToAgent` happens to fail. The handle is removed from `pumpTasks` on
    /// every exit path of the pump body (success, error, cancellation).
    private func forwardQoderRequest(
        router: QoderFailoverRouter,
        method: String,
        path: String,
        headers: [(String, String)],
        body: Data,
        originalConnection: NWConnection,
        connectionId: Int,
        startTime: Date,
        requestSize: Int,
        requestModel: String,
        responsesMode: Bool = false   // Issue #11
    ) {
        // Extract the proxy API key from `Authorization: Bearer <key>`. The
        // router uses it for session-ID derivation (ADR 0005 §1) and validates
        // it non-empty (CPA is bypassed for Qoder, so we own key validation).
        let proxyAPIKey = headers.first(where: { $0.0.lowercased() == "authorization" })?
            .1
            .components(separatedBy: " ")
            .dropFirst()
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        ?? ""

        // Issue #15: the body reaches here as `Data` straight from the parser
        // (no String round-trip on the hot path). The `qoder/` routing prefix
        // is stripped inside the router (ADR 0003 §1) before the body reaches
        // the translator and the upstream gateway — ProxyBridge only does
        // prefix *detection* (to decide routing), not stripping.
        let bodyData = body

        // ADR 0012: the pump runs in an unstructured Task so the `for await`
        // on the upstream byte stream doesn't block the MainActor. The handle
        // is stored in `pumpTasks[connectionId]` BEFORE the body's `for await`
        // begins, so the agent connection's stateUpdateHandler can cancel it
        // promptly on `.cancelled` / `.failed` (agent disconnect). Removal
        // happens on every exit path via the cleanup hop at the end of the
        // body (and via `cancelPumpTask`'s remove-then-cancel, which races the
        // body safely — both paths idempotently remove the same key). The
        // pump's cooperative-cancellation throw and the stream's `cancel()`
        // (called from `QoderGatewayStream.pump`'s defer on every exit) tear
        // down the upstream URLSession task together.
        let pumpTask = Task { [weak self] in
            guard let self = self else { return }

            // ADR 0012: remove the handle on EVERY exit path (success, error,
            // early return, cancellation). The Task body is MainActor-isolated
            // (unstructured `Task {}` inherits `forwardQoderRequest`'s
            // `@MainActor` isolation), so this is a synchronous MainActor
            // mutation — no hop needed. `cancelPumpTask(for:)` (called from the
            // stateUpdateHandler on disconnect) removes-then-cancels; if it ran
            // first this removeValue is a no-op, and vice-versa — both paths
            // idempotently clear the same key.
            defer { self.pumpTasks.removeValue(forKey: connectionId) }

            let opened: QoderOpenedStream
            do {
                opened = try await router.openStream(
                    requestBody: bodyData,
                    proxyAPIKey: proxyAPIKey
                )
            } catch let error as QoderFailoverError {
                // Pre-stream failure → true HTTP error. The status lives on the
                // error itself (issue #14): requestRejected carries the
                // translator's chosen 400/413, missingProxyAPIKey → 401,
                // noAccountsAvailable → 503. ProxyBridge.sendError wraps the
                // message in the ADR 0010 OpenAI error envelope, so the agent
                // sees a structured `{"error":{...}}` body matching the status.
                self.sendError(
                    to: originalConnection,
                    statusCode: error.httpStatus,
                    message: error.localizedDescription
                )
                return
            } catch {
                // Any other unexpected error → 502 (we couldn't reach upstream).
                self.sendError(to: originalConnection, statusCode: 502, message: "Qoder upstream error.")
                return
            }

            // Confirmed 2xx. Branch on the client's streaming intent (issue #9,
            // ADR 0014): `stream:true` → SSE head + live chunks (historic path);
            // missing/false `stream` → aggregate the SSE upstream into one
            // `chat.completion` JSON. The Qoder gateway stream is SSE either way;
            // only the client-facing shape differs. Both paths converge on the
            // shared metadata recording below via these locals:
            var capturedUsageDict: [String: Any]?
            var totalResponseBytes = 0
            var pumpFailed = false
            var httpStatus: Int? = 200

            if opened.streamRequested {
                // --- Streaming: write the SSE response head, then pump. ---
                let responseHead = "HTTP/1.1 200 OK\r\n" +
                    "Content-Type: text/event-stream\r\n" +
                    "Cache-Control: no-cache\r\n" +
                    "Connection: close\r\n" +
                    "\r\n"
                guard let headData = responseHead.data(using: .utf8) else {
                    originalConnection.cancel()
                    return
                }

                // Send head, then begin streaming. Use a continuation-style send.
                originalConnection.send(content: headData, completion: .contentProcessed { headError in
                    if headError != nil {
                        originalConnection.cancel()
                        return
                    }
                })

                // Pump upstream bytes → reparser → OpenAI chunks → agent socket.
                // The gateway client owns the byte-stream plumbing and calls our
                // `onChunk` per buffer; we feed each buffer through the reparser
                // and forward the OpenAI-shape bytes to the agent socket.
                // `QoderSSEReparser` is a per-request `var` (not Sendable by
                // design — never shared). Owned inside this Task.
                //
                // Issue #19: thread `stream_options.include_usage` from the
                // request body. For Chat streaming the client opts in via the
                // field; default false (spec-compliant). For Responses API
                // streaming the contract is different — `response.completed`
                // always carries `usage` — so we force `includeUsage: true`
                // there to preserve behavior (the reparser gate would otherwise
                // suppress the upstream usage chunk the adapter folds into
                // response.completed).
                let includeUsage = responsesMode
                    || Self.includeUsageFlag(in: bodyData)
                var reparser = QoderSSEReparser(includeUsage: includeUsage)

                // The onChunk closure captures mutable state via a final-class
                // holder (closures can't capture `inout` reparser). The holder is
                // local to this Task, never shared across isolation domains.
                // Issue #11: when `responsesMode` is set, the box also carries a
                // `QoderResponsesAdapter` that translates OpenAI
                // chat.completion.chunk SSE (the reparser's output) into
                // Responses API events before they reach the agent socket.
                final class ReparserBox: @unchecked Sendable {
                    var reparser: QoderSSEReparser
                    var responsesAdapter: QoderResponsesAdapter?   // Issue #11
                    var totalBytes: Int = 0
                    var failed: Bool = false
                    /// ADR 0010: the specific reason captured at whichever gate
                    /// tripped `failed`. Surfaced onto the mid-stream SSE error
                    /// frame so the client sees the real cause instead of a
                    /// generic "stream ended" message. nil until a gate sets it.
                    var failureDetail: String?
                    init(_ reparser: QoderSSEReparser, _ responsesAdapter: QoderResponsesAdapter?) {
                        self.reparser = reparser
                        self.responsesAdapter = responsesAdapter
                    }

                    /// Issue #11: translate OpenAI chat.completion.chunk SSE →
                    /// Responses API events. nil adapter = pass through (the
                    /// existing Chat path, byte-identical). The adapter is a
                    /// value type; this method copies it out, mutates, writes it
                    /// back so subsequent calls see accumulated state (same
                    /// in/out mechanics the reparser's `var` already uses here).
                    /// Best-effort: a translation failure (malformed JSON inside
                    /// a `data:` frame) returns empty rather than tearing the
                    /// stream — the reparser's gate owns hard failures.
                    func translate(_ openAIChunks: Data) -> Data {
                        guard var adapter = responsesAdapter else { return openAIChunks }
                        let translated = (try? adapter.ingest(openAIChunks)) ?? Data()
                        responsesAdapter = adapter
                        return translated
                    }
                }
                let box = ReparserBox(reparser, responsesMode ? QoderResponsesAdapter() : nil)
                // Track the agent connection so the closure can send to it.
                let agentConn = originalConnection

                // Feed the router's pre-handoff peek prefix through the reparser
                // first. The router consumed the leading chunk to detect an
                // in-envelope quota signal; those bytes must still reach the agent,
                // so we replay them before driving the remainder pump.
                if !opened.bufferedPrefix.isEmpty {
                    box.totalBytes += opened.bufferedPrefix.count
                    let prefixChunks: Data
                    do {
                        prefixChunks = try box.reparser.feed(opened.bufferedPrefix)
                    } catch {
                        // The router already probed the prefix for a non-200
                        // envelope; a gate trip here would be a second-order
                        // condition (e.g. malformed line the router's focused
                        // probe didn't trip on). Terminate the same way as a
                        // mid-stream gate.
                        box.failed = true
                        box.failureDetail = error.localizedDescription
                        Log.proxy("Qoder prefix gate tripped: \(error.localizedDescription)")
                        prefixChunks = Data()
                    }
                    if !prefixChunks.isEmpty {
                        // Issue #11: in responsesMode, translate OpenAI
                        // chat.completion.chunk SSE → Responses events before
                        // sending. The adapter is a value type held in the box;
                        // mutate the box's copy and send the translated bytes.
                        let toSend = box.translate(prefixChunks)
                        if !toSend.isEmpty {
                            try? await Self.sendToAgent(toSend, on: agentConn)
                        }
                    }
                }

                do {
                    try await opened.pump { rawChunk in
                        box.totalBytes += rawChunk.count
                        let openAIChunks: Data
                        do {
                            openAIChunks = try box.reparser.feed(rawChunk)
                        } catch {
                            // Reparser gate (reasoning_content / tool_calls /
                            // upstreamStatus). A mid-stream gate can't become a
                            // true HTTP 400 — the 200 SSE head already shipped.
                            // Terminate the agent stream; chunks already sent
                            // stand. ADR 0004 documents this wire behavior.
                            box.failed = true
                            box.failureDetail = error.localizedDescription
                            Log.proxy("Qoder stream gate tripped: \(error.localizedDescription)")
                            return false  // stop pumping
                        }
                        if !openAIChunks.isEmpty {
                            // Issue #11: translate through the responses adapter
                            // (no-op when not in responsesMode — see box.translate).
                            let toSend = box.translate(openAIChunks)
                            do {
                                if !toSend.isEmpty {
                                    try await Self.sendToAgent(toSend, on: agentConn)
                                }
                            } catch {
                                // Agent socket went away — stop pumping cleanly.
                                return false
                            }
                        }
                        return true
                    }
                } catch {
                    if !Task.isCancelled {
                        // ADR 0010: a transport drop (not a client cancellation)
                        // is a mid-stream failure — record it so the error-frame
                        // emission below surfaces it instead of silently
                        // truncating. Cancellations are clean teardowns and must
                        // not trip the gate.
                        box.failed = true
                        box.failureDetail = error.localizedDescription
                        Log.proxy("Qoder upstream stream ended: \(error.localizedDescription)")
                    }
                }

                totalResponseBytes = box.totalBytes
                pumpFailed = box.failed
                reparser = box.reparser  // read back final state for usage capture

                // ADR 0010: a mid-stream failure (after the 200 OK SSE head)
                // can no longer change the HTTP status. Instead of silently
                // truncating, emit a terminal error frame BEFORE the close so
                // the client sees a structured error. Routed through the
                // Responses adapter when in responsesMode (a Chat-shape frame
                // on a Responses stream would be malformed); otherwise the
                // Chat-shape error frame. The terminal-flush block below only
                // runs on success (`!pumpFailed`), so on failure this frame is
                // the only terminal the client sees.
                if pumpFailed {
                    let errMsg = box.failureDetail ?? "Qoder upstream stream ended before completion."
                    let frame: Data
                    if responsesMode, box.responsesAdapter != nil {
                        // The adapter carries accumulated sequence state; copy
                        // out, mutate (errorEvent stamps the next sequence
                        // number), write back so a later access sees it. Same
                        // in/out mechanics as `box.translate`.
                        var adapter = box.responsesAdapter!
                        frame = adapter.errorEvent(message: errMsg)
                        box.responsesAdapter = adapter
                    } else {
                        frame = QoderOpenAIError.sseTerminalFrame(statusCode: 502, message: errMsg)
                    }
                    if !frame.isEmpty {
                        // Await so the error frame lands before the close —
                        // avoids a race where the close cancels the in-flight
                        // send. Best-effort: a send failure here just means
                        // the client already disconnected.
                        _ = try? await Self.sendToAgent(frame, on: originalConnection)
                    }
                }

                // Flush the reparser's terminal chunk ([DONE] + trailing usage).
                // Issue #11: in responsesMode the terminal OpenAI chunk flows
                // through the adapter first (same translate-then-send path),
                // THEN `adapter.finish()` emits the Responses terminals
                // (output_text.done, output_item.done, response.completed). The
                // finish() call is made exactly once — its contract (see
                // QoderResponsesAdapter.finish()) is to emit response.completed
                // and is idempotent on a second call (returns empty).
                if !pumpFailed {
                    let terminal: Data
                    do {
                        terminal = try reparser.finish()
                    } catch {
                        terminal = Data()
                    }
                    if responsesMode {
                        if !terminal.isEmpty {
                            let toSend = box.translate(terminal)
                            if !toSend.isEmpty {
                                try? await Self.sendToAgent(toSend, on: originalConnection)
                            }
                        }
                        if box.responsesAdapter != nil {
                            // finish() is mutating; copy out, finish, then drop.
                            var adapter = box.responsesAdapter!
                            let completedData = (try? adapter.finish()) ?? Data()
                            box.responsesAdapter = nil   // idempotent guard
                            if !completedData.isEmpty {
                                try? await Self.sendToAgent(completedData, on: originalConnection)
                            }
                        }
                    } else {
                        if !terminal.isEmpty {
                            try? await Self.sendToAgent(terminal, on: originalConnection)
                        }
                    }
                }

                // Close the agent socket (Connection: close).
                originalConnection.send(content: nil, isComplete: true, completion: .contentProcessed { _ in
                    originalConnection.cancel()
                })

                capturedUsageDict = reparser.capturedUsage
            } else {
                // --- Non-streaming: aggregate SSE → one JSON object. ---
                // The head is written AFTER aggregation so Content-Length is
                // exact (a non-streaming client expects a complete JSON body,
                // not a chunked/trickled one). Pump the upstream through the
                // same `QoderSSEReparser` (so Qoder envelope parsing, the
                // upstream-status gate, and tool-call/usage capture stay
                // identical), then feed the reparser's OpenAI-shape chunks into
                // a `QoderCompletionAggregator`. Single parser of Qoder's
                // envelope — no parallel state machine (issue #9 acceptance).

                // Issue #26: `/v1/responses` requests (`responsesMode`) share
                // this aggregation path and branch only at emit time below —
                // the Chat path folds into a `chat.completion` object
                // (issue #9), the Responses path into a `response` object.
                // The issue #11 Task B 501 placeholder is gone with this.
                //
                // Issue #19: non-streaming completions always carry `usage`
                // (OpenAI includes it unconditionally in non-streaming
                // responses — `stream_options` applies to streaming only).
                // The reparser's trailing usage chunk feeds the aggregator's
                // `completionJSON` usage field, so force `includeUsage: true`
                // to preserve the existing behavior.
                var reparser = QoderSSEReparser(includeUsage: true)
                var aggregator = QoderCompletionAggregator()
                var aggregateFailed = false

                // Same final-class holder pattern as the streaming path: the
                // pump closure can't capture `inout` reparser/aggregator.
                final class AggregateBox: @unchecked Sendable {
                    var reparser: QoderSSEReparser
                    var aggregator: QoderCompletionAggregator
                    var totalBytes: Int = 0
                    var failed: Bool = false
                    init(_ r: QoderSSEReparser, _ a: QoderCompletionAggregator) {
                        self.reparser = r; self.aggregator = a
                    }
                }
                let box = AggregateBox(reparser, aggregator)

                // Feed the pre-handoff peek prefix: reparser first (unchanged),
                // then its OpenAI-shape output into the aggregator.
                if !opened.bufferedPrefix.isEmpty {
                    box.totalBytes += opened.bufferedPrefix.count
                    let prefixChunks: Data
                    do {
                        prefixChunks = try box.reparser.feed(opened.bufferedPrefix)
                    } catch {
                        box.failed = true
                        Log.proxy("Qoder (non-stream) prefix gate tripped: \(error.localizedDescription)")
                        prefixChunks = Data()
                    }
                    if !prefixChunks.isEmpty {
                        try? box.aggregator.ingest(prefixChunks)
                    }
                }

                do {
                    try await opened.pump { rawChunk in
                        box.totalBytes += rawChunk.count
                        let openAIChunks: Data
                        do {
                            openAIChunks = try box.reparser.feed(rawChunk)
                        } catch {
                            // Reparser gate. Unlike the streaming path, the
                            // 200 head has NOT been written yet — so a gate
                            // here can still surface as a true HTTP error
                            // (handled below after the pump). Record failure
                            // and stop pumping.
                            box.failed = true
                            Log.proxy("Qoder (non-stream) gate tripped: \(error.localizedDescription)")
                            return false
                        }
                        if !openAIChunks.isEmpty {
                            try? box.aggregator.ingest(openAIChunks)
                        }
                        return true
                    }
                } catch {
                    if !Task.isCancelled {
                        Log.proxy("Qoder (non-stream) upstream stream ended: \(error.localizedDescription)")
                    }
                    // A transport drop before the head was written → true error.
                    aggregateFailed = true
                }

                totalResponseBytes = box.totalBytes
                pumpFailed = box.failed || aggregateFailed
                reparser = box.reparser
                aggregator = box.aggregator

                // Flush the reparser so any trailing usage / stashed finish
                // reason reaches the aggregator (the reparser's `finish()`
                // emits the usage-only chunk + [DONE]; the aggregator ignores
                // [DONE] and folds the usage chunk).
                if !pumpFailed {
                    let terminal: Data
                    do {
                        terminal = try reparser.finish()
                    } catch {
                        terminal = Data()
                    }
                    if !terminal.isEmpty {
                        try? aggregator.ingest(terminal)
                    }
                }

                if pumpFailed {
                    // No head written yet → emit a true HTTP 500 instead of a
                    // truncated JSON body. This is the advantage the
                    // non-streaming path has over streaming (where a mid-stream
                    // gate can only truncate). ADR 0010 will centralize the
                    // error envelope; until then the existing text/plain error
                    // path is used.
                    httpStatus = nil
                    self.sendError(to: originalConnection, statusCode: 502, message: "Qoder upstream stream ended before completion.")
                    originalConnection.send(content: nil, isComplete: true, completion: .contentProcessed { _ in
                        originalConnection.cancel()
                    })
                } else {
                    // Issue #26: emit-time branch. Chat folds into a
                    // `chat.completion` object; Responses folds into a
                    // `response` object. Same aggregated content/usage — only
                    // the envelope differs.
                    let json: [String: Any] = responsesMode
                        ? aggregator.responsesObject(requestModel: requestModel)
                        : aggregator.completionJSON(requestModel: requestModel)
                    capturedUsageDict = aggregator.capturedUsage ?? reparser.capturedUsage
                    let bodyBytes: Data
                    // Compact JSON — OpenAI returns non-streaming completions
                    // compact, not pretty-printed.
                    if let compact = try? JSONSerialization.data(withJSONObject: json) {
                        bodyBytes = compact
                    } else {
                        bodyBytes = Data("{\"error\":\"failed to serialize completion\"}".utf8)
                    }
                    let head = "HTTP/1.1 200 OK\r\n" +
                        "Content-Type: application/json\r\n" +
                        "Content-Length: \(bodyBytes.count)\r\n" +
                        "Cache-Control: no-cache\r\n" +
                        "Connection: close\r\n" +
                        "\r\n"
                    let headBytes = Data(head.utf8)
                    // Head then body, awaiting each send so order is preserved
                    // (NWConnection does not guarantee ordering across
                    // overlapping sends).
                    try? await Self.sendToAgent(headBytes, on: originalConnection)
                    try? await Self.sendToAgent(bodyBytes, on: originalConnection)
                    originalConnection.send(content: nil, isComplete: true, completion: .contentProcessed { _ in
                        originalConnection.cancel()
                    })
                    totalResponseBytes += bodyBytes.count
                }
            }

            // Record completion metadata, including captured usage for the
            // Quotio-side usage accumulator (ADR 0005 §2). Shared across the
            // streaming and non-streaming branches.
            let usage = capturedUsageDict
            let inputTokens = (usage?["prompt_tokens"] as? Int)
                ?? (usage?["prompt_tokens"] as? NSNumber)?.intValue
            let outputTokens = (usage?["completion_tokens"] as? Int)
                ?? (usage?["completion_tokens"] as? NSNumber)?.intValue
            // OpenAI semantics: prompt_tokens INCLUDES cached. Pass through.
            // `completion_tokens_details` is a nested object that
            // JSONSerialization reconstructs as NSDictionary (not `[String:
            // Any]`), so coerce defensively — same NSNumber-fallback pattern as
            // the sibling token reads.
            let details = usage?["completion_tokens_details"] as? NSDictionary
            let reasoningTokens = (details?["reasoning_tokens"] as? Int)
                ?? (details?["reasoning_tokens"] as? NSNumber)?.intValue

            let durationMs = Int(Date().timeIntervalSince(startTime) * 1000)
            let finalMetadata = RequestMetadata(
                timestamp: startTime,
                method: method,
                path: path,
                provider: "qoder",
                model: requestModel,
                resolvedModel: requestModel,
                resolvedProvider: "qoder",
                statusCode: pumpFailed ? nil : httpStatus,
                durationMs: durationMs,
                requestSize: requestSize,
                responseSize: totalResponseBytes,
                fallbackAttempts: [],
                fallbackStartedFromCache: false,
                responseSnippet: nil,
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                cacheReadTokens: nil,
                cacheWriteTokens: nil,
                reasoningTokens: reasoningTokens
            )
            self.onRequestCompleted?(finalMetadata)
        }

        // ADR 0012: store the pump handle BEFORE its body's `for await` can
        // begin. This synchronous MainActor assignment runs before
        // `forwardQoderRequest` returns, so the agent connection's
        // stateUpdateHandler (which may fire `.cancelled` / `.failed` on a
        // fast disconnect) is guaranteed to find the handle in `pumpTasks`
        // from this point onward. The body's `defer` removes it on every exit.
        pumpTasks[connectionId] = pumpTask
    }

    /// Issue #19: parse `stream_options.include_usage` from a Chat Completions
    /// request body. OpenAI's streaming contract emits the trailing usage-only
    /// chunk ONLY when this field is `true`; missing/malformed → `false` (the
    /// spec default). Tolerates a non-object `stream_options` value (→ false).
    /// Nonisolated + value-type JSON parse → callable from any isolation domain
    /// (mirrors `QoderFailoverRouter.streamRequested(in:)`'s shape).
    ///
    /// Internal (not private) so `@testable` tests can pin the boundary
    /// behavior directly (issue #19 acceptance: missing/malformed stream_options).
    ///
    /// Strictness note: `NSNumber as? Bool` succeeds for JSON `1`/`0`
    /// (Foundation bridges them through NSNumber). To honor the OpenAI
    /// contract's JSON-boolean requirement we discriminate via `objCType`:
    /// JSONSerialization decodes true/false as `c` (char/BOOL), any other
    /// numeric type → not a boolean opt-in.
    nonisolated static func includeUsageFlag(in body: Data) -> Bool {
        guard let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let streamOptions = json["stream_options"] as? [String: Any] else {
            return false
        }
        guard let value = streamOptions["include_usage"] as? NSNumber else {
            return false
        }
        // Only accept a genuine JSON boolean (objCType "c"). A numeric 1/0
        // or a numeric-looking string is not an opt-in.
        return strcmp(value.objCType, "c") == 0 && value.boolValue
    }

    /// Send one chunk to the agent NWConnection, awaiting the send completion
    /// before returning so chunk order is preserved across `connection.send`
    /// calls (NWConnection does not guarantee ordering across overlapping
    /// sends). Throws on send error so the pump can terminate.
    private nonisolated static func sendToAgent(
        _ data: Data,
        on connection: NWConnection
    ) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume()
                }
            })
        }
    }

    // MARK: - Response Streaming (Iterative)

    private nonisolated func receiveResponse(
        from targetConnection: NWConnection,
        to originalConnection: NWConnection,
        connectionId: Int,
        startTime: Date,
        requestSize: Int,
        metadata: (provider: String?, model: String?, method: String, path: String),
        responseData: Data,
        fallbackContext: FallbackContext,
        headers: [(String, String)],
        method: String,
        path: String,
        version: String,
        targetPort: UInt16,
        targetHost: String
    ) {
        targetConnection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }

            if error != nil {
                targetConnection.cancel()
                originalConnection.cancel()
                return
            }

            // Use let to avoid captured var warning - Data is already accumulated via parameter
            let accumulatedResponse: Data
            if let data = data, !data.isEmpty {
                var newAccumulated = responseData
                newAccumulated.append(data)
                accumulatedResponse = newAccumulated
            } else {
                accumulatedResponse = responseData
            }

            // Check for quota exceeded BEFORE forwarding to client (within first 4KB to catch streaming errors)
            let quotaCheckThreshold = 4096
            if accumulatedResponse.count <= quotaCheckThreshold && !accumulatedResponse.isEmpty && fallbackContext.hasFallback {
                let fallbackReason = self.fallbackReason(responseData: accumulatedResponse)

                // Check for thinking signature errors - retry same provider with sanitized body
                if fallbackReason != nil {
                    let isSignatureError = FallbackFormatConverter.isThinkingSignatureError(responseData: accumulatedResponse)

                    if isSignatureError && !fallbackContext.triedSanitization,
                       let currentEntry = fallbackContext.currentEntry {
                        let sanitizedBody = self.sanitizeThinkingBlocks(fallbackContext.originalBody, targetModelId: currentEntry.modelId)

                        if sanitizedBody != fallbackContext.originalBody {
                            targetConnection.cancel()
                            let retryContext = fallbackContext.withSanitizationAttempted()

                            self.forwardRequest(
                                method: method,
                                path: path,
                                version: version,
                                headers: headers,
                                body: sanitizedBody,
                                originalConnection: originalConnection,
                                connectionId: connectionId,
                                startTime: startTime,
                                requestSize: requestSize,
                                metadata: metadata,
                                targetPort: targetPort,
                                targetHost: targetHost,
                                fallbackContext: retryContext
                            )
                            return
                        }
                    }
                }

                if let reason = fallbackReason, fallbackContext.hasMoreFallbacks {
                    // Don't forward error to client, try next fallback instead
                    targetConnection.cancel()

                    // Try next fallback
                    let updatedContext: FallbackContext
                    if let failedEntry = fallbackContext.currentEntry {
                        let failedAttempt = FallbackAttempt(entry: failedEntry, outcome: .failed, reason: reason)
                        updatedContext = fallbackContext.appendingAttempt(failedAttempt)
                    } else {
                        updatedContext = fallbackContext
                    }
                    let nextContext = updatedContext.next()
                    if let nextEntry = nextContext.currentEntry,
                       let virtualModelName = nextContext.virtualModelName {

                        // Update route state for UI display (cache is only updated on success)
                        Task { @MainActor in
                            let settings = FallbackSettingsManager.shared
                            settings.updateRouteState(
                                virtualModelName: virtualModelName,
                                entryIndex: nextContext.currentIndex,
                                entry: nextEntry,
                                totalEntries: nextContext.fallbackEntries.count
                            )
                        }

                        let nextBody = self.replaceModelInBody(fallbackContext.originalBody, with: nextEntry.modelId)

                        self.forwardRequest(
                            method: method,
                            path: path,
                            version: version,
                            headers: headers,
                            body: nextBody,
                            originalConnection: originalConnection,
                            connectionId: connectionId,
                            startTime: startTime,
                            requestSize: requestSize,
                            metadata: metadata,
                            targetPort: targetPort,
                            targetHost: targetHost,
                            fallbackContext: nextContext
                        )
                    }
                    return
                }
            }

            if let data = data, !data.isEmpty {
                // Forward chunk to client
                originalConnection.send(content: data, completion: .contentProcessed { sendError in
                    if isComplete {
                        // Request complete - record metadata
                        self.recordCompletion(
                            connectionId: connectionId,
                            startTime: startTime,
                            requestSize: requestSize,
                            responseSize: accumulatedResponse.count,
                            responseData: accumulatedResponse,
                            metadata: metadata,
                            fallbackContext: fallbackContext
                        )

                        targetConnection.cancel()
                        originalConnection.send(content: nil, isComplete: true, completion: .contentProcessed { _ in
                            originalConnection.cancel()
                        })
                    } else {
                        // Continue streaming - use async dispatch to break recursion stack
                        DispatchQueue.global(qos: .userInitiated).async {
                            self.receiveResponse(
                                from: targetConnection,
                                to: originalConnection,
                                connectionId: connectionId,
                                startTime: startTime,
                                requestSize: requestSize,
                                metadata: metadata,
                                responseData: accumulatedResponse,
                                fallbackContext: fallbackContext,
                                headers: headers,
                                method: method,
                                path: path,
                                version: version,
                                targetPort: targetPort,
                                targetHost: targetHost
                            )
                        }
                    }
                })
            } else if isComplete {
                // Record completion
                self.recordCompletion(
                    connectionId: connectionId,
                    startTime: startTime,
                    requestSize: requestSize,
                    responseSize: accumulatedResponse.count,
                    responseData: accumulatedResponse,
                    metadata: metadata,
                    fallbackContext: fallbackContext
                )

                targetConnection.cancel()
                originalConnection.send(content: nil, isComplete: true, completion: .contentProcessed { _ in
                    originalConnection.cancel()
                })
            }
        }
    }
    
    // MARK: - Completion Recording

    private nonisolated func recordCompletion(
        connectionId: Int,
        startTime: Date,
        requestSize: Int,
        responseSize: Int,
        responseData: Data,
        metadata: (provider: String?, model: String?, method: String, path: String),
        fallbackContext: FallbackContext
    ) {
        let durationMs = Int(Date().timeIntervalSince(startTime) * 1000)

        // Extract status code from response
        var statusCode: Int?
        if let responseString = String(data: responseData.prefix(100), encoding: .utf8),
           let statusLine = responseString.components(separatedBy: "\r\n").first {
            // Parse "HTTP/1.1 200 OK"
            let parts = statusLine.components(separatedBy: " ")
            if parts.count >= 2, let code = Int(parts[1]) {
                statusCode = code
            }
        }

        // Capture variables for Sendable closure
        let capturedStatusCode = statusCode
        let capturedMetadata = metadata

        // Extract resolved model/provider from fallback context
        let resolvedModel: String? = fallbackContext.currentEntry?.modelId
        let resolvedProvider: String? = fallbackContext.currentEntry?.provider.rawValue

        let finalReason: FallbackTriggerReason?
        if let statusCode = statusCode, !(200..<300).contains(statusCode) {
            finalReason = fallbackReason(responseData: responseData) ?? .httpStatus(statusCode)
        } else {
            finalReason = nil
        }

        var attempts = fallbackContext.attempts
        if fallbackContext.hasFallback,
           (fallbackContext.wasLoadedFromCache ||
            fallbackContext.currentIndex > 0 ||
            !attempts.isEmpty ||
            finalReason != nil),
           let entry = fallbackContext.currentEntry {
            let outcome: FallbackAttemptOutcome = finalReason == nil ? .success : .failed
            let finalAttempt = FallbackAttempt(entry: entry, outcome: outcome, reason: finalReason)
            attempts.append(finalAttempt)
        }

        let responseSnippet: String? = finalReason == nil ? nil : responseBodySnippet(from: responseData)

        // Notify callback on main thread
        Task { @MainActor [weak self] in
            // Cache successful entry ONLY if:
            // 1. Response is successful (HTTP 2xx)
            // 2. Fallback was actually triggered (currentIndex > 0)
            // 3. Entry was NOT loaded from cache (wasLoadedFromCache == false)
            let settings = FallbackSettingsManager.shared
            if let statusCode = capturedStatusCode, (200..<300).contains(statusCode),
               settings.isRouteCachingEnabled,
               fallbackContext.currentIndex > 0,
               !fallbackContext.wasLoadedFromCache,
               let virtualModelName = fallbackContext.virtualModelName,
               let currentEntry = fallbackContext.currentEntry {
                settings.setCachedEntryId(for: virtualModelName, entryId: currentEntry.id)
                settings.updateRouteState(
                    virtualModelName: virtualModelName,
                    entryIndex: fallbackContext.currentIndex,
                    entry: currentEntry,
                    totalEntries: fallbackContext.fallbackEntries.count
                )
            }

            let requestMetadata = RequestMetadata(
                timestamp: startTime,
                method: capturedMetadata.method,
                path: capturedMetadata.path,
                provider: capturedMetadata.provider,
                model: capturedMetadata.model,
                resolvedModel: resolvedModel,
                resolvedProvider: resolvedProvider,
                statusCode: capturedStatusCode,
                durationMs: durationMs,
                requestSize: requestSize,
                responseSize: responseSize,
                fallbackAttempts: attempts,
                fallbackStartedFromCache: fallbackContext.wasLoadedFromCache,
                responseSnippet: responseSnippet
            )
            self?.onRequestCompleted?(requestMetadata)
        }
    }
    
    // MARK: - Error Response
    
    private nonisolated func sendError(to connection: NWConnection, statusCode: Int, message: String) {
        // ADR 0010: build the OpenAI JSON error envelope via the single CPA
        // builder. Every status (Qoder auth → 401, endpoint gate → 404, parse
        // failure → 400, upstream → 502, etc.) flows through the same map, so
        // the bridge and CPA paths return indistinguishable error bodies. The
        // `message` here is the errText CPA names the parameter; the builder
        // handles empty → reason-phrase, valid-JSON → verbatim pass-through,
        // and the status → type/code mapping internally.
        let bodyData = QoderOpenAIError.body(statusCode: statusCode, message: message)

        // Map status code to proper HTTP reason phrase. This drives the HTTP
        // status line only — independent of the JSON envelope's type/code
        // (the builder owns that). Reuses `QoderOpenAIError.reasonPhrase(for:)`
        // so there is one reason-phrase table, not two (ADR 0010 §Consequences).
        let reasonPhrase = QoderOpenAIError.reasonPhrase(for: statusCode)

        // Build HTTP response with proper CRLF line endings (no leading whitespace).
        // Content-Type is now application/json (was text/plain) per ADR 0010.
        let headers = "HTTP/1.1 \(statusCode) \(reasonPhrase)\r\n" +
            "Content-Type: application/json\r\n" +
            "Content-Length: \(bodyData.count)\r\n" +
            "Connection: close\r\n" +
            "\r\n"

        guard let headerData = headers.data(using: .utf8) else {
            connection.cancel()
            return
        }

        var responseData = Data()
        responseData.append(headerData)
        responseData.append(bodyData)

        connection.send(content: responseData, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
