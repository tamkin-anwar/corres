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
            case .drafts: "Drafts"
            case .sent: "Sent"
            case .archive: "Archive"
            case .spam: "Spam"
            case .trash: "Trash"
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
    private(set) var loading: Set<Source> = []
    private let client = MailClient()

    func items(_ source: Source) -> [Correspondence] { pages[source]?.items ?? [] }
    func hasLoaded(_ source: Source) -> Bool { pages[source]?.loadedOnce ?? false }
    func failed(_ source: Source) -> Bool { pages[source]?.failed ?? false }
    /// The server's draft for a conversation in Drafts, to continue it.
    func draftID(for id: ThreadID) -> String? { pages[.kind(.drafts)]?.drafts[id] }

    func refresh(_ source: Source, accounts: [String], store: MailStore) async {
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
        var merged = replacing ? [] : page.items
        let known = Set(merged.map(\.id))
        for item in fetched.sorted(by: { $0.receivedAt > $1.receivedAt }) where !known.contains(item.id) {
            merged.append(item)
        }
        // A failed refresh keeps what was on screen.
        if replacing && failed && fetched.isEmpty { merged = page.items }
        page.items = merged
        page.drafts.merge(drafts) { $1 }
        page.loadedOnce = true
        page.failed = failed && fetched.isEmpty
        pages[source] = page
    }

    /// Gone from view at once after an archive, delete or move.
    func remove(_ ids: Set<ThreadID>) {
        for source in pages.keys { pages[source]?.items.removeAll { ids.contains($0.id) } }
    }
}
