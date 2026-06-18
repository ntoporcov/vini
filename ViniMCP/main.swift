import Darwin
import Foundation

signal(SIGPIPE, SIG_IGN)

let socketPath = configuredSocketPath()

do {
    let socketFD = try connectUnixSocket(path: socketPath)
    DispatchQueue.global(qos: .userInitiated).async {
        copyBytes(from: STDIN_FILENO, to: socketFD)
        shutdown(socketFD, SHUT_WR)
    }
    copyBytes(from: socketFD, to: STDOUT_FILENO)
    shutdown(socketFD, SHUT_RDWR)
    close(socketFD)
} catch {
    writeStderr("Vini MCP relay failed: \(error.localizedDescription)\nStart Vini, enable MCP Server in Settings, then try again.\n")
    exit(1)
}

private func configuredSocketPath() -> String {
    let arguments = CommandLine.arguments
    if let index = arguments.firstIndex(of: "--socket"), arguments.indices.contains(index + 1) {
        return arguments[index + 1]
    }
    if let envPath = ProcessInfo.processInfo.environment["VINI_MCP_SOCKET"], !envPath.isEmpty {
        return envPath
    }
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    return base
        .appendingPathComponent("Vini", isDirectory: true)
        .appendingPathComponent("mcp.sock", isDirectory: false)
        .path
}

private func connectUnixSocket(path: String) throws -> Int32 {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else {
        throw RelayError.posix(operation: "socket", code: errno)
    }

    do {
        try withUnixSocketAddress(path: path) { address, length in
            guard connect(fd, address, length) == 0 else {
                throw RelayError.posix(operation: "connect", code: errno)
            }
        }
        return fd
    } catch {
        close(fd)
        throw error
    }
}

private func copyBytes(from source: Int32, to destination: Int32) {
    var buffer = [UInt8](repeating: 0, count: 16 * 1024)

    while true {
        let bytesRead = buffer.withUnsafeMutableBytes { rawBuffer -> Int in
            guard let baseAddress = rawBuffer.baseAddress else { return 0 }
            return read(source, baseAddress, rawBuffer.count)
        }

        if bytesRead > 0 {
            guard writeAll(destination, bytes: buffer, count: bytesRead) else { return }
            continue
        }

        if bytesRead == 0 { return }
        if errno == EINTR { continue }
        return
    }
}

private func writeAll(_ fd: Int32, bytes: [UInt8], count: Int) -> Bool {
    var offset = 0

    while offset < count {
        let written = bytes.withUnsafeBytes { rawBuffer -> Int in
            guard let baseAddress = rawBuffer.baseAddress else { return 0 }
            return write(fd, baseAddress.advanced(by: offset), count - offset)
        }

        if written > 0 {
            offset += written
            continue
        }

        if written == 0 { return false }
        if errno == EINTR { continue }
        return false
    }

    return true
}

private func writeStderr(_ message: String) {
    guard let data = message.data(using: .utf8) else { return }
    data.withUnsafeBytes { rawBuffer in
        guard let baseAddress = rawBuffer.baseAddress else { return }
        _ = write(STDERR_FILENO, baseAddress, rawBuffer.count)
    }
}

private func withUnixSocketAddress<T>(
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
                throw RelayError.socketPathTooLong(path)
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

private enum RelayError: LocalizedError {
    case socketPathTooLong(String)
    case posix(operation: String, code: Int32)

    var errorDescription: String? {
        switch self {
        case .socketPathTooLong(let path):
            "Socket path is too long: \(path)"
        case .posix(let operation, let code):
            "\(operation) failed: \(String(cString: strerror(code)))."
        }
    }
}
