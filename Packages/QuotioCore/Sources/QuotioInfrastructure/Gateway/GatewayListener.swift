import Foundation
import Network
import QuotioApplication
import QuotioDomain

/// Agent-facing TCP front door. Binds the user-visible port (loopback-only
/// unless LAN sharing is enabled), parses each accepted connection with
/// `HTTP1RequestParser`, and byte-forwards the request to CPA on the internal
/// loopback port.
///
/// The listener forces `Connection: close` upstream and recomputes
/// `Content-Length`, so every connection carries exactly one request. The
/// response is relayed back verbatim until upstream closes.
///
/// `route(_:)` is the seam where Tasks 15/25 install Qoder/OpenCode
/// interception; today every request is `.passthrough`.
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
    /// ID, so an agent disconnect can cancel them promptly. Passthrough uses
    /// NWConnection callbacks only; the map is the hook Task 15's Qoder pump
    /// registers into.
    private var pumpTasks: [Int: Task<Void, Never>] = [:]

    private var activeConnections = 0
    private var nextConnectionID = 0
    private let maxActiveConnections = 100
    private nonisolated static let connectionTimeoutSeconds: UInt64 = 10

    private var readyContinuation: CheckedContinuation<Result<Void, Error>, Never>?

    public init() {}

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
        let upstreamPort = self.upstreamPort

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
            upstreamPort: upstreamPort,
            parser: HTTP1RequestParser()
        )
    }

    private func connectionEnded(_ connectionID: Int) {
        activeConnections -= 1
        pumpTasks.removeValue(forKey: connectionID)?.cancel()
    }

    // MARK: - Request receiving

    /// Drives `HTTP1RequestParser` on every receive callback. A parser is a
    /// value type owned per connection — exactly one request per connection,
    /// because the upstream is always sent `Connection: close`.
    private nonisolated static func receiveRequest(
        from connection: NWConnection,
        upstreamPort: UInt16,
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
                    receiveRequest(from: connection, upstreamPort: upstreamPort, parser: nextParser)
                }
            case .complete(let request):
                switch route(request) {
                case .passthrough:
                    forwardRequest(
                        request: request,
                        originalConnection: connection,
                        upstreamPort: upstreamPort
                    )
                }
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

    /// Routing seam. Tasks 15/25 extend this with the Qoder/OpenCode gates and
    /// routers; until then every request forwards to CPA.
    private nonisolated static func route(_ request: HTTP1Request) -> GatewayDisposition {
        .passthrough
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

    // MARK: - Error responses

    /// Minimal OpenAI error envelope. Task 15 swaps this for the ported
    /// `QoderOpenAIError` builder (status→type/code map, JSON pass-through).
    private nonisolated static func sendError(
        to connection: NWConnection,
        statusCode: Int,
        message: String
    ) {
        let bodyData: Data
        if let encoded = try? JSONSerialization.data(withJSONObject: [
            "error": ["message": message, "type": "server_error"],
        ]) {
            bodyData = encoded
        } else {
            bodyData = Data(#"{"error":{"type":"server_error"}}"#.utf8)
        }

        let reasonPhrase: String
        switch statusCode {
        case 400: reasonPhrase = "Bad Request"
        case 413: reasonPhrase = "Content Too Large"
        case 502: reasonPhrase = "Bad Gateway"
        case 504: reasonPhrase = "Gateway Timeout"
        default: reasonPhrase = "Internal Server Error"
        }

        let head = "HTTP/1.1 \(statusCode) \(reasonPhrase)\r\n"
            + "Content-Type: application/json\r\n"
            + "Content-Length: \(bodyData.count)\r\n"
            + "Connection: close\r\n"
            + "\r\n"
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
