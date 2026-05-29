import Foundation

/// Starts and stops services based on their `kind`.
///
/// Requires a **non-sandboxed** build to spawn `brew` / `launchctl`.
actor ServiceController {
    static let shared = ServiceController()

    private init() {}

    func start(_ service: MbappeService) async throws {
        switch service.kind {
        case .homebrew(let formula):
            try brew(["services", "start", formula])
        case .launchAgent(let label):
            try Shell.run(Shell.launchctlPath, ["start", label], throwOnFailure: true)
        case .userDefined(let def):
            // Mbappe owns the process so it can report status and stop it later.
            try await ProcessManager.shared.start(
                serviceID: service.id,
                command: def.startCommand,
                workingDirectory: def.workingDirectory
            )
        case .portProbe:
            throw ServiceControlError.notControllable(service.name)
        }
    }

    func stop(_ service: MbappeService) async throws {
        switch service.kind {
        case .homebrew(let formula):
            try brew(["services", "stop", formula])
        case .launchAgent(let label):
            try Shell.run(Shell.launchctlPath, ["stop", label], throwOnFailure: true)
        case .userDefined(let def):
            // Prefer terminating the tracked process. If a custom stop command is
            // provided, run it too (covers detached daemons).
            await ProcessManager.shared.stop(serviceID: service.id)
            if let stopCommand = def.stopCommand, !stopCommand.isEmpty {
                try Shell.runScript(stopCommand, throwOnFailure: false)
            }
        case .portProbe:
            throw ServiceControlError.notControllable(service.name)
        }
    }

    func restart(_ service: MbappeService) async throws {
        switch service.kind {
        case .homebrew(let formula):
            try brew(["services", "restart", formula])
        default:
            try await stop(service)
            try await start(service)
        }
    }

    // MARK: - Helpers

    private func brew(_ arguments: [String]) throws {
        guard let brewPath = Shell.brewPath() else {
            throw ServiceControlError.toolNotFound("brew")
        }
        try Shell.run(brewPath, arguments, throwOnFailure: true)
    }
}

enum ServiceControlError: LocalizedError {
    case toolNotFound(String)
    case notControllable(String)
    case noStopCommand(String)

    var errorDescription: String? {
        switch self {
        case .toolNotFound(let tool):
            "Required tool '\(tool)' was not found on this Mac."
        case .notControllable(let name):
            "'\(name)' was detected by port only and can't be started or stopped by Mbappe."
        case .noStopCommand(let name):
            "No stop command is configured for '\(name)'."
        }
    }
}
