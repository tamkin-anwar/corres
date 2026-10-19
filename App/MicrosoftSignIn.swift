import AuthenticationServices
import CryptoKit
import Foundation

/// Signing in an Outlook account (Outlook.com, Hotmail, Live, and work or
/// school Microsoft 365): Microsoft's own sign-in page in Apple's secure
/// web sheet, with PKCE, which is how Microsoft says a mobile app should
/// sign in without its own library. Corres never sees the password.
@MainActor
final class MicrosoftSignIn: NSObject, ASWebAuthenticationPresentationContextProviding {
    struct Result {
        let email: String
        let name: String?
        let givenName: String?
    }

    enum SignInError: Error { case notConfigured, cancelled, failed }

    static let redirectScheme = "msauth.studio.anwarcreative.corres"
    static var redirectURI: String { "\(redirectScheme)://auth" }

    private var session: ASWebAuthenticationSession?

    func signIn(hint: String? = nil) async throws -> Result {
        guard let clientID = OutlookTokenProvider.clientID else { throw SignInError.notConfigured }
        let verifier = Self.randomString(64)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        let state = Self.randomString(24)
        var components = URLComponents(string: "https://login.microsoftonline.com/common/oauth2/v2.0/authorize")!
        var items = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "response_mode", value: "query"),
            URLQueryItem(name: "scope", value: OutlookTokenProvider.scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "prompt", value: "select_account"),
        ]
        if let hint { items.append(URLQueryItem(name: "login_hint", value: hint)) }
        components.queryItems = items

        let callback: URL = try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: components.url!, callbackURLScheme: Self.redirectScheme) { url, error in
                if let url { continuation.resume(returning: url) }
                else if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin { continuation.resume(throwing: SignInError.cancelled) }
                else { continuation.resume(throwing: SignInError.failed) }
            }
            session.presentationContextProvider = self
            // Shares the person's Safari sign-in, so a work account already
            // signed in is a tap, as in Mail and Outlook's own app.
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            session.start()
        }
        let query = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard query.first(where: { $0.name == "state" })?.value == state,
              let code = query.first(where: { $0.name == "code" })?.value else { throw SignInError.failed }

        let tokens = try await OutlookTokenProvider.tokenRequest([
            "client_id": clientID, "grant_type": "authorization_code", "code": code,
            "redirect_uri": Self.redirectURI, "code_verifier": verifier,
            "scope": OutlookTokenProvider.scopes.joined(separator: " "),
        ])
        guard let refresh = tokens.refresh_token else { throw SignInError.failed }

        // Who signed in: their address and name, from Graph itself.
        var request = URLRequest(url: URL(string: "https://graph.microsoft.com/v1.0/me?$select=mail,userPrincipalName,displayName,givenName")!)
        request.setValue("Bearer \(tokens.access_token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let me = try? JSONDecoder().decode(Me.self, from: data),
              let email = (me.mail ?? me.userPrincipalName)?.lowercased(), email.contains("@") else { throw SignInError.failed }
        await OutlookTokenProvider.shared.store(refreshToken: refresh, accessToken: tokens.access_token,
                                                expiresIn: tokens.expires_in, for: email)
        return Result(email: email, name: me.displayName, givenName: me.givenName)
    }

    private struct Me: Decodable {
        let mail: String?
        let userPrincipalName: String?
        let displayName: String?
        let givenName: String?
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated { Platform.keyWindow } ?? ASPresentationAnchor()
    }

    private static func randomString(_ length: Int) -> String {
        let characters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        var generator = SystemRandomNumberGenerator()
        return String((0..<length).map { _ in characters.randomElement(using: &generator)! })
    }
}

extension Data {
    /// Base64 without padding, URL-safe (RFC 7636's code challenge).
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
