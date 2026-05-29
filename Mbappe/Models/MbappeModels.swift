import Foundation

// MARK: - Service

/// A single running service discovered on the local machine.
struct MbappeService: Identifiable, Hashable, Sendable {
    let id: String          // stable key, e.g. bundle id or pid-based string
    var name: String
    var pid: Int?
    var port: Int?
    var status: ServiceStatus
    var iconSystemName: String  // SF Symbol name
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
