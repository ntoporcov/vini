import Foundation
import MCP
import Network

actor ViniMCPServer {
    private let servicesStore: ServicesStore
    private var listener: NWListener?
    private var sessions: [String: SessionContext] = [:]

    /// Sessions idle for longer than this are evicted. Agents frequently reconnect
    /// without sending DELETE, and each abandoned session otherwise keeps an MCP
    /// `Server` and its message-loop task alive forever.
    private static let sessionIdleTimeout: TimeInterval = 30 * 60
    private static let maxSessions = 32

    final class SessionContext {
        let server: Server
        let transport: StatefulHTTPServerTransport
        var lastUsed: Date

        init(server: Server, transport: StatefulHTTPServerTransport) {
            self.server = server
            self.transport = transport
            self.lastUsed = Date()
        }
    }

    init(servicesStore: ServicesStore) {
        self.servicesStore = servicesStore
    }

    var isRunning: Bool {
        listener != nil
    }

    func start(port: Int) async throws {
        guard !isRunning else { return }

        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(exactly: port) ?? 0), port > 0 else {
            throw ViniMCPServerError.invalidPort(port)
        }

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        // Bind loopback only. Without this the listener accepts LAN connections,
        // which would let any host on the network start/stop services and read
        // logs. Note: the port must come from `requiredLocalEndpoint` rather than
        // `NWListener(using:on:)` — specifying both fails with EINVAL.
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: nwPort)

        let nwListener = try NWListener(using: params)

        nwListener.stateUpdateHandler = { state in
            switch state {
            case .failed(let error):
                NSLog("Vini MCP HTTP listener failed: \(error)")
            default:
                break
            }
        }

        nwListener.newConnectionHandler = { [weak self] connection in
            Task { await self?.handleNewConnection(connection) }
        }

        nwListener.start(queue: .global(qos: .userInitiated))
        listener = nwListener
    }

    func stop() async {
        listener?.cancel()
        listener = nil
        for (_, ctx) in sessions {
            await teardown(ctx)
        }
        sessions.removeAll()
    }

    /// Fully tear a session down. Cancelling the transport alone leaves the MCP
    /// `Server`'s receive-loop task running for the lifetime of the app.
    private func teardown(_ ctx: SessionContext) async {
        await ctx.server.stop()
        await ctx.transport.disconnect()
    }

    private func evictStaleSessions() async {
        let now = Date()
        var stale = sessions.filter { now.timeIntervalSince($0.value.lastUsed) > Self.sessionIdleTimeout }

        // Hard cap as a backstop against rapid reconnect churn.
        if sessions.count - stale.count > Self.maxSessions {
            let survivors = sessions
                .filter { stale[$0.key] == nil }
                .sorted { $0.value.lastUsed < $1.value.lastUsed }
            for (key, ctx) in survivors.prefix(sessions.count - stale.count - Self.maxSessions) {
                stale[key] = ctx
            }
        }

        for (key, ctx) in stale {
            sessions.removeValue(forKey: key)
            await teardown(ctx)
        }
    }

    // MARK: - Connection handling

    private nonisolated func handleNewConnection(_ connection: NWConnection) async {
        connection.start(queue: .global(qos: .userInitiated))
        await readHTTPRequest(connection: connection)
    }

    private nonisolated func readHTTPRequest(connection: NWConnection) async {
        // Read until the headers are complete and the body matches Content-Length.
        // A single `receive` only returns the first TCP segment, so large
        // initialize/tools-call bodies used to arrive truncated and fail to decode,
        // which surfaced to agents as a dropped connection.
        guard let data = await receiveFullRequest(connection: connection) else {
            connection.cancel()
            return
        }

        guard let (request, path) = parseHTTPRequest(data) else {
            let response = "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n"
            sendRawAndClose(connection: connection, data: Data(response.utf8))
            return
        }

        // Only accept /mcp endpoint
        guard path == "/mcp" else {
            let body = "{\"error\":\"Not Found\"}"
            let response = "HTTP/1.1 404 Not Found\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
            sendRawAndClose(connection: connection, data: Data(response.utf8))
            return
        }

        await self.routeRequest(request, connection: connection)
    }

    private nonisolated func receiveFullRequest(connection: NWConnection) async -> Data? {
        let maxRequestBytes = 8 * 1024 * 1024
        var buffer = Data()

        while true {
            let separator = Data("\r\n\r\n".utf8)
            if let headerRange = buffer.range(of: separator) {
                let headerText = String(decoding: buffer[..<headerRange.lowerBound], as: UTF8.self)
                let expected = Self.contentLength(inHeaders: headerText) ?? 0
                let bodyCount = buffer.distance(from: headerRange.upperBound, to: buffer.endIndex)
                if bodyCount >= expected { return buffer }
            }
            guard buffer.count < maxRequestBytes else { return buffer }

            let chunk = await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { content, _, isComplete, error in
                    if let error {
                        NSLog("Vini MCP: connection receive error: \(error)")
                        continuation.resume(returning: nil)
                        return
                    }
                    if content == nil || isComplete {
                        continuation.resume(returning: content ?? Data())
                        return
                    }
                    continuation.resume(returning: content)
                }
            }

            guard let chunk, !chunk.isEmpty else {
                return buffer.isEmpty ? nil : buffer
            }
            buffer.append(chunk)
        }
    }

    static func contentLength(inHeaders headers: String) -> Int? {
        for line in headers.components(separatedBy: "\r\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces)
            guard name.caseInsensitiveCompare("Content-Length") == .orderedSame else { continue }
            return Int(line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    private func routeRequest(_ request: HTTPRequest, connection: NWConnection) async {
        let sessionID = request.header("MCP-Session-Id")

        // Route to existing session
        if let sessionID, let ctx = sessions[sessionID] {
            ctx.lastUsed = Date()
            let response = await ctx.transport.handleRequest(request)
            if request.method.uppercased() == "DELETE" && response.statusCode == 200 {
                sessions.removeValue(forKey: sessionID)
                await teardown(ctx)
            }
            await sendHTTPResponse(response, connection: connection)
            return
        }

        // Stale session ID — tell client to re-initialize
        if sessionID != nil {
            let body = "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32600,\"message\":\"Session not found or expired. Re-initialize.\"},\"id\":null}"
            let raw = "HTTP/1.1 404 Not Found\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
            sendRawAndClose(connection: connection, data: Data(raw.utf8))
            return
        }

        // No session ID — only allow POST with initialize body
        if request.method.uppercased() == "POST", isInitializeRequest(request.body) {
            await evictStaleSessions()
            let ctx = await createSession()
            let response = await ctx.transport.handleRequest(request)

            // Extract session ID from response headers
            if let newSessionID = response.headers["MCP-Session-Id"] {
                sessions[newSessionID] = ctx
            } else {
                // Nothing will ever reference this session; don't leak its task.
                await teardown(ctx)
            }

            await sendHTTPResponse(response, connection: connection)
            return
        }

        // Non-initialize request without session
        let body = "{\"jsonrpc\":\"2.0\",\"error\":{\"code\":-32600,\"message\":\"Bad Request: Send an initialize request first.\"},\"id\":null}"
        let raw = "HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
        sendRawAndClose(connection: connection, data: Data(raw.utf8))
    }

    private nonisolated func isInitializeRequest(_ body: Data?) -> Bool {
        guard let body,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let method = json["method"] as? String else {
            return false
        }
        return method == "initialize"
    }

    private func createSession() async -> SessionContext {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        let transport = StatefulHTTPServerTransport()
        let server = Server(
            name: "vini",
            version: version,
            title: "Vini",
            instructions: """
            Vini controls local developer services configured by the user in the Vini menu-bar app. \
            Use list_services and list_groups first to understand current status and available controls. \
            Port-probed services are read-only. Starting, stopping, or restarting services runs the same \
            actions as the Vini UI.
            """,
            capabilities: .init(
                resources: .init(listChanged: true),
                tools: .init(listChanged: true)
            )
        )
        await ViniMCPToolRegistry.registerHandlers(on: server, store: servicesStore)
        do {
            try await server.start(transport: transport)
        } catch {
            // Silently swallowing this leaves a session that accepts requests and
            // emits SSE priming events but never answers them.
            NSLog("Vini MCP: server.start failed: \(error)")
        }
        return SessionContext(server: server, transport: transport)
    }

    // MARK: - HTTP parsing

    private nonisolated func parseHTTPRequest(_ data: Data) -> (HTTPRequest, String)? {
        // Decode only the header block: the body may not be valid UTF-8, and
        // decoding the whole request would reject it outright.
        let separator = Data("\r\n\r\n".utf8)
        let headerData: Data
        var body: Data?
        if let range = data.range(of: separator) {
            headerData = data[..<range.lowerBound]
            let bodyData = data[range.upperBound...]
            body = bodyData.isEmpty ? nil : Data(bodyData)
        } else {
            headerData = data
        }

        guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }

        let parts = requestLine.split(separator: " ", maxSplits: 2)
        guard parts.count >= 2 else { return nil }

        let method = String(parts[0])
        let path = String(parts[1]).split(separator: "?").first.map(String.init) ?? String(parts[1])

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colonIndex = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<colonIndex]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colonIndex)...]).trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        let httpRequest = HTTPRequest(method: method, headers: headers, body: body, path: path)
        return (httpRequest, path)
    }

    // MARK: - HTTP response writing

    private nonisolated func sendHTTPResponse(_ response: HTTPResponse, connection: NWConnection) async {
        switch response {
        case .stream(let stream, let headers):
            // Send headers with chunked/SSE
            var headerString = "HTTP/1.1 200 OK\r\n"
            for (name, value) in headers {
                headerString += "\(name): \(value)\r\n"
            }
            headerString += "\r\n"
            await send(connection: connection, data: Data(headerString.utf8))

            // Stream SSE events. Each chunk is awaited so that (a) the final
            // response is actually flushed before the stream closes, and (b) a slow
            // client applies backpressure instead of buffering without bound.
            do {
                for try await chunk in stream {
                    await send(connection: connection, data: chunk)
                }
            } catch {
                // Stream ended
            }
            // `routeResponse` finishes the stream immediately after yielding the
            // final message, so cancelling without flushing here would drop it.
            await closeGracefully(connection: connection)

        default:
            let statusCode = response.statusCode
            let statusText = HTTPStatusText.text(for: statusCode)
            var headerString = "HTTP/1.1 \(statusCode) \(statusText)\r\n"
            for (name, value) in response.headers {
                headerString += "\(name): \(value)\r\n"
            }
            let bodyData = response.bodyData ?? Data()
            headerString += "Content-Length: \(bodyData.count)\r\n"
            headerString += "\r\n"

            var fullResponse = Data(headerString.utf8)
            fullResponse.append(bodyData)
            sendRawAndClose(connection: connection, data: fullResponse)
        }
    }

    /// Send and wait for the data to be handed to the transport.
    private nonisolated func send(connection: NWConnection, data: Data) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            connection.send(
                content: data,
                completion: .contentProcessed { _ in continuation.resume() }
            )
        }
    }

    /// Close the write side, then cancel once everything queued has drained.
    private nonisolated func closeGracefully(connection: NWConnection) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            connection.send(
                content: nil,
                isComplete: true,
                completion: .contentProcessed { _ in
                    connection.cancel()
                    continuation.resume()
                }
            )
        }
    }

    private nonisolated func sendRaw(connection: NWConnection, data: Data) {
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    private nonisolated func sendRawAndClose(connection: NWConnection, data: Data) {
        connection.send(content: data, isComplete: true, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

enum ViniMCPServerError: LocalizedError {
    case invalidPort(Int)

    var errorDescription: String? {
        switch self {
        case .invalidPort(let port):
            "Invalid MCP server port: \(port). Must be between 1 and 65535."
        }
    }
}

private enum HTTPStatusText {
    static func text(for code: Int) -> String {
        switch code {
        case 200: "OK"
        case 202: "Accepted"
        case 400: "Bad Request"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 409: "Conflict"
        case 500: "Internal Server Error"
        default: "Unknown"
        }
    }
}
