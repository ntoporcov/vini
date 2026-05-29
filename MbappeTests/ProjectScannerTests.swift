import XCTest
@testable import Mbappe

final class ProjectScannerTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mbappe-scanner-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func write(_ file: String, in dir: URL, contents: String = "") throws {
        try contents.write(
            to: dir.appendingPathComponent(file),
            atomically: true,
            encoding: .utf8
        )
    }

    func testDetectsNodeProject() throws {
        try write("package.json", in: tempDir, contents: #"{"scripts":{"dev":"vite"}}"#)
        let type = ProjectScanner.projectType(for: tempDir)
        XCTAssertEqual(type, .node)
        XCTAssertEqual(ProjectScanner.command(for: .node, in: tempDir), "npm run dev")
    }

    func testNodeFallsBackToStartWhenNoPreferredScript() throws {
        try write("package.json", in: tempDir, contents: #"{"scripts":{"build":"tsc"}}"#)
        XCTAssertEqual(ProjectScanner.command(for: .node, in: tempDir), "npm start")
    }

    func testDetectsRustProject() throws {
        try write("Cargo.toml", in: tempDir)
        XCTAssertEqual(ProjectScanner.projectType(for: tempDir), .rust)
        XCTAssertEqual(ProjectScanner.command(for: .rust, in: tempDir), "cargo run")
    }

    func testDetectsGoProject() throws {
        try write("go.mod", in: tempDir)
        XCTAssertEqual(ProjectScanner.projectType(for: tempDir), .go)
    }

    func testDetectsDotnetByCsproj() throws {
        try write("App.csproj", in: tempDir)
        XCTAssertEqual(ProjectScanner.projectType(for: tempDir), .dotnet)
        XCTAssertEqual(ProjectScanner.command(for: .dotnet, in: tempDir), "dotnet run")
    }

    func testDetectsDjangoPython() throws {
        try write("manage.py", in: tempDir)
        XCTAssertEqual(ProjectScanner.projectType(for: tempDir), .python)
        XCTAssertEqual(ProjectScanner.command(for: .python, in: tempDir), "python manage.py runserver")
    }

    func testDetectsDockerCompose() throws {
        try write("docker-compose.yml", in: tempDir)
        XCTAssertEqual(ProjectScanner.projectType(for: tempDir), .docker)
        XCTAssertEqual(ProjectScanner.command(for: .docker, in: tempDir), "docker compose up")
    }

    func testEmptyDirectoryHasNoSuggestion() {
        XCTAssertNil(ProjectScanner.projectType(for: tempDir))
        XCTAssertNil(ProjectScanner.suggestion(for: tempDir))
    }

    func testNodeWinsOverDockerWhenBothPresent() throws {
        try write("package.json", in: tempDir, contents: #"{}"#)
        try write("Dockerfile", in: tempDir)
        XCTAssertEqual(ProjectScanner.projectType(for: tempDir), .node)
    }

    func testSuggestionUsesFolderName() throws {
        let projectDir = tempDir.appendingPathComponent("my-cool-api")
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        try write("go.mod", in: projectDir)
        let suggestion = ProjectScanner.suggestion(for: projectDir)
        XCTAssertEqual(suggestion?.name, "my-cool-api")
        XCTAssertEqual(suggestion?.directory, projectDir.path)
    }
}
