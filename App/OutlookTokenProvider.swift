import Foundation

/// An Outlook account's access to Microsoft Graph, the way
/// `GoogleTokenProvider` keeps a Gmail account's: a refresh token per
/// account in the shared Keychain group, and access tokens minted from it.
/// Microsoft rotates refresh tokens, so each refresh stores the new one.
///
/// The app's Microsoft client id is `MSClientID` in Info.plist (the app's
/// and the Share extension's).
actor OutlookTokenProvider {
    static let shared = OutlookTokenProvider()

    enum TokenError: Error { case noRefreshToken, noClientID, refreshFailed }

    /// What Corres asks for: read and organize mail, send it, change
    /// mailbox settings (Out of Office), and stay signed in.
    static let scopes = ["offline_access", "openid", "profile", "email", "User.Read",
                         "Mail.ReadWrite", "Mail.Send", "MailboxSettings.ReadWrite"]
    static let tokenURL = URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/token")!

    static var clientID: String? {
        (Bundle.main.object(forInfoDictionaryKey: "MSClientID") as? String).flatMap { $0.isEmpty ? nil : $0 }
    }

    private struct Cached { let value: String; let expiresAt: Date }
    private var cache: [String: Cached] = [:]
    private var inFlight: [String: Task<String, Error>] = [:]

    func accessToken(for account: String) async throws -> String {
        if let cached = cache[account], cached.expiresAt > Date().addingTimeInterval(60) { return cached.value }
        if let running = inFlight[account] { return try await running.value }
        let task = Task { try await self.refresh(account) }
        inFlight[account] = task
        defer { inFlight[account] = nil }
        return try await task.value
    }

    private func refresh(_ account: String) async throws -> String {
        guard let refreshToken = Keychain.get(key: Self.key(account)) else { throw TokenError.noRefreshToken }
        guard let clientID = Self.clientID else { throw TokenError.noClientID }
        let response = try await Self.tokenRequest([
            "client_id": clientID, "grant_type": "refresh_token", "refresh_token": refreshToken,
            "scope": Self.scopes.joined(separator: " "),
        ])
        if let rotated = response.refresh_token { Keychain.set(rotated, key: Self.key(account)) }
        cache[account] = Cached(value: response.access_token, expiresAt: .now.addingTimeInterval(TimeInterval(response.expires_in)))
        return response.access_token
    }

    func store(refreshToken: String, accessToken: String?, expiresIn: Int?, for account: String) {
        Keychain.set(refreshToken, key: Self.key(account))
        if let accessToken, let expiresIn {
            cache[account] = Cached(value: accessToken, expiresAt: .now.addingTimeInterval(TimeInterval(expiresIn)))
        }
    }

    func invalidateAccessToken(for account: String) { cache[account] = nil }

    func remove(_ account: String, everywhere: Bool = true) {
        Keychain.delete(key: Self.key(account), everywhere: everywhere)
        cache[account] = nil
    }

    func hasRefreshToken(for account: String) -> Bool { Keychain.get(key: Self.key(account)) != nil }

    private static func key(_ account: String) -> String { "studio.anwarcreative.corres.msRefreshToken.\(account.lowercased())" }

    // MARK: Token endpoint

    struct TokenResponse: Decodable {
        let access_token: String
        let refresh_token: String?
        let expires_in: Int
        let id_token: String?
    }

    static func tokenRequest(_ params: [String: String]) async throws -> TokenResponse {
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        request.httpBody = params.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.value)" }
            .joined(separator: "&").data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else { throw TokenError.refreshFailed }
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }
}
