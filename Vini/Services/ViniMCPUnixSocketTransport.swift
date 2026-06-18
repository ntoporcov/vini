import Darwin
import Foundation
import Logging
import MCP

actor ViniMCPUnixSocketTransport: Transport {
    nonisolated let logger: Logger

    private let fileDescriptor: Int32
    private let onDisconnect: (@Sendable () async -> Void)?
    private var isConnected = false
    private var didClose = false
    private let messageStream: AsyncThrowingStream<Data, Error>
    private let messageContinuation: AsyncThrowingStream<Data, Error>.Continuation

    init(fileDescriptor: Int32, onDisconnect: (@Sendable () async -> Void)? = nil) {
        self.fileDescriptor = fileDescriptor
        self.onDisconnect = onDisconnect
        self.logger = Logger(label: "vini.mcp.transport.unix-socket")

        var continuation: AsyncThrowingStream<Data, Error>.Continuation!
        self.messageStream = AsyncThrowingStream { continuation = $0 }
        self.messageContinuation = continuation
    }

    func connect() async throws {
        guard !isConnected else { return }
        try setNonBlocking(fileDescriptor)
        isConnected = true
        Task { await readLoop() }
    }

    func disconnect() async {
        guard isConnected || !didClose else { return }
        isConnected = false
        messageContinuation.finish()
        closeIfNeeded()
    }

    func send(_ data: Data) async throws {
        guard isConnected else { throw ViniMCPTransportError.notConnected }

        var remaining = data
        remaining.append(UInt8(ascii: "\n"))

        while !remaining.isEmpty {
            let written = remaining.withUnsafeBytes { rawBuffer -> Int in
                guard let baseAddress = rawBuffer.baseAddress else { return 0 }
                return Darwin.write(fileDescriptor, baseAddress, rawBuffer.count)
            }

            if written > 0 {
                remaining.removeFirst(written)
                continue
            }

            if written == 0 {
                throw ViniMCPTransportError.connectionClosed
            }

            let err = errno
            if err == EAGAIN || err == EWOULDBLOCK {
                try await Task.sleep(for: .milliseconds(10))
                continue
            }
            throw ViniMCPTransportError.posix(operation: "write", code: err)
        }
    }

    func receive() -> AsyncThrowingStream<Data, Error> {
        messageStream
    }

    private func readLoop() async {
        var buffer = [UInt8](repeating: 0, count: 4096)
        var pendingData = Data()

        while isConnected && !Task.isCancelled {
            let bytesRead = buffer.withUnsafeMutableBytes { rawBuffer -> Int in
                guard let baseAddress = rawBuffer.baseAddress else { return 0 }
                return Darwin.read(fileDescriptor, baseAddress, rawBuffer.count)
            }

            if bytesRead > 0 {
                pendingData.append(Data(buffer[..<bytesRead]))
                while let newlineIndex = pendingData.firstIndex(of: UInt8(ascii: "\n")) {
                    let messageData = pendingData[..<newlineIndex]
                    pendingData = pendingData[(newlineIndex + 1)...]
                    if !messageData.isEmpty {
                        messageContinuation.yield(Data(messageData))
                    }
                }
                continue
            }

            if bytesRead == 0 {
                break
            }

            let err = errno
            if err == EAGAIN || err == EWOULDBLOCK {
                try? await Task.sleep(for: .milliseconds(10))
                continue
            }

            messageContinuation.finish(throwing: ViniMCPTransportError.posix(operation: "read", code: err))
            await onDisconnect?()
            await disconnect()
            return
        }

        messageContinuation.finish()
        await onDisconnect?()
        await disconnect()
    }

    private func setNonBlocking(_ fd: Int32) throws {
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0 else {
            throw ViniMCPTransportError.posix(operation: "fcntl(F_GETFL)", code: errno)
        }
        guard fcntl(fd, F_SETFL, flags | O_NONBLOCK) >= 0 else {
            throw ViniMCPTransportError.posix(operation: "fcntl(F_SETFL)", code: errno)
        }
    }

    private func closeIfNeeded() {
        guard !didClose else { return }
        didClose = true
        Darwin.close(fileDescriptor)
    }
}

enum ViniMCPTransportError: LocalizedError {
    case notConnected
    case connectionClosed
    case posix(operation: String, code: Int32)

    var errorDescription: String? {
        switch self {
        case .notConnected:
            "MCP transport is not connected."
        case .connectionClosed:
            "MCP transport connection closed."
        case .posix(let operation, let code):
            "MCP transport \(operation) failed: \(String(cString: strerror(code)))."
        }
    }
}
