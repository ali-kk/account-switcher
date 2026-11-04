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

// MARK: Automatic switching

func record(_ id: String, five: Double, week: Double = 0, resets: String = "2026-11-03T15:40:00+00:00") -> AccountRecord {
    var r = AccountRecord(id: id, addedAt: fixedNow)
    r.usage = Usage(five_hour: .init(utilization: five, resets_at: resets),
                    seven_day: .init(utilization: week, resets_at: "2026-11-07T11:00:00+00:00"),
                    seven_day_opus: nil, seven_day_sonnet: nil, extra_usage: nil, limits: nil)
    return r
}

let policy = AutoSwitchPolicy()

@Test func limitedAccountMovesToLeastUsedWithRoom() {
    let a = record("A", five: 100), b = record("B", five: 60), c = record("C", five: 20)
    #expect(policy.target(active: a, accounts: [a, b, c], mainID: nil, lastSwitch: nil, now: fixedNow)?.id == "C")
    let weekly = record("A", five: 10, week: 100)
    #expect(policy.target(active: weekly, accounts: [weekly, b], mainID: nil, lastSwitch: nil, now: fixedNow)?.id == "B")
}

@Test func staysWhenNotLimitedOrNoRoomElsewhere() {
    let a = record("A", five: 99), b = record("B", five: 0)
    #expect(policy.target(active: a, accounts: [a, b], mainID: nil, lastSwitch: nil, now: fixedNow) == nil)
    let full = record("A", five: 100), alsoFull = record("B", five: 100)
    #expect(policy.target(active: full, accounts: [full, alsoFull], mainID: nil, lastSwitch: nil, now: fixedNow) == nil)
    #expect(policy.target(active: nil, accounts: [b], mainID: nil, lastSwitch: nil, now: fixedNow) == nil)
}

@Test func signedOutOrUnmeasuredAccountsAreNotTargets() {
    let a = record("A", five: 100)
    var out = record("B", five: 0); out.needsLogin = true
    let unknown = AccountRecord(id: "C", addedAt: fixedNow)
    #expect(policy.target(active: a, accounts: [a, out, unknown], mainID: nil, lastSwitch: nil, now: fixedNow) == nil)
}

@Test func mainAccountIsPreferredWheneverItHasRoom() {
    let main = record("M", five: 70), a = record("A", five: 100), b = record("B", five: 5)
    // Limited: main wins even though B is less used.
    #expect(policy.target(active: a, accounts: [main, a, b], mainID: "M", lastSwitch: nil, now: fixedNow)?.id == "M")
    // Not limited, but main has room again: go back to main.
    #expect(policy.target(active: b, accounts: [main, a, b], mainID: "M", lastSwitch: nil, now: fixedNow)?.id == "M")
    // Already on main: stay.
    #expect(policy.target(active: main, accounts: [main, a, b], mainID: "M", lastSwitch: nil, now: fixedNow) == nil)
}

@Test func limitedMainFallsBackToOthersThenComesBack() {
    var main = record("M", five: 100), b = record("B", five: 10)
    #expect(policy.target(active: main, accounts: [main, b], mainID: "M", lastSwitch: nil, now: fixedNow)?.id == "B")
    #expect(policy.target(active: b, accounts: [main, b], mainID: "M", lastSwitch: nil, now: fixedNow) == nil)
    main = record("M", five: 0)   // its window reset
    #expect(policy.target(active: b, accounts: [main, b], mainID: "M", lastSwitch: nil, now: fixedNow)?.id == "M")
}

@Test func cooldownHoldsSwitches() {
    let a = record("A", five: 100), b = record("B", five: 0)
    #expect(policy.target(active: a, accounts: [a, b], mainID: nil, lastSwitch: fixedNow.addingTimeInterval(-60), now: fixedNow) == nil)
    #expect(policy.target(active: a, accounts: [a, b], mainID: nil, lastSwitch: fixedNow.addingTimeInterval(-policy.cooldown - 1), now: fixedNow)?.id == "B")
}

