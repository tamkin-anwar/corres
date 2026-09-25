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

    /// One in-flight refresh per account, not one per caller. Launch alone
    /// now fires `sync`/`labelDirectory`/`pushService` concurrently for
    /// every connected account (Batch 29's own performance sweep), and on a
    /// cold cache all three would otherwise independently notice the same
    /// account has no valid token yet and each fire their own refresh-token
    /// POST to Google at once: three real network round trips and three
    /// separate hits against Google's OAuth token endpoint for what should
    /// be one. A caller that arrives while a refresh for that account is
    /// already running awaits that same in-flight `Task` instead of
    /// starting a second one.
    private var inFlightRefreshes: [String: Task<String, Error>] = [:]

    func accessToken(for email: String) async throws -> String {
        if let cached = cache[email], cached.expiresAt > Date().addingTimeInterval(Self.expiryBuffer) {
            return cached.value
        }
        if let existing = inFlightRefreshes[email] {
            return try await existing.value
        }
        let task = Task { try await self.refreshAccessToken(for: email) }
        inFlightRefreshes[email] = task
        defer { inFlightRefreshes[email] = nil }
        return try await task.value
    }

    private func refreshAccessToken(for email: String) async throws -> String {
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
            .map { "\($0.key)=\(Self.formURLEncode($0.value))" }
            .joined(separator: "&")
            .data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw TokenError.refreshFailed
        }
        let decoded = try JSONDecoder().decode(TokenResponse.self, from: data)
        cache[email] = CachedToken(value: decoded.access_token, expiresAt: Date().addingTimeInterval(TimeInterval(decoded.expires_in)))
        if let scope = decoded.scope {
            grantedScopes[email] = Set(scope.split(separator: " ").map(String.init))
        }
        return decoded.access_token
    }

    /// What this account's stored login actually allows, as Google reported
    /// it on the last token refresh; nil until one has happened this launch.
    /// Exists because a login can be missing `gmail.modify` while reading
    /// still works: Google's consent screen lets each permission be
    /// unchecked, and the pre-multi-account migration requested it
    /// silently, skipping the request entirely when no window was ready at
    /// launch. Sync then works and every change (read, archive, flag) fails.
    private var grantedScopes: [String: Set<String>] = [:]

    func grantedScopes(for email: String) -> Set<String>? { grantedScopes[email] }

    func store(refreshToken: String, for email: String) {
        Keychain.set(refreshToken, key: Self.keychainKey(for: email))
        cache[email] = nil
        grantedScopes[email] = nil
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

    /// A real, live bug, found by tracing a reported "Could not mark this
    /// conversation as read" alert back to its actual cause rather than
    /// guessing: this request body used to be built with
    /// `.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)`,
    /// which is the *wrong* character set for an
    /// `application/x-www-form-urlencoded` body — it's RFC 3986's generic
    /// URL query set, which deliberately leaves `+`, `&`, and `=` unescaped
    /// because those are all legal, meaningful characters in a URL's query
    /// string. In a form body they mean something else entirely: `&`
    /// separates parameters, `=` separates a key from its value, and `+`
    /// decodes back to a literal space. Google's OAuth refresh tokens are
    /// base64-derived and can genuinely contain any of those three
    /// characters; when one did, that one character silently truncated or
    /// corrupted the `refresh_token` field of every single refresh request
    /// for that account, Google's token endpoint rejected it, and every
    /// Gmail call for that account that needed a fresh token — not just
    /// "mark as read," anything: archive, trash, send, sync — failed with
    /// whatever generic error message that call surfaces, repeatedly and
    /// consistently, since the token never changes between attempts.
    /// RFC 3986's *unreserved* set (letters, digits, `-`, `.`, `_`, `~`) is
    /// what's actually safe to leave unescaped in a form body; everything
    /// else, including `+`/`&`/`=`, is percent-encoded here instead of
    /// assumed safe.
    private static let formURLEncodeAllowed: CharacterSet = {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return allowed
    }()

    private static func formURLEncode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: formURLEncodeAllowed) ?? value
    }

    private struct TokenResponse: Decodable { let access_token: String; let expires_in: Int; let scope: String? }
}
