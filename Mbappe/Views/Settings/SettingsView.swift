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
        }
        .frame(width: 480, height: 320)
    }
}

// MARK: - General

private struct GeneralSettingsTab: View {
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
        }
        .formStyle(.grouped)
        .padding()
    }
}

#if DEBUG
#Preview {
    SettingsView()
        .environmentObject(ServicesStore())
}
#endif
