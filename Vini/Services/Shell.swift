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
    /// Ceiling for control operations (`brew services start`, user stop commands),
    /// which can legitimately be slow on a cold run.
    static let defaultTimeout: TimeInterval = 60

    /// Tighter ceiling for discovery. Discovery runs on every refresh and must not
    /// wedge the UI if a tool hangs (e.g. `lsof` against a stale network mount).
    static let discoveryTimeout: TimeInterval = 15

    /// PATH suitable for Finder-launched app processes. Includes Homebrew,
    /// system paths, and common per-user JS/runtime manager shim locations.
    ///
    /// The no-working-directory result is cached: building it stats ~16 paths and
    /// lists the nvm versions directory, and it used to run on every `run()` call.
    static func toolSearchPath(currentPath: String?, workingDirectory: String? = nil) -> String {
        guard workingDirectory == nil || workingDirectory?.isEmpty == true else {
            return buildToolSearchPath(currentPath: currentPath, workingDirectory: workingDirectory)
        }
        return basePathCache.value(for: currentPath ?? "") {
            buildToolSearchPath(currentPath: currentPath, workingDirectory: nil)
        }
    }

    private static let basePathCache = PathCache()

    private static func buildToolSearchPath(currentPath: String?, workingDirectory: String?) -> String {
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
        throwOnFailure: Bool = false,
        timeout: TimeInterval = Shell.defaultTimeout
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

        // Both pipes must be drained concurrently. Reading stdout to EOF first
        // deadlocks whenever the child fills the ~64KB stderr buffer (brew emits
        // deprecation warnings there): the child blocks writing stderr, so stdout
        // never reaches EOF.
        let collector = OutputCollector()
        let group = DispatchGroup()
        for (handle, isStdout) in [
            (outPipe.fileHandleForReading, true),
            (errPipe.fileHandleForReading, false),
        ] {
            DispatchQueue.global(qos: .userInitiated).async(group: group) {
                let data = handle.readDataToEndOfFile()
                collector.store(data, isStdout: isStdout)
            }
        }

        var timedOut = false
        if group.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            // Kill the group: the child may have spawned its own children which
            // would otherwise keep the pipes open and the readers parked.
            let pid = process.processIdentifier
            let pgid = getpgid(pid) > 0 ? getpgid(pid) : pid
            ProcessManager.signalTree(rootPID: pid, pgid: pgid, signal: SIGKILL)
            _ = group.wait(timeout: .now() + 2)
        }
        process.waitUntilExit()

        let result = ShellResult(
            exitCode: timedOut ? -1 : process.terminationStatus,
            stdout: collector.stdoutString,
            stderr: timedOut
                ? "Timed out after \(Int(timeout))s"
                : collector.stderrString
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
    static func runScript(
        _ command: String,
        throwOnFailure: Bool = false,
        timeout: TimeInterval = Shell.defaultTimeout
    ) throws -> ShellResult {
        try run("/bin/zsh", ["-lc", command], throwOnFailure: throwOnFailure, timeout: timeout)
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

/// Memoises the computed tool search PATH.
///
/// `@unchecked Sendable`: state is guarded by `lock`. A lock-protected class is used
/// rather than `nonisolated(unsafe)` mutable global state.
private final class PathCache: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String: String] = [:]

    func value(for key: String, build: () -> String) -> String {
        lock.lock()
        if let cached = entries[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        // Built outside the lock: it touches the filesystem.
        let built = build()

        lock.lock()
        entries[key] = built
        lock.unlock()
        return built
    }
}

/// Accumulates stdout/stderr written from two concurrent reader queues.
///
/// `@unchecked Sendable`: all state is guarded by `lock`.
private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var stdout = Data()
    private var stderr = Data()

    func store(_ data: Data, isStdout: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if isStdout { stdout.append(data) } else { stderr.append(data) }
    }

    var stdoutString: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: stdout, as: UTF8.self)
    }

    var stderrString: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: stderr, as: UTF8.self)
    }
}

private extension Array where Element == String {    func uniquedExistingDirectories() -> [String] {
        var seen = Set<String>()
        return filter { path in
            guard !path.isEmpty, seen.insert(path).inserted else { return false }
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
    }
}
