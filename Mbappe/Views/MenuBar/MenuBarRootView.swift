import SwiftUI

/// Root view rendered inside the menu-bar popover.
struct MenuBarRootView: View {
    @EnvironmentObject private var store: ServicesStore
    @State private var showingManage = false
    @State private var activeSheet: EditorSheet?

    /// Which editor sheet is presented, if any.
    private enum EditorSheet: Identifiable {
        case newService
        case newGroup
        case editGroup(ServiceGroup)

        var id: String {
            switch self {
            case .newService: "newService"
            case .newGroup: "newGroup"
            case .editGroup(let group): "editGroup-\(group.id)"
            }
        }
    }

    var body: some View {
        Group {
            if showingManage {
                ManageServicesView(onBack: { showingManage = false })
            } else {
                mainList
            }
        }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .newService:
                UserServiceEditorView()
                    .environmentObject(store)
            case .newGroup:
                GroupEditorView()
                    .environmentObject(store)
            case .editGroup(let group):
                GroupEditorView(editing: group)
                    .environmentObject(store)
            }
        }
    }

    private var mainList: some View {
        VStack(spacing: 0) {
            MenuBarHeaderView(
                onAddService: { activeSheet = .newService },
                onAddGroup: { activeSheet = .newGroup }
            )
            Divider()
            ServiceListView(onEditGroup: { activeSheet = .editGroup($0) })
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
    let onAddService: () -> Void
    let onAddGroup: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text("Services")
                .font(.headline)
            Spacer()
            Menu {
                Button {
                    onAddService()
                } label: {
                    Label("New Service…", systemImage: "terminal")
                }
                Button {
                    onAddGroup()
                } label: {
                    Label("New Group…", systemImage: "rectangle.3.group")
                }
            } label: {
                Image(systemName: "plus")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()

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
