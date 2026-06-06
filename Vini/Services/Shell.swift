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
    /// PATH suitable for Finder-launched app processes. Includes Homebrew,
    /// system paths, and common per-user JS/runtime manager shim locations.
    static func toolSearchPath(currentPath: String?, workingDirectory: String? = nil) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var paths: [String] = []
        if let workingDirectory, !workingDirectory.isEmpty {
            paths.append("\(workingDirectory)/node_modules/.bin")
        }
        paths += [
            "\(home)/.nvm/current/bin",
            "\(home)/.volta/bin",
            "\(home)/.asdf/shims",
            "\(home)/.mise/shims",
            "\(home)/.yarn/bin",
            "\(home)/.config/yarn/global/node_modules/.bin",
            "\(home)/Library/pnpm",
            "\(home)/.bun/bin",
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
        ]
        paths += nvmVersionBinPaths(home: home)
        if let currentPath, !currentPath.isEmpty {
            paths.append(currentPath)
        }
        return paths.uniquedExistingDirectories().joined(separator: ":")
    }

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
        env["PATH"] = toolSearchPath(currentPath: env["PATH"])
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

    private static func nvmVersionBinPaths(home: String) -> [String] {
        let versionsURL = URL(fileURLWithPath: home)
            .appendingPathComponent(".nvm", isDirectory: true)
            .appendingPathComponent("versions", isDirectory: true)
            .appendingPathComponent("node", isDirectory: true)
        guard let versions = try? FileManager.default.contentsOfDirectory(
            at: versionsURL,
            includingPropertiesForKeys: nil
        ) else { return [] }
        return versions
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedDescending }
            .map { $0.appendingPathComponent("bin", isDirectory: true).path }
    }
}

private extension Array where Element == String {
    func uniquedExistingDirectories() -> [String] {
        var seen = Set<String>()
        return filter { path in
            guard !path.isEmpty, seen.insert(path).inserted else { return false }
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
    }
}
