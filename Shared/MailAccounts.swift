import Foundation

/// Which service an account's mail lives with. Corres is one mail app over
/// both: everything above the client (sorting, Needs You, Primary, Send
/// Later, drafts, the Share sheet) is the same whichever this is.
enum MailProvider: String, Codable, Sendable {
    case google, microsoft, icloud

    /// "Gmail", "Outlook", "iCloud": what people call the service.
    var title: String {
        switch self {
        case .google: "Gmail"
        case .microsoft: "Outlook"
        case .icloud: "iCloud"
        }
    }
}

/// Each connected account's provider, kept in the App Group so the Share
/// extension sends through the right one. Accounts connected before
/// Outlook existed have no entry and are Gmail.
enum MailAccounts {
    private static let key = "corres.accountProviders"
    private static var defaults: UserDefaults { UserDefaults(suiteName: "group.studio.anwarcreative.corres") ?? .standard }

    static func provider(for account: String) -> MailProvider {
        let map = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
        return map[account.lowercased()].flatMap(MailProvider.init(rawValue:)) ?? .google
    }

    static func setProvider(_ provider: MailProvider, for account: String) {
        var map = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
        map[account.lowercased()] = provider.rawValue
        defaults.set(map, forKey: key)
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
    ]

    /// "Gmail", "Outlook", or a work address's domain ("anwarlogistics.com").
    static func serviceName(for account: String) -> String {
        let domain = account.lowercased().components(separatedBy: "@").last ?? account
        return personalServices[domain] ?? domain
    }

    static func forget(_ account: String) {
        var map = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
        map[account.lowercased()] = nil
        defaults.set(map, forKey: key)
    }
}
