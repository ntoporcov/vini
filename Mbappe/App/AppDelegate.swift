import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    let servicesStore = ServicesStore()
    private var menuBarManager: MenuBarManager?

    func applicationDidFinishLaunching(_ notification: Notification) {
        menuBarManager = MenuBarManager(servicesStore: servicesStore)

        // Begin polling / refreshing running services on launch.
        Task {
            await servicesStore.refresh()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Menu-bar-only app — never quit when a settings window closes.
        false
    }
}
