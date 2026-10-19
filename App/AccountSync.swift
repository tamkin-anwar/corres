import Foundation

/// Which accounts you have, kept with their sign-ins in iCloud Keychain, so
/// an account added on your iPhone is there on your Mac and iPad without
/// signing in again, the way Mail's iCloud accounts follow you. Only the
/// address, its service, and for other email its server names travel;
/// the sign-in itself is the Keychain entry next to it.
enum AccountSync {
    struct Entry: Codable, Equatable {
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

    static func roster() -> [Entry] {
        Keychain.getSynced(key: key).flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } ?? []
    }

    /// Accounts from your other devices that this one doesn't have yet,
    /// with what's needed to reach them recorded here first.
    static func adopt(into known: [String]) -> [String] {
        let have = Set(known.map { $0.lowercased() })
        var added: [String] = []
        for entry in roster() where !have.contains(entry.email.lowercased()) {
            MailAccounts.setProvider(entry.provider, for: entry.email)
            if let server = entry.server { IMAPServer.save(server, for: entry.email) }
            added.append(entry.email)
        }
        return added
    }
}
