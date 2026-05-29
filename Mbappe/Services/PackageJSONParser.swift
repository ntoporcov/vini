import Foundation

/// Package manager detected for a Node project, with the command prefix used to
/// run a script.
enum NodePackageManager: String, Sendable {
    case npm
    case yarn
    case pnpm
    case bun

    var displayName: String {
        switch self {
        case .npm:  "npm"
        case .yarn: "Yarn"
        case .pnpm: "pnpm"
        case .bun:  "Bun"
        }
    }

    /// The command to run a named script.
    func runCommand(forScript script: String) -> String {
        switch self {
        case .npm:  "npm run \(script)"
        case .yarn: "yarn \(script)"
        case .pnpm: "pnpm run \(script)"
        case .bun:  "bun run \(script)"
        }
    }
}

/// One script entry from a package.json.
struct NodeScript: Identifiable, Hashable, Sendable {
    var id: String { name }
    let name: String
    let command: String  // the raw script body, for display
}

/// Result of parsing a package.json file.
struct ParsedPackageJSON: Sendable {
    /// Absolute path to the directory containing package.json.
    let directory: String
    /// Package "name" field, or the folder name if absent.
    let packageName: String
    let packageManager: NodePackageManager
    let scripts: [NodeScript]
}

/// Parses package.json files: extracts scripts and the package name, and detects
/// the package manager from the lockfile next to it.
enum PackageJSONParser {

    enum ParseError: LocalizedError, Equatable {
        case unreadable
        case invalidJSON
        case noScripts

        var errorDescription: String? {
            switch self {
            case .unreadable:  "Couldn't read the selected package.json."
            case .invalidJSON: "The selected file isn't valid package.json JSON."
            case .noScripts:   "This package.json has no \"scripts\" entries."
            }
        }
    }

    /// Parse the package.json at `fileURL`.
    static func parse(fileURL: URL) throws -> ParsedPackageJSON {
        guard let data = try? Data(contentsOf: fileURL) else {
            throw ParseError.unreadable
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ParseError.invalidJSON
        }

        let directory = fileURL.deletingLastPathComponent()
        let folderName = directory.lastPathComponent
        let packageName = (json["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? folderName

        let scriptsDict = (json["scripts"] as? [String: Any]) ?? [:]
        let scripts: [NodeScript] = scriptsDict
            .compactMap { key, value in
                guard let body = value as? String else { return nil }
                return NodeScript(name: key, command: body)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        guard !scripts.isEmpty else { throw ParseError.noScripts }

        return ParsedPackageJSON(
            directory: directory.path,
            packageName: packageName,
            packageManager: detectPackageManager(in: directory),
            scripts: scripts
        )
    }

    /// Detect the package manager from a lockfile in `directory`. Defaults to npm.
    static func detectPackageManager(in directory: URL) -> NodePackageManager {
        let fm = FileManager.default
        func exists(_ file: String) -> Bool {
            fm.fileExists(atPath: directory.appendingPathComponent(file).path)
        }
        if exists("bun.lockb") || exists("bun.lock") { return .bun }
        if exists("pnpm-lock.yaml") { return .pnpm }
        if exists("yarn.lock") { return .yarn }
        return .npm
    }
}
