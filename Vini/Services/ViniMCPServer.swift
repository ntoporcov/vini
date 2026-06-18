import Darwin
import Foundation
import MCP

actor ViniMCPServer {
    private struct Connection {
        let server: Server
        let transport: ViniMCPUnixSocketTransport
        let task: Task<Void, Never>
    }

    private let servicesStore: ServicesStore
    private var listenFileDescriptor: Int32 = -1
    private var acceptTask: Task<Void, Never>?
    private var connections: [Int32: Connection] = [:]

    init(servicesStore: ServicesStore) {
        self.servicesStore = servicesStore
    }

    var isRunning: Bool {
        listenFileDescriptor >= 0
    }

    func start() async throws {
        guard !isRunning else { return }

        try FileManager.default.createDirectory(
            at: ViniMCPConfiguration.applicationSupportDirectory,
            withIntermediateDirectories: true
        )
        try? FileManager.default.removeItem(at: ViniMCPConfiguration.socketURL)

        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw ViniMCPServerError.posix(operation: "socket", code: errno)
        }

        do {
            try Self.withUnixSocketAddress(path: ViniMCPConfiguration.socketPath) { address, length in
                guard Darwin.bind(fd, address, length) == 0 else {
                    throw ViniMCPServerError.posix(operation: "bind", code: errno)
                }
            }
            guard Darwin.listen(fd, SOMAXCONN) == 0 else {
                throw ViniMCPServerError.posix(operation: "listen", code: errno)
            }
            chmod(ViniMCPConfiguration.socketPath, S_IRUSR | S_IWUSR)
        } catch {
            Darwin.close(fd)
            throw error
        }

        listenFileDescriptor = fd
        acceptTask = Task.detached(priority: .background) { [weak self] in
            await self?.acceptLoop(listenFileDescriptor: fd)
        }
    }

    func stop() async {
        acceptTask?.cancel()
        acceptTask = nil

        if listenFileDescriptor >= 0 {
            Darwin.close(listenFileDescriptor)
            listenFileDescriptor = -1
        }

        for (_, connection) in connections {
            connection.task.cancel()
            await connection.server.stop()
            await connection.transport.disconnect()
        }
        connections.removeAll()
        try? FileManager.default.removeItem(at: ViniMCPConfiguration.socketURL)
    }

    private nonisolated func acceptLoop(listenFileDescriptor fd: Int32) async {
        while !Task.isCancelled {
            let clientFD = Darwin.accept(fd, nil, nil)
            if clientFD >= 0 {
                await handleAcceptedClient(fileDescriptor: clientFD)
                continue
            }

            let err = errno
            if err == EINTR {
                continue
            }
            if err == EBADF || err == EINVAL || Task.isCancelled {
                break
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private func handleAcceptedClient(fileDescriptor clientFD: Int32) async {
        let transport = ViniMCPUnixSocketTransport(fileDescriptor: clientFD)
        let server = makeServer()
        await ViniMCPToolRegistry.registerHandlers(on: server, store: servicesStore)

        let task = Task { [weak self] in
            do {
                try await server.start(transport: transport)
                await server.waitUntilCompleted()
            } catch {
                await transport.disconnect()
            }
            await self?.removeConnection(fileDescriptor: clientFD)
        }

        connections[clientFD] = Connection(server: server, transport: transport, task: task)
    }

    private func removeConnection(fileDescriptor: Int32) {
        connections[fileDescriptor]?.task.cancel()
        connections[fileDescriptor] = nil
    }

    private func makeServer() -> Server {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        return Server(
            name: "vini",
            version: version,
            title: "Vini",
            instructions: """
            Vini controls local developer services configured by the user in the Vini menu-bar app. Use list_services and list_groups first to understand current status and available controls. Port-probed services are read-only. Starting, stopping, or restarting services runs the same actions as the Vini UI.
            """,
            capabilities: .init(
                resources: .init(listChanged: true),
                tools: .init(listChanged: true)
            )
        )
    }

    private static func withUnixSocketAddress<T>(
        path: String,
        _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> T
    ) throws -> T {
        var address = sockaddr_un()
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)

        try withUnsafeMutableBytes(of: &address.sun_path) { rawBuffer in
            try path.withCString { cString in
                let count = strlen(cString) + 1
                guard count <= rawBuffer.count else {
                    throw ViniMCPServerError.socketPathTooLong(path)
                }
                rawBuffer.copyMemory(from: UnsafeRawBufferPointer(start: cString, count: count))
            }
        }

        return try withUnsafePointer(to: &address) { pointer in
            try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                try body(socketAddress, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }
}

enum ViniMCPServerError: LocalizedError {
    case socketPathTooLong(String)
    case posix(operation: String, code: Int32)

    var errorDescription: String? {
        switch self {
        case .socketPathTooLong(let path):
            "MCP socket path is too long: \(path)"
        case .posix(let operation, let code):
            "MCP server \(operation) failed: \(String(cString: strerror(code)))."
        }
    }
}
