import SwiftUI

/// Log preview shown inside the popover. Has a back button and a button to
/// pop the logs out into a standalone window.
struct LogPreviewView: View {
    let service: ViniService
    let session: LogSession
    let onBack: () -> Void
    let onOpenWindow: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            LogContentView(session: session, compact: true)
                .frame(height: 320)
        }
        .frame(width: 320)
        .background(.ultraThinMaterial)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.borderless)

            Image(systemName: service.iconSystemName)
                .foregroundStyle(.secondary)
            Text(service.name)
                .font(.headline)
                .lineLimit(1)

            Spacer()

            Button(action: onOpenWindow) {
                Image(systemName: "macwindow")
            }
            .buttonStyle(.borderless)
            .help("Open in window")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}
