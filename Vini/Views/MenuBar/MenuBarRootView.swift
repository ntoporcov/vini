import SwiftUI

/// Root view rendered inside the menu-bar popover.
struct MenuBarRootView: View {
    @EnvironmentObject private var store: ServicesStore
    @Environment(\.openWindow) private var openWindow
    @State private var showingManage = false
    @State private var logContext: LogContext?

    /// Active log preview (service + its live session).
    private struct LogContext: Identifiable {
        let service: ViniService
        let session: LogSession
        var id: String { service.id }
    }

    var body: some View {
        Group {
            if let logContext {
                LogPreviewView(
                    service: logContext.service,
                    session: logContext.session,
                    onBack: { self.logContext = nil },
                    onOpenWindow: {
                        openWindow(value: LogWindowTarget(
                            serviceID: logContext.service.id,
                            serviceName: logContext.service.name
                        ))
                        NSApp.activate(ignoringOtherApps: true)
                        self.logContext = nil
                    }
                )
            } else if showingManage {
                ManageServicesView(onBack: { showingManage = false })
            } else {
                mainList
            }
        }
    }

    /// Open an editor in a standalone window (not a popover sheet) so file/folder
    /// pickers behave. Activating brings the new window forward.
    private func openEditor(_ target: EditorWindowTarget) {
        openWindow(value: target)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func openMainWindow() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }

    private func viewLogs(_ service: ViniService) {
        Task {
            let session = await store.makeLogSession(for: service)
            logContext = LogContext(service: service, session: session)
        }
    }

    private var mainList: some View {
        VStack(spacing: 0) {
            MenuBarHeaderView(
                onAddService: { openEditor(.newService) },
                onAddGroup: { openEditor(.newGroup) },
                onOpenApp: { openMainWindow() }
            )
            Divider()
            ServiceListView(
                onEditGroup: { openEditor(.editGroup($0)) },
                onViewLogs: { viewLogs($0) }
            )
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
    let onOpenApp: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onOpenApp) {
                HStack(spacing: 8) {
                    Image(systemName: "figure.run")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Vini")
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Text("Open App")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open Vini")
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

    private let settingsWindowIdentifier = NSUserInterfaceItemIdentifier("com.ntoporcov.vini.settings")

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

            Button("Settings") {
                showSettingsWindow()
            }
            .font(.caption)
            .buttonStyle(.borderless)
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

    private func showSettingsWindow() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)

        Task { @MainActor in
            for delay in [0, 50_000_000, 200_000_000] {
                if delay > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(delay))
                }
                NSApp.activate(ignoringOtherApps: true)
                bringSettingsWindowToFront()
            }
        }
    }

    private func bringSettingsWindowToFront() {
        NSApp.windows
            .filter { window in
                window.identifier == settingsWindowIdentifier
                    || window.title.localizedCaseInsensitiveContains("settings")
            }
            .forEach { window in
                window.identifier = settingsWindowIdentifier
                window.makeKeyAndOrderFront(nil)
                window.orderFrontRegardless()
            }
    }
}

#if DEBUG
#Preview {
    MenuBarRootView()
        .environmentObject(ServicesStore())
}
#endif
