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
        services += probeUserDefined(userDefinitions, knownPorts: services.compactMap(\.port))

        // Add port-probed services only when no controllable service already covers
        // that port — avoids showing e.g. PostgreSQL twice (brew + port 5432).
        let coveredPorts = Set(services.compactMap(\.port))
        for probed in await ports where probed.port.map({ !coveredPorts.contains($0) }) ?? true {
            services.append(probed)
        }

        // De-dupe by id, preferring controllable entries, then sort by name.
        var seen = Set<String>()
        return services
            .sorted { $0.isControllable && !$1.isControllable }
            .filter { seen.insert($0.id).inserted }
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

        return entries.compactMap { entry in
            // Only surface formulae that match the curated catalog.
            guard let known = KnownServices.entry(forIdentifier: entry.name) else { return nil }
            return MbappeService(
                id: "brew:\(entry.name)",
                name: known.displayName,
                kind: .homebrew(formula: entry.name),
                pid: entry.pid,
                port: known.port,
                status: ServiceStatus(brewStatus: entry.status),
                iconSystemName: known.icon
            )
        }
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

            // Only surface agents that match the curated catalog of popular tools.
            guard let known = KnownServices.entry(forIdentifier: label) else { continue }

            let pid = Int(cols[0])
            services.append(
                MbappeService(
                    id: "launchd:\(label)",
                    name: known.displayName,
                    kind: .launchAgent(label: label),
                    pid: pid,
                    port: known.port,
                    status: pid != nil ? .running : .stopped,
                    iconSystemName: known.icon
                )
            )
        }
        return services
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
        _ definitions: [UserServiceDefinition],
        knownPorts: [Int]
    ) -> [MbappeService] {
        definitions.map { def in
            var status: ServiceStatus = .unknown
            if let probePort = def.probePort {
                status = (listeningPID(onPort: probePort) != nil) ? .running : .stopped
            }
            return MbappeService(
                id: "user:\(def.id.uuidString)",
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
