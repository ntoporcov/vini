import XCTest
@testable import Vini

final class ProjectScannerTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vini-scanner-tests-\(UUID().uuidString)")
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

    // MARK: - Tree walk (depth + pruning)

    private func mkdir(_ path: String) throws -> URL {
        let url = tempDir.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func testFindsProjectNestedSeveralLevelsDeep() throws {
        let deep = try mkdir("a/b/c/d/e/api")
        try write("go.mod", in: deep)
        let found = ProjectScanner.collectSuggestions(root: tempDir, depth: 6)
        XCTAssertEqual(found.map(\.name), ["api"])
    }

    func testDepthLimitStopsDeeperProjects() throws {
        let tooDeep = try mkdir("a/b/c/d/e/f/g/api")
        try write("go.mod", in: tooDeep)
        // 8 levels below root, but depth is 6 -> not found.
        let found = ProjectScanner.collectSuggestions(root: tempDir, depth: 6)
        XCTAssertTrue(found.isEmpty)
    }

    func testStopsDescendingOnceProjectDetected() throws {
        // A node project that also contains a nested sub-package.
        let project = try mkdir("frontend")
        try write("package.json", in: project, contents: #"{}"#)
        let nested = try mkdir("frontend/packages/ui")
        try write("package.json", in: nested, contents: #"{}"#)

        let found = ProjectScanner.collectSuggestions(root: tempDir, depth: 6)
        // Only the outer project is reported; we don't descend into it.
        XCTAssertEqual(found.map(\.name), ["frontend"])
    }

    func testSkipsNodeModulesAndBuildDirs() throws {
        let buried = try mkdir("node_modules/some-dep")
        try write("package.json", in: buried, contents: #"{}"#)
        let found = ProjectScanner.collectSuggestions(root: tempDir, depth: 6)
        XCTAssertTrue(found.isEmpty)
    }

    func testFindsMultipleSiblingProjects() throws {
        let api = try mkdir("services/api")
        try write("go.mod", in: api)
        let web = try mkdir("services/web")
        try write("package.json", in: web, contents: #"{}"#)
        let found = ProjectScanner.collectSuggestions(root: tempDir, depth: 6)
        XCTAssertEqual(Set(found.map(\.name)), ["api", "web"])
    }
}
