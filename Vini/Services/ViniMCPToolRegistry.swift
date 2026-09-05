import Foundation
import MCP

enum ViniMCPToolRegistry {
    static func registerHandlers(on server: Server, store: ServicesStore) async {
        await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: tools)
        }

        await server.withMethodHandler(CallTool.self) { params in
            await callTool(params, store: store)
        }

        await server.withMethodHandler(ListResources.self) { _ in
            ListResources.Result(resources: resources)
        }

        await server.withMethodHandler(ReadResource.self) { params in
            try await readResource(params, store: store)
        }
    }

    private static let tools: [Tool] = [
        Tool(
            name: "list_services",
            description: "List all services Vini currently knows about, including status, source, PID, port, visibility, and control metadata.",
            inputSchema: objectSchema(properties: [
                "status": stringSchema("Optional status filter: all, running, stopped, starting, stopping, unknown, active."),
                "scope": stringSchema("Optional scope: all or visible. Defaults to all.")
            ]),
            annotations: .init(readOnlyHint: true, destructiveHint: false, openWorldHint: false)
        ),
        Tool(
            name: "get_service",
            description: "Get full details for one service by exact id or name. Partial names are accepted if unambiguous.",
            inputSchema: objectSchema(properties: [
                "service": stringSchema("Service id or name.")
            ], required: ["service"]),
            annotations: .init(readOnlyHint: true, destructiveHint: false, openWorldHint: false)
        ),
        Tool(
            name: "refresh_services",
            description: "Ask Vini to refresh service discovery before reading state.",
            inputSchema: objectSchema(),
            annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: true)
        ),
        Tool(
            name: "start_service",
            description: "Start a controllable service by exact id or name.",
            inputSchema: objectSchema(properties: [
                "service": stringSchema("Service id or name.")
            ], required: ["service"]),
            annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: true)
        ),
        Tool(
            name: "stop_service",
            description: "Stop a controllable service by exact id or name.",
            inputSchema: objectSchema(properties: [
                "service": stringSchema("Service id or name.")
            ], required: ["service"]),
            annotations: .init(readOnlyHint: false, destructiveHint: true, idempotentHint: true, openWorldHint: true)
        ),
        Tool(
            name: "restart_service",
            description: "Restart a controllable service by exact id or name.",
            inputSchema: objectSchema(properties: [
                "service": stringSchema("Service id or name.")
            ], required: ["service"]),
            annotations: .init(readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: true)
        ),
        Tool(
            name: "list_groups",
            description: "List configured Vini service groups and their current member statuses.",
            inputSchema: objectSchema(),
            annotations: .init(readOnlyHint: true, destructiveHint: false, openWorldHint: false)
        ),
        Tool(
            name: "start_group",
            description: "Start all reachable services in a Vini group by id or name, respecting Vini's group mode.",
            inputSchema: objectSchema(properties: [
                "group": stringSchema("Group id or name.")
            ], required: ["group"]),
            annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: true)
        ),
        Tool(
            name: "stop_group",
            description: "Stop all reachable services in a Vini group by id or name.",
            inputSchema: objectSchema(properties: [
                "group": stringSchema("Group id or name.")
            ], required: ["group"]),
            annotations: .init(readOnlyHint: false, destructiveHint: true, idempotentHint: true, openWorldHint: true)
        ),
        Tool(
            name: "restart_group",
            description: "Restart active services in a group and start inactive services.",
            inputSchema: objectSchema(properties: [
                "group": stringSchema("Group id or name.")
            ], required: ["group"]),
            annotations: .init(readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: true)
        ),
        Tool(
            name: "get_logs",
            description: "Read recent Vini log output for a service.",
            inputSchema: objectSchema(properties: [
                "service": stringSchema("Service id or name."),
                "lines": intSchema("Maximum number of recent lines to return. Defaults to 200, capped at 2000.")
            ], required: ["service"]),
            annotations: .init(readOnlyHint: true, destructiveHint: false, openWorldHint: false)
        ),
        Tool(
            name: "diagnose_service",
            description: "Return service status, control metadata, recent log signals, and likely next steps for troubleshooting.",
            inputSchema: objectSchema(properties: [
                "service": stringSchema("Service id or name."),
                "lines": intSchema("Maximum number of recent log lines to inspect. Defaults to 200, capped at 2000.")
            ], required: ["service"]),
            annotations: .init(readOnlyHint: true, destructiveHint: false, openWorldHint: true)
        ),
        Tool(
            name: "get_services_for_directory",
            description: "Find Vini services and groups relevant to a given directory path. Returns user-defined services whose working directory is at or under the queried path, plus any groups containing those services.",
            inputSchema: objectSchema(properties: [
                "path": stringSchema("Absolute directory path to match against service working directories.")
            ], required: ["path"]),
            annotations: .init(readOnlyHint: true, destructiveHint: false, openWorldHint: false)
        ),
        Tool(
            name: "create_service",
            description: "Create a new user-defined service in Vini. Returns the created service info.",
            inputSchema: objectSchema(properties: [
                "name": stringSchema("Display name for the service."),
                "start_command": stringSchema("Shell command to start the service (e.g. 'yarn dev', 'docker compose up')."),
                "working_directory": stringSchema("Absolute path to the directory the command runs from."),
                "stop_command": stringSchema("Optional shell command to stop the service. If omitted, Vini will terminate the started process."),
                "probe_port": intSchema("Optional TCP port to probe for status checks."),
                "keep_alive_on_quit": boolSchema("If true, the process is left running when Vini quits and re-adopted on next launch. Defaults to false.")
            ], required: ["name", "start_command"]),
            annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false)
        ),
        Tool(
            name: "create_group",
            description: "Create a new service group in Vini. Optionally add existing services as members.",
            inputSchema: objectSchema(properties: [
                "name": stringSchema("Display name for the group."),
                "mode": stringSchema("Group mode: 'simultaneous' (start all at once) or 'sequenced' (start one after another). Defaults to simultaneous."),
                "service_ids": stringSchema("Optional comma-separated list of service ids to add as members.")
            ], required: ["name"]),
            annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false)
        ),
        Tool(
            name: "add_to_group",
            description: "Add a service or a nested group to an existing group. Preserves existing memberships elsewhere (duplicates into group). Cycles and self-nesting are rejected.",
            inputSchema: objectSchema(properties: [
                "service": stringSchema("Service or group id/name to add. To add a group, pass its id, name, or its 'group:<uuid>' reference id."),
                "group": stringSchema("Target group id or name.")
            ], required: ["service", "group"]),
            annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false)
        ),
        Tool(
            name: "remove_from_group",
            description: "Remove a service or a nested group from a specific group.",
            inputSchema: objectSchema(properties: [
                "service": stringSchema("Service or group id/name to remove. To target a group, pass its id, name, or its 'group:<uuid>' reference id."),
                "group": stringSchema("Group id or name to remove from.")
            ], required: ["service", "group"]),
            annotations: .init(readOnlyHint: false, destructiveHint: true, idempotentHint: true, openWorldHint: false)
        ),
        Tool(
            name: "move_to_group",
            description: "Move a service or a nested group into a group, removing it from all other groups. Pass group as empty string or omit to move to ungrouped. Cycles and self-nesting are rejected.",
            inputSchema: objectSchema(properties: [
                "service": stringSchema("Service or group id/name to move. To move a group, pass its id, name, or its 'group:<uuid>' reference id."),
                "group": stringSchema("Target group id or name. Empty or omitted means ungrouped.")
            ], required: ["service"]),
            annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false)
        )
    ]

    private static let resources: [Resource] = [
        Resource(
            name: "Vini Services",
            uri: "vini://services",
            description: "JSON snapshot of all services Vini currently knows about.",
            mimeType: "application/json"
        ),
        Resource(
            name: "Vini Groups",
            uri: "vini://groups",
            description: "JSON snapshot of configured Vini groups and member service status.",
            mimeType: "application/json"
        )
    ]

    private static func callTool(_ params: CallTool.Parameters, store: ServicesStore) async -> CallTool.Result {
        do {
            switch params.name {
            case "list_services":
                let status = params.arguments?["status"]?.stringValue
                let scope = params.arguments?["scope"]?.stringValue
                let response = try await store.mcpServices(status: status, scope: scope)
                return try toolResult(response)

            case "get_service":
                let query = try requiredString("service", in: params.arguments)
                let response = try await store.mcpService(query: query)
                return try toolResult(response)

            case "refresh_services":
                let response = await store.mcpRefreshServices()
                return try toolResult(response)

            case "start_service":
                let query = try requiredString("service", in: params.arguments)
                let response = try await store.mcpServiceAction(.start, query: query)
                return try toolResult(response)

            case "stop_service":
                let query = try requiredString("service", in: params.arguments)
                let response = try await store.mcpServiceAction(.stop, query: query)
                return try toolResult(response)

            case "restart_service":
                let query = try requiredString("service", in: params.arguments)
                let response = try await store.mcpServiceAction(.restart, query: query)
                return try toolResult(response)

            case "list_groups":
                let response = await store.mcpGroups()
                return try toolResult(response)

            case "start_group":
                let query = try requiredString("group", in: params.arguments)
                let response = try await store.mcpGroupAction(.start, query: query)
                return try toolResult(response)

            case "stop_group":
                let query = try requiredString("group", in: params.arguments)
                let response = try await store.mcpGroupAction(.stop, query: query)
                return try toolResult(response)

            case "restart_group":
                let query = try requiredString("group", in: params.arguments)
                let response = try await store.mcpGroupAction(.restart, query: query)
                return try toolResult(response)

            case "get_logs":
                let query = try requiredString("service", in: params.arguments)
                let lines = lineLimit(from: params.arguments)
                let response = try await store.mcpLogs(query: query, lineLimit: lines)
                return try toolResult(response)

            case "diagnose_service":
                let query = try requiredString("service", in: params.arguments)
                let lines = lineLimit(from: params.arguments)
                let response = try await store.mcpDiagnosis(query: query, lineLimit: lines)
                return try toolResult(response)

            case "get_services_for_directory":
                let path = try requiredString("path", in: params.arguments)
                let response = try await store.mcpServicesForDirectory(path: path)
                return try toolResult(response)

            case "create_service":
                let name = try requiredString("name", in: params.arguments)
                let startCommand = try requiredString("start_command", in: params.arguments)
                let workingDirectory = params.arguments?["working_directory"]?.stringValue
                let stopCommand = params.arguments?["stop_command"]?.stringValue
                let probePort = params.arguments?["probe_port"]?.intValue
                let keepAlive = params.arguments?["keep_alive_on_quit"]?.boolValue ?? false
                let response = try await store.mcpCreateService(
                    name: name, startCommand: startCommand,
                    workingDirectory: workingDirectory, stopCommand: stopCommand,
                    probePort: probePort, keepAliveOnQuit: keepAlive
                )
                return try toolResult(response)

            case "create_group":
                let name = try requiredString("name", in: params.arguments)
                let modeString = params.arguments?["mode"]?.stringValue ?? "simultaneous"
                let serviceIDsString = params.arguments?["service_ids"]?.stringValue
                let response = try await store.mcpCreateGroup(
                    name: name, modeString: modeString, serviceIDsCSV: serviceIDsString
                )
                return try toolResult(response)

            case "add_to_group":
                let serviceQuery = try requiredString("service", in: params.arguments)
                let groupQuery = try requiredString("group", in: params.arguments)
                let response = try await store.mcpAddToGroup(serviceQuery: serviceQuery, groupQuery: groupQuery)
                return try toolResult(response)

            case "remove_from_group":
                let serviceQuery = try requiredString("service", in: params.arguments)
                let groupQuery = try requiredString("group", in: params.arguments)
                let response = try await store.mcpRemoveFromGroup(serviceQuery: serviceQuery, groupQuery: groupQuery)
                return try toolResult(response)

            case "move_to_group":
                let serviceQuery = try requiredString("service", in: params.arguments)
                let groupQuery = params.arguments?["group"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
                let response = try await store.mcpMoveToGroup(serviceQuery: serviceQuery, groupQuery: groupQuery)
                return try toolResult(response)

            default:
                throw ViniMCPError.unknownTool(params.name)
            }
        } catch {
            return errorResult(error)
        }
    }

    private static func readResource(_ params: ReadResource.Parameters, store: ServicesStore) async throws -> ReadResource.Result {
        switch params.uri {
        case "vini://services":
            let response = try await store.mcpServices(status: nil, scope: "all")
            return try resourceResult(response, uri: params.uri)
        case "vini://groups":
            let response = await store.mcpGroups()
            return try resourceResult(response, uri: params.uri)
        default:
            throw ViniMCPError.unknownResource(params.uri)
        }
    }

    private static func toolResult<T: Codable>(_ payload: T) throws -> CallTool.Result {
        let text = try jsonString(payload)
        return try CallTool.Result(
            content: [.text(text)],
            structuredContent: payload,
            isError: false
        )
    }

    private static func resourceResult<T: Encodable>(_ payload: T, uri: String) throws -> ReadResource.Result {
        try ReadResource.Result(contents: [
            .text(jsonString(payload), uri: uri, mimeType: "application/json")
        ])
    }

    private static func errorResult(_ error: Error) -> CallTool.Result {
        CallTool.Result(content: [.text(error.localizedDescription)], isError: true)
    }

    private static func jsonString<T: Encodable>(_ payload: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(payload)
        return String(decoding: data, as: UTF8.self)
    }

    private static func requiredString(_ key: String, in arguments: [String: Value]?) throws -> String {
        guard let value = arguments?[key]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            throw ViniMCPError.missingArgument(key)
        }
        return value
    }

    private static func lineLimit(from arguments: [String: Value]?) -> Int {
        min(max(arguments?["lines"]?.intValue ?? 200, 1), 2000)
    }

    private static func objectSchema(properties: [String: Value] = [:], required: [String] = []) -> Value {
        var schema: [String: Value] = [
            "type": "object",
            "properties": .object(properties)
        ]
        if !required.isEmpty {
            schema["required"] = .array(required.map { .string($0) })
        }
        return .object(schema)
    }

    private static func stringSchema(_ description: String) -> Value {
        .object(["type": "string", "description": .string(description)])
    }

    private static func intSchema(_ description: String) -> Value {
        .object(["type": "integer", "description": .string(description)])
    }

    private static func boolSchema(_ description: String) -> Value {
        .object(["type": "boolean", "description": .string(description)])
    }
}

