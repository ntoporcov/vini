import XCTest
@testable import Mbappe

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
}
