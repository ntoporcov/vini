import Foundation

/// Discovers services on the local machine from multiple sources:
/// - Homebrew (`brew services list --json`)
/// - launchd user agents (`launchctl list`)
/// - Well-known listening ports (`lsof`)
///
/// Requires a **non-sandboxed** build to spawn these tools.
actor ServiceDiscovery {
    static let shared = ServiceDiscovery()

    private init() {}

    /// Discover all services. `userDefinitions` are merged in and probed for status.
    func discover(userDefinitions: [UserServiceDefinition] = []) async -> [MbappeService] {
        async let brew = discoverHomebrew()
        async let agents = discoverLaunchAgents()
        async let ports = discoverPorts()

        var services = await brew + agents
        services += await probeUserDefined(userDefinitions)

        // Add port-probed services only when no controllable service already covers
        // that port — avoids showing e.g. PostgreSQL twice (brew + port 5432).
        let coveredPorts = Set(services.compactMap(\.port))
        for probed in await ports where probed.port.map({ !coveredPorts.contains($0) }) ?? true {
            services.append(probed)
        }

        return Self.dedupe(services)
    }

    /// De-dupe merged services: drop exact id duplicates, and drop a second entry
    /// that shares a live PID with one already kept (two sources reporting the same
    /// running process). Controllable entries win, then sort by name. nil PIDs are
    /// never treated as duplicates of each other.
    static func dedupe(_ services: [MbappeService]) -> [MbappeService] {
        var seen = Set<String>()
        var seenPIDs = Set<Int>()
        return services
            .sorted { $0.isControllable && !$1.isControllable }
            .filter { service in
                guard seen.insert(service.id).inserted else { return false }
                if let pid = service.pid {
                    guard seenPIDs.insert(pid).inserted else { return false }
                }
                return true
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: - Homebrew

    private func discoverHomebrew() -> [MbappeService] {
        guard let brew = Shell.brewPath() else { return [] }
        guard let result = try? Shell.run(brew, ["services", "list", "--json"]),
              result.succeeded,
              let data = result.stdout.data(using: .utf8)
        else { return [] }

        guard let entries = try? JSONDecoder().decode([BrewServiceEntry].self, from: data) else {
            return []
        }

        return entries.map { entry in
            if let known = KnownServices.entry(forIdentifier: entry.name) {
                return MbappeService(
                    id: "brew:\(entry.name)",
                    name: known.displayName,
                    kind: .homebrew(formula: entry.name),
                    pid: entry.pid,
                    port: known.port,
                    status: ServiceStatus(brewStatus: entry.status),
                    iconSystemName: known.icon,
                    isCatalogKnown: true
                )
            }
            // Unlisted formula — still returned, flagged so it stays out of the
            // main list until the user surfaces it from the Manage view.
            return MbappeService(
                id: "brew:\(entry.name)",
                name: Self.prettyFormulaName(entry.name),
                kind: .homebrew(formula: entry.name),
                pid: entry.pid,
                port: nil,
                status: ServiceStatus(brewStatus: entry.status),
                iconSystemName: "gearshape.2",
                isCatalogKnown: false
            )
        }
    }

    private static func prettyFormulaName(_ formula: String) -> String {
        formula
            .split(separator: "@").first
            .map { $0.replacingOccurrences(of: "-", with: " ").capitalized } ?? formula
    }

    // MARK: - launchd

    private func discoverLaunchAgents() -> [MbappeService] {
        guard let result = try? Shell.run(Shell.launchctlPath, ["list"]), result.succeeded else {
            return []
        }

        // Format: "PID\tStatus\tLabel" with a header line.
        var services: [MbappeService] = []
        for line in result.stdout.split(separator: "\n").dropFirst() {
            let cols = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard cols.count == 3 else { continue }
            let label = String(cols[2])

            // Skip Apple's own system agents entirely — they are noise, not
            // user-managed services, and surfacing them would be dangerous.
            guard !label.hasPrefix("com.apple.") else { continue }

            // Skip Homebrew-managed agents: they are already surfaced (and better
            // controlled) via `brew services`, so showing them here would duplicate
            // e.g. PostgreSQL as both a Homebrew and a launchd entry.
            guard !label.hasPrefix("homebrew.mxcl.") else { continue }

            let pid = Int(cols[0])
            if let known = KnownServices.entry(forIdentifier: label) {
                services.append(
                    MbappeService(
                        id: "launchd:\(label)",
                        name: known.displayName,
                        kind: .launchAgent(label: label),
                        pid: pid,
                        port: known.port,
                        status: pid != nil ? .running : .stopped,
                        iconSystemName: known.icon,
                        isCatalogKnown: true
                    )
                )
            } else {
                // Unlisted agent — returned but flagged; surfaced only on demand.
                services.append(
                    MbappeService(
                        id: "launchd:\(label)",
                        name: Self.prettyLabelName(label),
                        kind: .launchAgent(label: label),
                        pid: pid,
                        port: nil,
                        status: pid != nil ? .running : .stopped,
                        iconSystemName: "gearshape.2",
                        isCatalogKnown: false
                    )
                )
            }
        }
        return services
    }

    private static func prettyLabelName(_ label: String) -> String {
        label
            .replacingOccurrences(of: "homebrew.mxcl.", with: "")
            .split(separator: ".").last
            .map { $0.replacingOccurrences(of: "-", with: " ").capitalized } ?? label
    }

    // MARK: - Ports

    /// Probe the catalog's well-known developer service ports.
    private func discoverPorts() -> [MbappeService] {
        var services: [MbappeService] = []
        for entry in KnownServices.catalog {
            guard let port = entry.port else { continue }
            guard let pid = listeningPID(onPort: port) else { continue }
            services.append(
                MbappeService(
                    id: "port:\(port)",
                    name: entry.displayName,
                    kind: .portProbe(port: port),
                    pid: pid,
                    port: port,
                    status: .running,
                    iconSystemName: entry.icon
                )
            )
        }
        return services
    }

    private func listeningPID(onPort port: Int) -> Int? {
        guard FileManager.default.isExecutableFile(atPath: Shell.lsofPath) else { return nil }
        guard let result = try? Shell.run(
            Shell.lsofPath,
            ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-t"]
        ), result.succeeded else { return nil }
        let pidLine = result.stdout.split(separator: "\n").first.map(String.init) ?? ""
        return Int(pidLine.trimmingCharacters(in: .whitespaces))
    }

    // MARK: - User-defined

    private func probeUserDefined(
        _ definitions: [UserServiceDefinition]
    ) async -> [MbappeService] {
        let runningIDs = await ProcessManager.shared.runningServiceIDs()
        return definitions.map { def in
            let id = "user:\(def.id.uuidString)"
            let status: ServiceStatus
            if runningIDs.contains(id) {
                // Mbappe owns a live process for this service.
                status = .running
            } else if let probePort = def.probePort {
                // Fall back to a port probe for detached/externally-started services.
                status = (listeningPID(onPort: probePort) != nil) ? .running : .stopped
            } else {
                status = .stopped
            }
            return MbappeService(
                id: id,
                name: def.name,
                kind: .userDefined(definition: def),
                pid: nil,
                port: def.probePort,
                status: status,
                iconSystemName: def.iconSystemName
            )
        }
    }
}

// MARK: - brew services JSON

private struct BrewServiceEntry: Decodable {
    let name: String
    let status: String
    let pid: Int?
}

private extension ServiceStatus {
    init(brewStatus: String) {
        switch brewStatus.lowercased() {
        case "started", "running": self = .running
        case "stopped", "none":    self = .stopped
        case "starting":           self = .starting
        case "error":              self = .unknown
        default:                   self = .unknown
        }
    }
}
