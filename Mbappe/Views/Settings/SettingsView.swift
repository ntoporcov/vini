import SwiftUI

/// App-level settings window content.
struct SettingsView: View {
    @EnvironmentObject private var store: ServicesStore

    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }
            ServicesSettingsTab()
                .tabItem {
                    Label("Services", systemImage: "square.stack.3d.up")
                }
        }
        .frame(width: 520, height: 420)
    }
}

// MARK: - General

private struct GeneralSettingsTab: View {
    @AppStorage("launchAtLogin") private var launchAtLogin: Bool = false
    @AppStorage("refreshInterval") private var refreshInterval: Double = 5.0

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Launch at login", isOn: $launchAtLogin)
            }

            Section("Refresh") {
                Picker("Auto-refresh interval", selection: $refreshInterval) {
                    Text("Off").tag(0.0)
                    Text("5 seconds").tag(5.0)
                    Text("10 seconds").tag(10.0)
                    Text("30 seconds").tag(30.0)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - Services

private struct ServicesSettingsTab: View {
    @EnvironmentObject private var store: ServicesStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            List {
                Section {
                    if store.userDefinitions.isEmpty {
                        Text("No custom services yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(store.userDefinitions) { def in
                            UserServiceSettingsRow(definition: def)
                        }
                    }
                } header: {
                    sectionHeader(
                        "Custom Services",
                        actionTitle: "Add Service",
                        action: { openWindow(value: EditorWindowTarget.newService) }
                    )
                }

                Section {
                    if store.groups.isEmpty {
                        Text("No groups yet.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(store.groups) { group in
                            GroupSettingsRow(group: group)
                        }
                    }
                } header: {
                    sectionHeader(
                        "Groups",
                        actionTitle: "Add Group",
                        action: { openWindow(value: EditorWindowTarget.newGroup) }
                    )
                }
            }
        }
    }

    private func sectionHeader(_ title: String, actionTitle: String, action: @escaping () -> Void) -> some View {
        HStack {
            Text(title)
            Spacer()
            Button(actionTitle, action: action)
                .font(.caption)
        }
    }
}

private struct UserServiceSettingsRow: View {
    let definition: UserServiceDefinition
    @EnvironmentObject private var store: ServicesStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: definition.iconSystemName)
                .frame(width: 18)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(definition.name)
                    .font(.system(size: 13, weight: .medium))
                Text(definition.startCommand)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button {
                openWindow(value: EditorWindowTarget.editService(definition))
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .help("Edit")
            Button(role: .destructive) {
                store.removeUserDefinition(id: definition.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete")
        }
        .padding(.vertical, 2)
    }
}

private struct GroupSettingsRow: View {
    let group: ServiceGroup
    @EnvironmentObject private var store: ServicesStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: group.mode.iconSystemName)
                .frame(width: 18)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(group.name)
                    .font(.system(size: 13, weight: .medium))
                Text("\(group.mode.displayLabel) · \(group.memberServiceIDs.count) service\(group.memberServiceIDs.count == 1 ? "" : "s")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                openWindow(value: EditorWindowTarget.editGroup(group))
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .help("Edit")
            Button(role: .destructive) {
                store.removeGroup(id: group.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete")
        }
        .padding(.vertical, 2)
    }
}

#if DEBUG
#Preview {
    SettingsView()
        .environmentObject(ServicesStore())
}
#endif
