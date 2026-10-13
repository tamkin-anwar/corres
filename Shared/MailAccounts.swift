import Foundation

/// Which service an account's mail lives with. Corres is one mail app over
/// both: everything above the client (sorting, Needs You, Primary, Send
/// Later, drafts, the Share sheet) is the same whichever this is.
enum MailProvider: String, Codable, Sendable {
    case google, microsoft

    /// "Gmail", "Outlook": what people call the service.
    var title: String {
        switch self {
        case .google: "Gmail"
        case .microsoft: "Outlook"
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

    static func forget(_ account: String) {
        var map = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
        map[account.lowercased()] = nil
        defaults.set(map, forKey: key)
    }
}
