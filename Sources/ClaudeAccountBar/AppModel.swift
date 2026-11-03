import AccountCore
import AppKit
import Foundation
import ServiceManagement
import UserNotifications

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var records: [AccountRecord] = []
    @Published private(set) var activeID: String?
    @Published private(set) var refreshing = false
    @Published private(set) var loadedOnce = false
    @Published private(set) var switchingID: String?
    @Published var message: String?
    @Published var notifyAtLimit: Bool {
        didSet { UserDefaults.standard.set(notifyAtLimit, forKey: "notifyAtLimit") }
    }
    @Published var autoSwitch: Bool {
        didSet { UserDefaults.standard.set(autoSwitch, forKey: "autoSwitch") }
    }
    /// Reopens sessions that stopped at a limit once it resets (works with a single account).
    @Published var resumeAtReset: Bool {
        didSet {
            UserDefaults.standard.set(resumeAtReset, forKey: "resumeAtReset")
            if resumeAtReset, !keepsSessionsGoing { setKeepsSessionsGoing(true) }
        }
    }
    @Published private(set) var opensAtLogin = SMAppService.mainApp.status == .enabled
    /// The account Claude Code goes back to whenever it has usage left.
    @Published private(set) var mainID: String? = UserDefaults.standard.string(forKey: "mainAccountID")
    @Published private(set) var keepsSessionsGoing = ClaudeSettings.keepsSessionsGoing(at: ClaudeSettings.liveURL)

    let manager = AccountManager()
    private var loop: Task<Void, Never>?
    private var notifiedLimit: Set<String> = []
    private let policy = AutoSwitchPolicy()
    private var lastAutoSwitch: Date?
    private var loginProcess: Process?
    private var loginInput: Pipe?

    /// Logins are picked up within this time; usage is fetched less often.
    static let usageInterval: TimeInterval = 180

    init() {
        UserDefaults.standard.register(defaults: ["notifyAtLimit": true, "autoSwitch": true, "resumeAtReset": true])
        notifyAtLimit = UserDefaults.standard.bool(forKey: "notifyAtLimit")
        autoSwitch = UserDefaults.standard.bool(forKey: "autoSwitch")
        resumeAtReset = UserDefaults.standard.bool(forKey: "resumeAtReset")
    }

    var active: AccountRecord? { records.first { $0.id == activeID } }

    func start() {
        enableLoginItemOnFirstRun()
        if resumeAtReset, !keepsSessionsGoing { setKeepsSessionsGoing(true) }
        guard loop == nil else { return }
        loop = Task { [weak self] in
            var lastUsage = Date.distantPast
            while !Task.isCancelled {
                guard let self else { return }
                if Date().timeIntervalSince(lastUsage) >= Self.usageInterval {
                    await self.refresh()
                    lastUsage = Date()
                } else {
                    _ = try? await self.manager.syncActive()
                    // Close to the limit: check the active account every sync so the switch is quick.
                    if let id = await self.manager.activeID, self.policy.needsCloseWatch(self.records.first { $0.id == id }) {
                        await self.manager.refresh(id: id)
                    }
                    // The main account's limit should have reset: check it so we go back promptly.
                    let main = self.records.first { $0.id == self.mainID }
                    if let main, self.policy.mainMayBeBack(main: main, activeID: self.activeID, now: Date()) {
                        await self.manager.refresh(id: main.id)
                    }
                    if let a = self.active, self.policy.activeMayBeBack(a, now: Date()) {
                        await self.manager.refresh(id: a.id)
                    }
                    await self.pull()
                    self.checkLimit()
                }
                // Normally every 30 s; shortened so a reset is noticed within seconds.
                let delay = self.policy.nextDelay(active: self.active, now: Date(), base: 30)
                try? await Task.sleep(for: .seconds(delay))
            }
        }
    }

    func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        await manager.refreshAll()
        await pull()
        loadedOnce = true
        refreshing = false
        checkLimit()
    }

    /// Opening the menu shows fresh numbers when the last fetch is more than a minute old.
    func menuOpened() {
        let stale = records.contains { ($0.usageFetchedAt.map { Date().timeIntervalSince($0) > 60 }) ?? true }
        if stale || records.isEmpty { Task { await refresh() } }
    }

    func switchTo(_ id: String) async {
        guard switchingID == nil, id != activeID else { return }
        switchingID = id
        defer { switchingID = nil }
        do {
            try await manager.switchTo(id)
            await manager.refresh(id: id)
            await pull()
            let name = active?.title ?? "the account"
            message = keepsSessionsGoing
                ? "Switched to \(name). Running sessions pick it up within about 30 seconds."
                : "Switched to \(name). New Claude Code sessions use it; restart open ones."
        } catch {
            await pull()
            message = error.localizedDescription
        }
        checkLimit()
    }

    func setMain(_ id: String?) {
        mainID = id
        UserDefaults.standard.set(id, forKey: "mainAccountID")
        checkLimit()
    }

    func setKeepsSessionsGoing(_ on: Bool) {
        do { try ClaudeSettings.setKeepSessionsGoing(on, at: ClaudeSettings.liveURL) }
        catch { message = "Could not update Claude Code settings: \(error.localizedDescription)" }
        keepsSessionsGoing = ClaudeSettings.keepsSessionsGoing(at: ClaudeSettings.liveURL)
    }

    func remove(_ id: String) {
        if id == mainID { setMain(nil) }
        Task {
            do { try await manager.remove(id) } catch { message = error.localizedDescription }
            await pull()
        }
    }

    /// Saves the current login, then runs `claude auth login` in the background (no Terminal): it
    /// opens the browser and catches the sign-in on a local port. Gives up after 5 minutes.
    func addAccount() {
        guard loginProcess == nil else { message = "Sign-in is already open in your browser."; return }
        Task {
            _ = try? await manager.syncActive()
            await pull()
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = ["-lc", "exec claude auth login"]
            let input = Pipe() // kept open and never written, so the paste-code prompt just waits
            p.standardInput = input
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            p.terminationHandler = { [weak self] proc in
                Task { @MainActor in await self?.loginFinished(status: proc.terminationStatus) }
            }
            do {
                try p.run()
                loginProcess = p
                loginInput = input
                message = "Finish signing in in your browser. The account shows up here when done."
                Task { [weak p] in
                    try? await Task.sleep(for: .seconds(300))
                    if let p, p.isRunning { p.terminate() }
                }
            } catch {
                message = "Could not start sign-in: \(error.localizedDescription)"
            }
        }
    }

    private func loginFinished(status: Int32) async {
        loginProcess = nil
        loginInput = nil
        _ = try? await manager.syncActive()
        await refresh()
        message = status == 0 ? "Signed in." : "Sign-in did not finish. Try Add Account again."
    }

    func setOpensAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            message = "Login item: \(error.localizedDescription)"
        }
        opensAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: Private

    private func pull() async {
        let s = await manager.snapshot()
        records = s.records.sorted { ($0.email ?? $0.id) < ($1.email ?? $1.id) }
        activeID = s.activeID
    }

    private func enableLoginItemOnFirstRun() {
        let key = "loginItemConfigured"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        setOpensAtLogin(true)
    }

    /// Puts Claude Code on the right account (main when it has room, otherwise the least-used
    /// one with room) when automatic switching is on; otherwise notifies once per limit hit.
    private func checkLimit() {
        guard let a = active else { return }
        trackSessions(a)
        if a.usage?.isLimited != true { notifiedLimit.remove(a.id) }
        Task {
            if autoSwitch, switchingID == nil,
               let target = policy.target(active: a, accounts: records, mainID: mainID, lastSwitch: lastAutoSwitch, now: Date()) {
                lastAutoSwitch = Date()
                await switchTo(target.id)
                if activeID == target.id {
                    let why = a.usage?.isLimited == true ? "\(a.title) hit its limit" : "\(target.title) is your main account and has usage again"
                    message = "\(why); switched to \(target.title)."
                    if notifyAtLimit { Notifier.switched(from: a, to: target, reason: why, sessionsContinue: keepsSessionsGoing) }
                    return
                }
            }
            guard a.usage?.isLimited == true, notifyAtLimit, !notifiedLimit.contains(a.id) else { return }
            notifiedLimit.insert(a.id)
            Notifier.limitReached(account: a, alternative: await manager.bestAlternative(to: a.id))
        }
    }

    /// Notes when the active account first hits a limit. Once it has room again, reopens the sessions
    /// that the limit stopped (not ones closed on purpose, not ones still running). Survives an app
    /// restart (the time is kept in UserDefaults).
    private func trackSessions(_ a: AccountRecord) {
        guard resumeAtReset, let limited = a.usage?.isLimited else { return }
        let key = "limitSeenAt"
        let seen = UserDefaults.standard.object(forKey: key) as? Date
        if limited {
            if seen == nil { UserDefaults.standard.set(Date(), forKey: key) }
        } else if let seen {
            UserDefaults.standard.removeObject(forKey: key)
            // Sessions stop a little before the app notices the limit, hence the margin.
            let stopped = SessionResume.stoppedAtLimit(since: seen.addingTimeInterval(-20 * 60), live: SessionResume.liveSessionIDs())
            let shown = Array(stopped.prefix(Self.maxReopen))
            for s in shown { Self.reopen(s) }
            guard !shown.isEmpty else { return }
            message = "Limit reset; reopened \(shown.count) session\(shown.count == 1 ? "" : "s")."
            if notifyAtLimit { Notifier.resumed(reopened: shown.count, skipped: stopped.count - shown.count) }
        }
    }

    /// One Terminal window per session; more than this would flood the screen.
    static let maxReopen = 6

    private static func reopen(_ s: SessionRef) {
        guard let script = SessionResume.script(for: s) else { return }
        let dir = ManagerPaths.live.store.deletingLastPathComponent().appendingPathComponent("resume")
        let url = dir.appendingPathComponent("\(s.sessionId).command")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            NSWorkspace.shared.open(url)
        } catch {}
    }
}

