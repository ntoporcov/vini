import AppKit
import Foundation
import Combine

/// Observable live view of one service's log file.
///
/// Loads the historic tail on start, then watches the file for appended bytes
/// and streams new content. Used by both the popover preview and the pop-out
/// window.
@MainActor
final class LogSession: ObservableObject {
    let serviceID: String
    let serviceName: String
    let isFileBacked: Bool

    @Published private(set) var text: String = ""
    @Published private(set) var lines: [String] = []
    @Published private(set) var attributedText: NSAttributedString = NSAttributedString()
    /// True when this Vini instance owns the process and is actively writing
    /// the log. False for re-adopted/detached processes (historic only).
    @Published var isLiveCaptureAvailable: Bool

    private var fileHandle: FileHandle?
    private var source: DispatchSourceFileSystemObject?
    private var offset: UInt64 = 0
    private let displayLineLimit = 2_000
    private var loadTask: Task<Void, Never>?
    private let seedText: String?

    init(serviceID: String, serviceName: String, isLiveCaptureAvailable: Bool, seedText: String? = nil) {
        self.serviceID = serviceID
        self.serviceName = serviceName
        self.isLiveCaptureAvailable = isLiveCaptureAvailable
        self.seedText = seedText
        self.isFileBacked = seedText == nil
    }

    deinit {
        source?.cancel()
        try? fileHandle?.close()
    }

    /// Load the existing tail and begin watching for new output.
    func start() {
        stop()
        setText("")
        if let seedText {
            setText(seedText)
            return
        }
        loadTask = Task { [serviceID] in
            let tail = await Task.detached(priority: .userInitiated) {
                LogFileManager.readTail(serviceID)
            }.value
            guard !Task.isCancelled else { return }
            setText(tail)
            beginWatching()
        }
    }

    func stop() {
        loadTask?.cancel()
        loadTask = nil
        source?.cancel()
        source = nil
        try? fileHandle?.close()
        fileHandle = nil
    }

    func clear() {
        stop()
        if seedText != nil {
            setText("")
            return
        }
        LogFileManager.clear(serviceID)
        setText("")
        offset = 0
        beginWatching()
    }

    func reload() {
        if let seedText {
            setText(seedText)
            return
        }
        loadTask?.cancel()
        loadTask = Task { [serviceID] in
            let tail = await Task.detached(priority: .userInitiated) {
                LogFileManager.readTail(serviceID)
            }.value
            guard !Task.isCancelled else { return }
            setText(tail)
        }
    }

    // MARK: - File watching

    private func beginWatching() {
        guard isFileBacked else { return }
        let url = LogFileManager.fileURL(for: serviceID)
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        fileHandle = handle
        offset = (try? handle.seekToEnd()) ?? 0

        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: handle.fileDescriptor,
            eventMask: [.write, .extend, .delete, .rename],
            queue: .main
        )
        source = src
        src.setEventHandler { [weak self] in
            self?.handleFileEvent()
        }
        src.resume()
    }

    private func handleFileEvent() {
        guard let handle = fileHandle else { return }
        let currentEnd = (try? handle.seekToEnd()) ?? 0
        if currentEnd < offset {
            // File was truncated/rotated — reload from scratch.
            reload()
            offset = currentEnd
            return
        }
        guard currentEnd > offset else { return }
        try? handle.seek(toOffset: offset)
        let newData = handle.readDataToEndOfFile()
        offset = currentEnd
        if !newData.isEmpty {
            appendText(String(decoding: newData, as: UTF8.self))
        }
    }

    private var cachedFont: NSFont?

    private func setText(_ newText: String) {
        let trimmed = trimmedToDisplayLimit(newText)
        text = trimmed
        lines = splitLines(trimmed)
        rebuildAttributedText(trimmed)
    }

    private func rebuildAttributedText(_ rawText: String) {
        let font = cachedFont ?? NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        cachedFont = font
        attributedText = ANSIParser.attributedString(
            from: rawText,
            font: font,
            defaultForeground: .labelColor,
            defaultBackground: .clear
        )
    }

    /// Update the font size used for attributed text (call when compact mode differs).
    func setFontSize(_ size: CGFloat) {
        let font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        cachedFont = font
        if !text.isEmpty {
            rebuildAttributedText(text)
        }
    }

    private func appendText(_ newText: String) {
        setText(text + newText)
    }

    private func trimmedToDisplayLimit(_ text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > displayLineLimit else { return text }
        return lines.suffix(displayLineLimit).joined(separator: "\n")
    }

    private func splitLines(_ text: String) -> [String] {
        text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }
}
