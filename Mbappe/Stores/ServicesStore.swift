import Foundation
import Combine

/// Central store for all discovered services.
/// Views observe this directly via `@EnvironmentObject`.
@MainActor
final class ServicesStore: ObservableObject {
    // MARK: - State

    @Published private(set) var services: [MbappeService] = []
    @Published private(set) var isRefreshing: Bool = false
    @Published private(set) var lastRefreshError: String? = nil

    // MARK: - Refresh

    /// Discover currently running services and update state.
    func refresh() async {
        isRefreshing = true
        lastRefreshError = nil
        defer { isRefreshing = false }

        do {
            let discovered = try await ServiceDiscovery.shared.discover()
            services = discovered
        } catch {
            lastRefreshError = error.localizedDescription
        }
    }

    // MARK: - Actions

    func start(_ service: MbappeService) async {
        guard let idx = services.firstIndex(where: { $0.id == service.id }) else { return }
        services[idx].status = .starting
        do {
            try await ServiceController.shared.start(service)
            services[idx].status = .running
        } catch {
            services[idx].status = .stopped
        }
        await refresh()
    }

    func stop(_ service: MbappeService) async {
        guard let idx = services.firstIndex(where: { $0.id == service.id }) else { return }
        services[idx].status = .stopping
        do {
            try await ServiceController.shared.stop(service)
            services[idx].status = .stopped
        } catch {
            services[idx].status = .unknown
        }
        await refresh()
    }

    func restart(_ service: MbappeService) async {
        await stop(service)
        await start(service)
    }
}
