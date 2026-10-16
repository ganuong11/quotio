import Foundation
import Network
import QuotioApplication
import QuotioDomain

/// Agent-facing TCP front door. Binds the user-visible port (loopback-only
/// unless LAN sharing is enabled), parses each accepted connection with
/// `HTTP1RequestParser`, and either byte-forwards the request to CPA on the
/// internal loopback port or intercepts `qoder/*` traffic for direct serving.
///
/// The listener forces `Connection: close` upstream and recomputes
/// `Content-Length`, so every connection carries exactly one request. The
/// response is relayed back verbatim until upstream closes.
///
/// Routing is decided in `route(_:)` per request: `/v1/models` merges CPA's
/// list with the Qoder catalog; `qoder/*` on the allowlisted POST surfaces is
/// dispatched to the injected `QoderFailoverRouter` (after `QoderAccessValidator`
/// authentication, mirroring CPA's AuthMiddleware); everything else is
/// byte-faithful passthrough.
public actor GatewayListener: ProxyFrontDoorListening {

    public enum StartError: Error, Equatable {
        case invalidPort(UInt16)
        case cancelled
    }

    private var listener: NWListener?
    private var upstreamPort: UInt16 = 0
    private(set) var isRunning = false
    private(set) var lastError: String?

    /// Pump Task handles for in-flight provider streams, keyed by connection
    /// ID, so an agent disconnect (or listener stop) cancels them promptly.
    private var pumpTasks: [Int: Task<Void, Never>] = [:]

    private var activeConnections = 0
    private var nextConnectionID = 0
    private let maxActiveConnections = 100
    private nonisolated static let connectionTimeoutSeconds: UInt64 = 10

    private var readyContinuation: CheckedContinuation<Result<Void, Error>, Never>?

    // MARK: - Provider routing (Task 15)

    /// Qoder failover router. Nil disables interception — `qoder/*` requests
    /// then fall through to CPA (which will 404 them), matching the legacy
    /// "branch not wired" posture.
    private var qoderRouter: QoderFailoverRouter?
    /// Shared API-key validator for intercepted provider traffic (ADR 0008).
    /// Fed by `apiKeySource` at listener start; while unprimed it fails CLOSED.
    private var accessValidator: QoderAccessValidator?
    private var apiKeySource: (@Sendable () async throws -> [String])?
    private var logger: (any ApplicationLogging)?
    /// Completion recorder (request accounting hook — ADR 0005 §2 consumer).
    public var onRequestCompleted: (@Sendable (GatewayRequestMetadata) -> Void)?

    public init() {}

    /// Wire the Qoder branch. Called before `start` (or while running — the
    /// next request observes the new values; routing state is actor-isolated).
    public func configureRouting(
        qoderRouter: QoderFailoverRouter?,
        accessValidator: QoderAccessValidator? = nil,
        apiKeySource: (@Sendable () async throws -> [String])? = nil,
        logger: (any ApplicationLogging)? = nil
    ) {
        self.qoderRouter = qoderRouter
        self.accessValidator = accessValidator
        self.apiKeySource = apiKeySource
        self.logger = logger
    }

    // MARK: - Lifecycle

    public func start(port: UInt16, bindHost: String, upstreamPort: UInt16) async throws {
        guard listener == nil, !isRunning else { return }
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw StartError.invalidPort(port)
        }
        lastError = nil
        self.upstreamPort = upstreamPort

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        // requiredLocalEndpoint pins the bind interface: "127.0.0.1" keeps the
        // front door loopback-only; "0.0.0.0" opens it to the LAN.
        parameters.requiredLocalEndpoint = .hostPort(
            host: NWEndpoint.Host(bindHost),
            port: endpointPort
        )

        let newListener = try NWListener(using: parameters)

        newListener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            Task { await self.handleListenerState(state) }
        }
        newListener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            Task { await self.handleNewConnection(connection) }
        }

        self.listener = newListener
        newListener.start(queue: .global(qos: .userInitiated))

        // Await the first terminal state so a bind failure (e.g. EADDRINUSE)
        // is thrown here rather than silently leaving the port dead.
        let watchdog = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 5_000_000_000)
            } catch {
                return
            }
            await self?.handleListenerState(.failed(NWError.posix(.ETIMEDOUT)))
        }
        defer { watchdog.cancel() }

        let result = await withCheckedContinuation {
            (cont: CheckedContinuation<Result<Void, Error>, Never>) in
            readyContinuation = cont
        }
        try result.get()

        // Prime the access validator before the first intercepted request.
        // A failed fetch leaves it .notPrimed (fail-closed) rather than
        // known-empty open access.
        if let apiKeySource {
            Task { [accessValidator] in
                if let keys = try? await apiKeySource() {
                    await accessValidator?.reload(keys: keys)
                }
            }
        }
    }

    public func stop() {
        readyContinuation?.resume(returning: .failure(StartError.cancelled))
        readyContinuation = nil
        listener?.cancel()
        listener = nil
        for task in pumpTasks.values { task.cancel() }
        pumpTasks.removeAll()
        activeConnections = 0
        isRunning = false
    }

    // MARK: - Listener state

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            isRunning = true
            readyContinuation?.resume(returning: .success(()))
            readyContinuation = nil
        case .failed(let error):
            isRunning = false
            lastError = error.localizedDescription
            if let readyContinuation {
                self.readyContinuation = nil
                readyContinuation.resume(returning: .failure(error))
            }
            listener?.cancel()
            listener = nil
        case .cancelled:
            isRunning = false
            if let readyContinuation {
                self.readyContinuation = nil
                readyContinuation.resume(returning: .failure(StartError.cancelled))
            }
        default:
            break
        }
    }

    // MARK: - Connection handling

    private func handleNewConnection(_ connection: NWConnection) {
        guard activeConnections < maxActiveConnections else {
            connection.cancel()
            return
        }
        activeConnections += 1
        nextConnectionID += 1
        let connectionID = nextConnectionID

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .cancelled, .failed:
                // Agent socket went away: release the slot and cancel the
                // in-flight pump so an upstream stream tears down promptly.
                Task { await self.connectionEnded(connectionID) }
            default:
                break
            }
        }

        connection.start(queue: .global(qos: .userInitiated))
        Self.receiveRequest(
            from: connection,
            listener: self,
            connectionID: connectionID,
            parser: HTTP1RequestParser()
        )
    }

    private func connectionEnded(_ connectionID: Int) {
        activeConnections -= 1
        pumpTasks.removeValue(forKey: connectionID)?.cancel()
    }

    private func removePumpTask(_ connectionID: Int) {
        pumpTasks.removeValue(forKey: connectionID)
    }

    // MARK: - Request receiving

    /// Drives `HTTP1RequestParser` on every receive callback. A parser is a
    /// value type owned per connection — exactly one request per connection,
    /// because the upstream is always sent `Connection: close`.
    private nonisolated static func receiveRequest(
        from connection: NWConnection,
        listener: GatewayListener,
        connectionID: Int,
        parser: HTTP1RequestParser
    ) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1048576) { data, _, isComplete, error in
            if error != nil {
                connection.cancel()
                return
            }
            guard let data, !data.isEmpty else {
                if isComplete { connection.cancel() }
                return
            }

            var localParser = parser
            switch localParser.feed(data) {
            case .needsMoreData:
                if isComplete {
                    connection.cancel()
                    return
                }
                let nextParser = localParser
                DispatchQueue.global(qos: .userInitiated).async {
                    receiveRequest(
                        from: connection,
                        listener: listener,
                        connectionID: connectionID,
                        parser: nextParser
                    )
                }
            case .complete(let request):
                Task { await listener.dispatchRequest(
                    request,
                    connection: connection,
                    connectionID: connectionID,
                    startTime: Date()
                ) }
            case .error(let parseError):
                let statusCode: Int
                switch parseError {
                case .headerTooLarge, .bodyTooLarge:
                    statusCode = 413
                default:
                    statusCode = 400
                }
                sendError(to: connection, statusCode: statusCode, message: parseError.errorDescription ?? "Bad Request")
            }
        }
    }

    // MARK: - Routing

    /// Single source of dispatch truth. `/v1/models` is always intercepted
    /// (merge only adds namespaces whose branch is servable); `qoder/*` models
    /// are intercepted only when the router is wired — otherwise they fall
    /// through to CPA unchanged.
    private func route(_ request: HTTP1Request) -> GatewayDisposition {
        if request.method == "GET",
           QoderRouteGate.pathWithoutQuery(request.path) == "/v1/models" {
            return .modelsMerge
        }
        let model = GatewayModelExtraction.extractModel(from: request.body)
        let qoderRoute = QoderRouteGate.resolve(
            method: request.method,
            path: request.path,
            model: model
        )
        if qoderRoute != .notQoder, qoderRouter != nil {
            return .qoder(qoderRoute)
        }
        return .passthrough
    }

    /// Actor-side dispatch — decided after the request is fully parsed.
    private func dispatchRequest(
        _ request: HTTP1Request,
        connection: NWConnection,
        connectionID: Int,
        startTime: Date
    ) async {
        switch route(request) {
        case .modelsMerge:
            serveModelsList(
                path: request.path,
                headers: request.headers.map { ($0.name, $0.value) },
                originalConnection: connection,
                mergeQoder: qoderRouter != nil
            )
        case .qoder(let qoderRoute):
            guard let router = qoderRouter else {
                Self.forwardRequest(
                    request: request,
                    originalConnection: connection,
                    upstreamPort: upstreamPort
                )
                return
            }
            if qoderRoute == .rejected {
                Self.sendError(
                    to: connection,
                    statusCode: 404,
                    message: "Qoder models are only supported on POST /v1/chat/completions and POST /v1/responses."
                )
                return
            }
            let effectiveBody: Data
            let responsesMode: Bool
            if qoderRoute == .responses {
                do {
                    effectiveBody = try QoderResponsesTranslator.synthesizeChatBody(from: request.body)
                    responsesMode = true
                } catch {
                    Self.sendError(to: connection, statusCode: 400, message: (error as? QoderTranslatorError)?.errorDescription ?? "Malformed responses request")
                    return
                }
            } else {
                effectiveBody = request.body
                responsesMode = false
            }
            await forwardQoderRequest(
                router: router,
                method: request.method,
                path: request.path,
                headers: request.headers.map { ($0.name, $0.value) },
                body: effectiveBody,
                originalConnection: connection,
                connectionID: connectionID,
                startTime: startTime,
                requestSize: request.headerBytes + request.body.count,
                requestModel: GatewayModelExtraction.extractModel(from: request.body) ?? "",
                responsesMode: responsesMode
            )
        case .passthrough:
            Self.forwardRequest(
                request: request,
                originalConnection: connection,
                upstreamPort: upstreamPort
            )
        }
    }

    // MARK: - CPA passthrough

    private nonisolated static func forwardRequest(
        request: HTTP1Request,
        originalConnection: NWConnection,
        upstreamPort: UInt16
    ) {
        guard let port = NWEndpoint.Port(rawValue: upstreamPort) else {
            sendError(to: originalConnection, statusCode: 500, message: "Invalid upstream port")
            return
        }

        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: port)
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.enableKeepalive = true
        tcpOptions.keepaliveIdle = 30
        tcpOptions.keepaliveInterval = 5
        tcpOptions.keepaliveCount = 3
        let parameters = NWParameters(tls: nil, tcp: tcpOptions)

        let targetConnection = NWConnection(to: endpoint, using: parameters)

        final class TimeoutState: @unchecked Sendable {
            var cancelled = false
        }
        let timeoutState = TimeoutState()

        DispatchQueue.global().asyncAfter(
            deadline: .now() + .seconds(Int(connectionTimeoutSeconds))
        ) { [weak targetConnection] in
            guard !timeoutState.cancelled,
                  let connection = targetConnection,
                  connection.state != .ready else { return }
            sendError(
                to: originalConnection,
                statusCode: 504,
                message: "Gateway timeout connecting to upstream"
            )
            connection.cancel()
        }

        targetConnection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                timeoutState.cancelled = true

                // Header section is rebuilt as a String (small, bounded by the
                // parser's header cap); the body appends as raw bytes — no
                // String round-trip, so non-UTF8 payloads survive.
                var head = "\(request.method) \(request.path) \(request.version)\r\n"
                let excludedHeaders: Set<String> = [
                    "connection", "content-length", "host",
                    "transfer-encoding", "accept-encoding",
                ]
                for header in request.headers where !excludedHeaders.contains(header.name.lowercased()) {
                    head += "\(header.name): \(header.value)\r\n"
                }
                head += "Host: 127.0.0.1:\(upstreamPort)\r\n"
                head += "Connection: close\r\n"
                head += "Content-Length: \(request.body.count)\r\n"
                head += "\r\n"

                guard let headData = head.data(using: .utf8) else {
                    sendError(to: originalConnection, statusCode: 500, message: "Failed to encode request")
                    targetConnection.cancel()
                    return
                }
                var requestData = headData
                requestData.append(request.body)

                targetConnection.send(content: requestData, completion: .contentProcessed { error in
                    if error != nil {
                        targetConnection.cancel()
                        originalConnection.cancel()
                    } else {
                        receiveResponse(from: targetConnection, to: originalConnection)
                    }
                })
            case .failed:
                timeoutState.cancelled = true
                sendError(to: originalConnection, statusCode: 502, message: "Bad Gateway - Cannot connect to proxy")
                targetConnection.cancel()
            default:
                break
            }
        }

        targetConnection.start(queue: .global(qos: .userInitiated))
    }

    /// Relays upstream response bytes to the agent verbatim until upstream
    /// closes (`Connection: close` guarantees the framing is self-terminating).
    private nonisolated static func receiveResponse(
        from targetConnection: NWConnection,
        to originalConnection: NWConnection
    ) {
        targetConnection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
            if error != nil {
                targetConnection.cancel()
                originalConnection.cancel()
                return
            }
            if let data, !data.isEmpty {
                originalConnection.send(content: data, completion: .contentProcessed { _ in
                    if isComplete {
                        targetConnection.cancel()
                        originalConnection.send(content: nil, isComplete: true, completion: .contentProcessed { _ in
                            originalConnection.cancel()
                        })
                    } else {
                        DispatchQueue.global(qos: .userInitiated).async {
                            receiveResponse(from: targetConnection, to: originalConnection)
                        }
                    }
                })
            } else if isComplete {
                targetConnection.cancel()
                originalConnection.send(content: nil, isComplete: true, completion: .contentProcessed { _ in
                    originalConnection.cancel()
                })
            }
        }
    }

    // MARK: - Qoder branch (ADR 0001)

    /// Shared API-key authentication for intercepted provider traffic (ADR
    /// 0008). Returns the principal (matched key) or the legacy Bearer suffix
    /// on the open-access fallbacks; nil means the request was already
    /// answered with an error.
    private func authenticateProxyRequest(
        headers: [(String, String)],
        path: String,
        connection: NWConnection,
        notReadyMessage: String
    ) async -> String? {
        func legacyBearerExtraction() -> String {
            headers.first(where: { $0.0.lowercased() == "authorization" })?
                .1
                .components(separatedBy: " ")
                .dropFirst()
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
            ?? ""
        }

        guard let validator = accessValidator else {
            return legacyBearerExtraction()
        }
        switch await validator.authenticate(path: path, headers: headers) {
        case .allowed(let principal):
            return principal
        case .notConfigured:
            return legacyBearerExtraction()
        case .notPrimed:
            Self.sendError(to: connection, statusCode: 503, message: notReadyMessage)
            return nil
        case .missing:
            Self.sendError(to: connection, statusCode: 401, message: "Missing API key")
            return nil
        case .invalid:
            Self.sendError(to: connection, statusCode: 401, message: "Invalid API key")
            return nil
        }
    }

    /// Forward a `qoder/<id>` request through the failover router, bypassing
    /// CPA. Streaming → SSE head + live chunks through the reparser (and the
    /// Responses adapter in responsesMode); non-streaming → aggregate into one
    /// `chat.completion`/`response` JSON.
    private func forwardQoderRequest(
        router: QoderFailoverRouter,
        method: String,
        path: String,
        headers: [(String, String)],
        body: Data,
        originalConnection: NWConnection,
        connectionID: Int,
        startTime: Date,
        requestSize: Int,
        requestModel: String,
        responsesMode: Bool = false
    ) async {
        guard let proxyAPIKey = await authenticateProxyRequest(
            headers: headers,
            path: path,
            connection: originalConnection,
            notReadyMessage: "Qoder API-key validation is not ready yet — the proxy key snapshot has not loaded. Retry in a moment."
        ) else {
            return
        }

        let bodyData = body

        // ADR 0012: the pump runs in an unstructured Task so the byte loop
        // doesn't block the listener actor. The handle is stored in
        // `pumpTasks[connectionID]` BEFORE the body starts so the connection's
        // stateUpdateHandler can cancel it promptly on agent disconnect.
        let pumpTask = Task { [weak self] in
            guard let self = self else { return }

            // Remove the handle on EVERY exit path.
            defer { Task { await self.removePumpTask(connectionID) } }

            let opened: QoderOpenedStream
            do {
                opened = try await router.openStream(
                    requestBody: bodyData,
                    proxyAPIKey: proxyAPIKey
                )
            } catch let error as QoderFailoverError {
                Self.sendError(
                    to: originalConnection,
                    statusCode: error.httpStatus,
                    message: error.errorDescription ?? "Qoder upstream error.",
                    retryAfter: error.retryAfterSeconds
                )
                return
            } catch {
                Self.sendError(to: originalConnection, statusCode: 502, message: "Qoder upstream error.")
                return
            }

            var capturedUsageDict: [String: Any]?
            var totalResponseBytes = 0
            var pumpFailed = false
            var httpStatus: Int? = 200

            if opened.streamRequested {
                let responseHead = "HTTP/1.1 200 OK\r\n" +
                    "Content-Type: text/event-stream\r\n" +
                    "Cache-Control: no-cache\r\n" +
                    "Connection: close\r\n" +
                    "\r\n"
                guard let headData = responseHead.data(using: .utf8) else {
                    originalConnection.cancel()
                    return
                }

                originalConnection.send(content: headData, completion: .contentProcessed { headError in
                    if headError != nil {
                        originalConnection.cancel()
                        return
                    }
                })

                let includeUsage = responsesMode
                    || GatewayIncludeUsageFlag.flag(in: bodyData)
                var reparser = QoderSSEReparser(includeUsage: includeUsage)

                final class ReparserBox: @unchecked Sendable {
                    var reparser: QoderSSEReparser
                    var responsesAdapter: QoderResponsesAdapter?
                    var totalBytes: Int = 0
                    var failed: Bool = false
                    var failureDetail: String?
                    init(_ reparser: QoderSSEReparser, _ responsesAdapter: QoderResponsesAdapter?) {
                        self.reparser = reparser
                        self.responsesAdapter = responsesAdapter
                    }

                    /// Translate OpenAI chat.completion.chunk SSE → Responses
                    /// events. nil adapter = pass through. Best-effort.
                    func translate(_ openAIChunks: Data) -> Data {
                        guard var adapter = responsesAdapter else { return openAIChunks }
                        let translated = (try? adapter.ingest(openAIChunks)) ?? Data()
                        responsesAdapter = adapter
                        return translated
                    }
                }
                let box = ReparserBox(reparser, responsesMode ? QoderResponsesAdapter() : nil)
                let agentConn = originalConnection

                // Replay the router's pre-handoff peek prefix through the
                // reparser first — those bytes must still reach the agent.
                if !opened.bufferedPrefix.isEmpty {
                    box.totalBytes += opened.bufferedPrefix.count
                    let prefixChunks: Data
                    do {
                        prefixChunks = try box.reparser.feed(opened.bufferedPrefix)
                    } catch {
                        box.failed = true
                        box.failureDetail = String(describing: error)
                        await log("Qoder prefix gate tripped: \(String(describing: error))")
                        prefixChunks = Data()
                    }
                    if !prefixChunks.isEmpty {
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
                            // Mid-stream gate can't change the shipped 200;
                            // terminate the stream (ADR 0004 wire behavior).
                            box.failed = true
                            box.failureDetail = String(describing: error)
                            return false
                        }
                        if !openAIChunks.isEmpty {
                            let toSend = box.translate(openAIChunks)
                            do {
                                if !toSend.isEmpty {
                                    try await Self.sendToAgent(toSend, on: agentConn)
                                }
                            } catch {
                                return false
                            }
                        }
                        return true
                    }
                } catch {
                    if !Task.isCancelled {
                        box.failed = true
                        box.failureDetail = String(describing: error)
                        await log("Qoder upstream stream ended: \(String(describing: error))")
                    }
                }

                totalResponseBytes = box.totalBytes
                pumpFailed = box.failed
                reparser = box.reparser

                // Mid-stream failure after the 200 head: emit a terminal error
                // frame before close (ADR 0010), translated through the
                // Responses adapter when in responsesMode.
                if pumpFailed {
                    let errMsg = box.failureDetail ?? "Qoder upstream stream ended before completion."
                    let frame: Data
                    if responsesMode, box.responsesAdapter != nil {
                        var adapter = box.responsesAdapter!
                        frame = adapter.errorEvent(message: errMsg)
                        box.responsesAdapter = adapter
                    } else {
                        frame = QoderOpenAIError.sseTerminalFrame(statusCode: 502, message: errMsg)
                    }
                    if !frame.isEmpty {
                        _ = try? await Self.sendToAgent(frame, on: originalConnection)
                    }
                }

                // Flush the reparser's terminal chunk ([DONE] + trailing usage)
                // — in responsesMode through the adapter, then adapter.finish()
                // emits the Responses terminals exactly once.
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
                            var adapter = box.responsesAdapter!
                            let completedData = (try? adapter.finish()) ?? Data()
                            box.responsesAdapter = nil
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

                originalConnection.send(content: nil, isComplete: true, completion: .contentProcessed { _ in
                    originalConnection.cancel()
                })

                capturedUsageDict = reparser.capturedUsage
            } else {
                // --- Non-streaming: aggregate SSE → one JSON object. The head
                // is written after aggregation so Content-Length is exact. ---
                var reparser = QoderSSEReparser(includeUsage: true)
                var aggregator = QoderCompletionAggregator()
                var aggregateFailed = false

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

                if !opened.bufferedPrefix.isEmpty {
                    box.totalBytes += opened.bufferedPrefix.count
                    let prefixChunks: Data
                    do {
                        prefixChunks = try box.reparser.feed(opened.bufferedPrefix)
                    } catch {
                        box.failed = true
                        await log("Qoder (non-stream) prefix gate tripped: \(String(describing: error))")
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
                            // No head written yet → this can still surface as a
                            // true HTTP error below.
                            box.failed = true
                            return false
                        }
                        if !openAIChunks.isEmpty {
                            try? box.aggregator.ingest(openAIChunks)
                        }
                        return true
                    }
                } catch {
                    if !Task.isCancelled {
                        await log("Qoder (non-stream) upstream stream ended: \(String(describing: error))")
                    }
                    aggregateFailed = true
                }

                totalResponseBytes = box.totalBytes
                pumpFailed = box.failed || aggregateFailed
                reparser = box.reparser
                aggregator = box.aggregator

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
                    httpStatus = nil
                    Self.sendError(to: originalConnection, statusCode: 502, message: "Qoder upstream stream ended before completion.")
                    originalConnection.send(content: nil, isComplete: true, completion: .contentProcessed { _ in
                        originalConnection.cancel()
                    })
                } else {
                    let json: [String: Any] = responsesMode
                        ? aggregator.responsesObject(requestModel: requestModel)
                        : aggregator.completionJSON(requestModel: requestModel)
                    capturedUsageDict = aggregator.capturedUsage ?? reparser.capturedUsage
                    let bodyBytes: Data
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
                    try? await Self.sendToAgent(headBytes, on: originalConnection)
                    try? await Self.sendToAgent(bodyBytes, on: originalConnection)
                    originalConnection.send(content: nil, isComplete: true, completion: .contentProcessed { _ in
                        originalConnection.cancel()
                    })
                    totalResponseBytes += bodyBytes.count
                }
            }

            // Record completion metadata, including captured usage for the
            // usage accumulator (ADR 0005 §2). Shared across both branches.
            let usage = capturedUsageDict
            let inputTokens = (usage?["prompt_tokens"] as? Int)
                ?? (usage?["prompt_tokens"] as? NSNumber)?.intValue
            let outputTokens = (usage?["completion_tokens"] as? Int)
                ?? (usage?["completion_tokens"] as? NSNumber)?.intValue
            let details = usage?["completion_tokens_details"] as? NSDictionary
            let reasoningTokens = (details?["reasoning_tokens"] as? Int)
                ?? (details?["reasoning_tokens"] as? NSNumber)?.intValue

            let durationMs = Int(Date().timeIntervalSince(startTime) * 1000)
            let finalMetadata = GatewayRequestMetadata(
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
                responseSnippet: nil,
                inputTokens: inputTokens,
                outputTokens: outputTokens,
                cacheReadTokens: nil,
                cacheWriteTokens: nil,
                reasoningTokens: reasoningTokens
            )
            await self.onRequestCompleted?(finalMetadata)
        }

        // Store the pump handle BEFORE its body can begin so a fast agent
        // disconnect finds it in `pumpTasks`.
        pumpTasks[connectionID] = pumpTask
    }

    private func log(_ message: String) async {
        await logger?.write(.warning, message: message)
    }

    /// Awaitable NWConnection send — preserves chunk order across the pump.
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

    // MARK: - GET /v1/models merge (ADR 0016)

    /// Intercepts `GET /v1/models`: forwards the request to CPA, accumulates
    /// the whole response (16 MiB cap), then merges the Qoder catalog via the
    /// pure `QoderModelsMerger`. Any failure forwards CPA's raw bytes verbatim
    /// — a merge failure must never break model discovery.
    private func serveModelsList(
        path: String,
        headers: [(String, String)],
        originalConnection: NWConnection,
        mergeQoder: Bool
    ) {
        let targetPort = upstreamPort
        guard let port = NWEndpoint.Port(rawValue: targetPort) else {
            Self.sendError(to: originalConnection, statusCode: 500, message: "Invalid upstream port")
            return
        }

        let endpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: port)
        let tcpOptions = NWProtocolTCP.Options()
        tcpOptions.enableKeepalive = true
        let parameters = NWParameters(tls: nil, tcp: tcpOptions)
        let targetConnection = NWConnection(to: endpoint, using: parameters)

        final class TimeoutState: @unchecked Sendable {
            var cancelled = false
        }
        let timeoutState = TimeoutState()
        let timeoutSeconds = Self.connectionTimeoutSeconds
        DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(Int(timeoutSeconds))) { [weak targetConnection] in
            guard !timeoutState.cancelled,
                  let conn = targetConnection,
                  conn.state != .ready else { return }
            conn.cancel()
        }

        let capturedHeaders = headers
        let capturedPath = path
        let maxAccumBytes = 16 * 1024 * 1024

        targetConnection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                timeoutState.cancelled = true
                var forwardedHeader = "GET \(capturedPath) HTTP/1.1\r\n"
                let excludedHeaders: Set<String> = [
                    "connection", "content-length", "host",
                    "transfer-encoding", "accept-encoding",
                ]
                for (name, value) in capturedHeaders
                where !excludedHeaders.contains(name.lowercased()) {
                    forwardedHeader += "\(name): \(value)\r\n"
                }
                forwardedHeader += "Host: 127.0.0.1:\(targetPort)\r\n"
                forwardedHeader += "Connection: close\r\n"
                forwardedHeader += "\r\n"

                guard let requestData = forwardedHeader.data(using: .utf8) else {
                    Task { await self.sendLocalError(to: originalConnection, statusCode: 500, message: "Failed to encode request") }
                    targetConnection.cancel()
                    return
                }

                targetConnection.send(content: requestData, completion: .contentProcessed { error in
                    if error != nil {
                        targetConnection.cancel()
                        originalConnection.cancel()
                    } else {
                        Self.receiveModelsList(
                            from: targetConnection,
                            to: originalConnection,
                            responseData: Data(),
                            mergeQoder: mergeQoder,
                            maxAccumBytes: maxAccumBytes
                        )
                    }
                })
            case .failed:
                timeoutState.cancelled = true
                Task { await self.sendLocalError(to: originalConnection, statusCode: 502, message: "Bad Gateway - Cannot connect to proxy") }
                targetConnection.cancel()
            default:
                break
            }
        }

        targetConnection.start(queue: .global(qos: .userInitiated))
    }

    private nonisolated static func receiveModelsList(
        from targetConnection: NWConnection,
        to originalConnection: NWConnection,
        responseData: Data,
        mergeQoder: Bool,
        maxAccumBytes: Int
    ) {
        targetConnection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
            if error != nil {
                targetConnection.cancel()
                sendError(to: originalConnection, statusCode: 502, message: "Bad Gateway - Upstream error")
                return
            }

            var accumulated = responseData
            if let data, !data.isEmpty {
                accumulated.append(data)
            }

            if accumulated.count > maxAccumBytes {
                targetConnection.cancel()
                sendError(to: originalConnection, statusCode: 502, message: "Bad Gateway - Response too large")
                return
            }

            if isComplete {
                targetConnection.cancel()
                finishModelsList(
                    accumulatedResponse: accumulated,
                    originalConnection: originalConnection,
                    mergeQoder: mergeQoder
                )
            } else {
                DispatchQueue.global(qos: .userInitiated).async {
                    receiveModelsList(
                        from: targetConnection,
                        to: originalConnection,
                        responseData: accumulated,
                        mergeQoder: mergeQoder,
                        maxAccumBytes: maxAccumBytes
                    )
                }
            }
        }
    }

    /// Merge the provider catalog into CPA's 2xx models body, else forward the
    /// raw response verbatim (status line included) — ADR 0016's "discovery
    /// never breaks" rule.
    private nonisolated static func finishModelsList(
        accumulatedResponse: Data,
        originalConnection: NWConnection,
        mergeQoder: Bool
    ) {
        var mergedBody: Data? = nil
        if mergeQoder,
           let status = statusCode(from: accumulatedResponse),
           (200..<300).contains(status),
           let body = QoderModelsMerger.extractHTTPBody(from: accumulatedResponse) {
            mergedBody = QoderModelsMerger.mergeQoderModels(into: body)
        }

        if let mergedBody {
            let header = "HTTP/1.1 200 OK\r\n" +
                "Content-Type: application/json\r\n" +
                "Content-Length: \(mergedBody.count)\r\n" +
                "Connection: close\r\n" +
                "\r\n"
            var responseData = Data()
            if let headerData = header.data(using: .utf8) {
                responseData.append(headerData)
            }
            responseData.append(mergedBody)
            originalConnection.send(content: responseData, completion: .contentProcessed { _ in
                originalConnection.send(content: nil, isComplete: true, completion: .contentProcessed { _ in
                    originalConnection.cancel()
                })
            })
        } else {
            originalConnection.send(content: accumulatedResponse, completion: .contentProcessed { _ in
                originalConnection.send(content: nil, isComplete: true, completion: .contentProcessed { _ in
                    originalConnection.cancel()
                })
            })
        }
    }

    private nonisolated static func statusCode(from response: Data) -> Int? {
        guard let headerEnd = response.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: response[..<headerEnd.lowerBound], encoding: .utf8),
              let statusLine = head.components(separatedBy: "\r\n").first else { return nil }
        let parts = statusLine.components(separatedBy: " ")
        guard parts.count >= 2 else { return nil }
        return Int(parts[1])
    }

    /// Actor-side helper so nonisolated receive callbacks can emit through the
    /// shared `sendError` without capturing send paths.
    private func sendLocalError(to connection: NWConnection, statusCode: Int, message: String) {
        Self.sendError(to: connection, statusCode: statusCode, message: message)
    }

    // MARK: - Error responses

    /// ADR 0010 OpenAI error envelope via `QoderOpenAIError` — every status
    /// (auth 401, gate 404, parse 400, upstream 502) returns an envelope
    /// indistinguishable from CPA's. `Retry-After` is emitted only for the
    /// 429 rate-limit case so agents auto-back-off.
    private nonisolated static func sendError(
        to connection: NWConnection,
        statusCode: Int,
        message: String,
        retryAfter: TimeInterval? = nil
    ) {
        let bodyData = QoderOpenAIError.body(statusCode: statusCode, message: message)
        let reasonPhrase = QoderOpenAIError.reasonPhrase(for: statusCode)

        var head = "HTTP/1.1 \(statusCode) \(reasonPhrase)\r\n"
            + "Content-Type: application/json\r\n"
            + "Content-Length: \(bodyData.count)\r\n"
        if let retryAfter {
            head += "Retry-After: \(Int(ceil(retryAfter)))\r\n"
        }
        head += "Connection: close\r\n\r\n"

        guard let headData = head.data(using: .utf8) else {
            connection.cancel()
            return
        }
        var response = headData
        response.append(bodyData)
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
