import Foundation

/// A persisted record of a process Vini should re-adopt after a restart.
struct PersistedProcess: Codable, Sendable {
    let serviceID: String
    let pid: Int32
    /// The command line Vini launched, used to verify the PID wasn't recycled.
    let command: String
    let startedAt: Date
}

/// Owns and tracks long-running child processes started for user-defined services.
///
/// Two kinds of tracking:
/// - **owned**: launched by this Vini instance; we hold the `Process` handle.
/// - **adopted**: launched by a previous Vini instance, re-attached by verified
///   PID after a restart (we only have the pid + original command).
///
/// Each service is launched via `zsh` so we can signal the whole process group on
/// stop. Requires a **non-sandboxed** build.
actor ProcessManager {
    static let shared = ProcessManager()

    private enum Tracked {
        case owned(
            process: Process,
            pipe: Pipe,
            reader: PipeLogReader,
            command: String,
            startedAt: Date,
            pgid: pid_t
        )
        case adopted(pid: Int32, command: String, startedAt: Date)
    }

    /// Keyed by service id (e.g. "user:<uuid>").
    private var running: [String: Tracked] = [:]

    /// Service ids whose process this instance owns (live log capture available).
    /// Adopted processes are NOT live-captured.
    func hasLiveCapture(_ serviceID: String) -> Bool {
        if case .owned = running[serviceID] { return true }
        return false
    }

    private let persistenceKey = "vini.keptAliveProcesses"

    private init() {}

    // MARK: - Queries

    /// Whether Vini currently tracks a live process for this service id.
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

    /// Service ids Vini is actively tracking as running.
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
        env["PATH"] = Shell.toolSearchPath(currentPath: env["PATH"], workingDirectory: dir)
        process.environment = env

        // Capture stdout + stderr into the service's log file. `PipeLogReader`
        // owns the EOF teardown that keeps an exited process from spinning a core.
        LogFileManager.writeSessionHeader(serviceID, command: command)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let capturedID = serviceID
        let reader = PipeLogReader(
            handle: pipe.fileHandleForReading,
            sink: LogSink(serviceID: capturedID)
        )
        reader.start()

        do {
            try process.run()
        } catch {
            reader.stop()
            throw ProcessManagerError.launchFailed(error.localizedDescription)
        }

        let startedAt = Date()
        let pid = process.processIdentifier
        // Foundation launches children as process-group leaders, so this is
        // normally == pid. Recorded up front because it cannot be read back once
        // the process has exited.
        let pgid = getpgid(pid) > 0 ? getpgid(pid) : pid

        // Without this, a child that exits on its own (crash, short-lived command)
        // leaves its pipe at EOF and its tracking entry behind forever.
        process.terminationHandler = { [weak self] proc in
            proc.terminationHandler = nil
            Task { await self?.handleChildExit(serviceID: capturedID, pid: proc.processIdentifier) }
        }

        running[serviceID] = .owned(
            process: process,
            pipe: pipe,
            reader: reader,
            command: command,
            startedAt: startedAt,
            pgid: pgid
        )

        if keepAlive {
            persist(PersistedProcess(
                serviceID: serviceID,
                pid: pid,
                command: command,
                startedAt: startedAt
            ))
        }
    }

    /// Called when the directly-launched wrapper shell exits.
    ///
    /// The service itself may still be up — a command that backgrounds or disowns
    /// its real server leaves live members in the same process group — so tracking
    /// is only released once the whole group is gone.
    private func handleChildExit(serviceID: String, pid: pid_t) {
        guard let entry = running[serviceID],
              case .owned(let process, _, let reader, _, _, let pgid) = entry,
              process.processIdentifier == pid
        else { return }

        if !Self.treeMembers(rootPID: pid, pgid: pgid).isEmpty {
            // Survivors still hold the write end of the pipe; keep capturing.
            return
        }

        reader.stop()
        running[serviceID] = nil
        removePersisted(serviceID: serviceID)
    }

    /// Stop the tracked process for `serviceID`. No-op if not tracked.
    ///
    /// Signals the entire process group plus any descendant that escaped it, so a
    /// wrapper shell dying does not leave an orphaned `node`/`vite` holding a port.
    /// Tracking is released immediately (before the grace period) so the UI stays
    /// responsive and re-entrant calls become no-ops.
    func stop(serviceID: String) async {
        guard let entry = running[serviceID] else { return }

        // Release tracking up front: this method suspends below, and leaving the
        // entry in place would let concurrent callers signal the same tree twice.
        running[serviceID] = nil
        removePersisted(serviceID: serviceID)
        if case .owned(_, _, let reader, _, _, _) = entry {
            reader.stop()
        }

        let pid = pidOf(entry)
        let pgid = pgidOf(entry)
        guard pid > 1 else { return }

        Self.signalTree(rootPID: pid, pgid: pgid, signal: SIGTERM)

        // Grace period. `Task.sleep` (not `Thread.sleep`) so the actor stays
        // available — blocking it here is what made start/stop feel dead.
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
            if Self.treeMembers(rootPID: pid, pgid: pgid).isEmpty { return }
        }
        Self.signalTree(rootPID: pid, pgid: pgid, signal: SIGKILL)
    }

    // MARK: - Teardown / quit

    /// Stop only services NOT in `keepAliveServiceIDs`. Kept-alive owned processes
    /// are left running, and their persisted records are refreshed so the next
    /// launch can re-adopt them.
    func handleAppTermination(keepAliveServiceIDs: Set<String>) async {
        // Snapshot: `stop` mutates `running` and suspends.
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
            }
        }

        let doomed = running.keys.filter { !keepAliveServiceIDs.contains($0) }
        // Concurrently, so quitting costs one grace period rather than 3s per service.
        await withTaskGroup(of: Void.self) { group in
            for id in doomed {
                group.addTask { await self.stop(serviceID: id) }
            }
        }
    }

    /// Stop every tracked process unconditionally.
    func stopAll() async {
        await withTaskGroup(of: Void.self) { group in
            for id in running.keys {
                group.addTask { await self.stop(serviceID: id) }
            }
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
        case .owned(let process, _, _, _, _, let pgid):
            if process.isRunning { return true }
            // The wrapper shell can exit while the real server keeps running in the
            // same process group (backgrounded / disowned commands), so a dead
            // direct child does not mean the service is down.
            return !Self.treeMembers(rootPID: process.processIdentifier, pgid: pgid).isEmpty
        case .adopted(let pid, _, _):
            return kill(pid, 0) == 0
        }
    }

    private func pidOf(_ entry: Tracked) -> Int32 {
        switch entry {
        case .owned(let process, _, _, _, _, _): process.processIdentifier
        case .adopted(let pid, _, _):   pid
        }
    }

    /// Process-group id to signal. Recorded at launch for owned processes; resolved
    /// live for adopted ones (their group was not persisted).
    private func pgidOf(_ entry: Tracked) -> pid_t {
        switch entry {
        case .owned(_, _, _, _, _, let pgid):
            return pgid
        case .adopted(let pid, _, _):
            let pgid = getpgid(pid)
            return pgid > 0 ? pgid : pid
        }
    }

    private func commandOf(_ entry: Tracked) -> String {
        switch entry {
        case .owned(_, _, _, let command, _, _):   command
        case .adopted(_, let command, _): command
        }
    }

    private func startedAtOf(_ entry: Tracked) -> Date {
        switch entry {
        case .owned(_, _, _, _, let startedAt, _):   startedAt
        case .adopted(_, _, let startedAt): startedAt
        }
    }

    // MARK: - Process tree signalling

    /// Live pids belonging to a launched service: members of its original process
    /// group, plus descendants of the root pid that escaped the group (daemons that
    /// call `setsid`). Excludes Vini itself and its own group.
    nonisolated static func treeMembers(rootPID: pid_t, pgid: pid_t) -> [pid_t] {
        let table = ProcessTable.snapshot()
        guard !table.isEmpty else { return [] }

        let selfPID = getpid()
        let selfPGID = getpgid(0)
        var found = Set<pid_t>()

        // Guard against ever matching our own group (possible only via pid reuse).
        if pgid > 1, pgid != selfPGID {
            for entry in table where entry.pgid == pgid {
                found.insert(entry.pid)
            }
        }

        var childrenOf: [pid_t: [pid_t]] = [:]
        for entry in table { childrenOf[entry.ppid, default: []].append(entry.pid) }

        var queue = [rootPID]
        var seen = Set<pid_t>()
        while let pid = queue.popLast() {
            guard seen.insert(pid).inserted else { continue }
            found.insert(pid)
            queue.append(contentsOf: childrenOf[pid] ?? [])
        }

        found.remove(selfPID)
        let live = Set(table.map(\.pid))
        return found.filter { $0 > 1 && live.contains($0) }
    }

    /// Signal the whole group, then mop up anything that left it.
    nonisolated static func signalTree(rootPID: pid_t, pgid: pid_t, signal sig: Int32) {
        if pgid > 1, pgid != getpgid(0) {
            _ = killpg(pgid, sig)
        }
        for pid in treeMembers(rootPID: rootPID, pgid: pgid) {
            _ = kill(pid, sig)
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

/// A snapshot of the live process table, read via `sysctl`.
///
/// Used instead of shelling out to `ps`/`pgrep` so that stopping a service costs
/// no subprocesses, and so orphaned descendants can be found even after their
/// parent has died and they were reparented to `launchd`.
enum ProcessTable {
    struct Entry {
        let pid: pid_t
        let ppid: pid_t
        let pgid: pid_t
    }

    static func snapshot() -> [Entry] {
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&name, 4, nil, &size, nil, 0) == 0, size > 0 else { return [] }

        // Over-allocate: processes can be created between sizing and fetching.
        size += size / 4 + MemoryLayout<kinfo_proc>.stride * 64
        var buffer = [kinfo_proc](
            repeating: kinfo_proc(),
            count: size / MemoryLayout<kinfo_proc>.stride
        )
        guard sysctl(&name, 4, &buffer, &size, nil, 0) == 0 else { return [] }

        let count = min(size / MemoryLayout<kinfo_proc>.stride, buffer.count)
        return buffer.prefix(count).map {
            Entry(pid: $0.kp_proc.p_pid, ppid: $0.kp_eproc.e_ppid, pgid: $0.kp_eproc.e_pgid)
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
