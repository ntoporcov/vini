import Foundation

// MARK: - Service

/// A single service tracked by Mbappe.
struct MbappeService: Identifiable, Hashable, Sendable {
    /// Stable key. For brew: "brew:<formula>". For launchd: "launchd:<label>".
    /// For port-probed: "port:<port>". For user-defined: "user:<uuid>".
    let id: String
    var name: String
    var kind: ServiceKind
    var pid: Int?
    var port: Int?
    var status: ServiceStatus
    var iconSystemName: String

    /// Whether this service matched the curated `KnownServices` catalog.
    /// Catalog services appear in the main list by default; unlisted ones
    /// must be explicitly surfaced by the user.
    var isCatalogKnown: Bool = true

    /// Whether Mbappe knows how to start/stop this service.
    var isControllable: Bool {
        switch kind {
        case .homebrew, .launchAgent, .userDefined:
            true
        case .portProbe:
            false
        }
    }
}

// MARK: - Kind

/// How a service was discovered and how it can be controlled.
enum ServiceKind: Hashable, Sendable {
    /// Managed by `brew services`. Associated value is the formula name.
    case homebrew(formula: String)

    /// A user LaunchAgent managed by `launchctl`. Associated value is the label.
    case launchAgent(label: String)

    /// Inferred only from a listening localhost port — read-only.
    case portProbe(port: Int)

    /// A service the user configured inside Mbappe with explicit start/stop commands.
    case userDefined(definition: UserServiceDefinition)

    var sourceLabel: String {
        switch self {
        case .homebrew:    "Homebrew"
        case .launchAgent: "launchd"
        case .portProbe:   "Port"
        case .userDefined: "Custom"
        }
    }
}

// MARK: - User-defined service

/// A service the user defines in-app to run on demand.
struct UserServiceDefinition: Hashable, Sendable, Codable, Identifiable {
    var id: UUID
    var name: String
    var startCommand: String
    var stopCommand: String?
    /// Directory the command runs from. Defaults to the user's home dir if nil.
    var workingDirectory: String?
    var probePort: Int?
    var iconSystemName: String

    init(
        id: UUID = UUID(),
        name: String,
        startCommand: String,
        stopCommand: String? = nil,
        workingDirectory: String? = nil,
        probePort: Int? = nil,
        iconSystemName: String = "terminal"
    ) {
        self.id = id
        self.name = name
        self.startCommand = startCommand
        self.stopCommand = stopCommand
        self.workingDirectory = workingDirectory
        self.probePort = probePort
        self.iconSystemName = iconSystemName
    }
}

// MARK: - Service group

/// How a group of services is executed when the user runs it.
enum ServiceGroupMode: String, Hashable, Sendable, Codable {
    /// Start all member services at once.
    case simultaneous
    /// Start member services one after another, in order.
    case sequenced

    var displayLabel: String {
        switch self {
        case .simultaneous: "Simultaneous"
        case .sequenced:    "Sequenced"
        }
    }

    var iconSystemName: String {
        switch self {
        case .simultaneous: "square.stack.3d.up"
        case .sequenced:    "arrow.right.to.line"
        }
    }
}

/// A named collection of services run together (simultaneously or in sequence).
struct ServiceGroup: Hashable, Sendable, Codable, Identifiable {
    var id: UUID
    var name: String
    var mode: ServiceGroupMode
    /// Ordered member service ids (e.g. "user:<uuid>", "brew:redis").
    var memberServiceIDs: [String]
    /// For `.sequenced`: if a member fails to start, stop the remaining sequence.
    var stopOnFailure: Bool
    var iconSystemName: String

    init(
        id: UUID = UUID(),
        name: String,
        mode: ServiceGroupMode = .simultaneous,
        memberServiceIDs: [String] = [],
        stopOnFailure: Bool = true,
        iconSystemName: String = "rectangle.3.group"
    ) {
        self.id = id
        self.name = name
        self.mode = mode
        self.memberServiceIDs = memberServiceIDs
        self.stopOnFailure = stopOnFailure
        self.iconSystemName = iconSystemName
    }
}

// MARK: - Project auto-discovery

/// A suggestion produced by scanning the filesystem for runnable projects.
struct ProjectSuggestion: Identifiable, Hashable, Sendable {
    var id: String { directory }
    /// Absolute path to the project directory.
    let directory: String
    /// Display name (usually the folder name).
    let name: String
    /// What kind of project was detected (drives the suggested command + icon).
    let projectType: ProjectType
    /// Suggested start command for this project.
    let suggestedCommand: String
}

/// Recognized project ecosystems, ranked roughly by how strong the signal is.
enum ProjectType: String, Hashable, Sendable, CaseIterable {
    case node
    case dotnet
    case python
    case go
    case rust
    case ruby
    case docker
    case make

    var displayName: String {
        switch self {
        case .node:   "Node.js"
        case .dotnet: ".NET"
        case .python: "Python"
        case .go:     "Go"
        case .rust:   "Rust"
        case .ruby:   "Ruby"
        case .docker: "Docker"
        case .make:   "Make"
        }
    }

    var iconSystemName: String {
        switch self {
        case .node:   "shippingbox"
        case .dotnet: "number.square"
        case .python: "chevron.left.forwardslash.chevron.right"
        case .go:     "g.circle"
        case .rust:   "gearshape.2"
        case .ruby:   "diamond"
        case .docker: "shippingbox.fill"
        case .make:   "hammer"
        }
    }
}

// MARK: - Status

enum ServiceStatus: String, Hashable, Sendable {
    case running
    case stopped
    case starting
    case stopping
    case unknown

    var displayLabel: String {
        switch self {
        case .running:  "Running"
        case .stopped:  "Stopped"
        case .starting: "Starting…"
        case .stopping: "Stopping…"
        case .unknown:  "Unknown"
        }
    }

    var isActive: Bool {
        self == .running || self == .starting
    }
}
