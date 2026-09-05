import XCTest
@testable import Vini

final class ProcessManagerTests: XCTestCase {

    func testStartTrackAndStop() async throws {
        let manager = ProcessManager.shared
        let id = "user:test-\(UUID().uuidString)"

        // Long-running command so we can observe it as running.
        try await manager.start(serviceID: id, command: "sleep 30", workingDirectory: nil)

        var running = await manager.isRunning(id)
        XCTAssertTrue(running)
        let ids = await manager.runningServiceIDs()
        XCTAssertTrue(ids.contains(id))

        await manager.stop(serviceID: id)
        running = await manager.isRunning(id)
        XCTAssertFalse(running)
    }

    func testStartingSameIdTwiceThrows() async throws {
        let manager = ProcessManager.shared
        let id = "user:dup-\(UUID().uuidString)"
        try await manager.start(serviceID: id, command: "sleep 30", workingDirectory: nil)
        defer { Task { await manager.stop(serviceID: id) } }

        do {
            try await manager.start(serviceID: id, command: "sleep 30", workingDirectory: nil)
            XCTFail("Expected alreadyRunning error")
        } catch {
            // expected
        }
        await manager.stop(serviceID: id)
    }

    func testShortCommandFinishesAndIsNotRunning() async throws {
        let manager = ProcessManager.shared
        let id = "user:quick-\(UUID().uuidString)"
        try await manager.start(serviceID: id, command: "true", workingDirectory: nil)

        // Give it a moment to exit.
        try await Task.sleep(for: .milliseconds(300))
        let running = await manager.isRunning(id)
        XCTAssertFalse(running)
    }

    // MARK: - PID verification (re-adoption safety)

    func testProcessMatchesAliveWithMatchingCommand() throws {
        let marker = "vini-test-\(UUID().uuidString)"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "sleep 30 # \(marker)"]
        try process.run()
        defer { process.terminate() }

