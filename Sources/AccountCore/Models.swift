import Foundation

/// The `claudeAiOauth` object Claude Code keeps in its keychain item. Kept as raw
/// JSON so fields added by future Claude Code versions survive a switch.
public struct OAuthTokens: Equatable, Sendable {
    public var raw: JSONValue

    public init(raw: JSONValue) { self.raw = raw }

    public var accessToken: String? { raw["accessToken"]?.stringValue }
    public var refreshToken: String? { raw["refreshToken"]?.stringValue }
    public var subscriptionType: String? { raw["subscriptionType"]?.stringValue }
    public var rateLimitTier: String? { raw["rateLimitTier"]?.stringValue }
    /// Milliseconds since 1970.
    public var expiresAt: Int64? { raw["expiresAt"]?.int64Value }

    public func isExpired(now: Date, margin: TimeInterval = 120) -> Bool {
        guard let expiresAt else { return true }
        return Double(expiresAt) / 1000 <= now.timeIntervalSince1970 + margin
    }

    /// Same login when either token matches (Claude Code may have rotated one of them).
    public func sameLogin(as other: OAuthTokens) -> Bool {
        (accessToken != nil && accessToken == other.accessToken)
            || (refreshToken != nil && refreshToken == other.refreshToken)
    }
}

/// Claude Code's whole keychain payload: `claudeAiOauth` plus other logins (`mcpOAuth`, …)
/// that must never be touched by a switch.
public struct CredentialsDocument: Equatable, Sendable {
    public var raw: JSONValue

    public init(raw: JSONValue) { self.raw = raw }
    public init(json: String) throws { raw = try JSONValue.parse(Data(json.utf8)) }

    public var claudeOAuth: OAuthTokens? {
        get { raw["claudeAiOauth"].map(OAuthTokens.init(raw:)) }
        set { raw["claudeAiOauth"] = newValue?.raw }
    }

    public func json() throws -> String { String(decoding: try raw.data(), as: UTF8.self) }
}

public struct Profile: Codable, Equatable, Sendable {
    public struct Account: Codable, Equatable, Sendable {
        public var uuid: String
        public var email: String?
        public var full_name: String?
        public var display_name: String?
        public var has_claude_max: Bool?
        public var has_claude_pro: Bool?
        public var created_at: String?
    }
    public struct Organization: Codable, Equatable, Sendable {
        public var uuid: String?
        public var name: String?
        public var organization_type: String?
        public var billing_type: String?
        public var rate_limit_tier: String?
        public var has_extra_usage_enabled: Bool?
        public var subscription_status: String?
        public var subscription_created_at: String?
    }
    public var account: Account
    public var organization: Organization?
}

public struct UsageWindow: Codable, Equatable, Sendable {
    /// 0–100.
    public var utilization: Double?
    public var resets_at: String?

    public var resetsAt: Date? { resets_at.flatMap(parseISODate) }
}

public struct UsageLimit: Codable, Equatable, Sendable {
    public var kind: String?
    public var group: String?
    public var percent: Double?
    public var severity: String?
    public var resets_at: String?
    public var is_active: Bool?

    public var resetsAt: Date? { resets_at.flatMap(parseISODate) }
}

public struct ExtraUsage: Codable, Equatable, Sendable {
    public var is_enabled: Bool?
    public var monthly_limit: Double?
    public var used_credits: Double?
    public var currency: String?
    public var spend_limit_reached: Bool?
}

public struct Usage: Codable, Equatable, Sendable {
    public var five_hour: UsageWindow?
    public var seven_day: UsageWindow?
    public var seven_day_opus: UsageWindow?
    public var seven_day_sonnet: UsageWindow?
    public var extra_usage: ExtraUsage?
    public var limits: [UsageLimit]?

    /// True when any window is used up, so new requests will be refused until it resets.
    public var isLimited: Bool {
        let windows = [five_hour, seven_day, seven_day_opus, seven_day_sonnet].compactMap { $0?.utilization }
        if windows.contains(where: { $0 >= 100 }) { return true }
        return (limits ?? []).contains { ($0.percent ?? 0) >= 100 }
    }

