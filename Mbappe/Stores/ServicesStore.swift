import Foundation
import Combine

/// Central store for all discovered services.
/// Views observe this directly via `@EnvironmentObject`.
@MainActor
final class ServicesStore: ObservableObject {
    // MARK: - State

    /// Services shown in the main list:
    /// catalog-known services that aren't hidden, plus any surfaced unlisted services.
    @Published private(set) var services: [MbappeService] = []
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
    @Published private(set) var allDiscovered: [MbappeService] = []

    /// Service groups (simultaneous / sequenced). Persisted to UserDefaults.
    @Published private(set) var groups: [ServiceGroup] = []

    /// Tree folder node ids the user has expanded. Persisted.
    @Published private(set) var expandedNodeIDs: Set<String> = []

    private let userDefinitionsKey = "mbappe.userDefinitions"
    private let hiddenServiceIDsKey = "mbappe.hiddenServiceIDs"
    private let surfacedServiceIDsKey = "mbappe.surfacedServiceIDs"
    private let groupsKey = "mbappe.groups"
    private let expandedNodeIDsKey = "mbappe.expandedNodeIDs"

    init() {
        loadUserDefinitions()
        loadHiddenServiceIDs()
        loadSurfacedServiceIDs()
        loadGroups()
        loadExpandedNodeIDs()
    }

    // MARK: - Derived collections (for the Manage view)

    /// Catalog services the user hid — offered for unhiding.
    var hiddenCatalogServices: [MbappeService] {
        allDiscovered.filter { $0.isCatalogKnown && hiddenServiceIDs.contains($0.id) }
    }

    /// Unlisted services not currently surfaced — offered for surfacing.
    var unlistedServices: [MbappeService] {
        allDiscovered.filter { !$0.isCatalogKnown && !surfacedServiceIDs.contains($0.id) }
    }

    /// Anything the Manage view should show (hidden catalog + unsurfaced unlisted).
    var manageableServices: [MbappeService] {
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
        allDiscovered = await ServiceDiscovery.shared.discover(userDefinitions: userDefinitions)
        applyFilter()
    }

    // MARK: - App lifecycle

    /// Re-adopt any kept-alive processes left running by a previous launch,
    /// then refresh so their status reflects reality.
    func adoptPersistedProcessesAndRefresh() async {
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
        await ProcessManager.shared.handleAppTermination(keepAliveServiceIDs: keepAliveServiceIDs)
        flushDefaults()
    }

    // MARK: - Logs

    /// Whether the given service currently has a log file with content.
    func hasLogs(for service: MbappeService) -> Bool {
        LogFileManager.size(service.id) > 0
    }

