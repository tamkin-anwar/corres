import Foundation

/// Which accounts you have, kept with their sign-ins in iCloud Keychain, so
/// an account added on your iPhone is there on your Mac and iPad without
/// signing in again, the way Mail's iCloud accounts follow you. Only the
/// address, its service, and for other email its server names travel;
/// the sign-in itself is the Keychain entry next to it.
enum AccountSync {
    struct Entry: Codable, Equatable, Sendable {
        let email: String
        let provider: MailProvider
        var server: IMAPServer?
    }

    private static let key = "corres.accountRoster"

    static func publish(_ accounts: [String]) {
        let entries = accounts.map { email in
            let provider = MailAccounts.provider(for: email)
            return Entry(email: email, provider: provider, server: provider == .imap ? IMAPServer.for(email) : nil)
        }
        guard entries != roster(), let data = try? JSONEncoder().encode(entries) else { return }
        Keychain.setSynced(data, key: key)
    }

    /// Adds these without dropping anything already listed: an account
    /// this device can't open yet (its sign-in hasn't synced, say) is still
    /// yours on the others. One removed from all your devices isn't put
    /// back by a device that hasn't heard yet.
    static func include(_ accounts: [String]) {
        let removed = removedEverywhere()
        let listed = roster().map(\.email)
        let have = Set(listed.map { $0.lowercased() })
        let missing = accounts.filter { !have.contains($0.lowercased()) && removed[$0.lowercased()] == nil }
        guard !missing.isEmpty else { return }
        publish(listed + missing)
    }

    /// Signed in here on purpose: listed for your other devices again, even
    /// if it was removed from all of them before, and no longer one this
    /// device was told to leave out.
    static func added(_ email: String) {
        var removed = removedEverywhere()
        if removed.removeValue(forKey: email.lowercased()) != nil { saveRemovedEverywhere(removed) }
        var here = removedHere
        if here.remove(email.lowercased()) != nil { removedHere = here }
        include([email])
    }

    /// Removed from all your devices: off the list, with a dated note so
    /// each device signs out of it when it next opens, rather than adding
    /// it back.
    static func remove(_ email: String) {
        var removed = removedEverywhere()
        removed[email.lowercased()] = .now
        // A year is long enough for any device to have opened since.
        saveRemovedEverywhere(removed.filter { $0.value > .now.addingTimeInterval(-365 * 86_400) })
        let listed = roster().map(\.email)
        guard listed.contains(where: { $0.caseInsensitiveCompare(email) == .orderedSame }) else { return }
        publish(listed.filter { $0.caseInsensitiveCompare(email) != .orderedSame })
    }

    // MARK: Removed

    /// Kept beside the list rather than in it, so builds from before this
    /// existed still read the list as they always did.
    private static let removedKey = "corres.accountRoster.removed"

    /// Accounts removed from all your devices, and when.
    static func removedEverywhere() -> [String: Date] {
        Keychain.getSynced(key: removedKey).flatMap { try? JSONDecoder().decode([String: Date].self, from: $0) } ?? [:]
    }

    private static func saveRemovedEverywhere(_ removed: [String: Date]) {
        guard let data = try? JSONEncoder().encode(removed) else { return }
        Keychain.setSynced(data, key: removedKey)
    }

    /// Accounts removed from this device only: still yours on the others,
    /// so they stay on the list, but this device doesn't take them back.
    private static let removedHereKey = "corres.accountsRemovedHere"
    static var removedHere: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: removedHereKey) ?? []) }
        set { UserDefaults.standard.set(newValue.sorted(), forKey: removedHereKey) }
    }

    static func removeHere(_ email: String) {
        removedHere.insert(email.lowercased())
    }

    static func roster() -> [Entry] {
        Keychain.getSynced(key: key).flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } ?? []
    }

    /// Accounts from your other devices that this one doesn't have yet,
    /// with what's needed to reach them recorded here first.
    static func adopt(into known: [String]) -> [String] {
        adopt(roster(), into: known)
    }

    /// The same, with the roster already read (it's an iCloud Keychain
    /// query, slow enough to read off the main thread at launch).
    static func adopt(_ roster: [Entry], into known: [String]) -> [String] {
        let have = Set(known.map { $0.lowercased() })
        let leftOut = removedHere
        var added: [String] = []
        for entry in roster where !have.contains(entry.email.lowercased()) && !leftOut.contains(entry.email.lowercased()) {
            MailAccounts.setProvider(entry.provider, for: entry.email)
            if let server = entry.server { IMAPServer.save(server, for: entry.email) }
            added.append(entry.email)
        }
        return added
    }
}
