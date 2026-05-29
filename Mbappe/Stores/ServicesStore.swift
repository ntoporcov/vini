import Foundation
import Combine

/// Central store for all discovered services.
/// Views observe this directly via `@EnvironmentObject`.
@MainActor
final class ServicesStore: ObservableObject {
    // MARK: - State

    @Published private(set) var services: [MbappeService] = []
    @Published private(set) var isRefreshing: Bool = false
    @Published private(set) var lastError: String? = nil

    /// User-defined services configured in-app. Persisted to UserDefaults.
    @Published private(set) var userDefinitions: [UserServiceDefinition] = []

    private let userDefinitionsKey = "mbappe.userDefinitions"

    init() {
        loadUserDefinitions()
    }

    // MARK: - Refresh

    /// Discover currently running services and update state.
    func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }
        services = await ServiceDiscovery.shared.discover(userDefinitions: userDefinitions)
    }

    // MARK: - Actions

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

    // MARK: - User definitions

    func addUserDefinition(_ definition: UserServiceDefinition) {
        userDefinitions.append(definition)
        saveUserDefinitions()
        Task { await refresh() }
    }

    func removeUserDefinition(id: UUID) {
        userDefinitions.removeAll { $0.id == id }
        saveUserDefinitions()
        Task { await refresh() }
    }

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

    // MARK: - Private

    private func mutateStatus(_ id: String, to status: ServiceStatus) async {
        guard let idx = services.firstIndex(where: { $0.id == id }) else { return }
        services[idx].status = status
    }
}