@Test func closeWatchAndMainReturnChecks() {
    #expect(policy.needsCloseWatch(record("A", five: 92)))
    #expect(!policy.needsCloseWatch(record("A", five: 50)))
    #expect(!policy.needsCloseWatch(nil))
    let resetPassed = record("M", five: 100, resets: "2020-01-01T00:00:00+00:00")
    let resetAhead = record("M", five: 100, resets: "2099-01-01T00:00:00+00:00")
    #expect(policy.mainMayBeBack(main: resetPassed, activeID: "B", now: fixedNow))
    #expect(!policy.mainMayBeBack(main: resetAhead, activeID: "B", now: fixedNow))
    #expect(!policy.mainMayBeBack(main: resetPassed, activeID: "M", now: fixedNow))
}

// MARK: Claude Code settings

@Test func keepSessionsGoingAddsAndRemovesOnlyItsKeys() throws {
    let env = try Env()
    let url = env.dir.appendingPathComponent("settings.json")
    try JSONValue.object(["model": .string("opus"), "env": .object(["FOO": .string("1")])]).data().write(to: url)
    #expect(!ClaudeSettings.keepsSessionsGoing(at: url))
    try ClaudeSettings.setKeepSessionsGoing(true, at: url)
    #expect(ClaudeSettings.keepsSessionsGoing(at: url))
    var v = try JSONValue.parse(Data(contentsOf: url))
    #expect(v["model"] == .string("opus") && v["env"]?["FOO"] == .string("1"))
    try ClaudeSettings.setKeepSessionsGoing(false, at: url)
    v = try JSONValue.parse(Data(contentsOf: url))
    #expect(v["autoContinueAtUsageLimit"] == nil && v["env"] == .object(["FOO": .string("1")]))
}

@Test func keepSessionsGoingLeavesAnUpToDateFileUntouched() throws {
    let env = try Env()
    let url = env.dir.appendingPathComponent("settings.json")
    let original = #"{"zeta":1,"autoContinueAtUsageLimit":true,"env":{"CLAUDE_CODE_RETRY_WATCHDOG_USAGE_LIMIT_RECHECK_MS":"60000"}}"#
    try Data(original.utf8).write(to: url)
    try ClaudeSettings.setKeepSessionsGoing(true, at: url)
    #expect(String(decoding: try Data(contentsOf: url), as: UTF8.self) == original)
}

@Test func keepSessionsGoingCreatesMissingFile() throws {
    let env = try Env()
    let url = env.dir.appendingPathComponent("new/settings.json")
    try ClaudeSettings.setKeepSessionsGoing(true, at: url)
    #expect(ClaudeSettings.keepsSessionsGoing(at: url))
}

@Test func titleSkipsPlaceholderNames() {
    var r = AccountRecord(id: "x", addedAt: fixedNow)
    r.email = "dev@x.com"
    r.displayName = "a"; #expect(r.title == "dev@x.com")
    r.fullName = "Ali"; #expect(r.title == "Ali")
    r.displayName = "Ali M"; #expect(r.title == "Ali M")
}

// MARK: Session resume

private func entry(_ type: String, error: Bool = false, text: String = "hi", cwd: String = "/w") -> String {
    #"{"type":"\#(type)","isApiErrorMessage":\#(error),"cwd":"\#(cwd)","message":{"content":[{"type":"text","text":"\#(text)"}]}}"#
}

@Test func detectsASessionStoppedByTheLimitEvenWithTrailingSystemEntries() throws {
    let id = "59bc3091-c97d-47a3-b9a7-b46cacf844e8"
    let limit = entry("assistant", error: true, text: "You've hit your 5-hour limit · resets 7:30am")
    let tail = "cut-off garbage\n" + entry("user") + "\n" + limit + "\n" + #"{"type":"system","subtype":"away_summary"}"# + "\n"
    #expect(SessionResume.limitStopped(tail: Data(tail.utf8), id: id) == SessionRef(sessionId: id, cwd: "/w"))
    // The user carried on after the limit message: not stopped any more.
    #expect(SessionResume.limitStopped(tail: Data((limit + "\n" + entry("user")).utf8), id: id) == nil)
    // Another API error is not a usage limit.
    #expect(SessionResume.limitStopped(tail: Data(entry("assistant", error: true, text: "Overloaded").utf8), id: id) == nil)
}

