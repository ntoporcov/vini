import SwiftUI

/// Scrollable list of all discovered services.
struct ServiceListView: View {
    @EnvironmentObject private var store: ServicesStore

    var body: some View {
        if store.services.isEmpty {
            emptyStateView
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(store.services) { service in
                        ServiceRowView(service: service)
                        if service.id != store.services.last?.id {
                            Divider()
                                .padding(.leading, 48)
                        }
                    }
                }
            }
            .frame(maxHeight: 380)
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 8) {
            Image(systemName: "server.rack")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("No services found")
                .font(.subheadline)
                .foregroundStyle(.secondary)
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
