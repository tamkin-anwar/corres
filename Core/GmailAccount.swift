import Foundation

/// UI-facing connection state only. The OAuth session itself (tokens) is
/// never represented here — GoogleAuthService (App layer) holds it via
/// GoogleSignIn's own Keychain-backed session store, matching ADR 004's
/// "tokens belong in Keychain, never in a value passed around loosely."
public struct GmailAccount: Identifiable, Hashable, Sendable {
    public let email: String
    public var id: String { email }

    public init(email: String) {
        self.email = email
    }
}