private enum ViniMCPError: LocalizedError {
    case missingArgument(String)
    case unknownTool(String)
    case unknownResource(String)
    case notFound(String)
    case ambiguous(String, [String])
    case actionFailed(String)

    var errorDescription: String? {
        switch self {
        case .missingArgument(let name):
            "Missing required argument '\(name)'."
        case .unknownTool(let name):
            "Unknown Vini MCP tool '\(name)'."
        case .unknownResource(let uri):
            "Unknown Vini MCP resource '\(uri)'."
        case .notFound(let query):
            "No service or group matched '\(query)'."
        case .ambiguous(let query, let matches):
            "'\(query)' matched multiple items: \(matches.joined(separator: ", ")). Use an exact id."
        case .actionFailed(let message):
            message
        }
    }
}

private enum ViniMCPServiceAction: String, Codable, Sendable {
    case start
    case stop
    case restart
}

private enum ViniMCPGroupAction: String, Codable, Sendable {
    case start
    case stop
    case restart
}

private struct ViniMCPServicesResponse: Codable, Sendable {
    let generatedAt: Date
    let scope: String
    let statusFilter: String?
    let services: [ViniMCPServiceInfo]
}

private struct ViniMCPServiceResponse: Codable, Sendable {
    let generatedAt: Date
    let service: ViniMCPServiceInfo
}

