import Foundation
import Observation

/// Every address each account can send as (Gmail → Settings → Accounts →
/// Send mail as), for Compose's From: someone with a studio, a support
/// alias and a personal address picks among all of them, and a reply goes
/// out from the address the email was sent to, as Gmail does. Read from
/// Gmail now and then, kept on this iPhone.
@MainActor @Observable
final class SendAsDirectory {
    static let shared = SendAsDirectory()

    private(set) var byAccount: [String: [GmailAPIClient.SendAs]] = [:]
    private let client = MailClient()
    private static let key = "corres.sendAs"
    private var refreshed: Set<String> = []

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode([String: [GmailAPIClient.SendAs]].self, from: data) {
            byAccount = saved
        }
    }

    /// Once per launch per account; quiet on failure (From just offers the
    /// account's own address).
    func refresh(accounts: [String]) async {
        for account in accounts where !refreshed.contains(account) {
            guard let found = try? await client.sendAs(account: account), !found.isEmpty else { continue }
            refreshed.insert(account)
            byAccount[account] = found
        }
        byAccount = byAccount.filter { accounts.contains($0.key) }
        UserDefaults.standard.set(try? JSONEncoder().encode(byAccount), forKey: Self.key)
        Self.publishOwnAddresses(accounts: accounts, aliases: allAddresses)
    }

    /// Tells the classifier every address that is you, so mail between
    /// your own accounts never lands in Needs You.
    static func publishOwnAddresses(accounts: [String], aliases: Set<String>) {
        InboxClassifier.ownAddresses = Set(accounts.map { $0.lowercased() }).union(aliases.map { $0.lowercased() })
    }

    /// The account's addresses, its own first, then the rest by address.
    func addresses(for account: String) -> [GmailAPIClient.SendAs] {
        let found = byAccount[account] ?? []
        let own = found.first { $0.isPrimary } ?? GmailAPIClient.SendAs(email: account.lowercased(), name: "", isDefault: found.isEmpty, isPrimary: true)
        return [own] + found.filter { !$0.isPrimary }.sorted { $0.email < $1.email }
    }

    /// Every address of every account: never someone to write to.
    var allAddresses: Set<String> { Set(byAccount.values.flatMap { $0.map(\.email) }) }

    /// The one Gmail sends new mail from by default.
    func defaultAddress(for account: String) -> GmailAPIClient.SendAs? {
        byAccount[account]?.first { $0.isDefault }
    }

    /// For a reply: the address of yours the email was sent to.
    func address(for account: String, answering thread: Correspondence) -> GmailAPIClient.SendAs? {
        let addressed = Set((thread.toRecipients + thread.ccRecipients).compactMap { PeopleIndex.parse($0)?.email ?? $0.lowercased() })
        return addresses(for: account).first { addressed.contains($0.email) }
    }
}
