import Foundation

/// A Claude Code session, as needed to reopen it.
public struct SessionRef: Equatable, Sendable {
    public var sessionId: String
    public var cwd: String
    public init(sessionId: String, cwd: String) { self.sessionId = sessionId; self.cwd = cwd }
}

/// Finds sessions that were stopped by the usage limit, so they can be reopened once it resets.
/// Works with a single account.
///
/// A session stopped by a limit ends its transcript (`~/.claude/projects/*/<id>.jsonl`) with an
/// assistant entry flagged `isApiErrorMessage` whose text starts "You've hit your …". Sessions the
/// user closed on purpose end differently, so they are left alone, as are sessions still running.
public enum SessionResume {
    public static var projectsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
    }
    public static var liveDir: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/sessions")
    }
    /// How much of the end of a transcript is read.
    static let tailBytes = 64 * 1024

    /// Session ids of running Claude Code processes.
    public static func liveSessionIDs(in dir: URL = liveDir, isAlive: (Int32) -> Bool = processExists) -> Set<String> {
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        var ids = Set<String>()
        for url in files where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url), let v = try? JSONValue.parse(data),
                  let pid = v["pid"]?.int64Value, let id = v["sessionId"]?.stringValue,
                  isAlive(Int32(truncatingIfNeeded: pid)) else { continue }
            ids.insert(id)
        }
        return ids
    }

    public static func processExists(_ pid: Int32) -> Bool { kill(pid, 0) == 0 }

    /// Sessions whose transcript changed after `since` and whose last conversation entry is a limit error.
    public static func stoppedAtLimit(since: Date, projects: URL = projectsDir, live: Set<String>) -> [SessionRef] {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? []
        var found: [(Date, SessionRef)] = []
        for dir in dirs {
            let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            for url in files where url.pathExtension == "jsonl" {
                let id = url.deletingPathExtension().lastPathComponent
                guard !live.contains(id),
                      let m = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                      m >= since, let ref = limitStopped(transcript: url, id: id) else { continue }
                found.append((m, ref))
            }
        }
        return found.sorted { $0.0 < $1.0 }.map(\.1)
    }

    static func limitStopped(transcript url: URL, id: String) -> SessionRef? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: size > UInt64(tailBytes) ? size - UInt64(tailBytes) : 0)
        guard let data = try? h.readToEnd() else { return nil }
        return limitStopped(tail: data, id: id)
    }

    /// Pure: the end of a transcript in, the session out when it stopped at a limit.
    static func limitStopped(tail: Data, id: String) -> SessionRef? {
        for line in tail.split(separator: UInt8(ascii: "\n")).reversed() {
            guard let v = try? JSONValue.parse(Data(line)) else { continue }  // also skips a cut first line
            let type = v["type"]?.stringValue
            guard type == "assistant" || type == "user" else { continue }     // skip system / bookkeeping entries
            guard type == "assistant", v["isApiErrorMessage"] == .bool(true),
                  case .array(let parts)? = v["message"]?["content"],
                  parts.contains(where: { $0["text"]?.stringValue?.hasPrefix("You've hit your") == true || $0["text"]?.stringValue?.hasPrefix("Usage limit reached") == true }),
                  let cwd = v["cwd"]?.stringValue, !cwd.isEmpty else { return nil }
            return SessionRef(sessionId: id, cwd: cwd)
        }
        return nil
    }

    /// A `.command` script that reopens one session in Terminal. Rejects ids that are not UUIDs.
    public static func script(for s: SessionRef) -> String? {
        guard UUID(uuidString: s.sessionId) != nil else { return nil }
        let dir = "'" + s.cwd.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return """
        #!/bin/zsh -l
        cd \(dir) || exit 1
        claude --resume \(s.sessionId) "continue"

        """
    }
}
