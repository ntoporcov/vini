import AppKit
import SwiftUI

/// Owns the `NSStatusItem` and keeps the menu-bar popover alive.
@MainActor
final class MenuBarManager {
    private let statusItem: NSStatusItem
    private var popover: NSPopover?
    private let servicesStore: ServicesStore

    init(servicesStore: ServicesStore) {
        self.servicesStore = servicesStore
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        configureButton()
        configurePopover()
    }

    private func configureButton() {
        guard let button = statusItem.button else { return }
        button.image = NSImage(systemSymbolName: "play.circle.fill", accessibilityDescription: "Mbappe")
        button.action = #selector(togglePopover(_:))
        button.target = self
    }

    private func configurePopover() {
        let popover = NSPopover()
        popover.contentSize = NSSize(width: 320, height: 480)
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(
            rootView: MenuBarRootView()
                .environmentObject(servicesStore)
        )
        self.popover = popover
    }

    @objc private func togglePopover(_ sender: NSStatusBarButton) {
        guard let popover else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}
