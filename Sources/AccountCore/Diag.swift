import Foundation

/// Tiny diagnostics log (no tokens, no secrets): `~/Library/Logs/ClaudeAccountBar.log`.
/// Answers "why did it not switch?" after the fact. Trimmed to its last ~200 KB when it grows.
public enum Diag {
    public static var url: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/ClaudeAccountBar.log")
    }
    private static let lock = NSLock()
    private static let stamp: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.timeZone = .current; return f
    }()

    public static func log(_ message: String) {
        // Only the installed app writes the log; tests and tools running the core code stay silent.
        guard Bundle.main.bundleIdentifier == "com.orbital.claude-account-bar" else { return }
        lock.lock(); defer { lock.unlock() }
        let line = "\(stamp.string(from: Date())) \(message)\n"
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 400_000,
           let data = try? Data(contentsOf: url) {
            try? data.suffix(200_000).write(to: url)
        }
        if let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: Data(line.utf8))
        } else {
            fm.createFile(atPath: url.path, contents: Data(line.utf8), attributes: [.posixPermissions: 0o600])
        }
    }
}
