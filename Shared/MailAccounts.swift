import Foundation

/// Which service an account's mail lives with. Corres is one mail app over
/// both: everything above the client (sorting, Needs You, Primary, Send
/// Later, drafts, the Share sheet) is the same whichever this is.
enum MailProvider: String, Codable, Sendable {
    /// `imap`: any other email account (Yahoo, Fastmail, a work server),
    /// on the same IMAP and SMTP engine as iCloud.
    case google, microsoft, icloud, imap

    /// "Gmail", "Outlook", "iCloud", "Email": what people call the service.
    var title: String {
        switch self {
        case .google: String(localized: "Gmail")
        case .microsoft: String(localized: "Outlook")
        case .icloud: String(localized: "iCloud")
        case .imap: String(localized: "Email")
        }
    }

    /// Reached over IMAP and SMTP with a password, not an API.
    var usesIMAP: Bool { self == .icloud || self == .imap }

    /// The most attachments one email from this service can carry, before
    /// encoding. iCloud takes 20 MB per email in all, and attachments grow
    /// by about a third on the way, so 15 MB of files.
    var attachmentLimit: Int {
        switch self {
        case .google, .microsoft, .imap: 25_000_000
        case .icloud: 15_000_000
        }
    }

    /// `attachmentLimit` as people read it: "25 MB".
    var attachmentLimitText: String { "\(attachmentLimit / 1_000_000) MB" }
}

/// Each connected account's provider, kept in the App Group so the Share
/// extension sends through the right one. Accounts connected before
/// Outlook existed have no entry and are Gmail.
enum MailAccounts {
    private static let key = "corres.accountProviders"
    /// One App Group store for the process. A new UserDefaults per read
    /// meant a trip to the preferences daemon each time, and this is read
    /// for every mail call and every row's account tag.
    nonisolated(unsafe) static let groupDefaults = UserDefaults(suiteName: "group.studio.anwarcreative.corres") ?? .standard

    /// The map, read from the App Group once and then kept; only Corres
    /// itself changes it (`setProvider`), which updates this copy too.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cachedMap: [String: String]?

    private static var map: [String: String] {
        lock.lock(); defer { lock.unlock() }
        if let cachedMap { return cachedMap }
        let loaded = groupDefaults.dictionary(forKey: key) as? [String: String] ?? [:]
        cachedMap = loaded
        return loaded
    }

    static func provider(for account: String) -> MailProvider {
        map[account.lowercased()].flatMap(MailProvider.init(rawValue:)) ?? .google
    }

    static func setProvider(_ provider: MailProvider, for account: String) {
        var updated = groupDefaults.dictionary(forKey: key) as? [String: String] ?? [:]
        updated[account.lowercased()] = provider.rawValue
        groupDefaults.set(updated, forKey: key)
        lock.lock(); cachedMap = updated; lock.unlock()
    }

    /// A short tag telling an account apart from the others in a shared
    /// inbox: the service or company it belongs to ("GMAIL", "OUTLOOK",
    /// "ANWARLOG"), or, when two accounts share one, the start of each
    /// address.
    static func tag(for account: String, among accounts: [String]) -> String {
        func service(_ address: String) -> String {
            let domain = address.lowercased().components(separatedBy: "@").last ?? address
            return personalServices[domain]?.uppercased()
                ?? String((domain.components(separatedBy: ".").first ?? domain).prefix(8)).uppercased()
        }
        let mine = service(account)
        let shared = accounts.filter { $0.lowercased() != account.lowercased() && service($0) == mine }
        guard !shared.isEmpty else { return mine }
        let local = account.components(separatedBy: "@").first ?? account
        return String(local.prefix(8)).uppercased()
    }

    private static let personalServices = [
        "gmail.com": "Gmail", "googlemail.com": "Gmail",
        "outlook.com": "Outlook", "hotmail.com": "Outlook", "live.com": "Outlook", "msn.com": "Outlook",
        "icloud.com": "iCloud", "me.com": "iCloud", "mac.com": "iCloud", "yahoo.com": "Yahoo",
        "ymail.com": "Yahoo", "rocketmail.com": "Yahoo", "aol.com": "AOL", "fastmail.com": "Fastmail",
        "zoho.com": "Zoho", "zohomail.com": "Zoho", "gmx.com": "GMX", "gmx.net": "GMX", "mail.com": "Mail.com",
        "proton.me": "Proton", "protonmail.com": "Proton", "yandex.com": "Yandex",
    ]

    /// "Gmail", "Outlook", or a work address's domain ("anwarlogistics.com").
    static func serviceName(for account: String) -> String {
        let domain = account.lowercased().components(separatedBy: "@").last ?? account
        return personalServices[domain] ?? domain
    }

    /// The service's name for sentences: "Gmail", "iCloud", or for any
    /// other account its own ("Yahoo", "Fastmail", "anwarlogistics.com").
    static func serviceTitle(for account: String) -> String {
        let provider = provider(for: account)
        return provider == .imap ? serviceName(for: account) : provider.title
    }

    static func forget(_ account: String) {
        var updated = groupDefaults.dictionary(forKey: key) as? [String: String] ?? [:]
        updated[account.lowercased()] = nil
        groupDefaults.set(updated, forKey: key)
        lock.lock(); cachedMap = updated; lock.unlock()
    }
}


/// Where an IMAP account's mail lives: its servers, and the name it signs
/// in with. iCloud's are fixed; any other account's were found when it was
/// added (`MailServerDiscovery`). Kept in the App Group, so the Share and
/// notification extensions reach the same servers.
struct IMAPServer: Codable, Sendable, Equatable {
    enum SMTPSecurity: String, Codable, Sendable { case tls, startTLS }
    var imapHost: String
    var imapPort: Int = 993
    var smtpHost: String
    var smtpPort: Int = 587
    var smtpSecurity: SMTPSecurity = .startTLS
    /// Usually the address itself; some servers want only the name.
    var username: String?

    static let icloud = IMAPServer(imapHost: "imap.mail.me.com", smtpHost: "smtp.mail.me.com")

    private static let key = "corres.imapServers"

    static func `for`(_ account: String) -> IMAPServer {
        if MailAccounts.provider(for: account) == .icloud { return .icloud }
        let all = MailAccounts.groupDefaults.data(forKey: key)
            .flatMap { try? JSONDecoder().decode([String: IMAPServer].self, from: $0) } ?? [:]
        return all[account.lowercased()] ?? .icloud
    }

    static func save(_ server: IMAPServer, for account: String) {
        var all = MailAccounts.groupDefaults.data(forKey: key)
            .flatMap { try? JSONDecoder().decode([String: IMAPServer].self, from: $0) } ?? [:]
        all[account.lowercased()] = server
        MailAccounts.groupDefaults.set(try? JSONEncoder().encode(all), forKey: key)
    }
}
