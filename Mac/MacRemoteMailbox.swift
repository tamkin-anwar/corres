import SwiftUI

/// Sent, Drafts, Archive, Spam and Trash: mail that lives on the server
/// rather than in Corres's lists, fetched from every account as you open
/// it, newest first, and more as you scroll (as on the iPhone's Mailboxes).
@MainActor @Observable
final class MacRemoteMailboxes {
    enum Kind: String, CaseIterable, Codable {
        case drafts = "DRAFTS", sent = "SENT", archive = "ALL", spam = "SPAM", trash = "TRASH"

        var title: String {
            switch self {
            case .drafts: String(localized: "Drafts")
            case .sent: String(localized: "Sent")
            case .archive: String(localized: "Archive")
            case .spam: String(localized: "Spam")
            case .trash: String(localized: "Trash")
            }
        }

        var systemImage: String {
            switch self {
            case .drafts: "doc"
            case .sent: "paperplane"
            case .archive: "archivebox"
            case .spam: "xmark.bin"
            case .trash: "trash"
            }
        }

        /// The label Gmail lists it by; nil is All Mail (Archive).
        var labelId: String? { self == .archive ? nil : rawValue }
    }

    /// A built-in mailbox across every account, or one account's own
    /// label or folder.
    enum Source: Hashable {
        case kind(Kind)
        case label(account: String, id: String)

        var labelId: String? {
            switch self {
            case .kind(let kind): kind.labelId
            case .label(_, let id): id
            }
        }
    }

    private struct Page {
        var items: [Correspondence] = []
        var drafts: [ThreadID: String] = [:]
        var next: [String: String] = [:]
        var exhausted: Set<String> = []
        var loadedOnce = false
        var failed = false
    }

    private var pages: [Source: Page] = [:]
    /// Archived, deleted or moved from each mailbox, and when: left out of
    /// what a load in flight brings back, until a refresh that starts once
    /// the server has had the change (`settled`).
    @ObservationIgnored private var removed: [Source: [ThreadID: Date]] = [:]
    /// Undo's few seconds, and time for the server to take the change.
    private static let settled: TimeInterval = 30
    private(set) var loading: Set<Source> = []
    private let client = MailClient()

    func items(_ source: Source) -> [Correspondence] { pages[source]?.items ?? [] }
    func hasLoaded(_ source: Source) -> Bool { pages[source]?.loadedOnce ?? false }
    func failed(_ source: Source) -> Bool { pages[source]?.failed ?? false }
    /// The server's draft for a conversation in Drafts, to continue it.
    func draftID(for id: ThreadID) -> String? { pages[.kind(.drafts)]?.drafts[id] }

    func refresh(_ source: Source, accounts: [String], store: MailStore) async {
        removed[source] = removed[source]?.filter { Date.now.timeIntervalSince($0.value) < Self.settled }
        pages[source] = Page(items: pages[source]?.items ?? [])
        // Sample mail only: nothing on a server to fetch.
        if accounts.isEmpty { pages[source]?.loadedOnce = true; return }
        await loadMore(source, accounts: accounts, store: store, replacing: true)
    }

    func loadMore(_ source: Source, accounts: [String], store: MailStore, replacing: Bool = false) async {
        // A label lives in one account.
        let accounts = if case .label(let account, _) = source { [account] } else { accounts }
        guard !loading.contains(source), !accounts.isEmpty else { return }
        var page = pages[source] ?? Page()
        let pending = accounts.filter { !page.exhausted.contains($0) }
        guard !pending.isEmpty else { return }
        loading.insert(source)
        defer { loading.remove(source) }
        var fetched: [Correspondence] = []
        var drafts: [ThreadID: String] = [:]
        var failed = false
        let client = client
        if source == .kind(.drafts) {
            await withTaskGroup(of: (String, [(draftID: String, message: Correspondence)]?, String?).self) { group in
                for account in pending {
                    let token = page.next[account]
                    group.addTask {
                        guard let result = try? await client.listDrafts(account: account, pageToken: token, pageSize: 50) else {
                            return (account, nil, nil)
                        }
                        return (account, result.items, result.nextPageToken)
                    }
                }
                for await (account, items, next) in group {
                    guard let items else { failed = true; continue }
                    for item in items { fetched.append(item.message); drafts[item.message.id] = item.draftID }
                    if let next { page.next[account] = next } else { page.exhausted.insert(account) }
                }
            }
        } else {
            await withTaskGroup(of: (String, [Correspondence]?, String?).self) { group in
                for account in pending {
                    let token = page.next[account]
                    group.addTask {
                        guard let result = try? await client.listMailbox(labelId: source.labelId, account: account,
                                                                          pageToken: token, pageSize: 50) else {
                            return (account, nil, nil)
                        }
                        return (account, result.items, result.nextPageToken)
                    }
                }
                for await (account, items, next) in group {
                    guard let items else { failed = true; continue }
                    fetched += items
                    if let next { page.next[account] = next } else { page.exhausted.insert(account) }
                }
            }
        }
        store.keepBrowsed(fetched)
        // What's here now, not as it was when this load began: something
        // removed meanwhile stays gone.
        let gone = removed[source] ?? [:]
        var merged = replacing ? [] : (pages[source]?.items ?? page.items).filter { gone[$0.id] == nil }
        let known = Set(merged.map(\.id))
        for item in fetched.sorted(by: { $0.receivedAt > $1.receivedAt }) where !known.contains(item.id) && gone[item.id] == nil {
            merged.append(item)
        }
        // A failed refresh keeps what was on screen.
        if replacing && failed && fetched.isEmpty { merged = (pages[source]?.items ?? page.items).filter { gone[$0.id] == nil } }
        page.items = merged
        page.drafts.merge(drafts) { $1 }
        page.loadedOnce = true
        page.failed = failed && fetched.isEmpty
        pages[source] = page
    }

    /// A draft sent, scheduled or deleted from its compose window: gone
    /// from Drafts at once. It stayed listed until Drafts was opened
    /// again, there to be opened and sent a second time.
    func removeDraft(serverID: String) {
        let source = Source.kind(.drafts)
        guard let id = pages[source]?.drafts.first(where: { $0.value == serverID })?.key else { return }
        pages[source]?.items.removeAll { $0.id == id }
        removed[source, default: [:]][id] = .now
    }

    /// Gone from view at once after an archive, delete or move.
    func remove(_ ids: Set<ThreadID>) {
        let now = Date.now
        for source in pages.keys {
            // Noted only where it was: one moved to Trash still shows there.
            let here = ids.intersection(pages[source]?.items.map(\.id) ?? [])
            pages[source]?.items.removeAll { here.contains($0.id) }
            for id in here { removed[source, default: [:]][id] = now }
        }
    }
}
