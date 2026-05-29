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

        var services = await brew + agents + ports
        services += probeUserDefined(userDefinitions, knownPorts: services.compactMap(\.port))

        // De-dupe by id, preferring controllable entries.
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

        return entries.map { entry in
            MbappeService(
                id: "brew:\(entry.name)",
                name: entry.name,
                kind: .homebrew(formula: entry.name),
                pid: entry.pid,
                port: nil,
                status: ServiceStatus(brewStatus: entry.status),
                iconSystemName: Self.icon(forName: entry.name)
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

            // Only surface user-relevant agents, skip Apple system noise.
            guard label.hasPrefix("homebrew.") || label.hasPrefix("com.user.") || isInterestingLabel(label) else {
                continue
            }

            let pid = Int(cols[0])
            services.append(
                MbappeService(
                    id: "launchd:\(label)",
                    name: prettyName(fromLabel: label),
                    kind: .launchAgent(label: label),
                    pid: pid,
                    port: nil,
                    status: pid != nil ? .running : .stopped,
                    iconSystemName: Self.icon(forName: label)
                )
            )
        }
        return services
    }

    private func isInterestingLabel(_ label: String) -> Bool {
        // Heuristic: skip Apple-bundled agents.
        !label.hasPrefix("com.apple.")
    }

    private func prettyName(fromLabel label: String) -> String {
        label
            .replacingOccurrences(of: "homebrew.mxcl.", with: "")
            .split(separator: ".")
            .last
            .map(String.init) ?? label
    }

    // MARK: - Ports

    /// Probe a small set of well-known developer service ports.
    private func discoverPorts() -> [MbappeService] {
        let wellKnown: [(port: Int, name: String)] = [
            (5432, "PostgreSQL"),
            (3306, "MySQL"),
            (6379, "Redis"),
            (27017, "MongoDB"),
            (9200, "Elasticsearch"),
            (5672, "RabbitMQ"),
            (8080, "HTTP (8080)"),
            (3000, "Dev Server (3000)"),
        ]

        var services: [MbappeService] = []
        for entry in wellKnown {
            guard let pid = listeningPID(onPort: entry.port) else { continue }
            services.append(
                MbappeService(
                    id: "port:\(entry.port)",
                    name: entry.name,
                    kind: .portProbe(port: entry.port),
                    pid: pid,
                    port: entry.port,
                    status: .running,
                    iconSystemName: Self.icon(forName: entry.name)
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

    // MARK: - Icons

    static func icon(forName name: String) -> String {
        let lower = name.lowercased()
        if lower.contains("postgres") || lower.contains("mysql") || lower.contains("mongo") || lower.contains("sql") {
            return "cylinder.fill"
        }
        if lower.contains("redis") || lower.contains("memcache") {
            return "memorychip"
        }
        if lower.contains("nginx") || lower.contains("http") || lower.contains("apache") {
            return "network"
        }
        if lower.contains("elastic") || lower.contains("search") {
            return "magnifyingglass"
        }
        if lower.contains("rabbit") || lower.contains("kafka") || lower.contains("queue") {
            return "tray.full"
        }
        return "gearshape.2"
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