    /// Build a live log session for a service. `isLiveCaptureAvailable` is false
    /// for re-adopted/detached processes (historic logs only).
    func makeLogSession(for service: MbappeService) async -> LogSession {
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

    func start(_ service: MbappeService) async {
        await mutateStatus(service.id, to: .starting)
        do {
            try await ServiceController.shared.start(service)
        } catch {
            lastError = error.localizedDescription
        }
        await refresh()
    }

    func stop(_ service: MbappeService) async {
        await mutateStatus(service.id, to: .stopping)
        do {
            try await ServiceController.shared.stop(service)
        } catch {
            lastError = error.localizedDescription
        }
        await refresh()
    }

    func restart(_ service: MbappeService) async {
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

    func isHidden(_ service: MbappeService) -> Bool {
        hiddenServiceIDs.contains(service.id)
    }

    func hide(_ service: MbappeService) {
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

    func isSurfaced(_ service: MbappeService) -> Bool {
        surfacedServiceIDs.contains(service.id)
    }

    /// Opt an unlisted service into the main list.
    func surface(id: String) {
        surfacedServiceIDs.insert(id)
        saveSurfacedServiceIDs()
        applyFilter()
    }

    /// Remove a previously surfaced unlisted service from the main list.
    func unsurface(_ service: MbappeService) {
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

    /// Delete a user-defined service. `service` must be of kind `.userDefined`.
    func delete(_ service: MbappeService) {
        guard case .userDefined(let definition) = service.kind else { return }
        removeUserDefinition(id: definition.id)
    }

    func removeUserDefinition(id: UUID) {
        userDefinitions.removeAll { $0.id == id }
        saveUserDefinitions()
        Task { await refresh() }
    }

    // MARK: - Service lookup

    /// Find a discovered service by its id.
    func service(withID id: String) -> MbappeService? {
        allDiscovered.first { $0.id == id }
    }

    func group(withID id: UUID) -> ServiceGroup? {
        groups.first { $0.id == id }
    }

    /// Resolve a group's plain-service members (non-group ids) into models, in order.
    func members(of group: ServiceGroup) -> [MbappeService] {
        group.memberServiceIDs.compactMap { service(withID: $0) }
    }

    // MARK: - Tree

    /// The full services tree (folders for simultaneous groups, leaves for
    /// services and sequenced groups, plus an Ungrouped bucket).
    var tree: [ServiceTreeNode] {
        ServiceTree.build(groups: groups, services: services)
    }

    // MARK: - Aggregate status

    /// Recursively collect the plain services reachable from a group (following
    /// nested groups), cycle-safe.
    func reachableServices(of group: ServiceGroup, visited: Set<UUID> = []) -> [MbappeService] {
        var seenVisited = visited
        seenVisited.insert(group.id)
        var result: [MbappeService] = []
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

    func updateGroup(_ group: ServiceGroup) {
        guard let idx = groups.firstIndex(where: { $0.id == group.id }) else { return }
        groups[idx] = group
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
    private func directSimultaneousServices(of group: ServiceGroup, visited: Set<UUID>) -> [MbappeService] {
        var result: [MbappeService] = []
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
        let services = reachableServices(of: group)
        await withTaskGroup(of: Void.self) { taskGroup in
            for svc in services {
                taskGroup.addTask { [weak self] in
                    await self?.stop(svc)
                }
            }
        }
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
        guard let data = UserDefaults.standard.data(forKey: userDefinitionsKey),
              let decoded = try? JSONDecoder().decode([UserServiceDefinition].self, from: data)
        else { return }
        userDefinitions = decoded
    }

    private func saveUserDefinitions() {
        guard let data = try? JSONEncoder().encode(userDefinitions) else { return }
        UserDefaults.standard.set(data, forKey: userDefinitionsKey)
        flushDefaults()
    }

    private func loadHiddenServiceIDs() {
        let stored = UserDefaults.standard.stringArray(forKey: hiddenServiceIDsKey) ?? []
        hiddenServiceIDs = Set(stored)
    }

    private func saveHiddenServiceIDs() {
        UserDefaults.standard.set(Array(hiddenServiceIDs), forKey: hiddenServiceIDsKey)
        flushDefaults()
    }

    private func loadSurfacedServiceIDs() {
        let stored = UserDefaults.standard.stringArray(forKey: surfacedServiceIDsKey) ?? []
        surfacedServiceIDs = Set(stored)
    }

    private func saveSurfacedServiceIDs() {
        UserDefaults.standard.set(Array(surfacedServiceIDs), forKey: surfacedServiceIDsKey)
        flushDefaults()
    }

    private func loadGroups() {
        guard let data = UserDefaults.standard.data(forKey: groupsKey),
              let decoded = try? JSONDecoder().decode([ServiceGroup].self, from: data)
        else { return }
        groups = decoded
    }

    private func saveGroups() {
        guard let data = try? JSONEncoder().encode(groups) else { return }
        UserDefaults.standard.set(data, forKey: groupsKey)
        flushDefaults()
    }

    private func loadExpandedNodeIDs() {
        let stored = UserDefaults.standard.stringArray(forKey: expandedNodeIDsKey) ?? []
        expandedNodeIDs = Set(stored)
    }

    private func saveExpandedNodeIDs() {
        UserDefaults.standard.set(Array(expandedNodeIDs), forKey: expandedNodeIDsKey)
        flushDefaults()
    }

    /// Force a synchronous flush of UserDefaults to disk. `cfprefsd` normally
    /// flushes lazily, which can lose recent writes if the app is killed shortly
    /// after. A menu-bar app is frequently force-quit, so we flush explicitly.
    private func flushDefaults() {
        UserDefaults.standard.synchronize()
    }

    // MARK: - Private

    private func mutateStatus(_ id: String, to status: ServiceStatus) async {
        guard let idx = services.firstIndex(where: { $0.id == id }) else { return }
        services[idx].status = status
    }

    #if DEBUG
    /// Test seam: seed discovered services without hitting the live machine.
    func _setDiscoveredForTesting(_ discovered: [MbappeService]) {
        allDiscovered = discovered
        applyFilter()
    }
    #endif
}
