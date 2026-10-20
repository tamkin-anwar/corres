import GoogleSignIn
import Observation

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
    nonisolated private static let connectedAccountsKey = "corres.connectedAccounts"

    /// Whether any Gmail account was connected on this iPhone, readable
    /// before `restoreConnectedAccounts()` finishes: sample mail must never
    /// be put back for someone who has real mail.
    nonisolated static var hasSavedAccounts: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-SampleMailOnly") { return false }
        #endif
        return !(UserDefaults.standard.stringArray(forKey: connectedAccountsKey) ?? []).isEmpty
    }

    /// Requested upfront at connect time, one consent screen (incremental
    /// grants need a live `GIDGoogleUser` for the account, which this design
    /// only has for whichever account GoogleSignIn's session holds).
    ///
    /// Only `gmail.modify`: it reads, organizes and sends, everything Corres
    /// does except Out of Office (`settingsScope`, asked for only there).
    /// `gmail.readonly` and `gmail.send` were redundant beside it, and
    /// Google's verification rejects scopes an app doesn't need. Note that
    /// `gmail.modify` is a *restricted* scope (Google's verification plus an
    /// annual CASA security assessment), not merely sensitive.
    private static let gmailScopes = [
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
        #if DEBUG
        // App Store screenshots: sample mail only, whatever accounts this
        // device has, and nothing written back to them.
        if ProcessInfo.processInfo.arguments.contains("-SampleMailOnly") { return }
        #endif
        watchICloudPasswords()
        var storedEmails = defaults.stringArray(forKey: Self.connectedAccountsKey) ?? []
        // Added on your other devices (iCloud Keychain): signed in here too.
        storedEmails += AccountSync.adopt(into: storedEmails)
        var restored: [GmailAccount] = []
        for email in storedEmails {
            let signedIn = switch MailAccounts.provider(for: email) {
            case .microsoft: await OutlookTokenProvider.shared.hasRefreshToken(for: email)
            case .icloud, .imap: IMAPCredentials.password(for: email) != nil
            case .google: await GoogleTokenProvider.shared.hasRefreshToken(for: email)
            }
            if signedIn { restored.append(GmailAccount(email: email)) }
        }
        if restored.isEmpty {
            await migrateLegacySingleAccountIfPresent(into: &restored)
        }
        accounts = restored
        // Launching never shrinks the list your other devices use.
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
        for account in accounts where MailAccounts.provider(for: account.email) == .google
            && (profiles[account.email] == nil || defaults.string(forKey: Self.givenNameKey) == nil) {
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
        for account in accounts where MailAccounts.provider(for: account.email) == .microsoft
            && profiles[account.email]?.photoURL == nil {
            await fillOutlookPhoto(for: account.email)
        }
    }

    /// An Outlook account's photo, from Microsoft Graph. Unlike Google's it
    /// has no public address, so it's fetched once with the account's token
    /// and kept on this iPhone. An account with no photo is asked again
    /// after a week, in case one has been added since.
    private func fillOutlookPhoto(for email: String) async {
        let checkedKey = "corres.outlookPhotoChecked.\(email.lowercased())"
        if let checked = defaults.object(forKey: checkedKey) as? Date, Date.now.timeIntervalSince(checked) < 7 * 86_400 { return }
        guard let token = try? await OutlookTokenProvider.shared.accessToken(for: email) else { return }
        defaults.set(Date.now, forKey: checkedKey)
        // The 240px size where the account has one (work and school), the
        // original otherwise (personal Microsoft accounts have no sizes).
        for path in ["photos/240x240/$value", "photo/$value"] {
            guard let url = URL(string: "https://graph.microsoft.com/v1.0/me/\(path)") else { continue }
            var request = URLRequest(url: url)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200, PlatformImage(data: data) != nil,
                  let file = ProfilePhotoCache.saveLocal(data, named: email) else { continue }
            setProfile(for: email, name: profiles[email]?.name, photo: file)
            return
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
    /// Out of Office (Gmail's vacation reply). Asked for only when someone
    /// opens it, never at sign-in, so nobody else sees a longer consent.
    static let settingsScope = "https://www.googleapis.com/auth/gmail.settings.basic"

    /// Whether this account's login allows settings like Out of Office.
    func canManageSettings(_ email: String) async -> Bool {
        // Outlook's sign-in includes mailbox settings; iCloud has none over IMAP.
        if MailAccounts.provider(for: email) == .microsoft { return true }
        if MailAccounts.provider(for: email).usesIMAP { return false }
        if await GoogleTokenProvider.shared.grantedScopes(for: email) == nil {
            // Scopes come with a fresh token; a cached one doesn't say.
            await GoogleTokenProvider.shared.invalidateAccessToken(for: email)
            _ = try? await GoogleTokenProvider.shared.accessToken(for: email)
        }
        return await GoogleTokenProvider.shared.grantedScopes(for: email)?.contains(Self.settingsScope) ?? false
    }

    /// Asks Google for the settings permission on this account, keeping
    /// everything it already allows.
    func grantSettings(for email: String) async -> Bool {
        guard let presenter = Self.rootViewController() else { return false }
        do {
            let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: presenter, hint: email,
                                                                   additionalScopes: Self.gmailScopes + [Self.settingsScope])
            guard result.user.profile?.email.lowercased() == email.lowercased() else { return false }
            await GoogleTokenProvider.shared.store(refreshToken: result.user.refreshToken.tokenString, for: email)
            return Set(result.user.grantedScopes ?? []).contains(Self.settingsScope)
        } catch {
            return false
        }
    }

    /// `hint` pre-selects an account in Google's picker, for reconnecting
    /// one whose permissions are incomplete. Gmail scopes are requested in
    /// the sign-in itself, one consent screen, rather than a basic sign-in
    /// followed by a separate `addScopes` prompt, so the refresh token
    /// stored below is the one that actually carries them.
    func signIn(hint: String? = nil) async {
        guard let presenter = Self.rootViewController() else {
            errorMessage = "Couldn't find a window to present sign-in from."
            return
        }
        isSigningIn = true
        defer { isSigningIn = false }
        do {
            let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: presenter, hint: hint,
                                                                   additionalScopes: Self.gmailScopes)
            guard let email = result.user.profile?.email, !email.isEmpty else {
                errorMessage = "Couldn't connect Gmail. Try again."
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
                errorMessage = "Couldn't connect Gmail. Try again."
            }
        }
    }

    private let microsoft = MicrosoftSignIn()

    /// Connects an Outlook account (Outlook.com, Hotmail, Live, or work or
    /// school Microsoft 365), alongside any others.
    func signInOutlook(hint: String? = nil) async {
        isSigningIn = true
        defer { isSigningIn = false }
        do {
            let result = try await microsoft.signIn(hint: hint)
            MailAccounts.setProvider(.microsoft, for: result.email)
            if defaults.string(forKey: Self.givenNameKey) == nil, let given = result.givenName, !given.isEmpty {
                defaults.set(given, forKey: Self.givenNameKey)
            }
            setProfile(for: result.email, name: result.name, photo: profiles[result.email]?.photoURL)
            defaults.removeObject(forKey: "corres.outlookPhotoChecked.\(result.email.lowercased())")
            Task { await fillOutlookPhoto(for: result.email) }
            if !accounts.contains(where: { $0.email == result.email }) {
                accounts.append(GmailAccount(email: result.email))
                persistAccountList()
            }
        } catch MicrosoftSignIn.SignInError.cancelled {
            // Changed their mind: nothing to say.
        } catch MicrosoftSignIn.SignInError.notConfigured {
            errorMessage = "Outlook sign-in isn't set up in this build yet."
        } catch {
            errorMessage = "Couldn't connect Outlook. Try again."
        }
    }

    /// Connects an iCloud Mail account with its address and an
    /// app-specific password, checked by signing in to iCloud's mail server
    /// before anything is saved. Returns a message to show when it didn't
    /// work, or nil when it did.
    func signInICloud(email rawEmail: String, password rawPassword: String) async -> String? {
        guard let email = ICloudSignIn.address(from: rawEmail) else { return "Enter your iCloud address, like name@icloud.com." }
        let password = rawPassword.replacingOccurrences(of: " ", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !password.isEmpty else { return "Paste or type the app-specific password." }
        isSigningIn = true
        defer { isSigningIn = false }
        do {
            try await IMAPSessions.verify(email: email, password: password)
        } catch GmailAPIClient.ClientError.notSignedIn {
            if !ICloudSignIn.looksLikeAppPassword(password) {
                return "That looks like your Apple Account password. iCloud only accepts an app-specific password here: make one with Open Apple Account above."
            }
            if !ICloudSignIn.isAppleDomain(email) {
                return "iCloud didn't accept that. Sign in with your main iCloud address (it ends in @icloud.com, @me.com or @mac.com), even if you send from your own domain."
            }
            return "iCloud didn't accept that password. Check the address is your main iCloud address, or make a new app-specific password and paste it."
        } catch {
            return "Couldn't reach iCloud Mail. Check your connection and try again."
        }
        if icloudNeedsPassword == email { icloudNeedsPassword = nil }
        IMAPCredentials.save(password, for: email)
        MailAccounts.setProvider(.icloud, for: email)
        await IMAPSessions.shared.forget(email)
        if !accounts.contains(where: { $0.email == email }) {
            accounts.append(GmailAccount(email: email))
            persistAccountList()
        }
        return nil
    }

    /// Adds any other email account: tries each server found for it
    /// (`MailServerDiscovery`) by signing in, and keeps the first that
    /// works. Returns what went wrong, or nil.
    func signInIMAP(email rawEmail: String, password rawPassword: String, candidates: [IMAPServer],
                    appPassword: Bool) async -> String? {
        let email = rawEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let password = rawPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard email.contains("@") else { return "Enter your email address." }
        guard !password.isEmpty else { return "Enter your password." }
        isSigningIn = true
        defer { isSigningIn = false }
        var rejected = false
        var working: IMAPServer?
        for server in candidates {
            do {
                try await IMAPSessions.verify(email: email, password: password, server: server)
                working = server
                break
            } catch GmailAPIClient.ClientError.notSignedIn {
                // This server knows the account but not the password, or it
                // isn't this account's server at all: try the rest first.
                rejected = true
                continue
            } catch {
                continue
            }
        }
        guard let server = working else {
            if rejected {
                return appPassword
                    ? "That password didn't work. This service needs an app password, made from the link above, not your usual password."
                    : "That password didn't work. If your email service offers app passwords, make one for Corres and use that."
            }
            return "Corres couldn't find your mail server. Check your connection, or enter the server settings yourself."
        }
        IMAPCredentials.save(password, for: email)
        IMAPServer.save(server, for: email)
        MailAccounts.setProvider(.imap, for: email)
        await IMAPSessions.shared.forget(email)
        if icloudNeedsPassword == email { icloudNeedsPassword = nil }
        if !accounts.contains(where: { $0.email == email }) {
            accounts.append(GmailAccount(email: email))
            persistAccountList()
        }
        return nil
    }

    /// Signs an account in again, with its own service. iCloud has no
    /// sign-in page to send you to: it asks for a new app-specific password.
    func reconnect(_ email: String) async {
        switch MailAccounts.provider(for: email) {
        case .microsoft: await signInOutlook(hint: email)
        case .icloud, .imap: icloudNeedsPassword = email
        case .google: await signIn(hint: email)
        }
    }

    /// An iCloud account whose password iCloud stopped accepting (usually
    /// after an Apple Account password change, which revokes app-specific
    /// passwords). The shell asks for a new one.
    var icloudNeedsPassword: String?
    @ObservationIgnored private var icloudRejection: NSObjectProtocol?

    /// Listens for iCloud turning a password away mid-session.
    func watchICloudPasswords() {
        guard icloudRejection == nil else { return }
        icloudRejection = NotificationCenter.default.addObserver(forName: IMAPSessions.passwordRejected, object: nil, queue: .main) { [weak self] note in
            guard let email = note.object as? String else { return }
            MainActor.assumeIsolated {
                guard let self, self.isConnected(email) else { return }
                self.icloudNeedsPassword = email
            }
        }
    }

    /// Disconnects exactly one account, leaving any others connected: the
    /// per-account equivalent of the old single-account `signOut()`.
    func signOut(_ email: String) async {
        accounts.removeAll { $0.email == email }
        persistAccountList(removing: email)
        MailIndexer.shared.forget(email)
        Task { await SpotlightIndex.shared.forget(account: email) }
        profiles[email] = nil
        if let data = try? JSONEncoder().encode(profiles) { defaults.set(data, forKey: Self.profilesKey) }
        if MailAccounts.provider(for: email).usesIMAP {
            IMAPCredentials.remove(email)
            // Re-adding it later starts with instant alerts off, as new.
            UserDefaults.standard.removeObject(forKey: AccountPreferences.icloudInstantKey(for: email))
            await IMAPSessions.shared.forget(email)
            await IMAPCache.shared.forgetAccount(email)
        } else if MailAccounts.provider(for: email) == .microsoft {
            await OutlookTokenProvider.shared.remove(email)
            await OutlookFolders.shared.forget(email)
        } else {
            await GoogleTokenProvider.shared.removeRefreshToken(for: email)
        }
        MailAccounts.forget(email)
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

    /// The list your other devices use only grows here, except for the one
    /// account you signed out of: an account this device can't open yet is
    /// still yours on the others.
    private func persistAccountList(removing signedOut: String? = nil) {
        defaults.set(accounts.map(\.email), forKey: Self.connectedAccountsKey)
        if let signedOut { AccountSync.remove(signedOut) } else { AccountSync.include(accounts.map(\.email)) }
        SendAsDirectory.publishOwnAddresses(accounts: accounts.map(\.email), aliases: SendAsDirectory.shared.allAddresses)
    }

    private static func rootViewController() -> SignInPresenter? {
        Platform.signInPresenter
    }
}
