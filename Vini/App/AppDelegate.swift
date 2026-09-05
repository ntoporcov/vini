import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    let servicesStore: ServicesStore
    private var menuBarManager: MenuBarManager?
    private let mcpServer: ViniMCPServer
    private var cancellables: Set<AnyCancellable> = []
    private var isTerminating = false

    override init() {
        servicesStore = ServicesStore(mode: .current)
        mcpServer = ViniMCPServer(servicesStore: servicesStore)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The main Window scene opens automatically on launch, so start with
        // .regular so the app appears in the Dock and Cmd-Tab immediately.
        // When the main window closes, MainWindowView.onDisappear demotes back
        // to .accessory.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        menuBarManager = MenuBarManager(servicesStore: servicesStore)
        observeMCPServerSetting()

        if servicesStore.isMCPServerEnabled && !servicesStore.isScreenshotMode {
            Task { await setMCPServerRunning(true) }
        }

        // Re-adopt any kept-alive processes from a previous launch, then refresh.
        Task {
            await servicesStore.adoptPersistedProcessesAndRefresh()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Menu-bar-only app — never quit when a settings window closes.
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if isTerminating { return .terminateNow }
        isTerminating = true
        // Stop non-keep-alive processes before quitting; keep-alive ones are
        // persisted for re-adoption on the next launch.
        Task {
            await mcpServer.stop()
            await servicesStore.handleAppTermination()
            NSApplication.shared.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    private func observeMCPServerSetting() {
        servicesStore.$isMCPServerEnabled
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] enabled in
                guard let self else { return }
                Task { await self.setMCPServerRunning(enabled) }
            }
            .store(in: &cancellables)

        servicesStore.$mcpServerPort
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in
                guard let self, self.servicesStore.isMCPServerEnabled else { return }
                Task {
                    await self.mcpServer.stop()
                    await self.setMCPServerRunning(true)
                }
            }
            .store(in: &cancellables)
    }

    private func setMCPServerRunning(_ running: Bool) async {
        guard !servicesStore.isScreenshotMode else { return }
        if running {
            do {
                try await mcpServer.start(port: servicesStore.mcpServerPort)
            } catch {
                NSLog("Failed to start Vini MCP server: \(error.localizedDescription)")
            }
        } else {
            await mcpServer.stop()
        }
    }
}
