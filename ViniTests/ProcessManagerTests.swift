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
}
