import SwiftUI

/// How each connected account looks and behaves in Corres, set from
/// Settings → an account. Modelled on Spark (a name for the account, its
/// colour, its own notifications, whether it shows in the unified inbox),
/// iOS Mail (notifications and a signature per account) and Gmail
/// (several named signatures, one for new mail and one for replies).
/// Kept on this iPhone; nothing here changes the account itself.
enum AccountPreferences {
    private static var defaults: UserDefaults { .standard }
    private static func key(_ name: String, _ account: String) -> String { "corres.account.\(name).\(account.lowercased())" }

    /// Bumped by Settings whenever an account's name, colour or place in
    /// All Inboxes changes, so lists observing it (`@AppStorage`) redraw.
    static let revisionKey = "corres.accounts.revision"
    static func changed() { defaults.set(defaults.integer(forKey: revisionKey) &+ 1, forKey: revisionKey) }
    static var revision: Int { defaults.integer(forKey: revisionKey) }

    // MARK: Name

    /// What Corres calls the account: in the account switcher, on its
    /// mail in All Inboxes, in Settings. "Work", "Studio", "Personal".
    static func nicknameKey(for account: String) -> String { key("nickname", account) }

    static func customNickname(for account: String) -> String? {
        defaults.string(forKey: nicknameKey(for: account)).flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
    }

    /// The custom name, or the service ("Gmail", "Outlook") or the
    /// company's domain for a work address.
    static func nickname(for account: String) -> String {
        customNickname(for: account) ?? MailAccounts.serviceName(for: account)
    }

    /// The short tag on its mail in All Inboxes.
    static func tag(for account: String, among accounts: [String]) -> String {
        if let custom = customNickname(for: account) { return String(custom.prefix(12)).uppercased() }
        return MailAccounts.tag(for: account, among: accounts)
    }

    // MARK: Your name

    /// The name people see the email from, for the account's own address
    /// (a send-as alias keeps the name Gmail gives it).
    static func senderNameKey(for account: String) -> String { key("senderName", account) }

    static func senderName(for account: String) -> String? {
        defaults.string(forKey: senderNameKey(for: account)).flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
    }

    // MARK: Colour

    /// Eight tones that sit with Corres's palette in light and dark, far
    /// enough apart to tell at a glance (Spark's twenty include near twins).
    struct Tone: Identifiable, Hashable {
        let id: Int
        let name: String
        let color: Color
    }

    static let tones: [Tone] = [
        Tone(id: 0, name: "Blue", color: Color(hex: 0x3B82F6)),
        Tone(id: 1, name: "Orange", color: Color(hex: 0xF08A24)),
        Tone(id: 2, name: "Green", color: Color(hex: 0x22A060)),
        Tone(id: 3, name: "Purple", color: Color(hex: 0x8B5CF6)),
        Tone(id: 4, name: "Pink", color: Color(hex: 0xE5508F)),
        Tone(id: 5, name: "Teal", color: Color(hex: 0x14A3A8)),
        Tone(id: 6, name: "Gold", color: Color(hex: 0xD4A017)),
        Tone(id: 7, name: "Red", color: Color(hex: 0xE0453A)),
    ]

    /// Settings → Accounts → Colour-Code Accounts. On by default once a
    /// second account is connected: Spark's default, and the quickest way
    /// to tell work from personal in one inbox.
    static let colorCodingKey = "corres.accountColors"
    static var colorCoding: Bool { defaults.object(forKey: colorCodingKey) as? Bool ?? true }

    static func toneKey(for account: String) -> String { key("tone", account) }

    /// The account's tone; until one is picked, the next free one in the
    /// order the accounts were added, so two accounts never start alike.
    static func tone(for account: String, among accounts: [String]) -> Tone {
        if let saved = defaults.object(forKey: toneKey(for: account)) as? Int, let tone = tones.first(where: { $0.id == saved }) {
            return tone
        }
        let taken = Set(accounts.compactMap { defaults.object(forKey: toneKey(for: $0)) as? Int })
        let unpicked = accounts.filter { defaults.object(forKey: toneKey(for: $0)) == nil }
        let free = tones.filter { !taken.contains($0.id) }
        let position = unpicked.firstIndex(of: account) ?? 0
        return free.isEmpty ? tones[position % tones.count] : free[position % free.count]
    }

    /// The colour shown for the account's mail, or nil with colour coding
    /// off or only one account.
    static func color(for account: String, among accounts: [String]) -> Color? {
        guard colorCoding, accounts.count > 1 else { return nil }
        return tone(for: account, among: accounts).color
    }

    // MARK: All Inboxes

    /// Off keeps an account out of All Inboxes, Needs You, Waiting and the
    /// Brief while it still syncs; switch to it to see its mail (Spark's
    /// "Show in Unified Inbox").
    static func allInboxesKey(for account: String) -> String { key("allInboxes", account) }
    static func showsInAllInboxes(_ account: String) -> Bool { defaults.object(forKey: allInboxesKey(for: account)) as? Bool ?? true }

