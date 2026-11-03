import Foundation

/// The two Claude Code settings that keep running sessions going across a switch:
/// - `autoContinueAtUsageLimit`: at a limit the session waits and continues instead of stopping.
/// - `CLAUDE_CODE_RETRY_WATCHDOG_USAGE_LIMIT_RECHECK_MS`: while waiting, it probes every minute
///   (the lowest Claude Code allows). Sessions re-read the login from the keychain every 30 s, so
///   the first probe after a switch goes out on the new account and the turn carries on.
public enum ClaudeSettings {
    public static let autoContinueKey = "autoContinueAtUsageLimit"
    public static let recheckEnv = "CLAUDE_CODE_RETRY_WATCHDOG_USAGE_LIMIT_RECHECK_MS"
    public static let recheckMs = "60000"

    public static var liveURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
    }

    public static func keepsSessionsGoing(at url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url), let v = try? JSONValue.parse(data) else { return false }
        return v[autoContinueKey] == .bool(true) && v["env"]?[recheckEnv] == .string(recheckMs)
    }

    /// Turns both settings on or off, keeping every other setting. Writes nothing when
    /// the file already says the same.
    public static func setKeepSessionsGoing(_ on: Bool, at url: URL) throws {
        var v: JSONValue = .object([:])
        if let data = try? Data(contentsOf: url) { v = try JSONValue.parse(data) }
        let before = v
        if on {
            v[autoContinueKey] = .bool(true)
            if v["env"] == nil { v["env"] = .object([:]) }
            v["env"]?[recheckEnv] = .string(recheckMs)
        } else {
            v[autoContinueKey] = nil
            v["env"]?[recheckEnv] = nil
            if v["env"] == .object([:]) { v["env"] = nil }
        }
        guard v != before else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try AccountManager.atomicWrite(try e.encode(v), to: url)
    }
}
