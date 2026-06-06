import SwiftUI

@main
struct ViniApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Window("Vini", id: "main") {
            MainWindowView()
                .environmentObject(appDelegate.servicesStore)
        }
        .windowResizability(.contentMinSize)

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
