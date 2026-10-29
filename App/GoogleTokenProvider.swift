import Foundation

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

    enum TokenError: Error {
        case noRefreshToken, noClientID, refreshFailed
        /// Google was busy or down (429, 5xx): try again, still signed in.
        case unavailable(statusCode: Int)
    }

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

    /// A sign-in Google turned down (revoked, or the password changed),
    /// and when. Not offered again for a while: every 20-second check,
    /// label refresh and waiting change asked again, thousands of times a
    /// day on a Mac left open. Signing in again brings a new one, tried at
    /// once.
    private var refused: [String: (token: Int, at: Date)] = [:]
    private static let refusedPause: TimeInterval = 10 * 60

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
        if let last = refused[email], last.token == refreshToken.hashValue,
           Date().timeIntervalSince(last.at) < Self.refusedPause {
            throw TokenError.refreshFailed
        }
        // The same client GoogleSignIn reads; from Info.plist, so the Share
        // extension (which doesn't link GoogleSignIn) can refresh too.
        guard let clientID = Bundle.main.object(forInfoDictionaryKey: "GIDClientID") as? String else {
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
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            if status == 429 || (500...599).contains(status) { throw TokenError.unavailable(statusCode: status) }
            refused[email] = (refreshToken.hashValue, Date())
            throw TokenError.refreshFailed
        }
        refused[email] = nil
        let decoded = try JSONDecoder().decode(TokenResponse.self, from: data)
        cache[email] = CachedToken(value: decoded.access_token, expiresAt: Date().addingTimeInterval(TimeInterval(decoded.expires_in)))
        if let idToken = decoded.id_token {
            idTokens[email] = CachedToken(value: idToken, expiresAt: Self.expiry(ofJWT: idToken)
                                          ?? Date().addingTimeInterval(TimeInterval(decoded.expires_in)))
        }
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

    /// Google's ID token for the account, which comes with every access
    /// token (the sign-in includes `openid email`): Google's signed word
    /// that this is the account's verified address. The push relay checks
    /// it so nobody can register an address they didn't sign in to. Kept
    /// in memory only, and fresh for at least five more minutes; nil when
    /// there's none (offline, or a sign-in without it).
    private var idTokens: [String: CachedToken] = [:]

    func idToken(for email: String) async -> String? {
        if let cached = idTokens[email], cached.expiresAt > Date().addingTimeInterval(5 * 60) { return cached.value }
        // A token still cached would skip the refresh that brings one.
        if inFlightRefreshes[email] == nil { cache[email] = nil }
        _ = try? await accessToken(for: email)
        guard let fresh = idTokens[email], fresh.expiresAt > Date() else { return nil }
        return fresh.value
    }

    /// A JWT's `exp`, without checking anything else: only to know when to
    /// ask for a new one.
    static func expiry(ofJWT token: String) -> Date? {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { return nil }
        var payload = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        payload += String(repeating: "=", count: (4 - payload.count % 4) % 4)
        guard let data = Data(base64Encoded: payload),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = claims["exp"] as? NSNumber else { return nil }
        return Date(timeIntervalSince1970: exp.doubleValue)
    }

    func store(refreshToken: String, for email: String) {
        Keychain.set(refreshToken, key: Self.keychainKey(for: email))
        cache[email] = nil
        idTokens[email] = nil
        grantedScopes[email] = nil
        refused[email] = nil
        // Signed in again: an older sign-in still waiting to be withdrawn
        // must not be, since withdrawing it would end this one too.
        Keychain.deleteDeviceOnly(key: Self.pendingRevokeKey(for: email), service: Self.pendingRevokeService)
    }

    /// Forgets the cached access token so the next call mints a fresh one.
    func invalidateAccessToken(for email: String) {
        cache[email] = nil
    }

    func removeRefreshToken(for email: String, everywhere: Bool) {
        let refreshToken = Keychain.get(key: Self.keychainKey(for: email))
        Keychain.delete(key: Self.keychainKey(for: email), everywhere: everywhere)
        cache[email] = nil
        idTokens[email] = nil
        // Removed from all your devices: Corres's access to the account is
        // given back at Google too, as the privacy policy says. Revoking one
        // token ends the whole grant ("Revocation removes all OAuth 2.0
        // scopes previously granted to a project, invalidating any issued
        // access or refresh tokens"), so every device's sign-in stops working
        // with it. Not from this device only: the others keep the account.
        // Offline, or Google busy, the removal still goes ahead and the
        // token waits on this device only (never synced or backed up) until
        // Google takes it (`retryPendingRevokes`), then it's deleted.
        guard everywhere, let refreshToken else { return }
        let key = Self.pendingRevokeKey(for: email)
        Keychain.setDeviceOnly(refreshToken, key: key, service: Self.pendingRevokeService)
        Task.detached(priority: .utility) {
            if await Self.revoke(refreshToken) { Keychain.deleteDeviceOnly(key: key, service: Self.pendingRevokeService) }
        }
    }

    /// Sign-ins removed from all devices that Google hasn't withdrawn yet,
    /// tried again whenever Corres comes back (`renewWatchIfDue`). One whose
    /// account was added again meanwhile, here or on another device, is
    /// dropped instead: withdrawing it would end the new sign-in too. After
    /// 30 days it's dropped anyway.
    func retryPendingRevokes() async {
        let prefix = Self.pendingRevokeKey(for: "")
        for item in Keychain.deviceOnlyItems(service: Self.pendingRevokeService) {
            let email = String(item.key.dropFirst(prefix.count))
            let stale = item.saved.map { $0.timeIntervalSinceNow < -30 * 86_400 } ?? false
            let done = !item.key.hasPrefix(prefix) || stale || Keychain.get(key: Self.keychainKey(for: email)) != nil
            if done { Keychain.deleteDeviceOnly(key: item.key, service: Self.pendingRevokeService); continue }
            if await Self.revoke(item.value) { Keychain.deleteDeviceOnly(key: item.key, service: Self.pendingRevokeService) }
        }
    }

    private static let pendingRevokeService = "corres.pendingRevoke"
    private static func pendingRevokeKey(for email: String) -> String { "studio.anwarcreative.corres.pendingRevoke.\(email)" }

    /// Google's revocation endpoint (RFC 7009), the token in the form body
    /// rather than the URL so it never lands in a URL log. 200 means
    /// revoked; 400 (`invalid_token`) means it already was. Either way it's
    /// done; anything else (offline, Google busy) is false, to try again.
    @discardableResult
    static func revoke(_ token: String) async -> Bool {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/revoke")!, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("token=\(formURLEncode(token))".utf8)
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let status = (response as? HTTPURLResponse)?.statusCode else { return false }
        return status == 200 || status == 400
    }

    /// Lets the Share extension use this account's sign-in too.
    func share(_ email: String) {
        Keychain.share(key: Self.keychainKey(for: email))
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

    private struct TokenResponse: Decodable { let access_token: String; let expires_in: Int; let scope: String?; let id_token: String? }
}
