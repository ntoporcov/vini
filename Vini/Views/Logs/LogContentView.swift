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
            if !session.isFileBacked {
                Label("Demo logs", systemImage: "sparkles")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if !session.isLiveCaptureAvailable {
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
            if !compact, session.isFileBacked {
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
        GeometryReader { geometry in
            ScrollViewReader { proxy in
                ScrollView([.vertical, .horizontal]) {
                    if session.text.isEmpty {
                        Text("No output yet.")
                            .font(.system(size: compact ? 10 : 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(
                                minWidth: geometry.size.width,
                                minHeight: geometry.size.height,
                                alignment: .topLeading
                            )
                            .padding(8)
                            .id("logBottom")
                    } else {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(session.lines.enumerated()), id: \.offset) { _, line in
                                Text(line.isEmpty ? " " : line)
                                    .font(.system(size: compact ? 10 : 12, design: .monospaced))
                                    .foregroundStyle(.primary)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: true, vertical: false)
                            }
                            Color.clear
                                .frame(width: 1, height: 1)
                                .id("logBottom")
                        }
                        .frame(
                            minWidth: geometry.size.width,
                            minHeight: geometry.size.height,
                            alignment: .topLeading
                        )
                        .padding(8)
                    }
                }
                .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
                .onChange(of: session.lines.count) {
                    if autoScroll {
                        withAnimation(.linear(duration: 0.1)) {
                            proxy.scrollTo("logBottom", anchor: .bottom)
                        }
                    }
                }
            }
        }
    }
}
