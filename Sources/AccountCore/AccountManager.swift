import Foundation

public enum AccountError: Error, Equatable, LocalizedError {
    case unknownAccount
    case missingTokens
    case needsLogin(String)

    public var errorDescription: String? {
        switch self {
        case .unknownAccount: return "That account is not known to Claude Accounts."
        case .missingTokens: return "No saved login for that account. Sign in to it once with Add Account."
        case .needsLogin(let who): return "\(who) was signed out. Sign in to it again with Add Account."
        }
    }
}

public struct ManagerPaths: Sendable {
    public var claudeConfig: URL
    public var store: URL

    public static var live: ManagerPaths {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return ManagerPaths(claudeConfig: home.appendingPathComponent(".claude.json"),
                            store: support.appendingPathComponent("ClaudeAccountBar/accounts.json"))
    }

    public init(claudeConfig: URL, store: URL) { self.claudeConfig = claudeConfig; self.store = store }
}

/// Owns the list of accounts, their saved logins and usage, and switching Claude Code between them.
public actor AccountManager {
    public static let claudeService = "Claude Code-credentials"
    public static let storeService = "ClaudeAccountBar"
    static let profileMaxAge: TimeInterval = 30 * 60

    private let secrets: SecretStore
    private let api: ClaudeAPI
    private let paths: ManagerPaths
    private let claudeAccount: String
    private let now: @Sendable () -> Date

    public private(set) var records: [AccountRecord] = []
    public private(set) var activeID: String?
    private var profileFetchedAt: [String: Date] = [:]

    public init(secrets: SecretStore = SecurityCLISecretStore(),
                api: ClaudeAPI = LiveClaudeAPI(),
                paths: ManagerPaths = .live,
                claudeKeychainAccount: String = NSUserName(),
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.secrets = secrets
        self.api = api
        self.paths = paths
        self.claudeAccount = claudeKeychainAccount
        self.now = now
        if let s = try? Self.loadStore(paths.store) {
            records = s.accounts
            activeID = s.activeID
        }
    }

    public func snapshot() -> (records: [AccountRecord], activeID: String?) { (records, activeID) }

    // MARK: Active login

    /// Reads Claude Code's current login, saves it (with any tokens Claude Code rotated)
    /// under its account, and returns that account's id.
    @discardableResult
    public func syncActive() async throws -> String? {
        guard let doc = try readClaudeDocument(), let tokens = doc.claudeOAuth, let access = tokens.accessToken else {
            activeID = nil
            try persist()
            return nil
        }
        var id = try knownID(for: tokens)
        if id == nil {
            do {
                let p = try await api.profile(accessToken: access)
                id = p.account.uuid
                update(id: p.account.uuid) { $0.apply(profile: p, tokens: tokens) }
                profileFetchedAt[p.account.uuid] = now()
            } catch {
                // Can't tell whose login this is: don't file tokens under a guessed account.
                activeID = configOAuthAccount()?["accountUuid"]?.stringValue
                try persist()
                return activeID
            }
        }
        guard let id else { return nil }
        if try storedTokens(id) != tokens {
            try secrets.write(service: Self.storeService, account: id, value: try tokens.raw.json())
        }
        let configAccount = configOAuthAccount()
        update(id: id) {
            if configAccount?["accountUuid"]?.stringValue == id { $0.oauthAccount = configAccount }
            $0.subscriptionType = tokens.subscriptionType ?? $0.subscriptionType
            $0.rateLimitTier = tokens.rateLimitTier ?? $0.rateLimitTier
            $0.needsLogin = false
        }
        activeID = id
        try persist()
        return id
    }

    // MARK: Switching

    /// Points Claude Code at another saved account. Other logins in the same keychain
    /// item (MCP servers) and the rest of ~/.claude.json are left as they are.
    public func switchTo(_ id: String) async throws {
        guard let record = records.first(where: { $0.id == id }) else { throw AccountError.unknownAccount }
        let current = try await syncActive()
        if current == id { return }
        guard var target = try storedTokens(id) else { throw AccountError.missingTokens }
        if target.isExpired(now: now()) {
            target = try await refreshStored(id: id, tokens: target)
        }
        var doc = try readClaudeDocument() ?? CredentialsDocument(raw: .object([:]))
        doc.claudeOAuth = target
        try secrets.write(service: Self.claudeService, account: claudeAccount, value: try doc.json())
        try writeConfigOAuthAccount(record.oauthAccount ?? record.synthesizedOAuthAccount())
        activeID = id
        try persist()
    }

    // MARK: Usage

    public func refreshAll() async {
        _ = try? await syncActive()
        for r in records { await refresh(id: r.id) }
    }

    /// Fetches usage (and, now and then, the profile) for one account.
    public func refresh(id: String) async {
        do {
            let token = try await usableAccessToken(id)
            guard let token else { // active login expired: Claude Code renews it itself
                Diag.log("usage skipped for \(records.first { $0.id == id }?.title ?? id): active login expired, waiting for Claude Code to renew it")
                return
            }
            let usage: Usage
            do {
                usage = try await api.usage(accessToken: token)
            } catch ClaudeAPIError.unauthorized where id != activeID {
                guard let stored = try storedTokens(id) else { throw AccountError.missingTokens }
                let renewed = try await refreshStored(id: id, tokens: stored)
                usage = try await api.usage(accessToken: renewed.accessToken ?? "")
            }
            if (profileFetchedAt[id].map { now().timeIntervalSince($0) > Self.profileMaxAge } ?? true),
               let p = try? await api.profile(accessToken: token) {
                update(id: id) { $0.apply(profile: p, tokens: nil) }
                profileFetchedAt[id] = now()
            }
            update(id: id) {
                $0.usage = usage
                $0.usageFetchedAt = now()
                $0.lastError = nil
            }
        } catch AccountError.needsLogin {
            update(id: id) { $0.lastError = "Signed out" }
        } catch {
            update(id: id) { $0.lastError = Self.describe(error) }
        }
        try? persist()
    }

    public func remove(_ id: String) throws {
        try secrets.delete(service: Self.storeService, account: id)
        records.removeAll { $0.id == id }
        try persist()
    }

    /// The account to move to when `id` is out of usage: not limited, still signed in,
    /// least used. Accounts whose usage is unknown come last.
    public func bestAlternative(to id: String?) -> AccountRecord? {
        records
            .filter { $0.id != id && !$0.needsLogin && !($0.usage?.isLimited ?? false) }
            .sorted { ($0.usage?.pressure ?? 101) < ($1.usage?.pressure ?? 101) }
            .first
    }

    // MARK: Internals

    private func usableAccessToken(_ id: String) async throws -> String? {
        if id == activeID {
            guard let t = try readClaudeDocument()?.claudeOAuth else { return nil }
            return t.isExpired(now: now(), margin: 0) ? nil : t.accessToken
        }
        guard var t = try storedTokens(id) else { throw AccountError.missingTokens }
        if t.isExpired(now: now()) { t = try await refreshStored(id: id, tokens: t) }
        return t.accessToken
    }

    /// Renews a saved login that Claude Code is not using. Never called for the active
    /// account: that would rotate the refresh token out from under running sessions.
    private func refreshStored(id: String, tokens: OAuthTokens) async throws -> OAuthTokens {
        guard id != activeID else { return tokens }
        let who = records.first { $0.id == id }?.title ?? id
        guard let refresh = tokens.refreshToken else { throw AccountError.needsLogin(who) }
        let scopes: [String]
        if case .array(let a)? = tokens.raw["scopes"] { scopes = a.compactMap(\.stringValue) } else { scopes = [] }
        let r: RefreshedTokens
        do {
            r = try await api.refresh(refreshToken: refresh, scopes: scopes)
        } catch ClaudeAPIError.unauthorized, ClaudeAPIError.http(400) {
            update(id: id) { $0.needsLogin = true }
            try? persist()
            throw AccountError.needsLogin(who)
        }
        var t = tokens
        t.raw["accessToken"] = .string(r.accessToken)
        t.raw["refreshToken"] = .string(r.refreshToken)
        t.raw["expiresAt"] = .int(Int64((now().timeIntervalSince1970 + r.expiresIn) * 1000))
        try secrets.write(service: Self.storeService, account: id, value: try t.raw.json())
        update(id: id) { $0.needsLogin = false }
        return t
    }

    private func knownID(for tokens: OAuthTokens) throws -> String? {
        for r in records { if let s = try storedTokens(r.id), s.sameLogin(as: tokens) { return r.id } }
        return nil
    }

    private func storedTokens(_ id: String) throws -> OAuthTokens? {
        guard let json = try secrets.read(service: Self.storeService, account: id) else { return nil }
        return OAuthTokens(raw: try JSONValue.parse(Data(json.utf8)))
    }

    private func readClaudeDocument() throws -> CredentialsDocument? {
        guard let json = try secrets.read(service: Self.claudeService, account: claudeAccount) else { return nil }
        return try CredentialsDocument(json: json)
    }

    private func update(id: String, _ change: (inout AccountRecord) -> Void) {
        if let i = records.firstIndex(where: { $0.id == id }) {
            change(&records[i])
        } else {
            var r = AccountRecord(id: id, addedAt: now())
            change(&r)
            records.append(r)
        }
    }

    private func configOAuthAccount() -> JSONValue? {
        guard let data = try? Data(contentsOf: paths.claudeConfig), let v = try? JSONValue.parse(data) else { return nil }
        return v["oauthAccount"]
    }

    private func writeConfigOAuthAccount(_ account: JSONValue) throws {
        let url = paths.claudeConfig
        var config: JSONValue = .object([:])
        if let data = try? Data(contentsOf: url) { config = try JSONValue.parse(data) }
        config["oauthAccount"] = account
        try Self.atomicWrite(try config.data(pretty: true), to: url)
    }

    struct StoreFile: Codable {
        var version = 1
        var accounts: [AccountRecord]
        var activeID: String?
    }

    static func loadStore(_ url: URL) throws -> StoreFile {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try d.decode(StoreFile.self, from: Data(contentsOf: url))
    }

    private func persist() throws {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: paths.store.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.atomicWrite(try e.encode(StoreFile(accounts: records, activeID: activeID)), to: paths.store)
    }

    /// Temp file + rename in the same folder, owner-only permissions.
    static func atomicWrite(_ data: Data, to url: URL) throws {
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: tmp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        if rename(tmp.path, url.path) != 0 {
            try? FileManager.default.removeItem(at: tmp)
            throw CocoaError(.fileWriteUnknown)
        }
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case ClaudeAPIError.unauthorized: return "Not authorised"
        case ClaudeAPIError.http(let c): return "Server error \(c)"
        case let e as LocalizedError where e.errorDescription != nil: return e.errorDescription!
        default: return (error as NSError).localizedDescription
        }
    }
}

extension JSONValue {
    func json() throws -> String { String(decoding: try data(), as: UTF8.self) }
}
