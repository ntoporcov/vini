import Foundation

/// Manages on-disk log files for services.
///
/// Files live under `~/Library/Application Support/Vini/logs/<sanitized-id>.log`.
/// Each file is size-bounded: when it exceeds `maxBytes` it is rotated to
/// `<file>.1` (a single previous generation is kept).
enum LogFileManager {
    static let maxBytes: UInt64 = 2 * 1024 * 1024  // 2 MB per service

    /// Root directory for all log files. Created on demand.
    static var logsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base
            .appendingPathComponent("Vini", isDirectory: true)
            .appendingPathComponent("logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The log file URL for a given service id.
    static func fileURL(for serviceID: String) -> URL {
        logsDirectory.appendingPathComponent("\(sanitize(serviceID)).log")
    }

    /// Replace characters that are unsafe in filenames.
    static func sanitize(_ id: String) -> String {
        id.map { ch -> Character in
            (ch.isLetter || ch.isNumber || ch == "-" || ch == "_") ? ch : "_"
        }.reduce(into: "") { $0.append($1) }
    }

    /// Open (creating if needed) a file handle positioned at end for appending.
    /// Rotates first if the file is already over the size limit.
    static func openForAppending(_ serviceID: String) -> FileHandle? {
        let url = fileURL(for: serviceID)
        rotateIfNeeded(serviceID)
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        let handle = try? FileHandle(forWritingTo: url)
        try? handle?.seekToEnd()
        return handle
    }

    /// Append a session separator marking a fresh start.
    static func writeSessionHeader(_ serviceID: String, command: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let header = "\n===== Vini session \(stamp) =====\n$ \(command)\n"
        append(serviceID, text: header)
    }

    /// Append arbitrary text to a service's log file.
    static func append(_ serviceID: String, text: String) {
        guard let handle = openForAppending(serviceID), let data = text.data(using: .utf8) else { return }
        try? handle.write(contentsOf: data)
        try? handle.close()
    }

    /// Read the tail of a log file (up to `maxBytes` worth, last `lineLimit` lines).
    static func readTail(_ serviceID: String, lineLimit: Int = 2000) -> String {
        let url = fileURL(for: serviceID)
        guard let data = try? Data(contentsOf: url) else { return "" }
        // Cap how much we decode for very large files.
        let slice = data.count > Int(maxBytes) ? data.suffix(Int(maxBytes)) : data
        let text = String(decoding: slice, as: UTF8.self)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.count <= lineLimit { return text }
        return lines.suffix(lineLimit).joined(separator: "\n")
    }

    /// Current byte size of a service's log file.
    static func size(_ serviceID: String) -> UInt64 {
        let url = fileURL(for: serviceID)
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? NSNumber)?.uint64Value ?? 0
    }

    /// Delete a service's log file (and its rotated generation).
    static func clear(_ serviceID: String) {
        let url = fileURL(for: serviceID)
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: url.appendingPathExtension("1"))
    }

    /// Rotate `<file>.log` -> `<file>.log.1` when it exceeds the size limit.
    static func rotateIfNeeded(_ serviceID: String) {
        let url = fileURL(for: serviceID)
        guard size(serviceID) > maxBytes else { return }
        let rotated = url.appendingPathExtension("1")
        try? FileManager.default.removeItem(at: rotated)
        try? FileManager.default.moveItem(at: url, to: rotated)
    }
}

/// A long-lived writer for one running service's log file.
///
/// `LogFileManager.append` reopens the file on every call — two `stat`s, an `open`,
/// an `lseek` and a `close` per chunk. A chatty dev server emits many small writes,
/// so live capture holds one handle open and rotates off a byte counter instead.
///
/// `@unchecked Sendable`: state is guarded by `lock`. Required because this is
/// captured by a `FileHandle.readabilityHandler`, which runs on a dispatch queue.
final class LogSink: @unchecked Sendable {
    private let serviceID: String
    private let lock = NSLock()
    private var handle: FileHandle?
    private var bytesWritten: UInt64 = 0
    private var isFinished = false

    init(serviceID: String) {
        self.serviceID = serviceID
    }

    func write(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard !isFinished, !data.isEmpty else { return }

        if handle == nil {
            handle = LogFileManager.openForAppending(serviceID)
            bytesWritten = LogFileManager.size(serviceID)
        }
        guard let handle else { return }

        try? handle.write(contentsOf: data)
        bytesWritten += UInt64(data.count)

        if bytesWritten > LogFileManager.maxBytes {
            try? handle.close()
            self.handle = nil
            LogFileManager.rotateIfNeeded(serviceID)
            bytesWritten = 0
        }
    }

    /// Release the file descriptor. Safe to call more than once.
    func finish() {
        lock.lock()
        defer { lock.unlock() }
        guard !isFinished else { return }
        isFinished = true
        try? handle?.close()
        handle = nil
    }

    deinit {
        try? handle?.close()
    }
}

/// Drains a pipe's read end into a `LogSink`, uninstalling itself at EOF.
///
/// The EOF teardown is the whole point of this type. A file descriptor at EOF is
/// *permanently* readable, so a `readabilityHandler` that merely returns when it
/// sees no data causes the dispatch source to re-fire in a tight loop — measured
/// at ~1M callbacks per second, i.e. a saturated CPU core for every service whose
/// process has exited.
///
/// `@unchecked Sendable`: `handle` and `sink` are both internally synchronised, and
/// the handler installed on a `FileHandle` is serialised by its dispatch source.
final class PipeLogReader: @unchecked Sendable {
    private let handle: FileHandle
    private let sink: LogSink

    init(handle: FileHandle, sink: LogSink) {
        self.handle = handle
        self.sink = sink
    }

    /// Whether a readability handler is currently installed.
    var isReading: Bool { handle.readabilityHandler != nil }

    func start() {
        handle.readabilityHandler = { [sink] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                // EOF. Must uninstall, or this spins forever.
                handle.readabilityHandler = nil
                sink.finish()
                return
            }
            sink.write(data)
        }
    }

    /// Uninstall the handler and release the log file descriptor. Idempotent.
    func stop() {
        handle.readabilityHandler = nil
        sink.finish()
    }
}
