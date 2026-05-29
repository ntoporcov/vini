import Foundation

/// A persisted record of a process Mbappe should re-adopt after a restart.
struct PersistedProcess: Codable, Sendable {
    let serviceID: String
    let pid: Int32
    /// The command line Mbappe launched, used to verify the PID wasn't recycled.
    let command: String
    let startedAt: Date
}

/// Owns and tracks long-running child processes started for user-defined services.
///
/// Two kinds of tracking:
/// - **owned**: launched by this Mbappe instance; we hold the `Process` handle.
/// - **adopted**: launched by a previous Mbappe instance, re-attached by verified
///   PID after a restart (we only have the pid + original command).
///
/// Each service is launched via `zsh` so we can signal the whole process group on
/// stop. Requires a **non-sandboxed** build.
actor ProcessManager {
    static let shared = ProcessManager()

    private enum Tracked {
        case owned(process: Process, command: String, startedAt: Date)
        case adopted(pid: Int32, command: String, startedAt: Date)
    }

    /// Keyed by service id (e.g. "user:<uuid>").
    private var running: [String: Tracked] = [:]

    private let persistenceKey = "mbappe.keptAliveProcesses"

    private init() {}

    // MARK: - Queries

    /// Whether Mbappe currently tracks a live process for this service id.
    func isRunning(_ serviceID: String) -> Bool {
        guard let entry = running[serviceID] else { return false }
        if isAlive(entry) { return true }
        running[serviceID] = nil
        return false
    }

    func pid(_ serviceID: String) -> Int? {
        guard let entry = running[serviceID], isAlive(entry) else { return nil }
        return Int(pidOf(entry))
    }

    /// Service ids Mbappe is actively tracking as running.
    func runningServiceIDs() -> Set<String> {
        for (id, entry) in running where !isAlive(entry) {
            running[id] = nil
        }
        return Set(running.keys)
    }

    // MARK: - Lifecycle

    /// Start a command for `serviceID`. Throws if already running or launch fails.
    /// `keepAlive` records the process so it can be re-adopted after a restart.
    func start(
        serviceID: String,
        command: String,
        workingDirectory: String?,
        keepAlive: Bool = false
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

        // Discard output (a future enhancement could capture logs).
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw ProcessManagerError.launchFailed(error.localizedDescription)
        }

        let startedAt = Date()
        running[serviceID] = .owned(process: process, command: command, startedAt: startedAt)

        if keepAlive {
            persist(PersistedProcess(
                serviceID: serviceID,
                pid: process.processIdentifier,
                command: command,
                startedAt: startedAt
            ))
        }
    }

    /// Stop the tracked process for `serviceID`. No-op if not running.
    func stop(serviceID: String) {
        guard let entry = running[serviceID] else { return }
        defer {
            running[serviceID] = nil
            removePersisted(serviceID: serviceID)
        }
        guard isAlive(entry) else { return }

        let pid = pidOf(entry)
        // Terminate the whole process group first; fall back to the process/pid.
        if killpg(pid, SIGTERM) != 0 {
            if case .owned(let process, _, _) = entry {
                process.terminate()
            } else {
                kill(pid, SIGTERM)
            }
        }

        // Wait briefly, then force-kill if still alive.
        let deadline = Date().addingTimeInterval(3)
        while isAlive(entry) && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        if isAlive(entry) {
            if killpg(pid, SIGKILL) != 0 {
                kill(pid, SIGKILL)
            }
        }
    }

    // MARK: - Teardown / quit

    /// Stop only services NOT in `keepAliveServiceIDs`. Kept-alive owned processes
    /// are left running, and their persisted records are refreshed so the next
    /// launch can re-adopt them.
    func handleAppTermination(keepAliveServiceIDs: Set<String>) {
        for (id, entry) in running {
            if keepAliveServiceIDs.contains(id) {
                // Leave it running; ensure it is persisted for re-adoption.
                if isAlive(entry) {
                    persist(PersistedProcess(
                        serviceID: id,
                        pid: pidOf(entry),
                        command: commandOf(entry),
                        startedAt: startedAtOf(entry)
                    ))
                }
            } else {
                stop(serviceID: id)
            }
        }
    }

    /// Stop every tracked process unconditionally.
    func stopAll() {
        for id in running.keys {
            stop(serviceID: id)
        }
    }

    // MARK: - Re-adoption (on launch)

    /// Re-adopt persisted processes whose PID is still alive AND whose running
    /// command still matches what we launched (guards against PID reuse).
    /// Returns the set of service ids successfully re-adopted.
    @discardableResult
    func adoptPersistedProcesses() -> Set<String> {
        let records = loadPersisted()
        var adopted = Set<String>()
        var survivors: [PersistedProcess] = []

        for record in records {
            if Self.processMatches(pid: record.pid, expectedCommand: record.command) {
                running[record.serviceID] = .adopted(
                    pid: record.pid,
                    command: record.command,
                    startedAt: record.startedAt
                )
                adopted.insert(record.serviceID)
                survivors.append(record)
            }
            // else: process is gone or PID was recycled — drop the record.
        }
        savePersisted(survivors)
        return adopted
    }

    // MARK: - PID verification

    /// Whether `pid` is alive and its current command contains `expectedCommand`.
    nonisolated static func processMatches(pid: Int32, expectedCommand: String) -> Bool {
        guard pid > 0 else { return false }
        // Cheap liveness check first.
        guard kill(pid, 0) == 0 else { return false }

        // Verify the command matches to avoid acting on a recycled PID.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-o", "command=", "-p", "\(pid)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return false
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let current = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !current.isEmpty else { return false }
        // The launched command appears in the ps output for the zsh -lc invocation.
        return current.contains(expectedCommand)
    }

    // MARK: - Tracked helpers

    private func isAlive(_ entry: Tracked) -> Bool {
        switch entry {
        case .owned(let process, _, _):
            return process.isRunning
        case .adopted(let pid, _, _):
            return kill(pid, 0) == 0
        }
    }

    private func pidOf(_ entry: Tracked) -> Int32 {
        switch entry {
        case .owned(let process, _, _): process.processIdentifier
        case .adopted(let pid, _, _):   pid
        }
    }

    private func commandOf(_ entry: Tracked) -> String {
        switch entry {
        case .owned(_, let command, _):   command
        case .adopted(_, let command, _): command
        }
    }

    private func startedAtOf(_ entry: Tracked) -> Date {
        switch entry {
        case .owned(_, _, let startedAt):   startedAt
        case .adopted(_, _, let startedAt): startedAt
        }
    }

    // MARK: - Persistence

    private func loadPersisted() -> [PersistedProcess] {
        guard let data = UserDefaults.standard.data(forKey: persistenceKey),
              let decoded = try? JSONDecoder().decode([PersistedProcess].self, from: data)
        else { return [] }
        return decoded
    }

    private func savePersisted(_ records: [PersistedProcess]) {
        guard let data = try? JSONEncoder().encode(records) else { return }
        UserDefaults.standard.set(data, forKey: persistenceKey)
    }

    private func persist(_ record: PersistedProcess) {
        var records = loadPersisted().filter { $0.serviceID != record.serviceID }
        records.append(record)
        savePersisted(records)
    }

    private func removePersisted(serviceID: String) {
        let records = loadPersisted().filter { $0.serviceID != serviceID }
        savePersisted(records)
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
