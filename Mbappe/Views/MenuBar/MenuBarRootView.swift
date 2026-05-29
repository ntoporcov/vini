import SwiftUI

/// Root view rendered inside the menu-bar popover.
struct MenuBarRootView: View {
    @EnvironmentObject private var store: ServicesStore
    @State private var showingManage = false

    var body: some View {
        if showingManage {
            ManageServicesView(onBack: { showingManage = false })
        } else {
            mainList
        }
    }

    private var mainList: some View {
        VStack(spacing: 0) {
            MenuBarHeaderView()
            Divider()
            ServiceListView()
            Divider()
            MenuBarFooterView(onManage: { showingManage = true })
        }
        .frame(width: 320)
        .background(.ultraThinMaterial)
    }
}

// MARK: - Header

private struct MenuBarHeaderView: View {
    @EnvironmentObject private var store: ServicesStore

    var body: some View {
        HStack {
            Text("Services")
                .font(.headline)
            Spacer()
            if store.isRefreshing {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button {
                    Task { await store.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

// MARK: - Footer

private struct MenuBarFooterView: View {
    @EnvironmentObject private var store: ServicesStore
    let onManage: () -> Void

    var body: some View {
        HStack {
            Button {
                onManage()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "eye.slash")
                    Text("Hidden")
                    if store.hasManageableServices {
                        Text("\(store.manageableServices.count)")
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(.secondary.opacity(0.25)))
                    }
                }
                .font(.caption)
            }
            .buttonStyle(.borderless)

            Spacer()

            SettingsLink {
                Text("Settings")
                    .font(.caption)
            }
            Divider()
                .frame(height: 12)
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .font(.caption)
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }
}

#if DEBUG
#Preview {
    MenuBarRootView()
        .environmentObject(ServicesStore())
}
#endif
