import Foundation
import Synchronization

/// A small thread-safe log the user can export from Settings and send back to
/// the developer after testing on a real phone. Keeps recent lines in memory and
/// appends everything to a file (rotated at ~1 MB).
public final class DiagnosticsLog: Sendable {
    private struct State {
        var entries: [String] = []
    }

    private let state = Mutex(State())
    private let fileURL: URL?
    private let maxEntries: Int
    private let maxFileBytes: Int
    private let now: @Sendable () -> Date

    public init(
        fileURL: URL?,
        maxEntries: Int = 2000,
        maxFileBytes: Int = 1_000_000,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.fileURL = fileURL
        self.maxEntries = maxEntries
        self.maxFileBytes = maxFileBytes
        self.now = now
    }

    public func log(_ message: String, category: String = "app") {
        let line = "\(now().ISO8601Format()) [\(category)] \(message)"
        state.withLock { state in
            state.entries.append(line)
            if state.entries.count > maxEntries {
                state.entries.removeFirst(state.entries.count - maxEntries)
            }
            append(line)
        }
    }

    /// Recent lines held in memory (this launch only).
    public func recentEntries() -> [String] {
        state.withLock { $0.entries }
    }

    /// The whole log file (previous launches included), or the in-memory lines
    /// if there is no file.
    public func exportText() -> String {
        state.withLock { state in
            guard let fileURL else { return state.entries.joined(separator: "\n") }
            let old = (try? String(contentsOf: rotatedURL(fileURL), encoding: .utf8)) ?? ""
            let current = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
            return old + current
        }
    }

    public func clear() {
        state.withLock { state in
            state.entries.removeAll()
            guard let fileURL else { return }
            try? FileManager.default.removeItem(at: fileURL)
            try? FileManager.default.removeItem(at: rotatedURL(fileURL))
        }
    }

    // MARK: - File (called with the lock held)

    private func rotatedURL(_ url: URL) -> URL {
        url.deletingPathExtension().appendingPathExtension("old.log")
    }

    private func append(_ line: String) {
        guard let fileURL else { return }
        let fm = FileManager.default
        let data = Data((line + "\n").utf8)
        if !fm.fileExists(atPath: fileURL.path) {
            try? fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            _ = fm.createFile(atPath: fileURL.path, contents: nil)
        }
        if let size = (try? fm.attributesOfItem(atPath: fileURL.path)[.size]) as? Int, size > maxFileBytes {
            try? fm.removeItem(at: rotatedURL(fileURL))
            try? fm.moveItem(at: fileURL, to: rotatedURL(fileURL))
            _ = fm.createFile(atPath: fileURL.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }
}
