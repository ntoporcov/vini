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

    private let userDefinitionsKey = "mbappe.userDefinitions"
    private let hiddenServiceIDsKey = "mbappe.hiddenServiceIDs"
    private let surfacedServiceIDsKey = "mbappe.surfacedServiceIDs"
    private let groupsKey = "mbappe.groups"

    init() {
        loadUserDefinitions()
        loadHiddenServiceIDs()
        loadSurfacedServiceIDs()
        loadGroups()
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

    /// Resolve a group's member ids into their current service models (in order).
    func members(of group: ServiceGroup) -> [MbappeService] {
        group.memberServiceIDs.compactMap { service(withID: $0) }
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
        saveGroups()
    }

    // MARK: - Group execution

    /// Start every member of a group. Simultaneous groups launch concurrently;
    /// sequenced groups launch in order and (optionally) stop early on failure.
    func runGroup(_ group: ServiceGroup) async {
        let members = members(of: group)
        switch group.mode {
        case .simultaneous:
            await withTaskGroup(of: Void.self) { taskGroup in
                for member in members {
                    taskGroup.addTask { [weak self] in
                        await self?.start(member)
                    }
                }
            }
        case .sequenced:
            for member in members {
                await mutateStatus(member.id, to: .starting)
                do {
                    try await ServiceController.shared.start(member)
                } catch {
                    lastError = "Group '\(group.name)' stopped at '\(member.name)': \(error.localizedDescription)"
                    if group.stopOnFailure {
                        await refresh()
                        return
                    }
                }
            }
            await refresh()
        }
    }

    /// Stop every member of a group (always concurrent — order doesn't matter on stop).
    func stopGroup(_ group: ServiceGroup) async {
        let members = members(of: group)
        await withTaskGroup(of: Void.self) { taskGroup in
            for member in members {
                taskGroup.addTask { [weak self] in
                    await self?.stop(member)
                }
            }
        }
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
