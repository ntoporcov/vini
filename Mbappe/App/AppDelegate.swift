import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    let servicesStore = ServicesStore()
    private var menuBarManager: MenuBarManager?
    private var isTerminating = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        menuBarManager = MenuBarManager(servicesStore: servicesStore)

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
            await servicesStore.handleAppTermination()
            NSApplication.shared.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
