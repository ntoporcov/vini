import Foundation

/// Manages on-disk log files for services.
///
/// Files live under `~/Library/Application Support/Mbappe/logs/<sanitized-id>.log`.
/// Each file is size-bounded: when it exceeds `maxBytes` it is rotated to
/// `<file>.1` (a single previous generation is kept).
enum LogFileManager {
    static let maxBytes: UInt64 = 2 * 1024 * 1024  // 2 MB per service

    /// Root directory for all log files. Created on demand.
    static var logsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base
            .appendingPathComponent("Mbappe", isDirectory: true)
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
        let header = "\n===== Mbappe session \(stamp) =====\n$ \(command)\n"
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