enum Notifier {
    static let category = "LIMIT_REACHED"
    static let switchAction = "SWITCH"

    static func setUp(delegate: UNUserNotificationCenterDelegate) {
        let c = UNUserNotificationCenter.current()
        c.delegate = delegate
        let action = UNNotificationAction(identifier: switchAction, title: "Switch", options: [])
        c.setNotificationCategories([UNNotificationCategory(identifier: category, actions: [action], intentIdentifiers: [])])
        c.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func switched(from: AccountRecord, to: AccountRecord, reason: String, sessionsContinue: Bool) {
        let content = UNMutableNotificationContent()
        content.title = "Switched to \(to.title)"
        content.body = reason + (sessionsContinue
            ? ". Sessions waiting at the limit carry on within about a minute."
            : ". New Claude Code sessions use it; restart open ones.")
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "switched-\(to.id)", content: content, trigger: nil))
    }

    static func resumed(reopened: Int, skipped: Int) {
        let content = UNMutableNotificationContent()
        content.title = "Claude limit reset"
        content.body = "Reopened \(reopened) stopped session\(reopened == 1 ? "" : "s") in Terminal."
            + (skipped > 0 ? " \(skipped) more were not reopened." : "")
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "resumed", content: content, trigger: nil))
    }

    static func limitReached(account: AccountRecord, alternative: AccountRecord?) {
        let content = UNMutableNotificationContent()
        content.title = "\(account.title) reached its Claude limit"
        var body = ""
        if let reset = account.usage?.limitResetsAt {
            body = "Resets \(reset.formatted(date: .omitted, time: .shortened))."
        }
        if let alt = alternative {
            body += (body.isEmpty ? "" : " ") + "Switch to \(alt.title) (\(Int(alt.usage?.pressure ?? 0))% used)?"
            content.categoryIdentifier = category
            content.userInfo = ["target": alt.id]
        } else {
            body += (body.isEmpty ? "" : " ") + "No other account has room right now."
        }
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "limit-\(account.id)", content: content, trigger: nil))
    }
}
