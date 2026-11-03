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
    @Published private(set) var opensAtLogin = SMAppService.mainApp.status == .enabled

    let manager = AccountManager()
    private var loop: Task<Void, Never>?
    private var notifiedLimit: Set<String> = []

    /// Logins are picked up within this time; usage is fetched less often.
    static let syncInterval: Duration = .seconds(30)
    static let usageInterval: TimeInterval = 180

    init() {
        UserDefaults.standard.register(defaults: ["notifyAtLimit": true])
        notifyAtLimit = UserDefaults.standard.bool(forKey: "notifyAtLimit")
    }

    var active: AccountRecord? { records.first { $0.id == activeID } }

    func start() {
        enableLoginItemOnFirstRun()
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
                    await self.pull()
                }
                try? await Task.sleep(for: Self.syncInterval)
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
            message = "Switched to \(name). New Claude Code sessions use it; restart open ones."
        } catch {
            await pull()
            message = error.localizedDescription
        }
        checkLimit()
    }

    func remove(_ id: String) {
        Task {
            do { try await manager.remove(id) } catch { message = error.localizedDescription }
            await pull()
        }
    }

    /// Saves the current login, then opens Terminal on `claude auth login`. The new
    /// account is picked up on the next sync once the sign-in finishes.
    func addAccount() {
        Task {
            _ = try? await manager.syncActive()
            await pull()
            do {
                let url = try Self.writeLoginScript()
                NSWorkspace.shared.open(url)
                message = "Sign in to the new account in Terminal. It shows up here within 30 seconds."
            } catch {
                message = "Could not open Terminal: \(error.localizedDescription)"
            }
        }
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

    /// One notification per limit hit, offering the least-used account that still has room.
    private func checkLimit() {
        guard let a = active else { return }
        guard a.usage?.isLimited == true else { notifiedLimit.remove(a.id); return }
        guard notifyAtLimit, !notifiedLimit.contains(a.id) else { return }
        notifiedLimit.insert(a.id)
        Task {
            let alt = await manager.bestAlternative(to: a.id)
            Notifier.limitReached(account: a, alternative: alt)
        }
    }

    static func writeLoginScript() throws -> URL {
        let dir = ManagerPaths.live.store.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("Add Claude Account.command")
        let script = """
        #!/bin/zsh -l
        echo "Sign in to the Claude account you want to add."
        echo "The account you use now stays saved in Claude Accounts."
        echo
        claude auth login
        echo
        echo "Done. Claude Accounts picks this account up within 30 seconds. You can close this window."

        """
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
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
