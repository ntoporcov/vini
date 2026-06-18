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
        .frame(width: 560, height: 520)
    }
}

// MARK: - General

private struct GeneralSettingsTab: View {
    @EnvironmentObject private var store: ServicesStore
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

            Section("MCP Server") {
                Toggle(
                    "Enable local MCP server",
                    isOn: Binding(
                        get: { store.isMCPServerEnabled },
                        set: { store.setMCPServerEnabled($0) }
                    )
                )

                Text(store.isMCPServerEnabled ? "Vini is listening for local MCP clients while the app is running." : "Enable this to let local AI agents control your Vini services.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Client configuration")
                            .font(.subheadline.weight(.medium))
                        Spacer()
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(ViniMCPConfiguration.clientConfigurationJSON, forType: .string)
                        }
                    }

                    Text(ViniMCPConfiguration.clientConfigurationJSON)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 8))
                }

                Text("Use this JSON in Claude Code, Codex, OpenCode, or any MCP client that supports stdio servers. Vini must be running and the server must be enabled.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
            HStack {
                Text("Services Tree")
                    .font(.headline)
                Spacer()
                Button("Add Service") {
                    openWindow(value: EditorWindowTarget.newService)
                    NSApp.activate(ignoringOtherApps: true)
                }
                Button("Add Group") {
                    openWindow(value: EditorWindowTarget.newGroup)
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
            .padding([.horizontal, .top], 16)
            .padding(.bottom, 8)

            ServiceListView(
                onEditGroup: { group in
                    openWindow(value: EditorWindowTarget.editGroup(group))
                    NSApp.activate(ignoringOtherApps: true)
                },
                onViewLogs: { _ in },
                maxHeight: nil
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Text("Drag services or groups onto a folder to move them. Drag onto Ungrouped to remove from groups. Use Duplicate to Group when a service should live in more than one group.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(16)
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
