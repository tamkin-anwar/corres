import Foundation
import GoogleSignIn

/// Turns a connected account's email into a valid Gmail access token,
/// independent of whichever account happens to be GoogleSignIn's own single
/// `currentUser` slot. GoogleSignIn-iOS has no first-party API for multiple
/// simultaneously-persisted accounts (confirmed via google/GoogleSignIn-iOS
/// issue #311, an open feature request): `currentUser`/
/// `restorePreviousSignIn()`/`signOut()` all operate on one Keychain-backed
/// slot. Corres works around this the same way other apps needing true
/// multi-account Google sign-in do: capture each account's own OAuth refresh
/// token once (`GIDGoogleUser.refreshToken.tokenString`, a documented public
/// property) at the moment it signs in, store it ourselves (Keychain, see
/// `Keychain.swift`), and mint access tokens directly against Google's OAuth
/// token endpoint from then on, never going back through GoogleSignIn's own
/// single-slot session for any account but whichever is currently active
/// there.
///
/// An `actor`, not `@MainActor`: token minting is pure networking with no UI
/// dependency, and the in-memory access-token cache needs to be safe to hit
/// from a background push/BGAppRefreshTask path as well as the main actor.
actor GoogleTokenProvider {
    static let shared = GoogleTokenProvider()

    enum TokenError: Error { case noRefreshToken, noClientID, refreshFailed }

    private struct CachedToken { let value: String; let expiresAt: Date }
    private var cache: [String: CachedToken] = [:]

    /// A short buffer before the real expiry, so a token doesn't expire
    /// mid-request for a call that started using it right as it lapsed.
    private static let expiryBuffer: TimeInterval = 60

    func accessToken(for email: String) async throws -> String {
        if let cached = cache[email], cached.expiresAt > Date().addingTimeInterval(Self.expiryBuffer) {
            return cached.value
        }
        guard let refreshToken = Keychain.get(key: Self.keychainKey(for: email)) else {
            throw TokenError.noRefreshToken
        }
        guard let clientID = GIDSignIn.sharedInstance.configuration?.clientID else {
            throw TokenError.noClientID
        }
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let params = ["client_id": clientID, "grant_type": "refresh_token", "refresh_token": refreshToken]
        request.httpBody = params
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")" }
            .joined(separator: "&")
            .data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw TokenError.refreshFailed
        }
        let decoded = try JSONDecoder().decode(TokenResponse.self, from: data)
        cache[email] = CachedToken(value: decoded.access_token, expiresAt: Date().addingTimeInterval(TimeInterval(decoded.expires_in)))
        return decoded.access_token
    }

    func store(refreshToken: String, for email: String) {
        Keychain.set(refreshToken, key: Self.keychainKey(for: email))
        cache[email] = nil
    }

    func removeRefreshToken(for email: String) {
        Keychain.delete(key: Self.keychainKey(for: email))
        cache[email] = nil
    }

    func hasRefreshToken(for email: String) -> Bool {
        Keychain.get(key: Self.keychainKey(for: email)) != nil
    }

    private static func keychainKey(for email: String) -> String {
        "studio.anwarcreative.corres.refreshToken.\(email)"
    }

    private struct TokenResponse: Decodable { let access_token: String; let expires_in: Int }
}