@Test func findsOnlyRecentNotRunningLimitStoppedTranscripts() throws {
    let env = try Env()
    let proj = env.dir.appendingPathComponent("p/-w")
    try FileManager.default.createDirectory(at: proj, withIntermediateDirectories: true)
    let limit = entry("assistant", error: true, text: "You've hit your session limit")
    let a = "59bc3091-c97d-47a3-b9a7-b46cacf844e8", b = "f10fa790-aa05-4b50-aa39-28fe40f4d3ba", c = "11111111-1111-1111-1111-111111111111"
    for id in [a, b] { try limit.write(to: proj.appendingPathComponent("\(id).jsonl"), atomically: true, encoding: .utf8) }
    try entry("user").write(to: proj.appendingPathComponent("\(c).jsonl"), atomically: true, encoding: .utf8)
    let root = env.dir.appendingPathComponent("p")
    let got = SessionResume.stoppedAtLimit(since: Date().addingTimeInterval(-60), projects: root, live: [b])
    #expect(got.map(\.sessionId) == [a])
    #expect(SessionResume.stoppedAtLimit(since: Date().addingTimeInterval(60), projects: root, live: []).isEmpty)
}

@Test func reopenScriptQuotesTheDirectoryAndRejectsBadIds() throws {
    let s = try #require(SessionResume.script(for: SessionRef(sessionId: "59bc3091-c97d-47a3-b9a7-b46cacf844e8", cwd: "/tmp/it's here")))
    #expect(s.contains("cd '/tmp/it'\\''s here'"))
    #expect(s.contains("claude --resume 59bc3091-c97d-47a3-b9a7-b46cacf844e8 \"continue\""))
    #expect(SessionResume.script(for: SessionRef(sessionId: "x; rm -rf ~", cwd: "/")) == nil)
}

@Test func readsRunningSessionIDs() throws {
    let env = try Env()
    try #"{"pid":7,"sessionId":"aaa","cwd":"/w"}"#.write(to: env.dir.appendingPathComponent("7.json"), atomically: true, encoding: .utf8)
    try #"{"pid":8,"sessionId":"bbb","cwd":"/w"}"#.write(to: env.dir.appendingPathComponent("8.json"), atomically: true, encoding: .utf8)
    #expect(SessionResume.liveSessionIDs(in: env.dir, isAlive: { $0 == 7 }) == ["aaa"])
}

@Test func singleAccountIsCheckedAtResetAndSleepLandsJustAfterIt() {
    let a = record("A", five: 100, resets: "2026-11-03T15:40:00+00:00")           // resets at 15:40
    let before = parseISODate("2026-11-03T15:39:50+00:00")!, after = parseISODate("2026-11-03T15:40:05+00:00")!
    #expect(!policy.activeMayBeBack(a, now: before))
    #expect(policy.activeMayBeBack(a, now: after))
    #expect(policy.nextDelay(active: a, now: before) == 12)                         // 10 s + 2 s margin
    #expect(policy.nextDelay(active: a, now: after) == 30)                          // already past: normal pace
    let ok = record("A", five: 10)
    #expect(!policy.activeMayBeBack(ok, now: after) && policy.nextDelay(active: ok, now: before) == 30)
}

@Test func reportedLimitSwitchesEvenWhenUsageLooksFine() {
    let a = record("A", five: 40), b = record("B", five: 10)                     // A's numbers are stale
    #expect(policy.target(active: a, accounts: [a, b], mainID: nil, lastSwitch: nil, now: fixedNow) == nil)
    #expect(policy.target(active: a, accounts: [a, b], mainID: nil, lastSwitch: nil, now: fixedNow, assumeLimited: true)?.id == "B")
    // Still honours the cooldown and never picks a limited account.
    #expect(policy.target(active: a, accounts: [a, b], mainID: nil, lastSwitch: fixedNow, now: fixedNow, assumeLimited: true) == nil)
    let full = record("B", five: 100)
    #expect(policy.target(active: a, accounts: [a, full], mainID: nil, lastSwitch: nil, now: fixedNow, assumeLimited: true) == nil)
}
