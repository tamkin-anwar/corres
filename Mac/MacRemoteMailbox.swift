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

    private struct Page {
        var items: [Correspondence] = []
        var drafts: [ThreadID: String] = [:]
        var next: [String: String] = [:]
        var exhausted: Set<String> = []
        var loadedOnce = false
        var failed = false
    }

    private var pages: [Kind: Page] = [:]
    private(set) var loading: Set<Kind> = []
    private let client = MailClient()

    func items(_ kind: Kind) -> [Correspondence] { pages[kind]?.items ?? [] }
    func hasLoaded(_ kind: Kind) -> Bool { pages[kind]?.loadedOnce ?? false }
    func failed(_ kind: Kind) -> Bool { pages[kind]?.failed ?? false }
    /// The server's draft for a conversation in Drafts, to continue it.
    func draftID(for id: ThreadID) -> String? { pages[.drafts]?.drafts[id] }

    func refresh(_ kind: Kind, accounts: [String], store: MailStore) async {
        pages[kind] = Page(items: pages[kind]?.items ?? [])
        // Sample mail only: nothing on a server to fetch.
        if accounts.isEmpty { pages[kind]?.loadedOnce = true; return }
        await loadMore(kind, accounts: accounts, store: store, replacing: true)
    }

    func loadMore(_ kind: Kind, accounts: [String], store: MailStore, replacing: Bool = false) async {
        guard !loading.contains(kind), !accounts.isEmpty else { return }
        var page = pages[kind] ?? Page()
        let pending = accounts.filter { !page.exhausted.contains($0) }
        guard !pending.isEmpty else { return }
        loading.insert(kind)
        defer { loading.remove(kind) }
        var fetched: [Correspondence] = []
        var drafts: [ThreadID: String] = [:]
        var failed = false
        let client = client
        if kind == .drafts {
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
                        guard let result = try? await client.listMailbox(labelId: kind.labelId, account: account,
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
        pages[kind] = page
    }

    /// Gone from view at once after an archive, delete or move.
    func remove(_ ids: Set<ThreadID>) {
        for kind in pages.keys { pages[kind]?.items.removeAll { ids.contains($0.id) } }
    }
}
