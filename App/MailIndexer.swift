import Foundation
import os

/// Brings the rest of each mailbox onto the device after the first sync,
/// so the whole of your recent mail is here and Search finds it at once,
/// without going back to Gmail, Outlook or iCloud to look.
///
/// The first sync is deliberately shallow (the newest Inbox and Sent mail,
/// for a fast first screen). This continues from there in the
/// background: a page of 50 conversations at a time, metadata only (the
/// sender, subject, preview and labels, not bodies or attachments),
/// newest first, back a year or 5,000 conversations per mailbox, picking
/// up where it left off next time. Archived mail it brings is kept for
/// Search only (`Correspondence.isArchivedCopy`); older Inbox mail joins
/// the lists like any other.
@MainActor
final class MailIndexer {
    static let shared = MailIndexer()

    private let client = MailClient()
    private var running = false
    private let defaults = UserDefaults.standard
    private static let log = Logger(subsystem: "studio.anwarcreative.corres", category: "index")

    static let horizon: TimeInterval = 365 * 86_400
    static let maxPerMailbox = 5_000
    static let pageSize = 50
    /// Between pages, so the index never competes with what you're doing
    /// or runs into a provider's rate limit.
    static let pause: Duration = .milliseconds(600)

    /// What each kind of account is indexed from. Gmail's and Outlook's All
    /// Mail already includes the Inbox and Sent; an IMAP server's Archive
    /// doesn't, so its Inbox and Sent are walked as well.
    static func mailboxes(for account: String) -> [String?] {
        MailAccounts.provider(for: account).usesIMAP ? ["INBOX", nil, "SENT"] : [nil]
    }

    /// Indexes a page at a time until every account's mailboxes reach the
    /// horizon, or until `budget` pages have been read this run. Returns
    /// whether anything new was saved, for the caller to refresh the lists.
    @discardableResult
    func run(accounts: [String], repository: any MailRepository, budget: Int = 60,
             stillWanted: @escaping @MainActor (String) -> Bool = { _ in true }) async -> Bool {
        guard !running else { return false }
        running = true
        defer { running = false }
        // A page from each mailbox in turn, so every account fills in
        // together rather than the first one taking the whole run.
        var streams = accounts.filter { $0 != "sample" }.flatMap { account in
            Self.mailboxes(for: account).map { (account: account, mailbox: $0) }
        }.filter { !state($0.account, $0.mailbox).done }
        var pagesLeft = budget
        var anySaved = false
        while pagesLeft > 0, !streams.isEmpty, !Task.isCancelled {
            for stream in streams {
                guard pagesLeft > 0, !Task.isCancelled else { break }
                var state = state(stream.account, stream.mailbox)
                let page: (items: [Correspondence], nextPageToken: String?)
                do {
                    page = try await client.listMailbox(labelId: stream.mailbox, account: stream.account,
                                                        pageToken: state.pageToken, pageSize: Self.pageSize)
                } catch {
                    // Offline, signed out or rate-limited: this one waits
                    // for next time; the others carry on.
                    Self.log.info("Index paused for a mailbox: \(String(describing: error), privacy: .public)")
                    streams.removeAll { $0 == stream }
                    continue
                }
                pagesLeft -= 1
                // Removed while the page loaded: its mail mustn't come back.
                guard stillWanted(stream.account) else {
                    streams.removeAll { $0.account == stream.account }
                    continue
                }
                let inserted = (try? await repository.upsert(page.items, isInitialSync: true)) ?? 0
                anySaved = anySaved || inserted > 0
                state.count += page.items.count
                state.pageToken = page.nextPageToken
                // The newest on the page: Gmail lists roughly by date, and
                // one old message among new ones isn't the end of the year.
                let newest = page.items.map(\.receivedAt).max() ?? .distantPast
                // A first page with nothing on it may be a hiccup, not an
                // empty mailbox: asked again on the next two runs first.
                if page.items.isEmpty, state.count == 0, state.emptyTries < 2 {
                    state.emptyTries += 1
                    Self.log.info("Index found nothing in a mailbox; will look again")
                    save(state, stream.account, stream.mailbox)
                    streams.removeAll { $0 == stream }
                    continue
                }
                // An empty page with more after it isn't the end: Outlook
                // sends those with a filter on, and they only mean "keep going".
                state.done = page.nextPageToken == nil
                    || (!page.items.isEmpty && newest < Date.now.addingTimeInterval(-Self.horizon))
                    || state.count >= Self.maxPerMailbox
                save(state, stream.account, stream.mailbox)
                if state.done {
                    Self.log.info("Index finished a mailbox: \(page.items.count) on the last page, more: \(page.nextPageToken != nil), newest \(newest.formatted(.iso8601), privacy: .public), total \(state.count)")
                    streams.removeAll { $0 == stream }
                }
                try? await Task.sleep(for: Self.pause)
            }
        }
        return anySaved
    }

    /// How far each account has been indexed, for Settings: the date of the
    /// oldest mail reached, or nil when finished.
    func isComplete(_ account: String) -> Bool {
        Self.mailboxes(for: account).allSatisfy { state(account, $0).done }
    }

    /// Removing an account forgets its progress, so adding it back starts over.
    func forget(_ account: String) {
        for mailbox in Self.mailboxes(for: account) { defaults.removeObject(forKey: Self.key(account, mailbox)) }
    }

    // MARK: Progress

    private struct State: Codable {
        var pageToken: String?
        var count = 0
        var done = false
        var emptyTries = 0
    }

    private static func key(_ account: String, _ mailbox: String?) -> String {
        "corres.index5.\(account.lowercased()).\(mailbox ?? "ALL")"
    }

    private func state(_ account: String, _ mailbox: String?) -> State {
        defaults.data(forKey: Self.key(account, mailbox)).flatMap { try? JSONDecoder().decode(State.self, from: $0) } ?? State()
    }

    private func save(_ state: State, _ account: String, _ mailbox: String?) {
        defaults.set(try? JSONEncoder().encode(state), forKey: Self.key(account, mailbox))
    }
}
