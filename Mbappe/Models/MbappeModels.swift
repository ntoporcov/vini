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
    var probePort: Int?
    var iconSystemName: String

    init(
        id: UUID = UUID(),
        name: String,
        startCommand: String,
        stopCommand: String? = nil,
        probePort: Int? = nil,
        iconSystemName: String = "terminal"
    ) {
        self.id = id
        self.name = name
        self.startCommand = startCommand
        self.stopCommand = stopCommand
        self.probePort = probePort
        self.iconSystemName = iconSystemName
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