private struct ViniMCPActionResponse: Codable, Sendable {
    let generatedAt: Date
    let action: String
    let service: ViniMCPServiceInfo
    let message: String
}

private struct ViniMCPGroupsResponse: Codable, Sendable {
    let generatedAt: Date
    let groups: [ViniMCPGroupInfo]
}

private struct ViniMCPGroupActionResponse: Codable, Sendable {
    let generatedAt: Date
    let action: String
    let group: ViniMCPGroupInfo
    let message: String
}

private struct ViniMCPRefreshResponse: Codable, Sendable {
    let generatedAt: Date
    let serviceCount: Int
    let visibleServiceCount: Int
    let groupCount: Int
}

private struct ViniMCPLogsResponse: Codable, Sendable {
    let generatedAt: Date
    let service: ViniMCPServiceInfo
    let lineLimit: Int
    let hasLogs: Bool
    let logs: String
}

private struct ViniMCPDiagnosisResponse: Codable, Sendable {
    let generatedAt: Date
    let service: ViniMCPServiceInfo
    let issues: [String]
    let suggestions: [String]
    let logSignals: [String]
    let recentLogs: String
}

private struct ViniMCPDirectoryResponse: Codable, Sendable {
    let generatedAt: Date
    let queriedPath: String
    let services: [ViniMCPServiceInfo]
    let groups: [ViniMCPGroupInfo]
}

