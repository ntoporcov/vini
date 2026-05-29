import SwiftUI

@main
struct MbappeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // The app is menu-bar only (LSUIElement = true).
        // All UI is driven from AppDelegate via NSStatusItem.
        Settings {
            SettingsView()
                .environmentObject(appDelegate.servicesStore)
        }

        // Standalone logs windows, one per service (opened from the popover).
        WindowGroup(for: LogWindowTarget.self) { $target in
            if let target {
                LogWindowView(target: target)
                    .environmentObject(appDelegate.servicesStore)
            }
        }
        .windowResizability(.contentMinSize)

        // Service / group create + edit flows run in a real window so file/folder
        // pickers behave correctly (popover sheets fight for focus).
        WindowGroup(for: EditorWindowTarget.self) { $target in
            if let target {
                EditorWindowView(target: target)
                    .environmentObject(appDelegate.servicesStore)
            }
        }
        .windowResizability(.contentSize)
    }
}
