import Foundation

public enum ClaudeAPIError: Error, Equatable {
    case http(Int)
    case unauthorized
    case badResponse
}

public struct RefreshedTokens: Equatable, Sendable {
    public var accessToken: String
    public var refreshToken: String
    public var expiresIn: Double
}

public protocol ClaudeAPI: Sendable {
    func profile(accessToken: String) async throws -> Profile
    func usage(accessToken: String) async throws -> Usage
    func refresh(refreshToken: String, scopes: [String]) async throws -> RefreshedTokens
}

/// The same OAuth endpoints Claude Code uses for `/usage` and its own login refresh.
public struct LiveClaudeAPI: ClaudeAPI {
    static let base = URL(string: "https://api.anthropic.com")!
    static let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let beta = "oauth-2025-04-20"

    let session: URLSession

    public init(session: URLSession = .shared) { self.session = session }

    public func profile(accessToken: String) async throws -> Profile {
        try await get("/api/oauth/profile", token: accessToken)
    }

    public func usage(accessToken: String) async throws -> Usage {
        try await get("/api/oauth/usage", token: accessToken)
    }

    public func refresh(refreshToken: String, scopes: [String]) async throws -> RefreshedTokens {
        var req = URLRequest(url: Self.tokenURL, timeoutInterval: 30)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: String] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": Self.clientID,
        ]
        if !scopes.isEmpty { body["scope"] = scopes.joined(separator: " ") }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await session.data(for: req)
        try Self.check(resp)
        struct R: Decodable { var access_token: String; var refresh_token: String?; var expires_in: Double? }
        let r = try JSONDecoder().decode(R.self, from: data)
        return RefreshedTokens(accessToken: r.access_token,
                               refreshToken: r.refresh_token ?? refreshToken,
                               expiresIn: r.expires_in ?? 3600)
    }

    private func get<T: Decodable>(_ path: String, token: String) async throws -> T {
        var req = URLRequest(url: Self.base.appendingPathComponent(path), timeoutInterval: 20)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue(Self.beta, forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, resp) = try await session.data(for: req)
        try Self.check(resp)
        do { return try JSONDecoder().decode(T.self, from: data) } catch { throw ClaudeAPIError.badResponse }
    }

    static func check(_ resp: URLResponse) throws {
        guard let h = resp as? HTTPURLResponse else { throw ClaudeAPIError.badResponse }
        if h.statusCode == 401 || h.statusCode == 403 { throw ClaudeAPIError.unauthorized }
        guard (200..<300).contains(h.statusCode) else { throw ClaudeAPIError.http(h.statusCode) }
    }
}
