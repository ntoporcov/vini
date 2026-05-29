import SwiftUI

/// Reusable log viewer: a monospaced, autoscrolling tail with a small toolbar.
/// Used both in the popover preview and the pop-out window.
struct LogContentView: View {
    @ObservedObject var session: LogSession
    /// Compact mode trims chrome for the popover.
    var compact: Bool = false

    @State private var autoScroll = true

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            logBody
        }
        .onAppear { session.start() }
        .onDisappear { session.stop() }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            if !session.isLiveCaptureAvailable {
                Label("Detached — historic logs only", systemImage: "bolt.slash")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else {
                Label("Live", systemImage: "dot.radiowaves.left.and.right")
                    .font(.caption2)
                    .foregroundStyle(.green)
            }
            Spacer()
            Toggle("Auto-scroll", isOn: $autoScroll)
                .toggleStyle(.checkbox)
                .font(.caption2)
            Button {
                session.clear()
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Clear log")
            if !compact {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([LogFileManager.fileURL(for: session.serviceID)])
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless)
                .help("Reveal log file in Finder")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var logBody: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(session.text.isEmpty ? "No output yet." : session.text)
                    .font(.system(size: compact ? 10 : 12, design: .monospaced))
                    .foregroundStyle(session.text.isEmpty ? .secondary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .id("logBottom")
            }
            .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
            .onChange(of: session.text) {
                if autoScroll {
                    withAnimation(.linear(duration: 0.1)) {
                        proxy.scrollTo("logBottom", anchor: .bottom)
                    }
                }
            }
        }
    }
}
