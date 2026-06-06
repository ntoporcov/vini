import Foundation
import Combine

enum ServicesStoreMode: Equatable {
    case normal
    case screenshot

    static var current: Self {
        let processInfo = ProcessInfo.processInfo
        if processInfo.arguments.contains("--screenshot-mode")
            || processInfo.arguments.contains("--demo-mode")
            || Self.isEnabled(processInfo.environment["VINI_SCREENSHOT_MODE"])
            || Self.isEnabled(processInfo.environment["VINI_DEMO_MODE"]) {
            return .screenshot
        }
        return .normal
    }

    private static func isEnabled(_ value: String?) -> Bool {
        guard let value else { return false }
        return ["1", "true", "yes", "on"].contains(value.lowercased())
    }
}

/// Central store for all discovered services.
/// Views observe this directly via `@EnvironmentObject`.
@MainActor
final class ServicesStore: ObservableObject {
    // MARK: - State

    /// Services shown in the main list:
    /// catalog-known services that aren't hidden, plus any surfaced unlisted services.
    @Published private(set) var services: [ViniService] = []
    @Published private(set) var isRefreshing: Bool = false
    @Published private(set) var lastError: String? = nil

    /// User-defined services configured in-app. Persisted to UserDefaults.
    @Published private(set) var userDefinitions: [UserServiceDefinition] = []

    /// Catalog service ids the user has chosen to hide from the main list. Persisted.
    @Published private(set) var hiddenServiceIDs: Set<String> = []

    /// Unlisted (non-catalog) service ids the user has chosen to surface
    /// into the main list. Persisted.
    @Published private(set) var surfacedServiceIDs: Set<String> = []

    /// All discovered services before any hide/surface filtering is applied.
    @Published private(set) var allDiscovered: [ViniService] = []

    /// Service groups (simultaneous / sequenced). Persisted to UserDefaults.
    @Published private(set) var groups: [ServiceGroup] = []

    /// Tree folder node ids the user has expanded. Persisted.
    @Published private(set) var expandedNodeIDs: Set<String> = []

    /// Preferred display order for services when they are not in a group.
    @Published private(set) var serviceOrderIDs: [String] = []

    /// Groups currently running a bulk start/stop/restart action.
    @Published private(set) var workingGroupIDs: Set<UUID> = []

    private let userDefinitionsKey = "vini.userDefinitions"
    private let hiddenServiceIDsKey = "vini.hiddenServiceIDs"
    private let surfacedServiceIDsKey = "vini.surfacedServiceIDs"
    private let groupsKey = "vini.groups"
    private let expandedNodeIDsKey = "vini.expandedNodeIDs"
    private let serviceOrderIDsKey = "vini.serviceOrderIDs"

    /// Backing store for persistence. Injectable so tests never touch the real
    /// app preferences domain.
    private let defaults: UserDefaults
    private let mode: ServicesStoreMode
    private var screenshotLogsByServiceID: [String: String] = [:]

    var isScreenshotMode: Bool { mode == .screenshot }

    init(defaults: UserDefaults = .standard, mode: ServicesStoreMode = .normal) {
        self.defaults = defaults
        self.mode = mode
        if mode == .screenshot {
            seedScreenshotDemo()
            return
        }
        loadUserDefinitions()
        loadHiddenServiceIDs()
        loadSurfacedServiceIDs()
        loadGroups()
        loadExpandedNodeIDs()
        loadServiceOrderIDs()
    }

    // MARK: - Derived collections (for the Manage view)

    /// Catalog services the user hid — offered for unhiding.
    var hiddenCatalogServices: [ViniService] {
        allDiscovered.filter { $0.isCatalogKnown && hiddenServiceIDs.contains($0.id) }
    }

    /// Unlisted services not currently surfaced — offered for surfacing.
    var unlistedServices: [ViniService] {
        allDiscovered.filter { !$0.isCatalogKnown && !surfacedServiceIDs.contains($0.id) }
    }

