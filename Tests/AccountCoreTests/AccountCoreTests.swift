import Foundation
import Testing
@testable import AccountCore

// MARK: Fakes

final class FakeAPI: ClaudeAPI, @unchecked Sendable {
    var profiles: [String: Profile] = [:]          // access token -> profile
    var usages: [String: Usage] = [:]              // access token -> usage
    var refreshes: [String: RefreshedTokens] = [:] // refresh token -> new tokens
    var refreshCalls: [String] = []
    var profileCalls = 0

    func profile(accessToken: String) async throws -> Profile {
        profileCalls += 1
        guard let p = profiles[accessToken] else { throw ClaudeAPIError.unauthorized }
        return p
    }
    func usage(accessToken: String) async throws -> Usage {
        guard let u = usages[accessToken] else { throw ClaudeAPIError.unauthorized }
        return u
    }
    func refresh(refreshToken: String, scopes: [String]) async throws -> RefreshedTokens {
        refreshCalls.append(refreshToken)
        guard let r = refreshes[refreshToken] else { throw ClaudeAPIError.unauthorized }
        return r
    }
}

let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)
let future = Int64((fixedNow.timeIntervalSince1970 + 3600) * 1000)
let past = Int64((fixedNow.timeIntervalSince1970 - 3600) * 1000)
let user = "tester"

func tokensJSON(_ access: String, _ refresh: String, expires: Int64 = future, sub: String = "max") -> JSONValue {
    .object([
        "accessToken": .string(access), "refreshToken": .string(refresh), "expiresAt": .int(expires),
        "scopes": .array([.string("user:inference")]), "subscriptionType": .string(sub),
        "rateLimitTier": .string("default_claude_max_5x"),
    ])
}

func claudeDoc(_ oauth: JSONValue) throws -> String {
    try JSONValue.object(["claudeAiOauth": oauth, "mcpOAuth": .object(["figma|1": .object(["token": .string("mcp-secret")])])]).json()
}

func profile(_ uuid: String, _ email: String) -> Profile {
    Profile(account: .init(uuid: uuid, email: email, full_name: nil, display_name: email.components(separatedBy: "@")[0],
                           has_claude_max: true, has_claude_pro: false, created_at: nil),
            organization: .init(uuid: "org-\(uuid)", name: "\(email) org", organization_type: "claude_max",
                                billing_type: "stripe_subscription", rate_limit_tier: "default_claude_max_5x",
                                has_extra_usage_enabled: false, subscription_status: "active", subscription_created_at: nil))
}

func usage(_ five: Double, _ week: Double = 0) -> Usage {
    Usage(five_hour: .init(utilization: five, resets_at: "2026-11-03T15:40:00.127839+00:00"),
          seven_day: .init(utilization: week, resets_at: "2026-11-07T11:00:00+00:00"),
          seven_day_opus: nil, seven_day_sonnet: nil, extra_usage: nil, limits: nil)
}

struct Env {
    let dir: URL
    let secrets = MemorySecretStore()
    let api = FakeAPI()
    var paths: ManagerPaths { .init(claudeConfig: dir.appendingPathComponent(".claude.json"), store: dir.appendingPathComponent("store/accounts.json")) }

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("cab-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    func manager() -> AccountManager {
        AccountManager(secrets: secrets, api: api, paths: paths, claudeKeychainAccount: user, now: { fixedNow })
    }

    func setClaudeLogin(_ oauth: JSONValue) throws {
        try secrets.write(service: AccountManager.claudeService, account: user, value: try claudeDoc(oauth))
    }

    func claudeLogin() throws -> CredentialsDocument {
        try CredentialsDocument(json: secrets.read(service: AccountManager.claudeService, account: user)!)
    }

    func writeConfig(_ v: JSONValue) throws { try v.data().write(to: paths.claudeConfig) }
    func config() throws -> JSONValue { try JSONValue.parse(Data(contentsOf: paths.claudeConfig)) }
}

/// Logs Claude Code into account A, then B, syncing after each, like the user adding both.
func twoAccounts(_ env: Env) async throws -> AccountManager {
    env.api.profiles = ["a1": profile("A", "a@x.com"), "b1": profile("B", "b@x.com")]
    let m = env.manager()
    try env.writeConfig(.object(["theme": .string("dark"), "oauthAccount": .object(["accountUuid": .string("A"), "emailAddress": .string("a@x.com"), "seatTier": .null])]))
    try env.setClaudeLogin(tokensJSON("a1", "ar1"))
    #expect(try await m.syncActive() == "A")
    try env.writeConfig(.object(["theme": .string("dark"), "oauthAccount": .object(["accountUuid": .string("B"), "emailAddress": .string("b@x.com")])]))
    try env.setClaudeLogin(tokensJSON("b1", "br1"))
    #expect(try await m.syncActive() == "B")
    return m
}

// MARK: Documents