private struct ViniMCPServiceInfo: Codable, Sendable {
    let id: String
    let name: String
    let status: String
    let statusLabel: String
    let source: String
    let kind: String
    let pid: Int?
    let port: Int?
    let iconSystemName: String
    let isControllable: Bool
    let isCatalogKnown: Bool
    let isVisibleInVini: Bool
    let isHidden: Bool
    let isSurfaced: Bool
    let hasLogs: Bool
    let homebrewFormula: String?
    let launchAgentLabel: String?
    let userDefinition: ViniMCPUserDefinitionInfo?
}

private struct ViniMCPUserDefinitionInfo: Codable, Sendable {
    let id: UUID
    let startCommand: String
    let stopCommand: String?
    let workingDirectory: String?
    let probePort: Int?
    let keepAliveOnQuit: Bool
}

private struct ViniMCPGroupInfo: Codable, Sendable {
    let id: UUID
    let referenceID: String
    let name: String
    let mode: String
    let stopOnFailure: Bool
    let iconSystemName: String
    let isPinnedToMenuBar: Bool
    let isWorking: Bool
    let memberIDs: [String]
    let reachableServices: [ViniMCPServiceInfo]
}

@MainActor
private extension ServicesStore {
    func mcpServices(status: String?, scope: String?) throws -> ViniMCPServicesResponse {
        let normalizedScope = (scope ?? "all").lowercased()
        guard ["all", "visible"].contains(normalizedScope) else {
            throw ViniMCPError.actionFailed("Unsupported scope '\(normalizedScope)'. Use all or visible.")
        }

        let sourceServices = normalizedScope == "visible" ? services : allDiscovered
        let normalizedStatus = status?.lowercased()
        let filtered = try sourceServices
            .map { mcpInfo(for: $0) }
            .filter { try matchesStatus($0, filter: normalizedStatus) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        return ViniMCPServicesResponse(
            generatedAt: Date(),
            scope: normalizedScope,
            statusFilter: normalizedStatus,
            services: filtered
        )
    }

    func mcpService(query: String) throws -> ViniMCPServiceResponse {
        let service = try resolveService(query)
        return ViniMCPServiceResponse(generatedAt: Date(), service: mcpInfo(for: service))
    }

    func mcpRefreshServices() async -> ViniMCPRefreshResponse {
        await refresh()
        return ViniMCPRefreshResponse(
            generatedAt: Date(),
            serviceCount: allDiscovered.count,
            visibleServiceCount: services.count,
            groupCount: groups.count
        )
    }

    func mcpServiceAction(_ action: ViniMCPServiceAction, query: String) async throws -> ViniMCPActionResponse {
        let service = try resolveService(query)
        clearError()
        switch action {
        case .start:
            await start(service)
        case .stop:
            await stop(service)
        case .restart:
            await restart(service)
        }
        if let lastError {
            throw ViniMCPError.actionFailed(lastError)
        }
        let updated = self.service(withID: service.id) ?? service
        return ViniMCPActionResponse(
            generatedAt: Date(),
            action: action.rawValue,
            service: mcpInfo(for: updated),
            message: "\(action.rawValue.capitalized) requested for \(updated.name)."
        )
    }

    func mcpGroups() -> ViniMCPGroupsResponse {
        ViniMCPGroupsResponse(
            generatedAt: Date(),
            groups: groups.map { mcpInfo(for: $0) }
        )
    }

    func mcpGroupAction(_ action: ViniMCPGroupAction, query: String) async throws -> ViniMCPGroupActionResponse {
        let group = try resolveGroup(query)
        clearError()
        switch action {
        case .start:
            await runGroup(group)
        case .stop:
            await stopGroup(group)
        case .restart:
            await restartOrStartGroup(group)
        }
        if let lastError {
            throw ViniMCPError.actionFailed(lastError)
        }
        let updated = self.group(withID: group.id) ?? group
        return ViniMCPGroupActionResponse(
            generatedAt: Date(),
            action: action.rawValue,
            group: mcpInfo(for: updated),
            message: "\(action.rawValue.capitalized) requested for group \(updated.name)."
        )
    }

    func mcpLogs(query: String, lineLimit: Int) throws -> ViniMCPLogsResponse {
        let service = try resolveService(query)
        let logs = LogFileManager.readTail(service.id, lineLimit: lineLimit)
        return ViniMCPLogsResponse(
            generatedAt: Date(),
            service: mcpInfo(for: service),
            lineLimit: lineLimit,
            hasLogs: !logs.isEmpty,
            logs: logs
        )
    }

    func mcpDiagnosis(query: String, lineLimit: Int) throws -> ViniMCPDiagnosisResponse {
        let service = try resolveService(query)
        let info = mcpInfo(for: service)
        let logs = LogFileManager.readTail(service.id, lineLimit: lineLimit)
        let logSignals = diagnosticLogSignals(in: logs)
        var issues: [String] = []
        var suggestions: [String] = []

        if !service.isControllable {
            issues.append("This service is detected by a listening port only, so Vini cannot start or stop it directly.")
            suggestions.append("Use the PID/port details to identify the owning process, or add it as a custom Vini service with start/stop commands.")
        }

        if service.status == .stopped {
            suggestions.append("The service is currently stopped. If it should be running, call start_service.")
        }

        if service.status == .unknown {
            issues.append("Vini could not determine the current service status.")
            suggestions.append("Call refresh_services, then inspect service logs or underlying service manager output.")
        }

        if case .userDefined(let definition) = service.kind {
            if definition.probePort == nil {
                suggestions.append("This custom service has no probe port; adding one can improve status checks and diagnosis.")
            }
            if definition.stopCommand?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true {
                suggestions.append("No custom stop command is configured; Vini will terminate the process it launched, but detached child processes may need a stop command.")
            }
            if let directory = definition.workingDirectory, !directoryExists(directory) {
                issues.append("Configured working directory does not exist: \(directory)")
            }
        }

        if !logSignals.isEmpty {
            issues.append("Recent logs contain error-like lines. Inspect logSignals and recentLogs before restarting repeatedly.")
        } else if logs.isEmpty {
            suggestions.append("No Vini log output is available for this service yet.")
        }

        return ViniMCPDiagnosisResponse(
            generatedAt: Date(),
            service: info,
            issues: issues,
            suggestions: suggestions,
            logSignals: logSignals,
            recentLogs: logs
        )
    }

    func mcpServicesForDirectory(path: String) async throws -> ViniMCPDirectoryResponse {
        let normalizedPath = (path as NSString).expandingTildeInPath
            .trimmingCharacters(in: CharacterSet(charactersIn: "/").inverted.inverted)
        let queryWithSlash = normalizedPath.hasSuffix("/") ? normalizedPath : normalizedPath + "/"

        let matchingServices = allDiscovered.filter { service in
            guard case .userDefined(let definition) = service.kind,
                  let workDir = definition.workingDirectory else { return false }
            let expanded = (workDir as NSString).expandingTildeInPath
            let expandedWithSlash = expanded.hasSuffix("/") ? expanded : expanded + "/"
            return expandedWithSlash.hasPrefix(queryWithSlash) || expanded == normalizedPath
        }

        let matchingServiceIDs = Set(matchingServices.map(\.id))

        let matchingGroups = groups.filter { group in
            group.memberServiceIDs.contains { memberID in
                matchingServiceIDs.contains(memberID)
            }
        }

        return ViniMCPDirectoryResponse(
            generatedAt: Date(),
            queriedPath: normalizedPath,
            services: matchingServices.map { mcpInfo(for: $0) },
            groups: matchingGroups.map { mcpInfo(for: $0) }
        )
    }

    func mcpCreateService(
        name: String, startCommand: String,
        workingDirectory: String?, stopCommand: String?,
        probePort: Int?, keepAliveOnQuit: Bool
    ) async throws -> ViniMCPActionResponse {
        let definition = UserServiceDefinition(
            name: name,
            startCommand: startCommand,
            stopCommand: stopCommand,
            workingDirectory: workingDirectory,
            probePort: probePort,
            keepAliveOnQuit: keepAliveOnQuit
        )
        addUserDefinition(definition)
        // After refresh, find the new service
        let serviceID = "user:\(definition.id.uuidString)"
        let service = self.service(withID: serviceID)
        let info = service.map { mcpInfo(for: $0) } ?? ViniMCPServiceInfo(
            id: serviceID, name: name, status: "stopped", statusLabel: "Stopped",
            source: "Custom", kind: "userDefined", pid: nil, port: probePort,
            iconSystemName: "shippingbox", isControllable: true, isCatalogKnown: true,
            isVisibleInVini: true, isHidden: false, isSurfaced: false, hasLogs: false,
            homebrewFormula: nil, launchAgentLabel: nil,
            userDefinition: ViniMCPUserDefinitionInfo(
                id: definition.id, startCommand: startCommand, stopCommand: stopCommand,
                workingDirectory: workingDirectory, probePort: probePort,
                keepAliveOnQuit: keepAliveOnQuit
            )
        )
        return ViniMCPActionResponse(
            generatedAt: Date(), action: "create",
            service: info, message: "Created service '\(name)' with id \(serviceID)."
        )
    }

    func mcpCreateGroup(name: String, modeString: String, serviceIDsCSV: String?) async throws -> ViniMCPGroupActionResponse {
        let mode: ServiceGroupMode
        switch modeString.lowercased() {
        case "sequenced": mode = .sequenced
        default: mode = .simultaneous
        }

        var memberIDs: [String] = []
        if let csv = serviceIDsCSV, !csv.isEmpty {
            memberIDs = csv.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            // Resolve names to IDs
            memberIDs = try memberIDs.map { raw in
                if allDiscovered.contains(where: { $0.id == raw }) { return raw }
                let resolved = try resolveService(raw)
                return resolved.id
            }
        }

        let group = ServiceGroup(name: name, mode: mode, memberServiceIDs: memberIDs)
        addGroup(group)

        return ViniMCPGroupActionResponse(
            generatedAt: Date(), action: "create",
            group: mcpInfo(for: group),
            message: "Created group '\(name)' with \(memberIDs.count) member(s)."
        )
    }

    func mcpAddToGroup(serviceQuery: String, groupQuery: String) async throws -> ViniMCPGroupActionResponse {
        let member = try resolveMemberReference(serviceQuery)
        let group = try resolveGroup(groupQuery)
        if let nestedGroupID = ServiceGroup.groupID(fromMemberID: member.memberID) {
            if nestedGroupID == group.id {
                throw ViniMCPError.actionFailed("Cannot add group '\(member.name)' to itself.")
            }
            if wouldCreateCycle(addingGroup: nestedGroupID, to: group.id) {
                throw ViniMCPError.actionFailed("Adding group '\(member.name)' to '\(group.name)' would create a cycle.")
            }
        }
        addMember(member.memberID, toGroup: group.id)
        let updated = self.group(withID: group.id) ?? group
        return ViniMCPGroupActionResponse(
            generatedAt: Date(), action: "add_member",
            group: mcpInfo(for: updated),
            message: "Added '\(member.name)' to group '\(updated.name)'."
        )
    }

    func mcpRemoveFromGroup(serviceQuery: String, groupQuery: String) async throws -> ViniMCPGroupActionResponse {
        let member = try resolveMemberReference(serviceQuery)
        let group = try resolveGroup(groupQuery)
        removeMember(member.memberID, fromGroup: group.id)
        let updated = self.group(withID: group.id) ?? group
        return ViniMCPGroupActionResponse(
            generatedAt: Date(), action: "remove_member",
            group: mcpInfo(for: updated),
            message: "Removed '\(member.name)' from group '\(updated.name)'."
        )
    }

    func mcpMoveToGroup(serviceQuery: String, groupQuery: String?) async throws -> ViniMCPActionResponse {
        let member = try resolveMemberReference(serviceQuery)
        let targetGroupID: UUID?
        if let groupQuery, !groupQuery.isEmpty {
            let group = try resolveGroup(groupQuery)
            targetGroupID = group.id
        } else {
            targetGroupID = nil
        }
        if let nestedGroupID = ServiceGroup.groupID(fromMemberID: member.memberID), let targetGroupID {
            if nestedGroupID == targetGroupID {
                throw ViniMCPError.actionFailed("Cannot move group '\(member.name)' into itself.")
            }
            if wouldCreateCycle(addingGroup: nestedGroupID, to: targetGroupID) {
                throw ViniMCPError.actionFailed("Moving group '\(member.name)' into that group would create a cycle.")
            }
        }
        moveMember(member.memberID, toGroup: targetGroupID)
        let destination = targetGroupID.flatMap { group(withID: $0)?.name } ?? "ungrouped"
        let info: ViniMCPServiceInfo
        if ServiceGroup.groupID(fromMemberID: member.memberID) != nil {
            info = placeholderServiceInfo(id: member.memberID, name: member.name, kind: "group")
        } else if let resolved = self.service(withID: member.memberID) {
            info = mcpInfo(for: resolved)
        } else {
            info = placeholderServiceInfo(id: member.memberID, name: member.name, kind: "userDefined")
        }
        return ViniMCPActionResponse(
            generatedAt: Date(), action: "move",
            service: info,
            message: "Moved '\(member.name)' to \(destination)."
        )
    }

    private func placeholderServiceInfo(id: String, name: String, kind: String) -> ViniMCPServiceInfo {
        ViniMCPServiceInfo(
            id: id, name: name, status: "unknown", statusLabel: "Unknown",
            source: "Group", kind: kind, pid: nil, port: nil,
            iconSystemName: "folder", isControllable: false, isCatalogKnown: true,
            isVisibleInVini: true, isHidden: false, isSurfaced: false, hasLogs: false,
            homebrewFormula: nil, launchAgentLabel: nil, userDefinition: nil
        )
    }

    private func matchesStatus(_ service: ViniMCPServiceInfo, filter: String?) throws -> Bool {
        guard let filter, filter != "all" else { return true }
        switch filter {
        case "active":
            return ["running", "starting"].contains(service.status)
        case "running", "stopped", "starting", "stopping", "unknown":
            return service.status == filter
        default:
            throw ViniMCPError.actionFailed("Unsupported status filter '\(filter)'.")
        }
    }

    private func resolveService(_ query: String) throws -> ViniService {
        if let exactID = allDiscovered.first(where: { $0.id == query }) {
            return exactID
        }

        let lowered = query.lowercased()
        let exactNames = allDiscovered.filter { $0.name.lowercased() == lowered }
        if exactNames.count == 1 { return exactNames[0] }
        if exactNames.count > 1 { throw ViniMCPError.ambiguous(query, exactNames.map(\.id)) }

        let partialMatches = allDiscovered.filter {
            $0.id.localizedCaseInsensitiveContains(query) || $0.name.localizedCaseInsensitiveContains(query)
        }
        if partialMatches.count == 1 { return partialMatches[0] }
        if partialMatches.count > 1 { throw ViniMCPError.ambiguous(query, partialMatches.map { "\($0.name) (\($0.id))" }) }

        throw ViniMCPError.notFound(query)
    }

    /// Resolve a query into a group-member reference: either a service id or a
    /// group's `group:<uuid>` reference id, along with a display name. Groups are
    /// preferred only when the query clearly targets one so a service and group
    /// sharing a name stays unambiguous where possible.
    private func resolveMemberReference(_ query: String) throws -> (memberID: String, name: String) {
        if let group = try? resolveGroup(query) {
            if (try? resolveService(query)) == nil {
                return (group.memberReferenceID, group.name)
            }
        }
        let service = try resolveService(query)
        return (service.id, service.name)
    }

    private func resolveGroup(_ query: String) throws -> ServiceGroup {
        if let uuid = UUID(uuidString: query), let group = group(withID: uuid) {
            return group
        }
        if let uuid = ServiceGroup.groupID(fromMemberID: query), let group = group(withID: uuid) {
            return group
        }

        let lowered = query.lowercased()
        let exactNames = groups.filter { $0.name.lowercased() == lowered }
        if exactNames.count == 1 { return exactNames[0] }
        if exactNames.count > 1 { throw ViniMCPError.ambiguous(query, exactNames.map { $0.id.uuidString }) }

        let partialMatches = groups.filter {
            $0.id.uuidString.localizedCaseInsensitiveContains(query) || $0.name.localizedCaseInsensitiveContains(query)
        }
        if partialMatches.count == 1 { return partialMatches[0] }
        if partialMatches.count > 1 { throw ViniMCPError.ambiguous(query, partialMatches.map { "\($0.name) (\($0.id.uuidString))" }) }

        throw ViniMCPError.notFound(query)
    }

    private func mcpInfo(for service: ViniService) -> ViniMCPServiceInfo {
        let visible = services.contains { $0.id == service.id }
        let hidden = hiddenServiceIDs.contains(service.id)
        let surfaced = surfacedServiceIDs.contains(service.id)
        let kindInfo = mcpKindInfo(for: service.kind)
        return ViniMCPServiceInfo(
            id: service.id,
            name: service.name,
            status: service.status.rawValue,
            statusLabel: service.status.displayLabel,
            source: service.kind.sourceLabel,
            kind: kindInfo.kind,
            pid: service.pid,
            port: service.port,
            iconSystemName: service.iconSystemName,
            isControllable: service.isControllable,
            isCatalogKnown: service.isCatalogKnown,
            isVisibleInVini: visible,
            isHidden: hidden,
            isSurfaced: surfaced,
            hasLogs: hasLogs(for: service),
            homebrewFormula: kindInfo.homebrewFormula,
            launchAgentLabel: kindInfo.launchAgentLabel,
            userDefinition: kindInfo.userDefinition
        )
    }

    private func mcpInfo(for group: ServiceGroup) -> ViniMCPGroupInfo {
        ViniMCPGroupInfo(
            id: group.id,
            referenceID: group.memberReferenceID,
            name: group.name,
            mode: group.mode.rawValue,
            stopOnFailure: group.stopOnFailure,
            iconSystemName: group.iconSystemName,
            isPinnedToMenuBar: group.isPinnedToMenuBar,
            isWorking: isGroupWorking(group.id),
            memberIDs: group.memberServiceIDs,
            reachableServices: reachableServices(of: group).map { mcpInfo(for: $0) }
        )
    }

    private func mcpKindInfo(for kind: ServiceKind) -> (
        kind: String,
        homebrewFormula: String?,
        launchAgentLabel: String?,
        userDefinition: ViniMCPUserDefinitionInfo?
    ) {
        switch kind {
        case .homebrew(let formula):
            return ("homebrew", formula, nil, nil)
        case .launchAgent(let label):
            return ("launchAgent", nil, label, nil)
        case .portProbe:
            return ("portProbe", nil, nil, nil)
        case .userDefined(let definition):
            return (
                "userDefined",
                nil,
                nil,
                ViniMCPUserDefinitionInfo(
                    id: definition.id,
                    startCommand: definition.startCommand,
                    stopCommand: definition.stopCommand,
                    workingDirectory: definition.workingDirectory,
                    probePort: definition.probePort,
                    keepAliveOnQuit: definition.keepAliveOnQuit
                )
            )
        }
    }

    private func diagnosticLogSignals(in logs: String) -> [String] {
        let markers = ["error", "failed", "failure", "exception", "fatal", "panic", "eaddrinuse", "address already in use", "permission denied"]
        return logs
            .split(separator: "\n")
            .map(String.init)
            .filter { line in
                let lowered = line.lowercased()
                return markers.contains { lowered.contains($0) }
            }
            .suffix(50)
            .map { $0 }
    }

    private func directoryExists(_ path: String) -> Bool {
        let expanded = (path as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}
