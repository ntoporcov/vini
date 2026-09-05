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
    func discover(userDefinitions: [UserServiceDefinition] = []) async -> [ViniService] {
        // One `lsof` for every port we care about, reused by both the catalog probe
        // and user-defined probes. Previously this was one subprocess per port
        // (9 catalog ports + one per user service) on every single refresh.
        let listeners = Self.listeningPIDsByPort()

        var services = discoverHomebrew() + discoverLaunchAgents()
        services += await probeUserDefined(userDefinitions, listeners: listeners)

        // Add port-probed services only when no controllable service already covers
        // that port — avoids showing e.g. PostgreSQL twice (brew + port 5432).
        let coveredPorts = Set(services.compactMap(\.port))
        for probed in discoverPorts(listeners: listeners)
        where probed.port.map({ !coveredPorts.contains($0) }) ?? true {
            services.append(probed)
        }

        return Self.dedupe(services)
    }

    /// De-dupe merged services: drop exact id duplicates, and drop a second entry
    /// that shares a live PID with one already kept (two sources reporting the same
    /// running process). Controllable entries win, then sort by name. nil PIDs are
    /// never treated as duplicates of each other.
    static func dedupe(_ services: [ViniService]) -> [ViniService] {
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

    private func discoverHomebrew() -> [ViniService] {
        guard let brew = Shell.brewPath() else { return [] }
        guard let result = try? Shell.run(brew, ["services", "list", "--json"], timeout: Shell.discoveryTimeout),
              result.succeeded,
              let data = result.stdout.data(using: .utf8)
        else { return [] }

        guard let entries = try? JSONDecoder().decode([BrewServiceEntry].self, from: data) else {
            return []
        }

        return entries.map { entry in
            if let known = KnownServices.entry(forIdentifier: entry.name) {
                return ViniService(
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
            return ViniService(
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

    private func discoverLaunchAgents() -> [ViniService] {
        guard let result = try? Shell.run(Shell.launchctlPath, ["list"], timeout: Shell.discoveryTimeout), result.succeeded else {
            return []
        }

        // Format: "PID\tStatus\tLabel" with a header line.
        var services: [ViniService] = []
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
                    ViniService(
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
                    ViniService(
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
    private func discoverPorts(listeners: [Int: Int]) -> [ViniService] {
        var services: [ViniService] = []
        for entry in KnownServices.catalog {
            guard let port = entry.port else { continue }
            guard let pid = listeners[port] else { continue }
            services.append(
                ViniService(
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

    /// Every listening TCP port on the machine mapped to its owning pid, from a
    /// single `lsof` invocation.
    ///
    /// Uses `-F` machine-readable output: a `p<pid>` line opens a process block and
    /// each following `n<addr>` line is one socket belonging to it.
    static func listeningPIDsByPort() -> [Int: Int] {
        guard FileManager.default.isExecutableFile(atPath: Shell.lsofPath) else { return [:] }
        guard let result = try? Shell.run(
            Shell.lsofPath,
            ["-nP", "-iTCP", "-sTCP:LISTEN", "-Fpn"],
            timeout: Shell.discoveryTimeout
        ) else { return [:] }
        // lsof exits non-zero when some sockets are unreadable, but still prints
        // usable output, so the exit code is deliberately not checked here.
        return parseLsofFieldOutput(result.stdout)
    }

    static func parseLsofFieldOutput(_ output: String) -> [Int: Int] {
        var result: [Int: Int] = [:]
        var currentPID: Int?

        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let tag = line.first else { continue }
            let value = line.dropFirst()
            switch tag {
            case "p":
                currentPID = Int(value)
            case "n":
                guard let pid = currentPID else { continue }
                // Addresses look like "*:3000", "127.0.0.1:5432" or "[::1]:5432".
                guard let colon = value.lastIndex(of: ":") else { continue }
                guard let port = Int(value[value.index(after: colon)...]) else { continue }
                // First writer wins, matching the previous `lsof -t | head -1`.
                if result[port] == nil { result[port] = pid }
            default:
                continue
            }
        }
        return result
    }

    // MARK: - User-defined

    private func probeUserDefined(
        _ definitions: [UserServiceDefinition],
        listeners: [Int: Int]
    ) async -> [ViniService] {
        let runningIDs = await ProcessManager.shared.runningServiceIDs()
        return definitions.map { def in
            let id = "user:\(def.id.uuidString)"
            let status: ServiceStatus
            if runningIDs.contains(id) {
                // Vini owns a live process for this service.
                status = .running
            } else if let probePort = def.probePort {
                // Fall back to a port probe for detached/externally-started services.
                status = listeners[probePort] != nil ? .running : .stopped
            } else {
                status = .stopped
            }
            return ViniService(
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
