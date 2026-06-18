import AppKit
import SwiftUI

@MainActor
final class SettingsWindowManager: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowManager()

    private let windowIdentifier = NSUserInterfaceItemIdentifier("com.ntoporcov.vini.settings")
    private weak var servicesStore: ServicesStore?
    private var window: NSWindow?

    private override init() {}

    func show(servicesStore: ServicesStore) {
        self.servicesStore = servicesStore

        let window = window ?? makeWindow(servicesStore: servicesStore)
        self.window = window

        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    private func makeWindow(servicesStore: ServicesStore) -> NSWindow {
        let controller = NSHostingController(
            rootView: SettingsView()
                .environmentObject(servicesStore)
        )
        let window = NSWindow(contentViewController: controller)
        window.title = "Settings"
        window.identifier = windowIdentifier
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 560, height: 520))
        window.minSize = NSSize(width: 560, height: 520)
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace]
        window.delegate = self
        window.center()
        return window
    }

    func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard servicesStore?.isScreenshotMode != true else { return }
            let hasVisibleWindow = NSApp.windows.contains { window in
                window.isVisible && window.canBecomeKey && window.identifier != windowIdentifier
            }
            if !hasVisibleWindow {
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }
}
