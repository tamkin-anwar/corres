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
    func signIn() async {
        guard let presenter = Self.rootViewController() else {
            errorMessage = "Could not find a window to present sign-in from."
            return
        }
        isSigningIn = true
        defer { isSigningIn = false }
        do {
            let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: presenter)
            let granted = Set(result.user.grantedScopes ?? [])
            if !granted.isSuperset(of: Self.gmailScopes) {
                _ = try await result.user.addScopes(Self.gmailScopes, presenting: presenter)
            }
            guard let email = result.user.profile?.email, !email.isEmpty else {
                errorMessage = "Could not connect Gmail. Please try again."
                return
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
        await GoogleTokenProvider.shared.removeRefreshToken(for: email)
        // GoogleSignIn's own session only ever tracks one account; clearing
        // it is only meaningful when the disconnected account happens to be
        // the one it currently holds, but calling it unconditionally when no
        // accounts remain is a harmless, simple way to also fully clear that
        // legacy single slot (relevant right after the migration path above).
        if accounts.isEmpty {
            GIDSignIn.sharedInstance.signOut()
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
