import Foundation

/// Claude Code sessions that were running when the usage limit hit, and the ones to reopen after
/// the limit resets. Works with a single account: no second login needed.
///
/// Claude Code keeps one `~/.claude/sessions/<pid>.json` per running session. Sessions still alive at
/// the reset are left alone (with "Keep sessions going" they wait and carry on by themselves); the
/// ones that exited in the meantime are reopened with `claude --resume <id> "continue"`.
public struct LiveSession: Codable, Equatable, Sendable {
    public var pid: Int32
    public var sessionId: String
    public var cwd: String

    public init(pid: Int32, sessionId: String, cwd: String) {
        self.pid = pid; self.sessionId = sessionId; self.cwd = cwd
    }
}

public enum SessionResume {
    public static var liveDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/sessions")
    }

    /// Interactive sessions that are running now.
    public static func liveSessions(in dir: URL = liveDir, isAlive: (Int32) -> Bool = processExists) -> [LiveSession] {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap { url in
            guard let data = try? Data(contentsOf: url),
                  let v = try? JSONValue.parse(data),
                  v["kind"]?.stringValue == "interactive",
                  let pid = v["pid"]?.int64Value, let id = v["sessionId"]?.stringValue, let cwd = v["cwd"]?.stringValue,
                  isAlive(Int32(truncatingIfNeeded: pid)) else { return nil }
            return LiveSession(pid: Int32(truncatingIfNeeded: pid), sessionId: id, cwd: cwd)
        }
    }

    /// Sessions from the snapshot that are gone now.
    public static func toResume(snapshot: [LiveSession], isAlive: (Int32) -> Bool = processExists) -> [LiveSession] {
        snapshot.filter { !isAlive($0.pid) }
    }

    public static func processExists(_ pid: Int32) -> Bool { kill(pid, 0) == 0 }

    /// A `.command` script that reopens one session in Terminal. Rejects ids that are not UUIDs.
    public static func script(for s: LiveSession) -> String? {
        guard UUID(uuidString: s.sessionId) != nil else { return nil }
        let dir = "'" + s.cwd.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return """
        #!/bin/zsh -l
        cd \(dir) || exit 1
        claude --resume \(s.sessionId) "continue"

        """
    }
}
