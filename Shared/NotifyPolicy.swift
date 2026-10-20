import Foundation

/// What the notification extension needs to decide how an email notifies,
/// kept in the App Group by the app (it can't read the app's own settings):
/// each account's choice, your VIPs and blocked senders. And which emails
/// the extension has already shown, so the app's own sync never shows the
/// same one twice.
struct NotifyPolicy: Codable, Sendable {
    /// Per account: "everything", "people", "needsYou" or "off"
    /// (`PushNotificationService.Level` raw values, or off).
    var levels: [String: String] = [:]
    /// Lowercased addresses.
    var vips: [String] = []
    var blocked: [String] = []
    /// Companies blocked by a Screener rule (lowercased domains). Optional
    /// so a policy saved before it existed still loads.
    var blockedDomains: [String]?

    private static let key = "corres.notifyPolicy"
    private static var defaults: UserDefaults { MailAccounts.groupDefaults }

    static func load() -> NotifyPolicy {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(NotifyPolicy.self, from: $0) } ?? NotifyPolicy()
    }

    func save() { Self.defaults.set(try? JSONEncoder().encode(self), forKey: Self.key) }

    func level(for account: String) -> String { levels[account.lowercased()] ?? "people" }

    // MARK: Already shown

    private static let shownKey = "corres.notifiedMessages"

    /// Remembers that this email's notification is on screen.
    static func markShown(_ messageID: String) {
        var shown = defaults.stringArray(forKey: shownKey) ?? []
        guard !shown.contains(messageID) else { return }
        shown.append(messageID)
        defaults.set(Array(shown.suffix(300)), forKey: shownKey)
    }

    // MARK: Gmail

    /// Gmail's pushes say only that something changed. Builds with Apple's
    /// notification filtering (CORRES_NSE_FILTERING, set once Apple grants
    /// it) ask the relay for a visible push per change, and the extension
    /// shows only what's new since this point, staying silent otherwise.
    #if CORRES_NSE_FILTERING
    static let gmailAlerts = true
    #else
    static let gmailAlerts = false
    #endif

    private static func cursorKey(_ account: String) -> String { "corres.gmailCursor.\(account.lowercased())" }

    static func gmailCursor(for account: String) -> String? { defaults.string(forKey: cursorKey(account)) }

    static func setGmailCursor(_ historyId: String, for account: String) {
        // Only forward: pushes can arrive out of order.
        if let current = gmailCursor(for: account), let old = UInt64(current), let new = UInt64(historyId), new <= old { return }
        defaults.set(historyId, forKey: cursorKey(account))
    }

    static func wasShown(_ messageID: String?) -> Bool {
        guard let messageID else { return false }
        return (defaults.stringArray(forKey: shownKey) ?? []).contains(messageID)
    }
}
