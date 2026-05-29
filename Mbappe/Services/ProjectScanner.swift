import Foundation

/// Scans common developer folders for runnable projects and suggests services.
///
/// Walks known dev roots up to a bounded depth, stops descending once a
/// directory is recognized as a project, and skips noisy dependency/build dirs
/// so deeper scans stay reasonably fast. Requires filesystem read access
/// (available to the non-sandboxed build).
actor ProjectScanner {
    static let shared = ProjectScanner()

    private init() {}

    /// Root folders to scan, relative to the user's home directory.
    /// Includes common generic dev folders plus known IDE project locations
    /// (IntelliJ's `IdeaProjects`, and `XcodeProjects` used by some devs).
    private static let scanRoots = [
        "Developer",
        "Projects",
        "Code",
        "src",
        "repos",
        "IdeaProjects",
        "XcodeProjects",
    ]

    /// How many directory levels below each root to inspect.
    private static let maxDepth = 6

    /// Scan the default roots and return de-duplicated suggestions, best signal first.
    func scan() -> [ProjectSuggestion] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var suggestions: [ProjectSuggestion] = []
        var seen = Set<String>()

        for root in Self.scanRoots {
            let rootURL = home.appendingPathComponent(root)
            guard isDirectory(rootURL) else { continue }
            for suggestion in scanTree(root: rootURL, depth: Self.maxDepth) {
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

    /// Breadth-limited walk that collects project suggestions. Once a directory
    /// is detected as a project, its children are NOT descended into (a project's
    /// sub-packages shouldn't each become a separate service, and it keeps deeper
    /// scans fast). Noisy dependency/build dirs are skipped.
    private func scanTree(root: URL, depth: Int) -> [ProjectSuggestion] {
        Self.collectSuggestions(root: root, depth: depth)
    }

    /// Pure, testable tree walk used by `scanTree`.
    static func collectSuggestions(root: URL, depth: Int) -> [ProjectSuggestion] {
        var suggestions: [ProjectSuggestion] = []
        var frontier: [URL] = [root]
        var level = 0
        let fm = FileManager.default

        // Check the root itself.
        if let rootSuggestion = suggestion(for: root) {
            return [rootSuggestion]
        }

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
                    let name = child.lastPathComponent
                    if ignoredDirectoryNames.contains(name) { continue }

                    if let suggestion = suggestion(for: child) {
                        // Detected a project — record it and stop descending here.
                        suggestions.append(suggestion)
                    } else {
                        // Not a project: keep descending to find nested ones.
                        next.append(child)
                    }
                }
            }
            frontier = next
            level += 1
        }
        return suggestions
    }

    private static let ignoredDirectoryNames: Set<String> = [
        "node_modules", ".git", "target", "build", "dist", ".venv", "venv",
        "Pods", "DerivedData", ".next", "bin", "obj", "vendor",
    ]
}
