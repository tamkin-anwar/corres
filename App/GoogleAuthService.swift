import GoogleSignIn
import Observation
import UIKit

/// Wraps GoogleSignIn. Kept out of Core deliberately — this is exactly the
/// "Gmail DTOs, OAuth, persistence details must not appear in SwiftUI views"
/// boundary from ADR 002; views see only `account`/`isSigningIn`/`errorMessage`,
/// never GIDGoogleUser or a raw token. The session itself (tokens) lives in
/// GoogleSignIn's own Keychain-backed store — see GmailAccount's doc comment.
@MainActor @Observable
final class GoogleAuthService {
    private(set) var account: GmailAccount?
    private(set) var isSigningIn = false
    var errorMessage: String?

    /// Read-only is deliberately the starting scope: Corres does not send,
    /// delete, or modify anything via Gmail yet (see Docs/Product.md's V1
    /// progression). Widen this only when that capability actually exists.
    private static let gmailScopes = ["https://www.googleapis.com/auth/gmail.readonly"]

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
            // Cancellation is not an error worth surfacing — the user changed
            // their mind, that is a normal outcome, not a failure.
            if nsError.domain != "com.google.GIDSignIn" || nsError.code != GIDSignInError.canceled.rawValue {
                errorMessage = "Could not connect Gmail. Please try again."
            }
        }
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
