import AppKit
import Combine
import SwiftUI

/// Owns the `NSStatusItem` and keeps the menu-bar popover alive.
@MainActor
final class MenuBarManager {
    private let statusItem: NSStatusItem
    private var popover: NSPopover?
    private var pinnedStatusItems: [UUID: NSStatusItem] = [:]
    private var pinnedPopovers: [UUID: NSPopover] = [:]
    private var cancellables: Set<AnyCancellable> = []
    private let servicesStore: ServicesStore

    init(servicesStore: ServicesStore) {
        self.servicesStore = servicesStore
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        configureButton()
        configurePopover()
        observeStore()
        reconcilePinnedItems()
    }

    private func configureButton() {
        guard let button = statusItem.button else { return }
        button.image = NSImage(systemSymbolName: "figure.run", accessibilityDescription: "Vini")
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

    private func observeStore() {
        servicesStore.$groups
            .combineLatest(servicesStore.$services)
            .combineLatest(servicesStore.$workingGroupIDs)
            // Coalesce bursts of state changes (a single pin toggle publishes
            // groups, and refreshes publish services/workingGroupIDs) into one
            // reconcile pass. Rapid create/remove thrash on NSStatusBar was
            // dropping newly-pinned items and mis-associating removals.
            .debounce(for: .milliseconds(50), scheduler: RunLoop.main)
            .sink { [weak self] _, _ in
                self?.reconcilePinnedItems()
            }
            .store(in: &cancellables)
    }

    private func reconcilePinnedItems() {
        let pinnedGroups = servicesStore.groups.filter(\.isPinnedToMenuBar)
        let pinnedIDs = Set(pinnedGroups.map(\.id))

        // Snapshot keys first: we mutate the dictionaries in the loop below, and
        // iterating `pinnedStatusItems.keys` directly while mutating is fragile.
        let staleIDs = pinnedStatusItems.keys.filter { !pinnedIDs.contains($0) }
        for id in staleIDs {
            if let item = pinnedStatusItems[id] {
                NSStatusBar.system.removeStatusItem(item)
            }
            pinnedStatusItems.removeValue(forKey: id)
            pinnedPopovers.removeValue(forKey: id)
        }

        for group in pinnedGroups {
            // Always ensure the popover exists and points at this exact group id
            // BEFORE the button can be clicked, so `togglePinnedPopover` never
            // resolves a nil or stale popover.
            configurePinnedPopover(for: group)

            let item = pinnedStatusItems[group.id] ?? makePinnedStatusItem(for: group)
            pinnedStatusItems[group.id] = item
            configurePinnedStatusItem(item, for: group)
        }
    }

    private func makePinnedStatusItem(for group: ServiceGroup) -> NSStatusItem {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.target = self
            button.action = #selector(togglePinnedPopover(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.identifier = NSUserInterfaceItemIdentifier(group.id.uuidString)
        }
        return item
    }

    private func configurePinnedStatusItem(_ item: NSStatusItem, for group: ServiceGroup) {
        guard let button = item.button else { return }
        button.identifier = NSUserInterfaceItemIdentifier(group.id.uuidString)
        button.image = Self.statusImage(iconSystemName: group.iconSystemName, status: aggregateStatus(for: group))
        button.imagePosition = .imageOnly
        button.toolTip = group.name
    }

    private func configurePinnedPopover(for group: ServiceGroup) {
        // Create the popover once per group id and cache it. The hosted view
        // reads live state from the store via `groupID`, so it never needs to be
        // rebuilt on subsequent reconciles.
        guard pinnedPopovers[group.id] == nil else { return }
        let popover = NSPopover()
        popover.contentSize = NSSize(width: 320, height: 420)
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(
            rootView: PinnedGroupPopoverView(groupID: group.id)
                .environmentObject(servicesStore)
        )
        pinnedPopovers[group.id] = popover
    }

    @objc private func togglePinnedPopover(_ sender: NSStatusBarButton) {
        guard let rawID = sender.identifier?.rawValue,
              let groupID = UUID(uuidString: rawID),
              let group = servicesStore.group(withID: groupID),
              let popover = pinnedPopovers[groupID]
        else { return }

        if NSApp.currentEvent?.type == .rightMouseUp {
            popover.performClose(sender)
            Task { await servicesStore.restartOrStartGroup(group) }
            return
        }

        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func aggregateStatus(for group: ServiceGroup) -> PinnedGroupStatus {
        let services = servicesStore.reachableServices(of: group)
        guard !services.isEmpty else { return .noneRunning }
        if servicesStore.isGroupWorking(group.id) {
            return .transitioning
        }
        if services.contains(where: { $0.status == .starting || $0.status == .stopping }) {
            return .transitioning
        }
        let runningCount = services.filter { $0.status.isActive }.count
        if runningCount == services.count { return .allRunning }
        if runningCount > 0 { return .someRunning }
        return .noneRunning
    }

    private static func statusImage(iconSystemName: String, status: PinnedGroupStatus) -> NSImage? {
        let size = NSSize(width: 28, height: 18)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.clear.setFill()
        NSRect(origin: .zero, size: size).fill()

        let symbolName = status == .transitioning ? "arrow.triangle.2.circlepath" : iconSystemName
        let symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
            .applying(.init(paletteColors: [.white]))
        let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        symbol?.withSymbolConfiguration(symbolConfiguration)?.draw(
            in: NSRect(x: 1, y: 1, width: 16, height: 16),
            from: .zero,
            operation: .sourceOver,
            fraction: 1
        )

        let dotRect = NSRect(x: 20, y: 5, width: 8, height: 8)
        status.color.setFill()
        NSBezierPath(ovalIn: dotRect).fill()
        NSColor.windowBackgroundColor.withAlphaComponent(0.9).setStroke()
        let ring = NSBezierPath(ovalIn: dotRect.insetBy(dx: -0.75, dy: -0.75))
        ring.lineWidth = 1
        ring.stroke()

        image.unlockFocus()
        image.isTemplate = false
        return image
    }
}

private enum PinnedGroupStatus {
    case allRunning
    case someRunning
    case noneRunning
    case transitioning

    var color: NSColor {
        switch self {
        case .allRunning: .systemGreen
        case .someRunning: .systemYellow
        case .noneRunning: .systemRed
        case .transitioning: .systemYellow
        }
    }
}
