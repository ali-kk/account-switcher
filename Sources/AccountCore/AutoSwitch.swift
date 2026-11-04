import Foundation

/// Decides which account Claude Code should be on.
///
/// - The main account is used whenever it has usage left.
/// - When the active account hits a limit, move to the least-used account with room.
/// - Once the main account's limit resets, go back to it.
public struct AutoSwitchPolicy: Sendable {
    /// Minimum time between automatic switches, so usage figures from just before a switch
    /// cannot bounce the login straight back.
    public var cooldown: TimeInterval = 3 * 60
    /// From this usage on, the active account is checked every sync instead of every few minutes.
    public var watchClosely: Double = 90

    public init() {}

    /// The account to switch to, or nil to stay. `assumeLimited`: a running session reported the limit
    /// even though the usage numbers (possibly stale) do not.
    public func target(active: AccountRecord?, accounts: [AccountRecord], mainID: String?,
                       lastSwitch: Date?, now: Date, assumeLimited: Bool = false) -> AccountRecord? {
        guard let active else { return nil }
        if let lastSwitch, now.timeIntervalSince(lastSwitch) < cooldown { return nil }
        func hasRoom(_ r: AccountRecord) -> Bool {
            r.id != active.id && !r.needsLogin && r.usage != nil && !(r.usage?.isLimited ?? true)
        }
        if let main = accounts.first(where: { $0.id == mainID }), hasRoom(main) { return main }
        guard active.usage?.isLimited == true || assumeLimited else { return nil }
        return accounts.filter(hasRoom).min { $0.usage!.pressure < $1.usage!.pressure }
    }

    public func needsCloseWatch(_ active: AccountRecord?) -> Bool {
        (active?.usage?.pressure ?? 0) >= watchClosely
    }

    /// The main account is not active and its limit should have reset: check it now.
    public func mainMayBeBack(main: AccountRecord?, activeID: String?, now: Date) -> Bool {
        guard let main, main.id != activeID, let u = main.usage, u.isLimited else { return false }
        return (u.limitResetsAt ?? .distantFuture) <= now
    }

    /// The active account is limited and its limit should have reset: check it every sync
    /// until the server says it has room, instead of waiting for the 3-minute usage poll.
    public func activeMayBeBack(_ active: AccountRecord?, now: Date) -> Bool {
        guard let u = active?.usage, u.isLimited else { return false }
        return (u.limitResetsAt ?? .distantFuture) <= now
    }

    /// How long the sync loop sleeps: normally `base`, shortened to land just after a reset.
    public func nextDelay(active: AccountRecord?, now: Date, base: TimeInterval = 30) -> TimeInterval {
        guard let u = active?.usage, u.isLimited, let at = u.limitResetsAt, at > now else { return base }
        return min(base, max(1, at.timeIntervalSince(now) + 2))
    }
}