        let pid = process.processIdentifier
        XCTAssertTrue(ProcessManager.processMatches(pid: pid, expectedCommand: marker))
    }

    func testProcessMatchesFailsOnMismatchedCommand() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "sleep 30 # real-command"]
        try process.run()
        defer { process.terminate() }

        let pid = process.processIdentifier
        // PID is alive, but the command does not match -> must NOT adopt.
        XCTAssertFalse(ProcessManager.processMatches(pid: pid, expectedCommand: "totally-different-command"))
    }

    func testProcessMatchesFailsForDeadPID() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "true"]
        try process.run()
        process.waitUntilExit()

        let pid = process.processIdentifier
        XCTAssertFalse(ProcessManager.processMatches(pid: pid, expectedCommand: "true"))
    }

    func testProcessMatchesFailsForInvalidPID() {
        XCTAssertFalse(ProcessManager.processMatches(pid: -1, expectedCommand: "anything"))
        XCTAssertFalse(ProcessManager.processMatches(pid: 0, expectedCommand: "anything"))
    }

    // MARK: - Log capture

    func testProcessOutputIsCapturedToLogFile() async throws {
        let manager = ProcessManager.shared
        let id = "user:logcap-\(UUID().uuidString)"
        let marker = "hello-\(UUID().uuidString)"
        LogFileManager.clear(id)

        try await manager.start(serviceID: id, command: "echo \(marker)", workingDirectory: nil)

        // Wait for the process to finish and the pipe handler to flush.
        try await Task.sleep(for: .milliseconds(500))

        let logs = LogFileManager.readTail(id)
        XCTAssertTrue(logs.contains(marker), "expected captured output to contain \(marker), got: \(logs)")
        await manager.stop(serviceID: id)
        LogFileManager.clear(id)
    }

    // MARK: - Regression: EOF busy-spin

    /// A file descriptor at EOF is *permanently* readable. A `readabilityHandler`
    /// that returns without uninstalling itself therefore makes the dispatch source
    /// re-fire in a tight loop — ~1M callbacks/sec, a saturated CPU core for every
    /// service whose process has exited. `PipeLogReader` must uninstall at EOF.
    func testPipeLogReaderUninstallsItselfAtEOF() async throws {
        let id = "user:eof-\(UUID().uuidString)"
        LogFileManager.clear(id)
        defer { LogFileManager.clear(id) }

        let pipe = Pipe()
        let reader = PipeLogReader(
            handle: pipe.fileHandleForReading,
            sink: LogSink(serviceID: id)
        )
        reader.start()
        XCTAssertTrue(reader.isReading)

        try pipe.fileHandleForWriting.write(contentsOf: Data("hello\n".utf8))
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(reader.isReading, "reader stopped while the pipe was still open")

        // Closing the only writer puts the read end at EOF.
        try pipe.fileHandleForWriting.close()

        var uninstalled = false
        for _ in 0..<40 {
            try await Task.sleep(for: .milliseconds(50))
            if !reader.isReading {
                uninstalled = true
                break
            }
        }

        XCTAssertTrue(
            uninstalled,
            "readabilityHandler still installed after EOF — this is the CPU busy-spin"
        )
        XCTAssertTrue(LogFileManager.readTail(id).contains("hello"), "output was not captured")
    }

    /// `stop()` must be safe to call repeatedly.
    func testPipeLogReaderStopIsIdempotent() {
        let id = "user:eof2-\(UUID().uuidString)"
        defer { LogFileManager.clear(id) }
        let pipe = Pipe()
        let reader = PipeLogReader(
            handle: pipe.fileHandleForReading,
            sink: LogSink(serviceID: id)
        )
        reader.start()
        reader.stop()
        reader.stop()
        XCTAssertFalse(reader.isReading)
    }

    // MARK: - Regression: orphaned process group

    /// The wrapper shell can exit while the real server keeps running in the same
    /// process group (backgrounded / disowned commands). The old `stop` guarded on
    /// `Process.isRunning` and returned early, leaving that server alive forever
    /// holding its port. `stop` must signal the whole tree regardless.
    func testStopKillsSurvivorsAfterWrapperShellExits() async throws {
        let manager = ProcessManager.shared
        let id = "user:orphan-\(UUID().uuidString)"
        let pidFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("vini-orphan-\(UUID().uuidString).pid")

        // The zsh exits immediately; the nohup'd child survives in the same group.
        try await manager.start(
            serviceID: id,
            command: "nohup sleep 300 >/dev/null 2>&1 & echo $! > \(pidFile.path); exit 0",
            workingDirectory: nil
        )
        try await Task.sleep(for: .milliseconds(700))

        let survivorPID = try Self.readPID(from: pidFile)
        defer {
            kill(survivorPID, SIGKILL)
            try? FileManager.default.removeItem(at: pidFile)
        }
        XCTAssertEqual(kill(survivorPID, 0), 0, "test setup failed: survivor never started")

        // Tracking must survive the wrapper's exit, otherwise stop() can't clean up.
        let stillTracked = await manager.isRunning(id)
        XCTAssertTrue(stillTracked, "service reported stopped while its process was still alive")

        await manager.stop(serviceID: id)
        try await Task.sleep(for: .milliseconds(400))

        XCTAssertNotEqual(
            kill(survivorPID, 0),
            0,
            "stop() left orphaned pid \(survivorPID) running"
        )
    }

    private static func readPID(from url: URL) throws -> pid_t {
        let text = try String(contentsOf: url, encoding: .utf8)
        return try XCTUnwrap(
            pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)),
            "could not read survivor pid from \(url.path)"
        )
    }

    /// `treeMembers` must never return our own pid or pid 0/1.
    func testTreeMembersNeverIncludesSelfOrInit() {
        let members = ProcessManager.treeMembers(rootPID: getpid(), pgid: getpgid(0))
        XCTAssertFalse(members.contains(getpid()), "would signal Vini itself")
        XCTAssertFalse(members.contains(0))
        XCTAssertFalse(members.contains(1), "would signal launchd")
    }

    func testProcessTableSnapshotSeesCurrentProcess() throws {
        let table = ProcessTable.snapshot()
        XCTAssertFalse(table.isEmpty)
        let me = try XCTUnwrap(table.first { $0.pid == getpid() })
        XCTAssertEqual(me.ppid, getppid())
        XCTAssertEqual(me.pgid, getpgid(0))
    }
}
