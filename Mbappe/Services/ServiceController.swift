import Foundation

/// Starts and stops services.
/// Replace the stub implementation with real launch/stop logic
/// (e.g. `brew services`, `launchctl`, shell commands).
actor ServiceController {
    static let shared = ServiceController()

    private init() {}

    func start(_ service: MbappeService) async throws {
        // TODO: implement real start logic
        // Example: try await shell("brew services start \(service.id)")
        try await Task.sleep(for: .milliseconds(500))
    }

    func stop(_ service: MbappeService) async throws {
        // TODO: implement real stop logic
        // Example: try await shell("brew services stop \(service.id)")
        try await Task.sleep(for: .milliseconds(500))
    }

    // MARK: - Shell helper

    @discardableResult
    private func shell(_ command: String) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw ServiceControlError.commandFailed(command: command, output: output)
        }
        return output
    }
}

enum ServiceControlError: LocalizedError {
    case commandFailed(command: String, output: String)

    var errorDescription: String? {
        switch self {
        case .commandFailed(let command, let output):
            "Command failed: \(command)\n\(output)"
        }
    }
}
