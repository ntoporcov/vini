import XCTest
@testable import Vini

final class LogFileManagerTests: XCTestCase {

    private var serviceID: String!

    override func setUp() {
        super.setUp()
        serviceID = "user:logtest-\(UUID().uuidString)"
    }

    override func tearDown() {
        LogFileManager.clear(serviceID)
        super.tearDown()
    }

    func testAppendAndReadTail() {
        LogFileManager.append(serviceID, text: "line one\n")
        LogFileManager.append(serviceID, text: "line two\n")
        let tail = LogFileManager.readTail(serviceID)
        XCTAssertTrue(tail.contains("line one"))
        XCTAssertTrue(tail.contains("line two"))
    }

    func testReadTailRespectsLineLimit() {
        for i in 1...50 {
            LogFileManager.append(serviceID, text: "line \(i)\n")
        }
        let tail = LogFileManager.readTail(serviceID, lineLimit: 5)
        XCTAssertFalse(tail.contains("line 1\n"))
        XCTAssertTrue(tail.contains("line 50"))
    }

    func testClearRemovesContent() {
        LogFileManager.append(serviceID, text: "something\n")
        XCTAssertGreaterThan(LogFileManager.size(serviceID), 0)
        LogFileManager.clear(serviceID)
        XCTAssertEqual(LogFileManager.size(serviceID), 0)
        XCTAssertEqual(LogFileManager.readTail(serviceID), "")
    }

    func testSanitizeMakesSafeFilenames() {
        XCTAssertEqual(LogFileManager.sanitize("user:ABC-123_x"), "user_ABC-123_x")
        XCTAssertEqual(LogFileManager.sanitize("brew:postgresql@17"), "brew_postgresql_17")
    }

    func testSessionHeaderIncludesCommand() {
        LogFileManager.writeSessionHeader(serviceID, command: "npm run dev")
        let tail = LogFileManager.readTail(serviceID)
        XCTAssertTrue(tail.contains("Vini session"))
        XCTAssertTrue(tail.contains("npm run dev"))
    }

    func testRotationKeepsOneGenerationUnderLimit() {
        // Write just over the limit to force a rotation on next open.
        let chunk = String(repeating: "x", count: 64 * 1024) + "\n"
        var written: UInt64 = 0
        while written <= LogFileManager.maxBytes {
            LogFileManager.append(serviceID, text: chunk)
            written += UInt64(chunk.utf8.count)
        }
        // Trigger rotation explicitly and confirm the live file shrinks.
        LogFileManager.rotateIfNeeded(serviceID)
        let rotated = LogFileManager.fileURL(for: serviceID).appendingPathExtension("1")
        XCTAssertTrue(FileManager.default.fileExists(atPath: rotated.path))
        XCTAssertLessThanOrEqual(LogFileManager.size(serviceID), LogFileManager.maxBytes)
        try? FileManager.default.removeItem(at: rotated)
    }
}
