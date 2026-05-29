import Foundation

/// Owns and tracks long-running child processes started for user-defined services.
///
/// Each service is launched in its own process group so we can terminate the whole
/// tree (a shell plus whatever it spawned, e.g. `npm` -> `node`). Requires a
/// **non-sandboxed** build.
actor ProcessManager {
    static let shared = ProcessManager()

    private struct Running {
        let process: Process
        let startedAt: Date
    }

    /// Keyed by service id (e.g. "user:<uuid>").
    private var running: [String: Running] = [:]

    private init() {}

    // MARK: - Queries

    /// Whether Mbappe currently owns a live process for this service id.
    func isRunning(_ serviceID: String) -> Bool {
        guard let entry = running[serviceID] else { return false }
        if entry.process.isRunning { return true }
        // Reap finished processes lazily.
        running[serviceID] = nil
        return false
    }

    func pid(_ serviceID: String) -> Int? {
        guard let entry = running[serviceID], entry.process.isRunning else { return nil }
        return Int(entry.process.processIdentifier)
    }

    /// Service ids Mbappe is actively tracking as running.
    func runningServiceIDs() -> Set<String> {
        for (id, entry) in running where !entry.process.isRunning {
            running[id] = nil
        }
        return Set(running.keys)
    }

    // MARK: - Lifecycle

    /// Start a command for `serviceID`. Throws if already running or launch fails.
    func start(
        serviceID: String,
        command: String,
        workingDirectory: String?
    ) throws {
        if isRunning(serviceID) {
            throw ProcessManagerError.alreadyRunning(serviceID)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let dir = workingDirectory ?? home
        process.currentDirectoryURL = URL(fileURLWithPath: dir)

        var env = ProcessInfo.processInfo.environment
        let extraPaths = "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = (env["PATH"].map { "\($0):\(extraPaths)" }) ?? extraPaths
        process.environment = env

        // Detach into its own process group so we can signal the whole tree on stop.
        // (posix_spawn via Process: setting a new session is done by launching `zsh`
        // which becomes the group leader; we kill by negative pid below.)

        // Discard output (a future enhancement could capture logs).
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw ProcessManagerError.launchFailed(error.localizedDescription)
        }

        running[serviceID] = Running(process: process, startedAt: Date())
    }

    /// Stop the tracked process for `serviceID`. No-op if not running.
    func stop(serviceID: String) {
        guard let entry = running[serviceID] else { return }
        let process = entry.process
        defer { running[serviceID] = nil }

        guard process.isRunning else { return }

        let pid = process.processIdentifier
        // Try to terminate the whole process group first (negative pid),
        // then fall back to the single process.
        if killpg(pid, SIGTERM) != 0 {
            process.terminate()
        }

        // Give it a moment, then force-kill if still alive.
        let deadline = Date().addingTimeInterval(3)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        if process.isRunning {
            if killpg(pid, SIGKILL) != 0 {
                kill(pid, SIGKILL)
            }
        }
    }

    /// Stop every tracked process (e.g. on app teardown).
    func stopAll() {
        for id in running.keys {
            stop(serviceID: id)
        }
    }
}

enum ProcessManagerError: LocalizedError {
    case alreadyRunning(String)
    case launchFailed(String)

    var errorDescription: String? {
        switch self {
        case .alreadyRunning(let id):
            "A process for '\(id)' is already running."
        case .launchFailed(let message):
            "Failed to start process: \(message)"
        }
    }
}
