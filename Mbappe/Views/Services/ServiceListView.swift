import SwiftUI

/// Scrollable list of service groups and individual services.
struct ServiceListView: View {
    @EnvironmentObject private var store: ServicesStore

    /// Called when the user asks to edit a group.
    var onEditGroup: (ServiceGroup) -> Void = { _ in }
    /// Called when the user asks to view a service's logs.
    var onViewLogs: (MbappeService) -> Void = { _ in }

    var body: some View {
        if store.services.isEmpty && store.groups.isEmpty {
            emptyStateView
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    if !store.groups.isEmpty {
                        sectionHeader("Groups")
                        ForEach(store.groups) { group in
                            GroupRowView(group: group, onEdit: { onEditGroup(group) })
                            Divider().padding(.leading, 48)
                        }
                    }

                    if !store.services.isEmpty {
                        if !store.groups.isEmpty {
                            sectionHeader("Services")
                        }
                        ForEach(store.services) { service in
                            ServiceRowView(service: service, onViewLogs: { onViewLogs(service) })
                            if service.id != store.services.last?.id {
                                Divider().padding(.leading, 48)
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: 380)
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        HStack {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 4)
    }

    private var emptyStateView: some View {
        VStack(spacing: 8) {
            Image(systemName: "server.rack")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No services found")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("Use + to add a service or group.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}

#if DEBUG
#Preview {
    ServiceListView()
        .environmentObject(ServicesStore())
        .frame(width: 320)
}
#endif
