import GoogleSignIn
import Observation
import UIKit

/// Wraps GoogleSignIn for the interactive sign-in UI only. Kept out of Core
/// deliberately, matching the "Gmail DTOs, OAuth, persistence details must
/// not appear in SwiftUI views" boundary from ADR 002; views see only
/// `accounts`/`isSigningIn`/`errorMessage`, never GIDGoogleUser or a raw
/// token.
///
/// True simultaneous multi-account (Batch 29) moves where the session itself
/// lives: each connected account's refresh token is captured the moment it
/// signs in and stored independently via `GoogleTokenProvider`/`Keychain`,
/// not left in GoogleSignIn's own single-slot Keychain store, since that
/// store only ever remembers one signed-in user (see `GoogleTokenProvider`'s
/// doc comment). This is a deliberate departure from ADR 005's original "the
/// session lives entirely in GoogleSignIn's own store" stance, accepted
/// because that stance cannot support more than one account at a time.
@MainActor @Observable
final class GoogleAuthService {
    private(set) var accounts: [GmailAccount] = []
    private(set) var isSigningIn = false
    var errorMessage: String?

    private let defaults = UserDefaults.standard
    private static let connectedAccountsKey = "corres.connectedAccounts"

    /// `gmail.readonly`, `gmail.send`, and now `gmail.modify` (Archive/Trash/
    /// read state) all requested upfront at connect time, one consent
    /// screen, rather than `gmail.modify`'s old incremental request-on-first-
    /// use pattern: incremental scope grants need a live `GIDGoogleUser` for
    /// the account in question, which this design only ever has for
    /// whichever account GoogleSignIn's own session currently holds, not for
    /// every connected account. Requesting everything upfront sidesteps that
    /// entirely. All three remain Google's "sensitive," not "restricted,"
    /// scopes; see Docs/Architecture.md ADR 005.
    private static let gmailScopes = [
        "https://www.googleapis.com/auth/gmail.readonly",
        "https://www.googleapis.com/auth/gmail.send",
        "https://www.googleapis.com/auth/gmail.modify",
    ]

    var primaryAccount: GmailAccount? { accounts.first }
    static let givenNameKey = "corres.givenName"
    private static let profilesKey = "corres.accountProfiles"

    func isConnected(_ email: String) -> Bool { accounts.contains { $0.email == email } }

    /// Restores every account this device already has a stored refresh token
    /// for. Also migrates a single pre-Batch-29 GoogleSignIn session
    /// (someone who connected Gmail before multi-account existed): without
    /// this, that person's real, existing connection would otherwise vanish
    /// after updating, since their refresh token only ever lived in
    /// GoogleSignIn's own store, never in Corres's own Keychain entry.
    func restoreConnectedAccounts() async {
        let storedEmails = defaults.stringArray(forKey: Self.connectedAccountsKey) ?? []
        var restored: [GmailAccount] = []
        for email in storedEmails where await GoogleTokenProvider.shared.hasRefreshToken(for: email) {
            restored.append(GmailAccount(email: email))
        }
        if restored.isEmpty {
            await migrateLegacySingleAccountIfPresent(into: &restored)
        }
        accounts = restored
        persistAccountList()
        Task { await fillProfilesIfMissing() }
    }

    /// Each account's display name and Google profile photo, for the
    /// account button and switcher. Kept in UserDefaults on this device only.
    private(set) var profiles: [String: AccountProfile] = [:]

    struct AccountProfile: Codable, Equatable {
        var name: String?
        var photoURL: URL?
    }

    func profile(for email: String) -> AccountProfile? { profiles[email] }

    private func setProfile(for email: String, name: String?, photo: URL?) {
        profiles[email] = AccountProfile(name: name, photoURL: photo)
        if let data = try? JSONEncoder().encode(profiles) { defaults.set(data, forKey: Self.profilesKey) }
    }

    /// Accounts connected before Corres kept names and photos never stored
    /// them; ask Google's own profile endpoint once per account (sign-in
    /// already granted the basic profile scope). Silent on any failure:
    /// the UI falls back to a monogram.
    private func fillProfilesIfMissing() async {
        if let data = defaults.data(forKey: Self.profilesKey),
           let stored = try? JSONDecoder().decode([String: AccountProfile].self, from: data) {
            profiles = stored
        }
        for account in accounts where profiles[account.email] == nil || defaults.string(forKey: Self.givenNameKey) == nil {
            guard let token = try? await GoogleTokenProvider.shared.accessToken(for: account.email),
                  let url = URL(string: "https://openidconnect.googleapis.com/v1/userinfo") else { continue }
            var request = URLRequest(url: url)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if account.email == accounts.first?.email, defaults.string(forKey: Self.givenNameKey) == nil,
               let given = json["given_name"] as? String, !given.isEmpty {
                defaults.set(given, forKey: Self.givenNameKey)
            }
            // Google photo URLs carry their size as a suffix ("=s96-c");
            // ask for 192px so the circle stays sharp at 3x.
            let photo = (json["picture"] as? String).flatMap { raw -> URL? in
                let base = raw.range(of: "=s", options: .backwards).map { String(raw[..<$0.lowerBound]) } ?? raw
                return URL(string: base + "=s192-c")
            }
            setProfile(for: account.email, name: json["name"] as? String, photo: photo)
        }
    }