    /// Anything the Manage view should show (hidden catalog + unsurfaced unlisted).
    var manageableServices: [ViniService] {
        (hiddenCatalogServices + unlistedServices)
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var hasManageableServices: Bool {
        !hiddenCatalogServices.isEmpty || !unlistedServices.isEmpty
    }

    // MARK: - Refresh

    /// Discover currently running services and update state.
    func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }
        guard mode == .normal else {
            applyFilter()
            return
        }
        allDiscovered = await ServiceDiscovery.shared.discover(userDefinitions: userDefinitions)
        applyFilter()
    }

    // MARK: - App lifecycle

    /// Re-adopt any kept-alive processes left running by a previous launch,
    /// then refresh so their status reflects reality.
    func adoptPersistedProcessesAndRefresh() async {
        guard mode == .normal else {
            await refresh()
            return
        }
        await ProcessManager.shared.adoptPersistedProcesses()
        await refresh()
    }

    /// Service ids the user marked keep-alive-on-quit.
    private var keepAliveServiceIDs: Set<String> {
        Set(
            userDefinitions
                .filter { $0.keepAliveOnQuit }
                .map { "user:\($0.id.uuidString)" }
        )
    }

    /// On quit: stop non-keep-alive processes, leave keep-alive ones running.
    func handleAppTermination() async {
        guard mode == .normal else { return }
        await ProcessManager.shared.handleAppTermination(keepAliveServiceIDs: keepAliveServiceIDs)
        flushDefaults()
    }

    // MARK: - Logs

    /// Whether the given service currently has a log file with content.
    func hasLogs(for service: ViniService) -> Bool {
        if mode == .screenshot {
            return !(screenshotLogsByServiceID[service.id]?.isEmpty ?? true)
        }
        return LogFileManager.size(service.id) > 0
    }

    /// Build a live log session for a service. `isLiveCaptureAvailable` is false
    /// for re-adopted/detached processes (historic logs only).
    func makeLogSession(for service: ViniService) async -> LogSession {
        if mode == .screenshot {
            return LogSession(
                serviceID: service.id,
                serviceName: service.name,
                isLiveCaptureAvailable: false,
                seedText: screenshotLogsByServiceID[service.id] ?? ""
            )
        }
        let live = await ProcessManager.shared.hasLiveCapture(service.id)
        return LogSession(
            serviceID: service.id,
            serviceName: service.name,
            isLiveCaptureAvailable: live
        )
    }

    private func applyFilter() {
        services = allDiscovered.filter { service in
            if service.isCatalogKnown {
                return !hiddenServiceIDs.contains(service.id)
            } else {
                return surfacedServiceIDs.contains(service.id)
            }
        }
    }

    // MARK: - Service actions

    func start(_ service: ViniService) async {
        guard service.isControllable else {
            lastError = ServiceControlError.notControllable(service.name).localizedDescription
            return
        }
        if mode == .screenshot {
            await simulateServiceAction(service.id, pending: .starting, final: .running)
            return
        }
        await mutateStatus(service.id, to: .starting)
        do {
            try await ServiceController.shared.start(service)
        } catch {
            lastError = error.localizedDescription
        }
        await refresh()
    }

    func stop(_ service: ViniService) async {
        guard service.isControllable else {
            lastError = ServiceControlError.notControllable(service.name).localizedDescription
            return
        }
        if mode == .screenshot {
            await simulateServiceAction(service.id, pending: .stopping, final: .stopped)
            return
        }
        await mutateStatus(service.id, to: .stopping)
        do {
            try await ServiceController.shared.stop(service)
        } catch {
            lastError = error.localizedDescription
        }
        await refresh()
    }

    func restart(_ service: ViniService) async {
        guard service.isControllable else {
            lastError = ServiceControlError.notControllable(service.name).localizedDescription
            return
        }
        if mode == .screenshot {
            await simulateServiceAction(service.id, pending: .starting, final: .running)
            return
        }
        await mutateStatus(service.id, to: .starting)
        do {
            try await ServiceController.shared.restart(service)
        } catch {
            lastError = error.localizedDescription
        }
        await refresh()
    }

    func clearError() {
        lastError = nil
    }

    // MARK: - Hide / unhide (catalog services)

    func isHidden(_ service: ViniService) -> Bool {
        hiddenServiceIDs.contains(service.id)
    }

    func hide(_ service: ViniService) {
        hiddenServiceIDs.insert(service.id)
        saveHiddenServiceIDs()
        applyFilter()
    }

    func unhide(id: String) {
        hiddenServiceIDs.remove(id)
        saveHiddenServiceIDs()
        applyFilter()
    }

    func unhideAll() {
        hiddenServiceIDs.removeAll()
        saveHiddenServiceIDs()
        applyFilter()
    }

    // MARK: - Surface / unsurface (unlisted services)

    func isSurfaced(_ service: ViniService) -> Bool {
        surfacedServiceIDs.contains(service.id)
    }

    /// Opt an unlisted service into the main list.
    func surface(id: String) {
        surfacedServiceIDs.insert(id)
        saveSurfacedServiceIDs()
        applyFilter()
    }

    /// Remove a previously surfaced unlisted service from the main list.
    func unsurface(_ service: ViniService) {
        surfacedServiceIDs.remove(service.id)
        saveSurfacedServiceIDs()
        applyFilter()
    }

    // MARK: - User definitions

    func addUserDefinition(_ definition: UserServiceDefinition) {
        userDefinitions.append(definition)
        saveUserDefinitions()
        Task { await refresh() }
    }

    /// Add several user-defined services at once (e.g. from NPM scripts).
    func addUserDefinitions(_ definitions: [UserServiceDefinition]) {
        guard !definitions.isEmpty else { return }
        userDefinitions.append(contentsOf: definitions)
        saveUserDefinitions()
        Task { await refresh() }
    }

    /// Add several user-defined services and immediately group them together.
    /// Used by helpers that create related services in one shot.
    func addUserDefinitions(_ definitions: [UserServiceDefinition], groupedUnder groupName: String) {
        guard !definitions.isEmpty else { return }
        userDefinitions.append(contentsOf: definitions)
        let memberIDs = definitions.map { "user:\($0.id.uuidString)" }
        groups.append(ServiceGroup(name: groupName, mode: .simultaneous, memberServiceIDs: memberIDs))
        saveUserDefinitions()
        saveGroups()
        Task { await refresh() }
    }

    /// Delete a user-defined service. `service` must be of kind `.userDefined`.
    func delete(_ service: ViniService) {
        guard case .userDefined(let definition) = service.kind else { return }
        removeUserDefinition(id: definition.id)
    }

    /// Remove services from the visible list in bulk. User-defined services are
    /// deleted; catalog services are hidden; surfaced unlisted services are unsurfaced.
    func removeFromList(_ services: [ViniService]) {
        guard !services.isEmpty else { return }
        var removedUserDefinition = false

        for service in services {
            switch service.kind {
            case .userDefined(let definition):
                userDefinitions.removeAll { $0.id == definition.id }
                removeServiceReferences(service.id)
                removedUserDefinition = true
            default:
                if service.isCatalogKnown {
                    hiddenServiceIDs.insert(service.id)
                } else {
                    surfacedServiceIDs.remove(service.id)
                }
            }
        }

        saveUserDefinitions()
        saveHiddenServiceIDs()
        saveSurfacedServiceIDs()
        saveGroups()
        applyFilter()
        if removedUserDefinition {
            Task { await refresh() }
        }
    }

    func removeUserDefinition(id: UUID) {
        let serviceID = "user:\(id.uuidString)"
        userDefinitions.removeAll { $0.id == id }
        removeServiceReferences(serviceID)
        saveUserDefinitions()
        saveGroups()
        Task { await refresh() }
    }

    // MARK: - Service lookup

    /// Find a discovered service by its id.
    func service(withID id: String) -> ViniService? {
        allDiscovered.first { $0.id == id }
    }

    func group(withID id: UUID) -> ServiceGroup? {
        groups.first { $0.id == id }
    }

    /// Resolve a group's plain-service members (non-group ids) into models, in order.
    func members(of group: ServiceGroup) -> [ViniService] {
        group.memberServiceIDs.compactMap { service(withID: $0) }
    }

    // MARK: - Tree

    /// The full services tree (folders for simultaneous groups, leaves for
    /// services and sequenced groups, plus an Ungrouped bucket).
    var tree: [ServiceTreeNode] {
        ServiceTree.build(groups: groups, services: services, serviceOrderIDs: serviceOrderIDs)
    }

    // MARK: - Aggregate status

    /// Recursively collect the plain services reachable from a group (following
    /// nested groups), cycle-safe.
    func reachableServices(of group: ServiceGroup, visited: Set<UUID> = []) -> [ViniService] {
        var seenVisited = visited
        seenVisited.insert(group.id)
        var result: [ViniService] = []
        for member in group.memberServiceIDs {
            if let gid = ServiceGroup.groupID(fromMemberID: member) {
                guard !seenVisited.contains(gid), let child = self.group(withID: gid) else { continue }
                result += reachableServices(of: child, visited: seenVisited)
            } else if let svc = service(withID: member) {
                result.append(svc)
            }
        }
        return result
    }

    // MARK: - Groups CRUD

    func addGroup(_ group: ServiceGroup) {
        groups.append(group)
        saveGroups()
    }

    func createSimultaneousGroup(name: String = "New Group", serviceIDs: [String]) {
        let memberIDs = serviceIDs.reduce(into: [String]()) { result, id in
            if !result.contains(id) { result.append(id) }
        }
        guard !memberIDs.isEmpty else { return }
        groups.append(ServiceGroup(name: name, mode: .simultaneous, memberServiceIDs: memberIDs))
        saveGroups()
    }

    func updateGroup(_ group: ServiceGroup) {
        guard let idx = groups.firstIndex(where: { $0.id == group.id }) else { return }
        groups[idx] = group
        saveGroups()
    }

    func setGroupPinned(_ groupID: UUID, isPinned: Bool) {
        guard let idx = groups.firstIndex(where: { $0.id == groupID }) else { return }
        groups[idx].isPinnedToMenuBar = isPinned
        saveGroups()
    }

    func removeGroup(id: UUID) {
        groups.removeAll { $0.id == id }
        // Also strip references to this group from any other group's members.
        let ref = "group:\(id.uuidString)"
        for idx in groups.indices {
            groups[idx].memberServiceIDs.removeAll { $0 == ref }
        }
        saveGroups()
    }

    /// Remove a single member (a service id or "group:<uuid>") from a group.
    func removeMember(_ memberID: String, fromGroup groupID: UUID) {
        guard let idx = groups.firstIndex(where: { $0.id == groupID }) else { return }
        groups[idx].memberServiceIDs.removeAll { $0 == memberID }
        saveGroups()
    }

    private func removeServiceReferences(_ serviceID: String) {
        for idx in groups.indices {
            groups[idx].memberServiceIDs.removeAll { $0 == serviceID }
        }
        serviceOrderIDs.removeAll { $0 == serviceID }
        saveServiceOrderIDs()
    }

    /// Add a service or group reference to a group, preserving existing
    /// membership elsewhere. This is the explicit "duplicate into group" path.
    func addMember(_ memberID: String, toGroup groupID: UUID) {
        guard let idx = groups.firstIndex(where: { $0.id == groupID }) else { return }
        if let candidateGroupID = ServiceGroup.groupID(fromMemberID: memberID), wouldCreateCycle(addingGroup: candidateGroupID, to: groupID) {
            return
        }
        guard !groups[idx].memberServiceIDs.contains(memberID) else { return }
        groups[idx].memberServiceIDs.append(memberID)
        saveGroups()
    }

    /// Move a member to a group, or to Ungrouped when `targetGroupID` is nil.
    /// Moving removes existing memberships so drag/drop has predictable semantics.
    func moveMember(_ memberID: String, toGroup targetGroupID: UUID?) {
        moveMember(memberID, toGroup: targetGroupID, beforeMemberID: nil)
    }

    /// Move a member before another member in the target container. A nil target
    /// group means root/Ungrouped: services become ungrouped, groups become root.
    func moveMember(_ memberID: String, toGroup targetGroupID: UUID?, beforeMemberID: String?) {
        if let candidateGroupID = ServiceGroup.groupID(fromMemberID: memberID), let targetGroupID,
           wouldCreateCycle(addingGroup: candidateGroupID, to: targetGroupID) { return }

        for idx in groups.indices {
            groups[idx].memberServiceIDs.removeAll { $0 == memberID }
        }
        if let targetGroupID, let idx = groups.firstIndex(where: { $0.id == targetGroupID }) {
            insert(memberID, into: &groups[idx].memberServiceIDs, before: beforeMemberID)
        } else if ServiceGroup.groupID(fromMemberID: memberID) == nil {
            serviceOrderIDs.removeAll { $0 == memberID }
            insert(memberID, into: &serviceOrderIDs, before: beforeMemberID)
        }
        saveGroups()
        saveServiceOrderIDs()
    }

    /// Reorder a top-level group before another top-level group.
    func moveGroup(_ groupID: UUID, before targetGroupID: UUID?) {
        guard let sourceIndex = groups.firstIndex(where: { $0.id == groupID }) else { return }
        let group = groups.remove(at: sourceIndex)
        if let targetGroupID, let targetIndex = groups.firstIndex(where: { $0.id == targetGroupID }) {
            groups.insert(group, at: targetIndex)
        } else {
            groups.append(group)
        }
        saveGroups()
    }

    private func insert(_ memberID: String, into members: inout [String], before beforeMemberID: String?) {
        guard !members.contains(memberID) else { return }
        if let beforeMemberID, let idx = members.firstIndex(of: beforeMemberID), beforeMemberID != memberID {
            members.insert(memberID, at: idx)
        } else {
            members.append(memberID)
        }
    }

    /// Would adding `candidateGroupID` as a member of `targetGroupID` create a
    /// cycle? (True if candidate already reaches target.)
    func wouldCreateCycle(addingGroup candidateGroupID: UUID, to targetGroupID: UUID) -> Bool {
        if candidateGroupID == targetGroupID { return true }
        guard let candidate = group(withID: candidateGroupID) else { return false }
        // If target is reachable from candidate, adding candidate->...->target
        // under target would loop.
        return groupReaches(candidate, targetID: targetGroupID, visited: [])
    }

    private func groupReaches(_ group: ServiceGroup, targetID: UUID, visited: Set<UUID>) -> Bool {
        if group.id == targetID { return true }
        var v = visited
        v.insert(group.id)
        for member in group.memberServiceIDs {
            guard let gid = ServiceGroup.groupID(fromMemberID: member), !v.contains(gid) else { continue }
            guard let child = self.group(withID: gid) else { continue }
            if groupReaches(child, targetID: targetID, visited: v) { return true }
        }
        return false
    }

    // MARK: - Group execution

    /// Start every member of a group. Simultaneous groups launch members
    /// concurrently (recursing into nested groups); sequenced groups launch
    /// members in order and (optionally) stop early on failure.
    func runGroup(_ group: ServiceGroup) async {
        beginGroupOperation(group.id)
        defer { endGroupOperation(group.id) }
        await runGroup(group, visited: [])
    }

    private func runGroup(_ group: ServiceGroup, visited: Set<UUID>) async {
        guard !visited.contains(group.id) else { return }
        var v = visited
        v.insert(group.id)

        switch group.mode {
        case .simultaneous:
            // Start plain services + nested simultaneous groups all at once, but
            // run nested SEQUENCED groups as ordered units (preserving their order).
            let plainServices = directSimultaneousServices(of: group, visited: v)
            let sequencedChildren = nestedSequencedGroups(of: group, visited: v)

            await withTaskGroup(of: Void.self) { taskGroup in
                for svc in plainServices {
                    taskGroup.addTask { [weak self] in
                        await self?.start(svc)
                    }
                }
            }
            // Sequenced children each preserve their internal ordering.
            for child in sequencedChildren {
                await runGroup(child, visited: v)
            }
        case .sequenced:
            for member in group.memberServiceIDs {
                if let gid = ServiceGroup.groupID(fromMemberID: member) {
                    if let child = self.group(withID: gid) {
                        await runGroup(child, visited: v)
                    }
                    continue
                }
                guard let svc = service(withID: member) else { continue }
                if mode == .screenshot {
                    await start(svc)
                    continue
                }
                await mutateStatus(svc.id, to: .starting)
                do {
                    try await ServiceController.shared.start(svc)
                } catch {
                    lastError = "Group '\(group.name)' stopped at '\(svc.name)': \(error.localizedDescription)"
                    if group.stopOnFailure {
                        await refresh()
                        return
                    }
                }
            }
        }
        await refresh()
    }

    /// Plain leaf services reachable through simultaneous nesting (NOT crossing
    /// into sequenced groups, which are run as ordered units).
    private func directSimultaneousServices(of group: ServiceGroup, visited: Set<UUID>) -> [ViniService] {
        var result: [ViniService] = []
        for member in group.memberServiceIDs {
            if let gid = ServiceGroup.groupID(fromMemberID: member) {
                guard !visited.contains(gid), let child = self.group(withID: gid), child.mode == .simultaneous else { continue }
                var v = visited
                v.insert(gid)
                result += directSimultaneousServices(of: child, visited: v)
            } else if let svc = service(withID: member) {
                result.append(svc)
            }
        }
        return result
    }

    /// Sequenced groups reachable through simultaneous nesting.
    private func nestedSequencedGroups(of group: ServiceGroup, visited: Set<UUID>) -> [ServiceGroup] {
        var result: [ServiceGroup] = []
        for member in group.memberServiceIDs {
            guard let gid = ServiceGroup.groupID(fromMemberID: member),
                  !visited.contains(gid),
                  let child = self.group(withID: gid) else { continue }
            if child.mode == .sequenced {
                result.append(child)
            } else {
                var v = visited
                v.insert(gid)
                result += nestedSequencedGroups(of: child, visited: v)
            }
        }
        return result
    }

    /// Stop every reachable member of a group (always concurrent).
    func stopGroup(_ group: ServiceGroup) async {
        beginGroupOperation(group.id)
        defer { endGroupOperation(group.id) }
        let services = reachableServices(of: group)
        await withTaskGroup(of: Void.self) { taskGroup in
            for svc in services {
                taskGroup.addTask { [weak self] in
                    await self?.stop(svc)
                }
            }
        }
    }

    /// Restart services that are already active and start the rest.
    func restartOrStartGroup(_ group: ServiceGroup) async {
        beginGroupOperation(group.id)
        defer { endGroupOperation(group.id) }
        let services = reachableServices(of: group)
        await withTaskGroup(of: Void.self) { taskGroup in
            for svc in services where svc.isControllable {
                taskGroup.addTask { [weak self] in
                    if svc.status.isActive {
                        await self?.restart(svc)
                    } else {
                        await self?.start(svc)
                    }
                }
            }
        }
    }

    func isGroupWorking(_ groupID: UUID) -> Bool {
        workingGroupIDs.contains(groupID)
    }

    // MARK: - Expansion state (tree folders)

    func isExpanded(_ nodeID: String) -> Bool {
        expandedNodeIDs.contains(nodeID)
    }

    func toggleExpanded(_ nodeID: String) {
        if expandedNodeIDs.contains(nodeID) {
            expandedNodeIDs.remove(nodeID)
        } else {
            expandedNodeIDs.insert(nodeID)
        }
        saveExpandedNodeIDs()
    }

    // MARK: - Persistence

    private func loadUserDefinitions() {
        guard let data = defaults.data(forKey: userDefinitionsKey),
              let decoded = try? JSONDecoder().decode([UserServiceDefinition].self, from: data)
        else { return }
        userDefinitions = decoded
    }

    private func saveUserDefinitions() {
        guard mode == .normal else { return }
        guard let data = try? JSONEncoder().encode(userDefinitions) else { return }
        defaults.set(data, forKey: userDefinitionsKey)
        flushDefaults()
    }

    private func loadHiddenServiceIDs() {
        let stored = defaults.stringArray(forKey: hiddenServiceIDsKey) ?? []
        hiddenServiceIDs = Set(stored)
    }

    private func saveHiddenServiceIDs() {
        guard mode == .normal else { return }
        defaults.set(Array(hiddenServiceIDs), forKey: hiddenServiceIDsKey)
        flushDefaults()
    }

    private func loadSurfacedServiceIDs() {
        let stored = defaults.stringArray(forKey: surfacedServiceIDsKey) ?? []
        surfacedServiceIDs = Set(stored)
    }

    private func saveSurfacedServiceIDs() {
        guard mode == .normal else { return }
        defaults.set(Array(surfacedServiceIDs), forKey: surfacedServiceIDsKey)
        flushDefaults()
    }

    private func loadGroups() {
        guard let data = defaults.data(forKey: groupsKey),
              let decoded = try? JSONDecoder().decode([ServiceGroup].self, from: data)
        else { return }
        groups = decoded
    }

    private func saveGroups() {
        guard mode == .normal else { return }
        guard let data = try? JSONEncoder().encode(groups) else { return }
        defaults.set(data, forKey: groupsKey)
        flushDefaults()
    }

    private func loadExpandedNodeIDs() {
        let stored = defaults.stringArray(forKey: expandedNodeIDsKey) ?? []
        expandedNodeIDs = Set(stored)
    }

    private func saveExpandedNodeIDs() {
        guard mode == .normal else { return }
        defaults.set(Array(expandedNodeIDs), forKey: expandedNodeIDsKey)
        flushDefaults()
    }

    private func loadServiceOrderIDs() {
        serviceOrderIDs = defaults.stringArray(forKey: serviceOrderIDsKey) ?? []
    }

    private func saveServiceOrderIDs() {
        guard mode == .normal else { return }
        defaults.set(serviceOrderIDs, forKey: serviceOrderIDsKey)
        flushDefaults()
    }

    /// Force a synchronous flush of UserDefaults to disk. `cfprefsd` normally
    /// flushes lazily, which can lose recent writes if the app is killed shortly
    /// after. A menu-bar app is frequently force-quit, so we flush explicitly.
    private func flushDefaults() {
        guard mode == .normal else { return }
        defaults.synchronize()
    }

    // MARK: - Private

    private func seedScreenshotDemo() {
        let apiDefinition = UserServiceDefinition(
            id: UUID(uuidString: "1A63A431-CC68-48E1-8B8D-02DFE35CA001")!,
            name: "API Gateway",
            startCommand: "go run ./cmd/api",
            stopCommand: "pkill -f cmd/api",
            workingDirectory: "~/Code/freight-os",
            probePort: 8080,
            keepAliveOnQuit: true,
            iconSystemName: "curlybraces"
        )
        let webDefinition = UserServiceDefinition(
            id: UUID(uuidString: "1A63A431-CC68-48E1-8B8D-02DFE35CA002")!,
            name: "Web Dashboard",
            startCommand: "pnpm dev",
            stopCommand: nil,
            workingDirectory: "~/Code/freight-os/apps/web",
            probePort: 5173,
            keepAliveOnQuit: false,
            iconSystemName: "globe"
        )
        let workerDefinition = UserServiceDefinition(
            id: UUID(uuidString: "1A63A431-CC68-48E1-8B8D-02DFE35CA003")!,
            name: "Route Worker",
            startCommand: "python -m workers.routes",
            stopCommand: "pkill -f workers.routes",
            workingDirectory: "~/Code/freight-os/services/worker",
            probePort: nil,
            keepAliveOnQuit: false,
            iconSystemName: "gearshape.2"
        )
        let storybookDefinition = UserServiceDefinition(
            id: UUID(uuidString: "1A63A431-CC68-48E1-8B8D-02DFE35CA004")!,
            name: "Storybook",
            startCommand: "pnpm storybook",
            stopCommand: nil,
            workingDirectory: "~/Code/freight-os/apps/web",
            probePort: 6006,
            keepAliveOnQuit: false,
            iconSystemName: "paintpalette"
        )

        userDefinitions = [apiDefinition, webDefinition, workerDefinition, storybookDefinition]

        let apiID = "user:\(apiDefinition.id.uuidString)"
        let webID = "user:\(webDefinition.id.uuidString)"
        let workerID = "user:\(workerDefinition.id.uuidString)"
        let storybookID = "user:\(storybookDefinition.id.uuidString)"
        let postgresID = "brew:postgresql@17"
        let redisID = "brew:redis"
        let rabbitID = "brew:rabbitmq"
        let nginxID = "brew:nginx"
        let elasticID = "brew:elasticsearch"
        let mailhogID = "port:8025"

        allDiscovered = [
            ViniService(id: apiID, name: apiDefinition.name, kind: .userDefined(definition: apiDefinition), pid: 8124, port: 8080, status: .running, iconSystemName: apiDefinition.iconSystemName),
            ViniService(id: webID, name: webDefinition.name, kind: .userDefined(definition: webDefinition), pid: 8152, port: 5173, status: .running, iconSystemName: webDefinition.iconSystemName),
            ViniService(id: workerID, name: workerDefinition.name, kind: .userDefined(definition: workerDefinition), pid: nil, port: nil, status: .stopped, iconSystemName: workerDefinition.iconSystemName),
            ViniService(id: storybookID, name: storybookDefinition.name, kind: .userDefined(definition: storybookDefinition), pid: 8181, port: 6006, status: .starting, iconSystemName: storybookDefinition.iconSystemName),
            ViniService(id: postgresID, name: "PostgreSQL 17", kind: .homebrew(formula: "postgresql@17"), pid: 7421, port: 5432, status: .running, iconSystemName: "cylinder.fill"),
            ViniService(id: redisID, name: "Redis", kind: .homebrew(formula: "redis"), pid: 7398, port: 6379, status: .running, iconSystemName: "memorychip"),
            ViniService(id: rabbitID, name: "RabbitMQ", kind: .homebrew(formula: "rabbitmq"), pid: nil, port: 5672, status: .stopped, iconSystemName: "tray.full"),
            ViniService(id: nginxID, name: "Nginx", kind: .homebrew(formula: "nginx"), pid: 7460, port: 80, status: .running, iconSystemName: "network"),
            ViniService(id: elasticID, name: "Elasticsearch", kind: .homebrew(formula: "elasticsearch"), pid: nil, port: 9200, status: .stopped, iconSystemName: "magnifyingglass"),
            ViniService(id: mailhogID, name: "Mailhog", kind: .portProbe(port: 8025), pid: 8244, port: 8025, status: .running, iconSystemName: "envelope")
        ]

        let backendID = UUID(uuidString: "62D1CA6A-7076-4C36-8C70-6E634E937001")!
        let frontendID = UUID(uuidString: "62D1CA6A-7076-4C36-8C70-6E634E937002")!
        let startupID = UUID(uuidString: "62D1CA6A-7076-4C36-8C70-6E634E937003")!
        let freightID = UUID(uuidString: "62D1CA6A-7076-4C36-8C70-6E634E937004")!

        let backend = ServiceGroup(
            id: backendID,
            name: "Backend",
            mode: .simultaneous,
            memberServiceIDs: [apiID, postgresID, redisID, rabbitID, workerID],
            iconSystemName: "server.rack",
            isPinnedToMenuBar: true
        )
        let frontend = ServiceGroup(
            id: frontendID,
            name: "Frontend",
            mode: .simultaneous,
            memberServiceIDs: [webID, storybookID, nginxID],
            iconSystemName: "globe"
        )
        let startup = ServiceGroup(
            id: startupID,
            name: "Morning Startup",
            mode: .sequenced,
            memberServiceIDs: [postgresID, redisID, apiID, webID],
            iconSystemName: "arrow.right.to.line",
            isPinnedToMenuBar: false
        )
        let freight = ServiceGroup(
            id: freightID,
            name: "Freight Ops",
            mode: .simultaneous,
            memberServiceIDs: [backend.memberReferenceID, frontend.memberReferenceID, startup.memberReferenceID],
            iconSystemName: "truck.box",
            isPinnedToMenuBar: true
        )

        groups = [freight, backend, frontend, startup]
        expandedNodeIDs = [
            freight.memberReferenceID,
            backend.memberReferenceID,
            frontend.memberReferenceID,
            ServiceTree.ungroupedNodeID
        ]
        serviceOrderIDs = [mailhogID, elasticID]
        screenshotLogsByServiceID = Self.screenshotLogs(
            apiID: apiID,
            webID: webID,
            workerID: workerID,
            storybookID: storybookID,
            postgresID: postgresID,
            redisID: redisID,
            nginxID: nginxID
        )
        applyFilter()
    }

    private static func screenshotLogs(
        apiID: String,
        webID: String,
        workerID: String,
        storybookID: String,
        postgresID: String,
        redisID: String,
        nginxID: String
    ) -> [String: String] {
        [
            apiID: """
            ===== Vini demo session 2026-06-05T09:14:21Z =====
            $ go run ./cmd/api
            [09:14:22] config loaded env=local region=us-east-1
            [09:14:22] connected to postgres host=localhost port=5432 db=freight
            [09:14:23] redis cache ready url=redis://localhost:6379
            [09:14:23] route optimizer warm cache: 184 lanes
            [09:14:24] API listening on http://localhost:8080
            [09:14:27] GET /health 200 4ms
            [09:14:31] POST /loads/search 200 42ms carriers=18
            """,
            webID: """
            ===== Vini demo session 2026-06-05T09:14:18Z =====
            $ pnpm dev
            VITE v6.0.0 ready in 411 ms
            Local:   http://localhost:5173/
            Network: use --host to expose
            [hmr] connected
            [freight-dashboard] loaded 12 pinned lanes
            """,
            workerID: """
            ===== Vini demo session 2026-06-05T08:55:03Z =====
            $ python -m workers.routes
            worker booted queue=route-plans concurrency=4
            processed job route-plan:SEA-LAX duration=118ms
            processed job route-plan:AUS-DEN duration=91ms
            stopped cleanly
            """,
            storybookID: """
            ===== Vini demo session 2026-06-05T09:15:02Z =====
            $ pnpm storybook
            info => Starting manager...
            info => Starting preview...
            Storybook 8.4.0 for react-vite started
            Local: http://localhost:6006/
            """,
            postgresID: """
            2026-06-05 09:13:40.118 UTC [7421] LOG: database system is ready to accept connections
            2026-06-05 09:14:22.904 UTC [7612] LOG: connection authorized: user=freight database=freight
            """,
            redisID: """
            7398:M 05 Jun 2026 09:13:41.245 * Ready to accept connections tcp
            7398:M 05 Jun 2026 09:14:23.003 * Background saving started by pid 7410
            """,
            nginxID: """
            2026/06/05 09:13:49 [notice] 7460#0: start worker processes
            2026/06/05 09:14:30 [info] 7461#0: *42 client 127.0.0.1 requested /api/loads
            """
        ]
    }

    private func simulateServiceAction(_ id: String, pending: ServiceStatus, final: ServiceStatus) async {
        await mutateStatus(id, to: pending)
        try? await Task.sleep(nanoseconds: 180_000_000)
        await mutateStatus(id, to: final)
    }

    private func mutateStatus(_ id: String, to status: ServiceStatus) async {
        if let idx = services.firstIndex(where: { $0.id == id }) {
            services[idx].status = status
        }
        if let idx = allDiscovered.firstIndex(where: { $0.id == id }) {
            allDiscovered[idx].status = status
        }
    }

    private func beginGroupOperation(_ id: UUID) {
        workingGroupIDs.insert(id)
    }

    private func endGroupOperation(_ id: UUID) {
        workingGroupIDs.remove(id)
    }

    #if DEBUG
    /// Test seam: seed discovered services without hitting the live machine.
    func _setDiscoveredForTesting(_ discovered: [ViniService]) {
        allDiscovered = discovered
        applyFilter()
    }
    #endif
}
