import Foundation

/// Every personal preference in Settings, in one place, with the defaults
/// researched against Apple Mail, Gmail and Spark. Read from anywhere
/// (views use `@AppStorage` with the same keys); stored on this iPhone.
enum CorresSettings {
    private static var defaults: UserDefaults { .standard }

    // MARK: Composing

    /// Apple Mail's own default is 10 seconds; Off sends at once.
    static let undoSendKey = "corres.undoSendSeconds"
    static let undoSendChoices = [0, 5, 10, 20, 30]
    static var undoSendSeconds: Int { defaults.object(forKey: undoSendKey) as? Int ?? 10 }

    static let defaultReplyKey = "corres.defaultReply"
    enum DefaultReply: String, CaseIterable, Identifiable {
        case reply, replyAll
        var id: String { rawValue }
        var title: String { self == .reply ? "Reply" : "Reply All" }
    }
    static var defaultReply: DefaultReply {
        defaults.string(forKey: defaultReplyKey).flatMap(DefaultReply.init) ?? .reply
    }

    static let defaultFromKey = "corres.defaultFromAccount"
    static var defaultFromAccount: String? { defaults.string(forKey: defaultFromKey) }

    static func signatureKey(for account: String) -> String { "corres.signature.\(account.lowercased())" }
    static func signature(for account: String?) -> String {
        guard let account else { return "" }
        return (defaults.string(forKey: signatureKey(for: account)) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Reading

    static let remoteImagesKey = "corres.remoteImages"
    enum RemoteImages: String, CaseIterable, Identifiable {
        case ask, always
        var id: String { rawValue }
        var title: String { self == .ask ? "Ask first" : "Always load" }
    }
    static var remoteImages: RemoteImages {
        defaults.string(forKey: remoteImagesKey).flatMap(RemoteImages.init) ?? .ask
    }

    static let confirmTrashKey = "corres.confirmTrash"
    static var confirmTrash: Bool { defaults.bool(forKey: confirmTrashKey) }

    static let markReadOnOpenKey = "corres.markReadOnOpen"
    static var markReadOnOpen: Bool { defaults.object(forKey: markReadOnOpenKey) as? Bool ?? true }

    static let openLinksKey = "corres.openLinks"
    enum OpenLinks: String, CaseIterable, Identifiable {
        case inCorres, browser
        var id: String { rawValue }
        var title: String { self == .inCorres ? "In Corres" : "Default browser" }
    }
    static var openLinks: OpenLinks {
        defaults.string(forKey: openLinksKey).flatMap(OpenLinks.init) ?? .inCorres
    }

    // MARK: Lists

    static let previewLinesKey = "corres.previewLines"
    static var previewLines: Int { defaults.object(forKey: previewLinesKey) as? Int ?? 2 }

    static let showAvatarsKey = "corres.showAvatars"
    static var showAvatars: Bool { defaults.object(forKey: showAvatarsKey) as? Bool ?? true }

    static let badgeKey = "corres.badge"
    enum Badge: String, CaseIterable, Identifiable {
        case needsYou, unread, off
        var id: String { rawValue }
        var title: String {
            switch self {
            case .needsYou: "Needs You"
            case .unread: "Unread"
            case .off: "Off"
            }
        }
    }
    static var badge: Badge { defaults.string(forKey: badgeKey).flatMap(Badge.init) ?? .needsYou }

    // MARK: Sorting

    static let vipsKey = "corres.vips"
    /// Lowercased addresses of people who always land in Needs You and
    /// always notify.
    static var vips: Set<String> { Set(defaults.stringArray(forKey: vipsKey) ?? []) }
    static func setVIP(_ email: String, _ isVIP: Bool) {
        var all = vips
        if isVIP { all.insert(email.lowercased()) } else { all.remove(email.lowercased()) }
        defaults.set(all.sorted(), forKey: vipsKey)
    }

    static let sensitivityKey = "corres.sensitivity"
    static var sensitivity: InboxClassifier.Sensitivity {
        defaults.string(forKey: sensitivityKey).flatMap(InboxClassifier.Sensitivity.init) ?? .balanced
    }

    static let morningHourKey = "corres.snooze.morningHour"
    static let laterTodayEveningKey = "corres.snooze.laterTodayEvening"

    /// Hands the sorting and snooze choices to Core, which has no access
    /// to Settings itself. Called at launch and whenever one changes.
    @MainActor static func applyToCore() {
        InboxClassifier.vipAddresses = vips
        InboxClassifier.sensitivity = sensitivity
        TimePhrase.morningHour = defaults.object(forKey: morningHourKey) as? Int ?? 8
        TimePhrase.laterTodayIsEvening = defaults.bool(forKey: laterTodayEveningKey)
    }

    static let followUpDaysKey = "corres.followUpDays"
    static let followUpChoices = [1, 2, 3, 5, 7]
    static var followUpDays: Int { defaults.object(forKey: followUpDaysKey) as? Int ?? 3 }

    static func accountNotificationsKey(for account: String) -> String { "corres.notify.\(account.lowercased())" }
    static func notifies(for account: String) -> Bool {
        defaults.object(forKey: accountNotificationsKey(for: account)) as? Bool ?? true
    }
}
