import SwiftUI

/// Root view rendered inside the menu-bar popover.
struct MenuBarRootView: View {
    @EnvironmentObject private var store: ServicesStore

    var body: some View {
        VStack(spacing: 0) {
            MenuBarHeaderView()
            Divider()
            ServiceListView()
            Divider()
            MenuBarFooterView()
        }
        .frame(width: 320)
        .background(.ultraThinMaterial)
    }
}

// MARK: - Header

private struct MenuBarHeaderView: View {
    @EnvironmentObject private var store: ServicesStore

    var body: some View {
        HStack {
            Text("Services")
                .font(.headline)
            Spacer()
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
    var body: some View {
        HStack {
            Spacer()
            SettingsLink {
                Text("Settings")
                    .font(.caption)
            }
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
}

#if DEBUG
#Preview {
    MenuBarRootView()
        .environmentObject(ServicesStore())
}
#endif
