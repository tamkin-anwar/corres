import Contacts
import Foundation
import Observation
import UIKit

/// Who Corres offers as you type a name: in To and Cc, and in search
/// ("Sara Wiltshire" as you type "sara"). A tester expected it, as Mail
/// and Gmail do it, and Corres used to know only who had written to you in
/// mail synced to this iPhone, so someone you write to all the time but
/// had archived never appeared.
///
/// Three sources, all your own mail, kept on this iPhone:
/// - synced mail (who writes to you, who you've written to),
/// - your recent Sent mail, read once per account (headers only), which
///   keeps names as you addressed them,
/// - Gmail itself, asked "from or to <name>" when what's typed matches
///   nobody known, so someone from years ago is still found,
/// - your iPhone Contacts, once you allow it (as Mail and Spark use them).
///
/// Any suggestion can be dismissed for good ("Don't Suggest"), the way
/// Mail's "Remove from Recents" works.
@MainActor @Observable
final class PeopleDirectory {
    /// Sent history and Gmail lookups; saved. Synced mail is added fresh.
    private var history = PeopleIndex()
    private var fromSynced = PeopleIndex()
    private var backfilled: Set<String> = []
    /// People you've said not to suggest.
    private var hidden: Set<String> = []
    private var contacts = PeopleIndex()
    /// Contacts photos by address, decoded once.
    private var photos: [String: UIImage] = [:]

    /// The person's Contacts photo, if you've allowed Contacts and they
    /// have one.
    func photo(for email: String) -> UIImage? { photos[email.lowercased()] }
    private var looked: Set<String> = []
    private(set) var isLookingUp = false
    private let client = GmailAPIClient()

    private static let sentHistoryLimit = 500
    private static var fileURL: URL {
        URL.applicationSupportDirectory.appending(path: "people.json")
    }

    private struct Saved: Codable {
        var history: PeopleIndex
        var backfilled: Set<String>
        var hidden: Set<String>
        /// Bumped when what's read from Sent mail changes, so it's read again.
        var version: Int?
    }
    /// 2: unsubscribe requests and bounce addresses aren't people.
    private static let version = 2

