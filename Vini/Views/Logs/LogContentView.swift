import SwiftUI

/// Reusable log viewer: a monospaced, autoscrolling tail with a small toolbar.
/// Used both in the popover preview and the pop-out window.
struct LogContentView: View {
    @ObservedObject var session: LogSession
    /// Compact mode trims chrome for the popover.
    var compact: Bool = false

    @State private var autoScroll = true
    @State private var showFindBar = false

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            logBody
        }
        .onAppear {
            session.setFontSize(compact ? 10 : 12)
            session.start()
        }
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
                showFindBar.toggle()
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.borderless)
            .help("Find (⌘F)")
            .keyboardShortcut("f", modifiers: .command)
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
        ZStack(alignment: .bottom) {
            Group {
                if session.text.isEmpty {
                    Text("No output yet.")
                        .font(.system(size: compact ? 10 : 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(8)
                } else {
                    LogTextView(
                        attributedText: session.attributedText,
                        fontSize: compact ? 10 : 12,
                        autoScroll: $autoScroll,
                        showFindBar: $showFindBar
                    )
                }
            }

            if !autoScroll && !session.text.isEmpty {
                Button {
                    autoScroll = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.down")
                            .font(.caption)
                        Text("Scroll to bottom")
                            .font(.caption)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().stroke(Color.primary.opacity(0.1)))
                }
                .buttonStyle(.plain)
                .shadow(color: .black.opacity(0.15), radius: 4, y: 2)
                .padding(.bottom, 12)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
                .animation(.easeInOut(duration: 0.2), value: autoScroll)
            }
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
    }
}