    /// The accounts a merged view shows. Never none: hiding every account
    /// from All Inboxes would leave it empty with no way to see why.
    static func allInboxesAccounts(_ accounts: [String]) -> [String] {
        let shown = accounts.filter(showsInAllInboxes)
        return shown.isEmpty ? accounts : shown
    }

    /// `threads` scoped to one account, or to every account shown in All Inboxes.
    static func scope<T>(_ items: [T], account: String?, all accounts: [String], by accountOf: (T) -> String) -> [T] {
        if let account { return items.filter { accountOf($0) == account } }
        let hidden = Set(accounts.filter { !showsInAllInboxes($0) })
        guard !hidden.isEmpty, hidden.count < accounts.count else { return items }
        return items.filter { !hidden.contains(accountOf($0)) }
    }

    // MARK: Notifications

    /// Per account, as in Spark and iOS Mail: follow Settings →
    /// Notifications, or choose for this account alone.
    enum Notify: String, CaseIterable, Identifiable {
        case standard, everything, people, needsYou, off
        var id: String { rawValue }

        var title: String {
            switch self {
            case .standard: "Same as Settings"
            case .everything: PushNotificationService.Level.everything.title
            case .people: PushNotificationService.Level.people.title
            case .needsYou: PushNotificationService.Level.needsYou.title
            case .off: "Off"
            }
        }
    }

    static func notifyKey(for account: String) -> String { key("notify", account) }

    static func notify(for account: String) -> Notify {
        if let raw = defaults.string(forKey: notifyKey(for: account)), let choice = Notify(rawValue: raw) { return choice }
        // The earlier on/off switch carries over.
        return CorresSettings.notifies(for: account) ? .standard : .off
    }

    /// What this account notifies about, or nil when it's quiet.
    static func level(for account: String) -> PushNotificationService.Level? {
        switch notify(for: account) {
        case .standard: .current
        case .everything: .everything
        case .people: .people
        case .needsYou: .needsYou
        case .off: nil
        }
    }
}

// MARK: - Signatures

/// One signature, named so it can be picked: "Studio", "Short", "Personal".
struct Signature: Codable, Identifiable, Hashable {
    var id: String = UUID().uuidString
    var name: String
    var text: String
}

/// Every signature, and which one each account adds to new mail and to
/// replies (Gmail's two defaults; a short one on replies is common). In
/// Compose the signature can be switched for that one email.
enum Signatures {
    private static var defaults: UserDefaults { .standard }
    static let key = "corres.signatures"

    static var all: [Signature] {
        get {
            migrateIfNeeded()
            guard let data = defaults.data(forKey: key) else { return [] }
            return (try? JSONDecoder().decode([Signature].self, from: data)) ?? []
        }
        set { defaults.set(try? JSONEncoder().encode(newValue), forKey: key) }
    }

    static func defaultKey(for account: String, reply: Bool) -> String {
        "corres.account.\(reply ? "replySignature" : "newSignature").\(account.lowercased())"
    }

    /// The signature's id, "" for none.
    static func defaultID(for account: String, reply: Bool) -> String {
        migrateIfNeeded()
        return defaults.string(forKey: defaultKey(for: account, reply: reply)) ?? ""
    }

    static func setDefault(_ id: String, for account: String, reply: Bool) {
        defaults.set(id, forKey: defaultKey(for: account, reply: reply))
    }

    static func signature(for account: String?, reply: Bool) -> Signature? {
        guard let account else { return nil }
        let id = defaultID(for: account, reply: reply)
        return all.first { $0.id == id }
    }

    static func text(for account: String?, reply: Bool) -> String {
        (signature(for: account, reply: reply)?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func delete(_ id: String) {
        all.removeAll { $0.id == id }
        for (key, value) in defaults.dictionaryRepresentation()
        where (key.hasPrefix("corres.account.newSignature.") || key.hasPrefix("corres.account.replySignature.")) && value as? String == id {
            defaults.set("", forKey: key)
        }
    }

    /// The one signature per account from before becomes a named one,
    /// still that account's default for new mail and replies.
    private static let migratedKey = "corres.signatures.migrated"
    private static func migrateIfNeeded() {
        guard !defaults.bool(forKey: migratedKey) else { return }
        defaults.set(true, forKey: migratedKey)
        let prefix = "corres.signature."
        var created: [Signature] = []
        for (key, value) in defaults.dictionaryRepresentation() where key.hasPrefix(prefix) {
            let account = String(key.dropFirst(prefix.count))
            guard account != "sample", let text = value as? String,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            let existing = created.first { $0.text == text }
            let signature = existing ?? Signature(name: AccountPreferences.nickname(for: account), text: text)
            if existing == nil { created.append(signature) }
            defaults.set(signature.id, forKey: defaultKey(for: account, reply: false))
            defaults.set(signature.id, forKey: defaultKey(for: account, reply: true))
        }
        if !created.isEmpty { defaults.set(try? JSONEncoder().encode(created), forKey: key) }
    }
}
