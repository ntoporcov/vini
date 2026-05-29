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

    private let userDefinitionsKey = "mbappe.userDefinitions"
    private let hiddenServiceIDsKey = "mbappe.hiddenServiceIDs"
    private let surfacedServiceIDsKey = "mbappe.surfacedServiceIDs"

    init() {
        loadUserDefinitions()
        loadHiddenServiceIDs()
        loadSurfacedServiceIDs()
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
    }

    private func loadHiddenServiceIDs() {
        let stored = UserDefaults.standard.stringArray(forKey: hiddenServiceIDsKey) ?? []
        hiddenServiceIDs = Set(stored)
    }

    private func saveHiddenServiceIDs() {
        UserDefaults.standard.set(Array(hiddenServiceIDs), forKey: hiddenServiceIDsKey)
    }

    private func loadSurfacedServiceIDs() {
        let stored = UserDefaults.standard.stringArray(forKey: surfacedServiceIDsKey) ?? []
        surfacedServiceIDs = Set(stored)
    }

    private func saveSurfacedServiceIDs() {
        UserDefaults.standard.set(Array(surfacedServiceIDs), forKey: surfacedServiceIDsKey)
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