    /// When the earliest exhausted window opens again.
    public var limitResetsAt: Date? {
        var dates: [Date] = []
        for w in [five_hour, seven_day, seven_day_opus, seven_day_sonnet].compactMap({ $0 })
        where (w.utilization ?? 0) >= 100 { if let d = w.resetsAt { dates.append(d) } }
        for l in limits ?? [] where (l.percent ?? 0) >= 100 { if let d = l.resetsAt { dates.append(d) } }
        return dates.max()
    }

    /// Highest of the session and weekly windows, for ranking accounts.
    public var pressure: Double {
        max(five_hour?.utilization ?? 0, seven_day?.utilization ?? 0)
    }
}

/// What the app remembers about one account. Tokens are not in here; they live in the keychain.
public struct AccountRecord: Codable, Equatable, Identifiable, Sendable {
    public var id: String           // account uuid
    public var email: String?
    public var displayName: String?
    public var fullName: String?
    public var organizationName: String?
    public var organizationUuid: String?
    public var organizationType: String?
    public var billingType: String?
    public var subscriptionType: String?
    public var subscriptionStatus: String?
    public var subscriptionCreatedAt: String?
    public var rateLimitTier: String?
    public var extraUsageEnabled: Bool?
    public var accountCreatedAt: String?
    /// The `oauthAccount` block Claude Code keeps in ~/.claude.json for this account.
    public var oauthAccount: JSONValue?
    public var usage: Usage?
    public var usageFetchedAt: Date?
    public var lastError: String?
    public var needsLogin: Bool = false
    public var addedAt: Date

    public init(id: String, addedAt: Date) { self.id = id; self.addedAt = addedAt }

    /// Display name, unless it is a placeholder like "a"; then full name or email.
    public var title: String {
        for name in [displayName, fullName] {
            if let n = name?.trimmingCharacters(in: .whitespaces), n.count >= 2 { return n }
        }
        return email ?? displayName ?? id
    }

    /// "Max 5x", "Max 20x", "Pro", "Team", …
    public var planName: String {
        let tier = (rateLimitTier ?? "").lowercased()
        let sub = (subscriptionType ?? "").lowercased()
        if tier.contains("max_20x") { return "Max 20x" }
        if tier.contains("max_5x") { return "Max 5x" }
        switch sub {
        case "max": return "Max"
        case "pro": return "Pro"
        case "team": return "Team"
        case "enterprise": return "Enterprise"
        case "": return organizationType?.replacingOccurrences(of: "_", with: " ").capitalized ?? "Unknown"
        default: return sub.capitalized
        }
    }

    mutating func apply(profile p: Profile, tokens: OAuthTokens?) {
        email = p.account.email ?? email
        displayName = p.account.display_name ?? displayName
        fullName = p.account.full_name ?? fullName
        accountCreatedAt = p.account.created_at ?? accountCreatedAt
        if let o = p.organization {
            organizationName = o.name ?? organizationName
            organizationUuid = o.uuid ?? organizationUuid
            organizationType = o.organization_type ?? organizationType
            billingType = o.billing_type ?? billingType
            subscriptionStatus = o.subscription_status ?? subscriptionStatus
            subscriptionCreatedAt = o.subscription_created_at ?? subscriptionCreatedAt
            rateLimitTier = o.rate_limit_tier ?? rateLimitTier
            extraUsageEnabled = o.has_extra_usage_enabled ?? extraUsageEnabled
        }
        if let tokens {
            subscriptionType = tokens.subscriptionType ?? subscriptionType
            rateLimitTier = tokens.rateLimitTier ?? rateLimitTier
        }
    }

    /// A minimal `oauthAccount` block when Claude Code's own copy was never seen.
    func synthesizedOAuthAccount() -> JSONValue {
        var o: [String: JSONValue] = ["accountUuid": .string(id)]
        if let email { o["emailAddress"] = .string(email) }
        if let displayName { o["displayName"] = .string(displayName) }
        if let fullName { o["fullName"] = .string(fullName) }
        if let organizationName { o["organizationName"] = .string(organizationName) }
        if let organizationUuid { o["organizationUuid"] = .string(organizationUuid) }
        if let billingType { o["billingType"] = .string(billingType) }
        return .object(o)
    }
}

func parseISODate(_ s: String) -> Date? {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let d = f.date(from: s) { return d }
    f.formatOptions = [.withInternetDateTime]
    return f.date(from: s)
}
