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

    @Published private(set) var text: String = ""
    /// True when this Mbappe instance owns the process and is actively writing
    /// the log. False for re-adopted/detached processes (historic only).
    @Published var isLiveCaptureAvailable: Bool

    private var fileHandle: FileHandle?
    private var source: DispatchSourceFileSystemObject?
    private var offset: UInt64 = 0

    init(serviceID: String, serviceName: String, isLiveCaptureAvailable: Bool) {
        self.serviceID = serviceID
        self.serviceName = serviceName
        self.isLiveCaptureAvailable = isLiveCaptureAvailable
    }

    deinit {
        source?.cancel()
        try? fileHandle?.close()
    }

    /// Load the existing tail and begin watching for new output.
    func start() {
        text = LogFileManager.readTail(serviceID)
        beginWatching()
    }

    func stop() {
        source?.cancel()
        source = nil
        try? fileHandle?.close()
        fileHandle = nil
    }

    func clear() {
        stop()
        LogFileManager.clear(serviceID)
        text = ""
        offset = 0
        beginWatching()
    }

    func reload() {
        text = LogFileManager.readTail(serviceID)
    }

    // MARK: - File watching

    private func beginWatching() {
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
            text = LogFileManager.readTail(serviceID)
            offset = currentEnd
            return
        }
        guard currentEnd > offset else { return }
        try? handle.seek(toOffset: offset)
        let newData = handle.readDataToEndOfFile()
        offset = currentEnd
        if !newData.isEmpty {
            text.append(String(decoding: newData, as: UTF8.self))
        }
    }
}
