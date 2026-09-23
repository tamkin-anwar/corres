import GoogleSignIn
import Observation
import UIKit

/// Wraps GoogleSignIn. Kept out of Core deliberately, matching the
/// "Gmail DTOs, OAuth, persistence details must not appear in SwiftUI views"
/// boundary from ADR 002; views see only `account`/`isSigningIn`/`errorMessage`,
/// never GIDGoogleUser or a raw token. The session itself (tokens) lives in
/// GoogleSignIn's own Keychain-backed store; see GmailAccount's doc comment.
@MainActor @Observable
final class GoogleAuthService {
    private(set) var account: GmailAccount?
    private(set) var isSigningIn = false
    var errorMessage: String?

    /// `gmail.readonly` plus `gmail.send`, and nothing wider at first connect:
    /// `gmail.modify` (needed for Archive/Trash/read state) is requested
    /// incrementally, the same pattern `gmail.send` already used, only the
    /// first time one of those actions is actually attempted (see
    /// `ensureModifyScope`). All three are Google's "sensitive," not
    /// "restricted," scopes, so they need standard OAuth consent-screen
    /// review before general release but not a CASA security assessment;
    /// see Docs/Architecture.md ADR 005.
    private static let gmailScopes = [
        "https://www.googleapis.com/auth/gmail.readonly",
        "https://www.googleapis.com/auth/gmail.send",
    ]
    private static let sendScope = "https://www.googleapis.com/auth/gmail.send"
    private static let modifyScope = "https://www.googleapis.com/auth/gmail.modify"

    func restorePreviousSignIn() async {
        guard let user = try? await GIDSignIn.sharedInstance.restorePreviousSignIn() else {
            account = nil
            return
        }
        account = GmailAccount(email: user.profile?.email ?? "")
    }

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
            account = GmailAccount(email: result.user.profile?.email ?? "")
        } catch {
            let nsError = error as NSError
            // Cancellation is not an error worth surfacing: the user changed
            // their mind, and that is a normal outcome, not a failure.
            if nsError.domain != "com.google.GIDSignIn" || nsError.code != GIDSignInError.canceled.rawValue {
                errorMessage = "Could not connect Gmail. Please try again."
            }
        }
    }

    /// An account connected before `gmail.send` was requested only has
    /// `gmail.readonly` granted; this asks for the missing scope
    /// incrementally (another system consent sheet, not a full re-sign-in)
    /// the first time it's actually needed, rather than forcing every
    /// existing connection to disconnect and reconnect.
    @discardableResult
    func ensureSendScope() async -> Bool { await ensureScope(Self.sendScope) }

    /// Same incremental pattern as `ensureSendScope`, for Archive/Trash/read
    /// state, which all need `gmail.modify`, not requested at first connect.
    @discardableResult
    func ensureModifyScope() async -> Bool { await ensureScope(Self.modifyScope) }

    private func ensureScope(_ scope: String) async -> Bool {
        guard let user = GIDSignIn.sharedInstance.currentUser else { return false }
        if Set(user.grantedScopes ?? []).contains(scope) { return true }
        guard let presenter = Self.rootViewController() else { return false }
        _ = try? await user.addScopes([scope], presenting: presenter)
        return Set(user.grantedScopes ?? []).contains(scope)
    }

    func signOut() {
        GIDSignIn.sharedInstance.signOut()
        account = nil
    }

    private static func rootViewController() -> UIViewController? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?.rootViewController
    }
}
