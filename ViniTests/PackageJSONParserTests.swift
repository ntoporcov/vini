import XCTest
@testable import Vini

final class PackageJSONParserTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vini-pkgjson-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    @discardableResult
    private func write(_ file: String, _ contents: String) throws -> URL {
        let url = tempDir.appendingPathComponent(file)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testParsesScriptsAndName() throws {
        let url = try write("package.json", #"""
        { "name": "my-app", "scripts": { "dev": "vite", "build": "tsc", "start": "node ." } }
        """#)
        let parsed = try PackageJSONParser.parse(fileURL: url)
        XCTAssertEqual(parsed.packageName, "my-app")
        XCTAssertEqual(parsed.scripts.map(\.name), ["build", "dev", "start"]) // sorted
        XCTAssertEqual(parsed.scripts.first { $0.name == "dev" }?.command, "vite")
    }

    func testFallsBackToFolderNameWhenNameMissing() throws {
        let url = try write("package.json", #"{ "scripts": { "dev": "vite" } }"#)
        let parsed = try PackageJSONParser.parse(fileURL: url)
        XCTAssertEqual(parsed.packageName, tempDir.lastPathComponent)
    }

    func testThrowsOnNoScripts() throws {
        let url = try write("package.json", #"{ "name": "x" }"#)
        XCTAssertThrowsError(try PackageJSONParser.parse(fileURL: url)) { error in
            XCTAssertEqual(error as? PackageJSONParser.ParseError, .noScripts)
        }
    }

    func testThrowsOnInvalidJSON() throws {
        let url = try write("package.json", "not json {")
        XCTAssertThrowsError(try PackageJSONParser.parse(fileURL: url)) { error in
            XCTAssertEqual(error as? PackageJSONParser.ParseError, .invalidJSON)
        }
    }

    // MARK: - Package manager detection

    func testDetectsNpmByDefault() {
        XCTAssertEqual(PackageJSONParser.detectPackageManager(in: tempDir), .npm)
    }

    func testDetectsYarn() throws {
        try write("yarn.lock", "")
        XCTAssertEqual(PackageJSONParser.detectPackageManager(in: tempDir), .yarn)
    }

    func testDetectsPnpm() throws {
        try write("pnpm-lock.yaml", "")
        XCTAssertEqual(PackageJSONParser.detectPackageManager(in: tempDir), .pnpm)
    }

    func testDetectsBun() throws {
        try write("bun.lockb", "")
        XCTAssertEqual(PackageJSONParser.detectPackageManager(in: tempDir), .bun)
    }

    func testBunWinsWhenMultipleLockfiles() throws {
        try write("yarn.lock", "")
        try write("bun.lockb", "")
        XCTAssertEqual(PackageJSONParser.detectPackageManager(in: tempDir), .bun)
    }

    // MARK: - Run commands

    func testRunCommandsPerManager() {
        XCTAssertEqual(NodePackageManager.npm.runCommand(forScript: "dev"), "npm run dev")
        XCTAssertEqual(NodePackageManager.yarn.runCommand(forScript: "dev"), "yarn dev")
        XCTAssertEqual(NodePackageManager.pnpm.runCommand(forScript: "dev"), "pnpm run dev")
        XCTAssertEqual(NodePackageManager.bun.runCommand(forScript: "dev"), "bun run dev")
    }
}