    init() {
        if let data = try? Data(contentsOf: Self.fileURL), let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            hidden = saved.hidden
            if saved.version == Self.version {
                history = saved.history
                backfilled = saved.backfilled
            }
        }
        Task { await loadContacts() }
    }

    private var index: PeopleIndex {
        var combined = history
        combined.merge(fromSynced)
        combined.merge(contacts)
        return combined
    }

    func suggestions(for query: String, excluding: Set<String> = [], limit: Int = 6) -> [Person] {
        index.suggestions(for: query, excluding: excluding.union(hidden),
                          favored: Set(contacts.people.keys), limit: limit)
    }

    /// Before anything is typed: who you're in touch with now.
    /// Your own names (as on your accounts), so another address of yours
    /// isn't offered as someone to write to.
    func top(excluding: Set<String> = [], ownNames: Set<String> = [], limit: Int = 6) -> [Person] {
        index.top(limit: limit, excluding: excluding.union(hidden), favored: Set(contacts.people.keys), ownNames: ownNames)
    }

    /// Everyone Compose would suggest, for the Share extension.
    func forSharing() -> (index: PeopleIndex, favored: Set<String>) {
        var shared = index
        shared.remove(hidden)
        return (shared, Set(contacts.people.keys))
    }

    /// "Don't Suggest": never offered again (until all accounts are removed).
    func hide(_ email: String) {
        hidden.insert(email.lowercased())
        save()
    }

    // MARK: Contacts

    /// Whether to offer "Include Contacts": never asked yet.
    var canAskForContacts: Bool { CNContactStore.authorizationStatus(for: .contacts) == .notDetermined }

    /// Asks once, when it helps (you typed a name Corres didn't know).
    func includeContacts() async {
        _ = try? await CNContactStore().requestAccess(for: .contacts)
        await loadContacts()
    }

    private func loadContacts() async {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        var allowed = status == .authorized
        if #available(iOS 18.0, *), status == .limited { allowed = true }
        guard allowed, CorresSettings.suggestContacts else {
            contacts = PeopleIndex()
            photos = [:]
            return
        }
        let found: [(String, String, UIImage?)] = await Task.detached(priority: .utility) {
            let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactOrganizationNameKey, CNContactEmailAddressesKey,
                        CNContactImageDataAvailableKey, CNContactThumbnailImageDataKey] as [CNKeyDescriptor]
            var found: [(String, String, UIImage?)] = []
            // Decoded here, off the main thread: hundreds of photos at
            // launch would otherwise stutter the first screen.
            var decoded: [Data: UIImage] = [:]
            try? CNContactStore().enumerateContacts(with: CNContactFetchRequest(keysToFetch: keys)) { contact, _ in
                let name = [contact.givenName, contact.familyName].filter { !$0.isEmpty }.joined(separator: " ")
                var photo: UIImage?
                if contact.imageDataAvailable, let data = contact.thumbnailImageData {
                    photo = decoded[data] ?? UIImage(data: data)?.preparingForDisplay()
                    decoded[data] = photo
                }
                for address in contact.emailAddresses {
                    found.append((name.isEmpty ? contact.organizationName : name, address.value as String, photo))
                }
            }
            return found
        }.value
        var index = PeopleIndex()
        var images: [String: UIImage] = [:]
        for (name, email, photo) in found {
            index.recordContact(name: name, email: email)
            if let photo { images[email.lowercased()] = photo }
        }
        contacts = index
        photos = images
    }

    /// Settings → Composing → Suggest from Contacts changed.
    func contactsSettingChanged() async { await loadContacts() }

    /// Rebuilds from synced mail. Cheap; call when mail changes.
    func update(from threads: [Correspondence], accounts: [String]) {
        fromSynced = PeopleIndex.from(threads, accounts: Set(accounts.map { $0.lowercased() }))
    }

    /// Reads each account's recent Sent mail once, for who you write to.
    func backfillIfNeeded(accounts: [String]) async {
        for account in accounts where !backfilled.contains(account) {
            guard let sent = try? await client.sentAddressing(account: account, limit: Self.sentHistoryLimit) else { continue }
            for message in sent {
                for recipient in message.recipients where PeopleIndex.parse(recipient)?.email != account.lowercased() {
                    history.recordSent(to: recipient, at: message.date, subject: message.subject)
                }
            }
            backfilled.insert(account)
            save()
        }
    }

    /// Asks Gmail for someone matching `query` when nobody known does.
    /// Once per query; quiet on failure (suggestions just stay as they are).
    func lookUp(_ query: String, accounts: [String]) async {
        let term = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard term.count >= 3, !accounts.isEmpty, !looked.contains(term),
              index.suggestions(for: term, limit: 1).isEmpty else { return }
        looked.insert(term)
        isLookingUp = true
        defer { isLookingUp = false }
        let mine = Set(accounts.map { $0.lowercased() })
        for account in accounts {
            guard let found = try? await client.addressing(matching: term, account: account) else { continue }
            for message in found {
                let sender = PeopleIndex.parse(message.from)
                if let sender, mine.contains(sender.email) {
                    for recipient in message.recipients where !mine.contains(PeopleIndex.parse(recipient)?.email ?? "") {
                        history.recordSent(to: recipient, at: message.date, subject: message.subject)
                    }
                } else if let sender {
                    history.recordReceived(from: sender.name, email: sender.email, at: message.date, isAutomated: false)
                }
            }
        }
        save()
    }

    /// Forgets everyone, when the last account is removed.
    func reset() {
        history = PeopleIndex()
        backfilled = []
        hidden = []
        looked = []
        save()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(Saved(history: history, backfilled: backfilled, hidden: hidden, version: Self.version)) else { return }
        try? FileManager.default.createDirectory(at: URL.applicationSupportDirectory, withIntermediateDirectories: true)
        try? data.write(to: Self.fileURL, options: [.atomic, .completeFileProtection])
    }
}