@Test func jsonValueRoundTripKeepsLargeIntegersAndUnknownKeys() throws {
    let src = #"{"expiresAt":1793731488466,"ratio":0.5,"flag":true,"nested":{"x":[1,"two",null]}}"#
    let v = try JSONValue.parse(Data(src.utf8))
    #expect(v["expiresAt"] == .int(1793731488466))
    #expect(try JSONValue.parse(v.data()) == v)
}

@Test func replacingClaudeLoginKeepsMcpLogins() throws {
    var doc = try CredentialsDocument(json: claudeDoc(tokensJSON("a1", "ar1")))
    doc.claudeOAuth = OAuthTokens(raw: tokensJSON("b1", "br1"))
    let again = try CredentialsDocument(json: doc.json())
    #expect(again.claudeOAuth?.accessToken == "b1")
    #expect(again.raw["mcpOAuth"]?["figma|1"]?["token"] == .string("mcp-secret"))
}

@Test func usageDecodesLiveShapeAndDetectsLimit() throws {
    let json = #"""
    {"five_hour":{"utilization":100.0,"resets_at":"2026-11-03T15:40:00.127839+00:00","limit_dollars":null},
     "seven_day":{"utilization":3.0,"resets_at":"2026-11-07T11:00:00.127862+00:00"},
     "seven_day_opus":null,"tangelo":null,
     "extra_usage":{"is_enabled":false,"user_disabled":false,"spend_limit_reached":false},
     "limits":[{"kind":"session","group":"session","percent":100,"severity":"critical","resets_at":"2026-11-03T15:40:00.127839+00:00","scope":null,"is_active":true}]}
    """#
    let u = try JSONDecoder().decode(Usage.self, from: Data(json.utf8))
    #expect(u.isLimited)
    #expect(u.limitResetsAt != nil)
    #expect(u.pressure == 100)
    #expect(!usage(99, 50).isLimited)
    #expect(usage(10, 100).isLimited)
}

@Test func planNames() {
    var r = AccountRecord(id: "x", addedAt: fixedNow)
    r.rateLimitTier = "default_claude_max_20x"; #expect(r.planName == "Max 20x")
    r.rateLimitTier = "default_claude_max_5x"; #expect(r.planName == "Max 5x")
    r.rateLimitTier = nil; r.subscriptionType = "pro"; #expect(r.planName == "Pro")
}

@Test func securityCommandIsHexAndQuoted() {
    #expect(SecurityCLISecretStore.hex("{\"a\":1}") == "7b2261223a317d")
    let cmd = SecurityCLISecretStore.addCommand(service: "Claude Code-credentials", account: "me", hex: "7b7d")
    #expect(cmd == #"add-generic-password -U -a "me" -s "Claude Code-credentials" -X 7b7d"#)
}

// MARK: Capturing logins

@Test func newLoginIsIdentifiedOnceThenMatchedByToken() async throws {
    let env = try Env()
    env.api.profiles = ["a1": profile("A", "a@x.com")]
    try env.setClaudeLogin(tokensJSON("a1", "ar1"))
    let m = env.manager()
    #expect(try await m.syncActive() == "A")
    #expect(try await m.syncActive() == "A")
    #expect(env.api.profileCalls == 1)
    let r = await m.records
    #expect(r.count == 1 && r[0].email == "a@x.com" && r[0].subscriptionStatus == "active")
}

@Test func tokensRotatedByClaudeCodeAreSaved() async throws {
    let env = try Env()
    let m = try await twoAccounts(env)
    // Claude Code renewed B's access token but kept the refresh token.
    try env.setClaudeLogin(tokensJSON("b2", "br1"))
    #expect(try await m.syncActive() == "B")
    let saved = try env.secrets.read(service: AccountManager.storeService, account: "B")!
    #expect(saved.contains("b2"))
}

@Test func unidentifiableLoginIsNotFiledUnderAGuess() async throws {
    let env = try Env()
    let m = try await twoAccounts(env)
    // Offline / unknown token while the config still says B.
    try env.setClaudeLogin(tokensJSON("zz", "zr"))
    #expect(try await m.syncActive() == "B")
    #expect(!(try env.secrets.read(service: AccountManager.storeService, account: "B")!.contains("zz")))
}

@Test func storeSurvivesRestart() async throws {
    let env = try Env()
    _ = try await twoAccounts(env)
    let again = env.manager()
    #expect(await again.records.map(\.id) == ["A", "B"])
    #expect(await again.activeID == "B")
}

// MARK: Switching

@Test func switchSwapsOnlyTheClaudeLoginAndConfigAccount() async throws {
    let env = try Env()
    let m = try await twoAccounts(env)
    try await m.switchTo("A")
    let doc = try env.claudeLogin()
    #expect(doc.claudeOAuth?.accessToken == "a1")
    #expect(doc.raw["mcpOAuth"]?["figma|1"]?["token"] == .string("mcp-secret"))
    let cfg = try env.config()
    #expect(cfg["oauthAccount"]?["accountUuid"] == .string("A"))
    #expect(cfg["oauthAccount"]?["seatTier"] == .null)   // Claude Code's own copy restored
    #expect(cfg["theme"] == .string("dark"))            // rest of the config untouched
    #expect(await m.activeID == "A")
    let perms = try FileManager.default.attributesOfItem(atPath: env.paths.claudeConfig.path)[.posixPermissions] as? Int
    #expect(perms == 0o600)
}

@Test func switchSavesTheOutgoingAccountsLatestTokensFirst() async throws {
    let env = try Env()
    let m = try await twoAccounts(env)
    try env.setClaudeLogin(tokensJSON("b9", "br9")) // rotated both; profile identifies it
    env.api.profiles["b9"] = profile("B", "b@x.com")
    try await m.switchTo("A")
    try await m.switchTo("B")
    #expect(try env.claudeLogin().claudeOAuth?.accessToken == "b9")
}

@Test func switchRenewsAnExpiredSavedLogin() async throws {
    let env = try Env()
    let m = try await twoAccounts(env)
    try env.secrets.write(service: AccountManager.storeService, account: "A", value: tokensJSON("a1", "ar1", expires: past).json())
    env.api.refreshes["ar1"] = RefreshedTokens(accessToken: "a2", refreshToken: "ar2", expiresIn: 28800)
    try await m.switchTo("A")
    let t = try env.claudeLogin().claudeOAuth!
    #expect(t.accessToken == "a2" && t.refreshToken == "ar2")
    #expect(!t.isExpired(now: fixedNow))
}

@Test func switchToSignedOutAccountFailsAndLeavesLoginAlone() async throws {
    let env = try Env()
    let m = try await twoAccounts(env)
    try env.secrets.write(service: AccountManager.storeService, account: "A", value: tokensJSON("a1", "dead", expires: past).json())
    await #expect(throws: AccountError.self) { try await m.switchTo("A") }
    #expect(try env.claudeLogin().claudeOAuth?.accessToken == "b1")
    #expect(await m.records.first { $0.id == "A" }?.needsLogin == true)
}

@Test func switchToUnknownAccountThrows() async throws {
    let env = try Env()
    let m = try await twoAccounts(env)
    await #expect(throws: AccountError.unknownAccount) { try await m.switchTo("nope") }
}

// MARK: Usage

@Test func activeLoginIsNeverRefreshedByTheApp() async throws {
    let env = try Env()
    let m = try await twoAccounts(env)
    try env.setClaudeLogin(tokensJSON("b1", "br1", expires: past))
    env.api.refreshes["br1"] = RefreshedTokens(accessToken: "bX", refreshToken: "brX", expiresIn: 1)
    await m.refresh(id: "B")
    #expect(env.api.refreshCalls.isEmpty)
}

@Test func usageIsFetchedForInactiveAccountsWithRenewal() async throws {
    let env = try Env()
    let m = try await twoAccounts(env)
    try env.secrets.write(service: AccountManager.storeService, account: "A", value: tokensJSON("a1", "ar1", expires: past).json())
    env.api.refreshes["ar1"] = RefreshedTokens(accessToken: "a2", refreshToken: "ar2", expiresIn: 28800)
    env.api.usages = ["a2": usage(40), "b1": usage(100)]
    await m.refreshAll()
    let recs = await m.records
    #expect(recs.first { $0.id == "A" }?.usage?.pressure == 40)
    #expect(recs.first { $0.id == "B" }?.usage?.isLimited == true)
    #expect(try env.secrets.read(service: AccountManager.storeService, account: "A")!.contains("ar2"))
}

@Test func bestAlternativeSkipsLimitedAndSignedOut() async throws {
    let env = try Env()
    env.api.profiles = ["a1": profile("A", "a@x.com"), "b1": profile("B", "b@x.com"), "c1": profile("C", "c@x.com")]
    let m = env.manager()
    for (t, r) in [("a1", "ar1"), ("c1", "cr1"), ("b1", "br1")] {
        try env.setClaudeLogin(tokensJSON(t, r)); _ = try await m.syncActive()
    }
    env.api.usages = ["a1": usage(100), "b1": usage(100), "c1": usage(70)]
    await m.refreshAll()
    #expect(await m.bestAlternative(to: "B")?.id == "C")
    env.api.usages["c1"] = usage(100, 100)
    await m.refreshAll()
    #expect(await m.bestAlternative(to: "B") == nil)
}

@Test func removeForgetsAccountAndItsSavedLogin() async throws {
    let env = try Env()
    let m = try await twoAccounts(env)
    try await m.remove("A")
    #expect(await m.records.map(\.id) == ["B"])
    #expect(try env.secrets.read(service: AccountManager.storeService, account: "A") == nil)
}
