import Foundation

/// Result of running a shell command.
struct ShellResult: Sendable {
    let exitCode: Int32
    let stdout: String
    let stderr: String

    var succeeded: Bool { exitCode == 0 }
}

enum ShellError: LocalizedError {
    case launchFailed(String)
    case nonZeroExit(command: String, result: ShellResult)

    var errorDescription: String? {
        switch self {
        case .launchFailed(let message):
            "Failed to launch command: \(message)"
        case .nonZeroExit(let command, let result):
            "Command failed (exit \(result.exitCode)): \(command)\n\(result.stderr.isEmpty ? result.stdout : result.stderr)"
        }
    }
}

/// Runs external processes for service discovery and control.
///
/// This relies on the app being **non-sandboxed** (Developer ID distribution).
/// A sandboxed Mac App Store build cannot spawn arbitrary executables.
enum Shell {
    /// Run a binary directly with arguments (preferred — no shell parsing).
    @discardableResult
    static func run(
        _ launchPath: String,
        _ arguments: [String] = [],
        environment: [String: String]? = nil,
        throwOnFailure: Bool = false
    ) throws -> ShellResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments

        var env = ProcessInfo.processInfo.environment
        // Ensure common tool paths are present even when launched from Finder.
        let extraPaths = "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = (env["PATH"].map { "\($0):\(extraPaths)" }) ?? extraPaths
        if let environment {
            for (key, value) in environment { env[key] = value }
        }
        process.environment = env

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
        } catch {
            throw ShellError.launchFailed(error.localizedDescription)
        }

        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let result = ShellResult(
            exitCode: process.terminationStatus,
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? ""
        )

        if throwOnFailure && !result.succeeded {
            throw ShellError.nonZeroExit(
                command: "\(launchPath) \(arguments.joined(separator: " "))",
                result: result
            )
        }
        return result
    }

    /// Run a command line through `/bin/zsh -lc` (for user-defined commands).
    @discardableResult
    static func runScript(_ command: String, throwOnFailure: Bool = false) throws -> ShellResult {
        try run("/bin/zsh", ["-lc", command], throwOnFailure: throwOnFailure)
    }

    // MARK: - Tool discovery

    /// Resolve the Homebrew binary, preferring Apple Silicon location.
    static func brewPath() -> String? {
        let candidates = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static let launchctlPath = "/bin/launchctl"
    static let lsofPath = "/usr/sbin/lsof"
}
