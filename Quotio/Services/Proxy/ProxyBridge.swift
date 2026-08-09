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
    let originalBody: String
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
        originalBody: "",
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
                }
            } else if case .failed = state {
                Task { @MainActor in
                    weakSelf.activeConnections -= 1
                }
            }
        }
        
        connection.start(queue: .global(qos: .userInitiated))
        
        // Start receiving request
        receiveRequest(
            from: connection,
            connectionId: connectionId,
            startTime: startTime,
            accumulatedData: Data()
        )
    }
    
    // MARK: - Request Receiving (Iterative)
    
    /// Receives HTTP request data iteratively to avoid stack overflow
    private nonisolated func receiveRequest(
        from connection: NWConnection,
        connectionId: Int,
        startTime: Date,
        accumulatedData: Data
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
            
            var newData = accumulatedData
            newData.append(data)
            
            // Check if we have a complete HTTP request
            if let requestString = String(data: newData, encoding: .utf8),
               let headerEndRange = requestString.range(of: "\r\n\r\n") {
                
                let headerEndIndex = requestString.distance(from: requestString.startIndex, to: headerEndRange.upperBound)
                let headerPart = String(requestString.prefix(headerEndIndex))
                
                // Check Content-Length to determine if we have full body
                if let contentLengthLine = headerPart
                    .components(separatedBy: "\r\n")
                    .first(where: { $0.lowercased().hasPrefix("content-length:") }) {
                    
                    let headerParts = contentLengthLine.components(separatedBy: ":")
                    guard headerParts.count > 1 else { return }
                    
                    let lengthStr = headerParts[1].trimmingCharacters(in: .whitespaces)
                    if let contentLength = Int(lengthStr) {
                        let currentBodyLength = newData.count - headerEndIndex
                        
                        // Need more data
                        if currentBodyLength < contentLength {
                            let nextData = newData
                            // Use async dispatch to break recursion stack
                            DispatchQueue.global(qos: .userInitiated).async {
                                self.receiveRequest(
                                    from: connection,
                                    connectionId: connectionId,
                                    startTime: startTime,
                                    accumulatedData: nextData
                                )
                            }
                            return
                        }
                    }
                }
                
                // Complete request - process it
                self.processRequest(
                    data: newData,
                    connection: connection,
                    connectionId: connectionId,
                    startTime: startTime
                )
                
            } else if !isComplete {
                // Haven't found header end yet, continue receiving
                // Use async dispatch to break recursion stack
                let nextData = newData
                DispatchQueue.global(qos: .userInitiated).async {
                    self.receiveRequest(
                        from: connection,
                        connectionId: connectionId,
                        startTime: startTime,
                        accumulatedData: nextData
                    )
                }
            } else {
                // Complete but malformed
                self.processRequest(
                    data: newData,
                    connection: connection,
                    connectionId: connectionId,
                    startTime: startTime
                )
            }
        }
    }
    
    // MARK: - Request Processing

    private nonisolated func processRequest(
        data: Data,
        connection: NWConnection,
        connectionId: Int,
        startTime: Date
    ) {
        guard let requestString = String(data: data, encoding: .utf8) else {
            sendError(to: connection, statusCode: 400, message: "Invalid request encoding")
            return
        }

        // Parse HTTP request line
        let lines = requestString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            sendError(to: connection, statusCode: 400, message: "Missing request line")
            return
        }

        let parts = requestLine.components(separatedBy: " ")
        guard parts.count >= 3 else {
            sendError(to: connection, statusCode: 400, message: "Invalid request format")
            return
        }

        let method = parts[0]
        let path = parts[1]
        let httpVersion = parts[2]

        // Collect headers
        var headers: [(String, String)] = []
        for line in lines.dropFirst() {
            if line.isEmpty { break }
            guard let colonIndex = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<colonIndex]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)
            headers.append((name, value))
        }

        // Extract body
        var body = ""
        if let bodyRange = requestString.range(of: "\r\n\r\n") {
            body = String(requestString[bodyRange.upperBound...])
        }

        let metadata = extractMetadata(method: method, path: path, body: body)

        // Qoder branch (ADR 0001): a request whose body `model:` starts with
        // `qoder/` is intercepted here and routed direct to api3.qoder.sh,
        // bypassing CPA entirely. The CPA path (createFallbackContext +
        // forwardRequest below) is untouched. The branch is gated on the
        // `qoderRouter` being wired (QuotaViewModel sets it at proxy start); a
        // qoder/ request with no router falls through to CPA, which will 404
        // — preferable to silently swallowing it.
        //
        // The router read happens inside the MainActor Task below (alongside
        // the rest of the request setup) because `qoderRouter` is MainActor-
        // isolated and `processRequest` is `nonisolated`.
        let isQoderBound = metadata.model?.hasPrefix("qoder/") == true

        // Issue #11: `/v1/responses` is the OpenAI Responses API. A qoder/ model
        // on that endpoint routes to a separate Responses adapter
        // (`QoderResponsesTranslator` input + `QoderResponsesAdapter` output),
        // reusing the Chat gateway core. The body is synthesized into Chat
        // Completions shape before reaching the router so COSY/failover/reparser
        // are identical to the Chat path. Full ADR 0009 method/path enforcement
        // (404 for qoder-bound requests on wrong paths) is separate foundation
        // work; this branch only adds the responses routing decision.
        let isResponsesEndpoint = method == "POST" && path == "/v1/responses"

        // Check for virtual model and create fallback context
        Task { @MainActor [weak self] in
            guard let self = self else { return }

            // Qoder branch: route to the failover router and return — the CPA
            // path (fallback + forwardRequest) does not run for qoder/ models.
            if isQoderBound, let router = self.qoderRouter {
                // Issue #11: Responses API path. Synthesize the Chat body here
                // (pre-router) so the router/translator/COSY path is byte-
                // identical to Chat. Parse errors become a 400 — the Responses
                // body didn't carry model/input/etc. Non-responses qoder
                // requests keep their body byte-identical (only the new flag +
                // the synthesized body differ).
                let effectiveBody: String
                let responsesMode: Bool
                if isResponsesEndpoint {
                    do {
                        let chatBody = try QoderResponsesTranslator.synthesizeChatBody(from: Data(body.utf8))
                        effectiveBody = String(data: chatBody, encoding: .utf8) ?? body
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
                    requestSize: data.count,
                    requestModel: metadata.model ?? "",
                    responsesMode: responsesMode
                )
                return
            }

            let fallbackContext = self.createFallbackContext(body: body)
            let resolvedBody: String

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
                requestSize: data.count,
                metadata: metadata,
                targetPort: targetPortValue,
                targetHost: targetHostValue,
                fallbackContext: fallbackContext
            )
        }
    }

    // MARK: - Fallback Support

    /// Create fallback context if the request uses a virtual model
    private func createFallbackContext(body: String) -> FallbackContext {
        let settings = FallbackSettingsManager.shared

        // Check if fallback is enabled
        guard settings.isEnabled else {
            return .empty
        }

        // Extract model from body
        guard let bodyData = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
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
        _ body: String,
        with newModel: String
    ) -> String {
        guard let bodyData = body.data(using: .utf8),
              var json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
              json["model"] != nil else {
            return body
        }

        json["model"] = newModel

        guard let newData = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]),
              let newBody = String(data: newData, encoding: .utf8) else {
            return body
        }

        return newBody
    }

    private nonisolated func sanitizeThinkingBlocks(_ body: String, targetModelId: String) -> String {
        guard let bodyData = body.data(using: .utf8),
              var json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
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

        guard let newData = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]),
              let newBody = String(data: newData, encoding: .utf8) else {
            return body
        }

        return newBody
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
    
    private nonisolated func extractMetadata(method: String, path: String, body: String) -> (provider: String?, model: String?, method: String, path: String) {
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
        
        // Extract model from JSON body
        var model: String?
        if let bodyData = body.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any],
           let modelValue = json["model"] as? String {
            model = modelValue
            
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
        body: String,
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
                // Build forwarded request with Connection: close
                var forwardedRequest = "\(capturedMethod) \(capturedPath) \(capturedVersion)\r\n"

                // Forward headers, excluding ones we'll override or that break error detection
                let excludedHeaders: Set<String> = ["connection", "content-length", "host", "transfer-encoding", "accept-encoding"]
                for (name, value) in capturedHeaders {
                    if !excludedHeaders.contains(name.lowercased()) {
                        forwardedRequest += "\(name): \(value)\r\n"
                    }
                }

                // Add our headers
                forwardedRequest += "Host: \(targetHost):\(targetPort)\r\n"
                forwardedRequest += "Connection: close\r\n"  // KEY: Force fresh connections
                forwardedRequest += "Content-Length: \(body.utf8.count)\r\n"
                forwardedRequest += "\r\n"
                forwardedRequest += body

                guard let requestData = forwardedRequest.data(using: .utf8) else {
                    self.sendError(to: originalConnection, statusCode: 500, message: "Failed to encode request")
                    targetConnection.cancel()
                    return
                }

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
    /// Cancellation: the pump Task is captured and cancelled from the agent
    /// connection's stateUpdateHandler on disconnect, so a dropped agent
    /// socket doesn't leak the URLSession byte stream.
    private func forwardQoderRequest(
        router: QoderFailoverRouter,
        method: String,
        path: String,
        headers: [(String, String)],
        body: String,
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

        // Pass the raw body to the router. The `qoder/` routing prefix is
        // stripped inside the router (ADR 0003 §1) before the body reaches the
        // translator and the upstream gateway — ProxyBridge only does prefix
        // *detection* (to decide routing), not stripping.
        let bodyData = Data(body.utf8)

        // The pump runs in a detached-from-actor Task so the `for await` on
        // the upstream byte stream doesn't block the MainActor. Cancellation:
        // when the proxy stops or the agent socket is cancelled, the active-
        // counter handler in `handleNewConnection` runs `connection.cancel()`;
        // our pump's next `sendToAgent` then fails, the `try` propagates, and
        // `Task.checkCancellation()` breaks the byte iterator (URLSession
        // tears its stream down when the iterator is dropped). No explicit
        // stateUpdateHandler wiring needed here — NWConnection allows only one
        // handler, already set in `handleNewConnection`.
        Task { [weak self] in
            guard let self = self else { return }

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
                var reparser = QoderSSEReparser()

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
                // --- Non-streaming: aggregate SSE → one chat.completion JSON. ---
                // The head is written AFTER aggregation so Content-Length is
                // exact (a non-streaming client expects a complete JSON body,
                // not a chunked/trickled one). Pump the upstream through the
                // same `QoderSSEReparser` (so Qoder envelope parsing, the
                // upstream-status gate, and tool-call/usage capture stay
                // identical), then feed the reparser's OpenAI-shape chunks into
                // a `QoderCompletionAggregator`. Single parser of Qoder's
                // envelope — no parallel state machine (issue #9 acceptance).

                // Issue #11 Task B: non-streaming Responses shape is a follow-up
                // (the `{id, object:"response", output:[...], usage}` object
                // needs a fold from `QoderCompletionAggregator` output, similar
                // to how Chat non-streaming was done in issue #9). Return an
                // explicit 501 rather than silently returning a Chat-shaped
                // object on a Responses endpoint — silent misrouting is worse
                // than a clear error. Clients should retry with `stream:true`.
                // The shared metadata recording below still runs (no `return`)
                // so the request is counted; `httpStatus = nil` marks it as a
                // non-2xx outcome so the recorder reports `statusCode: nil`.
                if responsesMode {
                    httpStatus = nil
                    self.sendError(to: originalConnection, statusCode: 501,
                        message: "Non-streaming Responses API is not yet supported; retry with stream:true.")
                    originalConnection.send(content: nil, isComplete: true, completion: .contentProcessed { _ in
                        originalConnection.cancel()
                    })
                } else {
                var reparser = QoderSSEReparser()
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
                    let json = aggregator.completionJSON(requestModel: requestModel)
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
                }   // closes `else` of `if responsesMode` (Issue #11)
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