    /// One-time upgrade path: reads whatever GoogleSignIn's own single-slot
    /// store still remembers (true for anyone who connected before this
    /// batch shipped) and captures its refresh token into Corres's own
    /// storage, so the existing connection carries over instead of silently
    /// requiring a fresh sign-in.
    private func migrateLegacySingleAccountIfPresent(into restored: inout [GmailAccount]) async {
        guard let user = try? await GIDSignIn.sharedInstance.restorePreviousSignIn() else { return }
        guard let email = user.profile?.email else { return }
        let granted = Set(user.grantedScopes ?? [])
        if !granted.isSuperset(of: Self.gmailScopes), let presenter = Self.rootViewController() {
            _ = try? await user.addScopes(Self.gmailScopes, presenting: presenter)
        }
        await GoogleTokenProvider.shared.store(refreshToken: user.refreshToken.tokenString, for: email)
        restored.append(GmailAccount(email: email))
    }

    /// Always drives GoogleSignIn's own interactive, account-picker-capable
    /// flow, then folds the result into `accounts` as an addition, never a
    /// replacement: signing in a second account must not drop the first, the
    /// whole point of this batch. Signing in an already-connected account
    /// again (e.g. to refresh a revoked grant) is a harmless no-op merge.
    static let modifyScope = "https://www.googleapis.com/auth/gmail.modify"

    /// `hint` pre-selects an account in Google's picker, for reconnecting
    /// one whose permissions are incomplete. Gmail scopes are requested in
    /// the sign-in itself, one consent screen, rather than a basic sign-in
    /// followed by a separate `addScopes` prompt, so the refresh token
    /// stored below is the one that actually carries them.
    func signIn(hint: String? = nil) async {
        guard let presenter = Self.rootViewController() else {
            errorMessage = "Could not find a window to present sign-in from."
            return
        }
        isSigningIn = true
        defer { isSigningIn = false }
        do {
            let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: presenter, hint: hint,
                                                                   additionalScopes: Self.gmailScopes)
            guard let email = result.user.profile?.email, !email.isEmpty else {
                errorMessage = "Could not connect Gmail. Please try again."
                return
            }
            // Only the first account's name is kept, for the Brief's
            // greeting; it never leaves the device.
            if defaults.string(forKey: Self.givenNameKey) == nil,
               let given = result.user.profile?.givenName, !given.isEmpty {
                defaults.set(given, forKey: Self.givenNameKey)
            }
            if let profile = result.user.profile {
                setProfile(for: email, name: profile.name, photo: profile.hasImage ? profile.imageURL(withDimension: 192) : nil)
            }
            // Google's consent screen lets each permission be unchecked.
            // Without modify, reading works but read/unread, archive, trash,
            // flags, and labels all fail — say so now, not on the first tap.
            if !Set(result.user.grantedScopes ?? []).contains(Self.modifyScope) {
                errorMessage = "Corres can read \(email) but wasn't allowed to manage it, so marking read, archiving, and flagging won't work. Reconnect and leave every Gmail permission checked."
            }
            await GoogleTokenProvider.shared.store(refreshToken: result.user.refreshToken.tokenString, for: email)
            if !accounts.contains(where: { $0.email == email }) {
                accounts.append(GmailAccount(email: email))
                persistAccountList()
            }
        } catch {
            let nsError = error as NSError
            // Cancellation is not an error worth surfacing: the user changed
            // their mind, and that is a normal outcome, not a failure.
            if nsError.domain != "com.google.GIDSignIn" || nsError.code != GIDSignInError.canceled.rawValue {
                errorMessage = "Could not connect Gmail. Please try again."
            }
        }
    }

    /// Disconnects exactly one account, leaving any others connected: the
    /// per-account equivalent of the old single-account `signOut()`.
    func signOut(_ email: String) async {
        accounts.removeAll { $0.email == email }
        persistAccountList()
        profiles[email] = nil
        if let data = try? JSONEncoder().encode(profiles) { defaults.set(data, forKey: Self.profilesKey) }
        await GoogleTokenProvider.shared.removeRefreshToken(for: email)
        // GoogleSignIn's own session only ever tracks one account; clearing
        // it is only meaningful when the disconnected account happens to be
        // the one it currently holds, but calling it unconditionally when no
        // accounts remain is a harmless, simple way to also fully clear that
        // legacy single slot (relevant right after the migration path above).
        if accounts.isEmpty {
            GIDSignIn.sharedInstance.signOut()
            // The Brief's greeting name belongs to whoever is connected.
            defaults.removeObject(forKey: Self.givenNameKey)
        }
    }

    private func persistAccountList() {
        defaults.set(accounts.map(\.email), forKey: Self.connectedAccountsKey)
    }

    private static func rootViewController() -> UIViewController? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?.rootViewController
    }
}
