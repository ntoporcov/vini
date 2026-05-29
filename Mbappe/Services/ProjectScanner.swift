import Foundation

/// Scans common developer folders for runnable projects and suggests services.
///
/// Detection is intentionally shallow (a couple of levels deep) and based on
/// well-known indicator files so it stays fast. Requires filesystem read access
/// (available to the non-sandboxed build).
actor ProjectScanner {
    static let shared = ProjectScanner()

    private init() {}

    /// Root folders to scan, relative to the user's home directory.
    private static let scanRoots = ["Developer", "Projects", "Code", "src", "repos"]

    /// How many directory levels below each root to inspect.
    private static let maxDepth = 2

    /// Scan the default roots and return de-duplicated suggestions, best signal first.
    func scan() -> [ProjectSuggestion] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var suggestions: [ProjectSuggestion] = []
        var seen = Set<String>()

        for root in Self.scanRoots {
            let rootURL = home.appendingPathComponent(root)
            guard isDirectory(rootURL) else { continue }
            for dir in directories(under: rootURL, depth: Self.maxDepth) {
                guard let suggestion = Self.suggestion(for: dir) else { continue }
                if seen.insert(suggestion.directory).inserted {
                    suggestions.append(suggestion)
                }
            }
        }
        return suggestions.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Detect a single arbitrary directory (used when the user picks a folder).
    func detect(directory: URL) -> ProjectSuggestion? {
        Self.suggestion(for: directory)
    }

    // MARK: - Detection (pure, testable)

    /// Map indicator files in a directory to a project suggestion.
    static func suggestion(for directory: URL) -> ProjectSuggestion? {
        guard let type = projectType(for: directory) else { return nil }
        let name = directory.lastPathComponent
        return ProjectSuggestion(
            directory: directory.path,
            name: name,
            projectType: type,
            suggestedCommand: command(for: type, in: directory)
        )
    }

    /// Determine the project type from indicator files present in `directory`.
    static func projectType(for directory: URL) -> ProjectType? {
        let fm = FileManager.default
        func exists(_ file: String) -> Bool {
            fm.fileExists(atPath: directory.appendingPathComponent(file).path)
        }
        func hasFile(withExtension ext: String) -> Bool {
            guard let contents = try? fm.contentsOfDirectory(atPath: directory.path) else { return false }
            return contents.contains { $0.hasSuffix(".\(ext)") }
        }

        // Order matters: prefer the most specific / actionable signal.
        if exists("package.json") { return .node }
        if exists("Cargo.toml") { return .rust }
        if exists("go.mod") { return .go }
        if exists("pyproject.toml") || exists("requirements.txt") || exists("manage.py") { return .python }
        if exists("Gemfile") { return .ruby }
        if hasFile(withExtension: "csproj") || hasFile(withExtension: "sln") || hasFile(withExtension: "fsproj") { return .dotnet }
        if exists("docker-compose.yml") || exists("docker-compose.yaml") || exists("compose.yaml") { return .docker }
        if exists("Dockerfile") { return .docker }
        if exists("Makefile") { return .make }
        return nil
    }

    /// A reasonable default start command for a detected project type.
    static func command(for type: ProjectType, in directory: URL) -> String {
        switch type {
        case .node:
            return nodeCommand(in: directory)
        case .dotnet:
            return "dotnet run"
        case .python:
            let fm = FileManager.default
            if fm.fileExists(atPath: directory.appendingPathComponent("manage.py").path) {
                return "python manage.py runserver"
            }
            return "python main.py"
        case .go:
            return "go run ."
        case .rust:
            return "cargo run"
        case .ruby:
            return "bundle exec rails server"
        case .docker:
            return "docker compose up"
        case .make:
            return "make"
        }
    }

    /// Pick a sensible npm script if one is obviously present, else `npm start`.
    private static func nodeCommand(in directory: URL) -> String {
        let packageURL = directory.appendingPathComponent("package.json")
        guard let data = try? Data(contentsOf: packageURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let scripts = json["scripts"] as? [String: Any]
        else { return "npm start" }

        for preferred in ["dev", "start", "serve"] where scripts[preferred] != nil {
            return "npm run \(preferred)"
        }
        return "npm start"
    }

    // MARK: - Filesystem helpers

    private func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    /// Breadth-limited directory walk up to `depth` levels below `root` (inclusive of root).
    private func directories(under root: URL, depth: Int) -> [URL] {
        var result: [URL] = [root]
        var frontier: [URL] = [root]
        var level = 0
        let fm = FileManager.default

        while level < depth, !frontier.isEmpty {
            var next: [URL] = []
            for dir in frontier {
                guard let children = try? fm.contentsOfDirectory(
                    at: dir,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                ) else { continue }
                for child in children {
                    let isDir = (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                    guard isDir == true else { continue }
                    // Skip noisy dependency/build dirs.
                    let name = child.lastPathComponent
                    if Self.ignoredDirectoryNames.contains(name) { continue }
                    result.append(child)
                    next.append(child)
                }
            }
            frontier = next
            level += 1
        }
        return result
    }

    private static let ignoredDirectoryNames: Set<String> = [
        "node_modules", ".git", "target", "build", "dist", ".venv", "venv",
        "Pods", "DerivedData", ".next", "bin", "obj", "vendor",
    ]
}
