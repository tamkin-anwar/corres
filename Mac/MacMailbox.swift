import SwiftUI

/// A place in the sidebar.
enum MacMailbox: Hashable, Codable {
    case needsYou, waiting, newSenders
    case filter(String)   // a MailFilter's raw value: Primary, Everything, Unread…
    case account(String)  // one account's inbox
    case flagged, snoozed, handled
    case server(String)   // a MacRemoteMailboxes.Kind: Sent, Drafts, Archive, Spam, Trash

    static let primary = MacMailbox.filter(MailFilter.primary.rawValue)

    var title: String {
        switch self {
        case .needsYou: "Needs You"
        case .waiting: "Waiting"
        case .newSenders: "New Senders"
        case .filter(let raw): raw
        case .account(let email): AccountPreferences.nickname(for: email)
        case .flagged: "Flagged"
        case .snoozed: "Snoozed"
        case .handled: "Handled"
        case .server(let raw): MacRemoteMailboxes.Kind(rawValue: raw)?.title ?? raw
        }
    }

    var remoteKind: MacRemoteMailboxes.Kind? {
        if case .server(let raw) = self { MacRemoteMailboxes.Kind(rawValue: raw) } else { nil }
    }

    var systemImage: String {
        switch self {
        case .needsYou: "exclamationmark.circle"
        case .waiting: "clock"
        case .newSenders: "person.crop.circle.badge.questionmark"
        case .filter(let raw):
            switch MailFilter(rawValue: raw) {
            case .primary: "tray"
            case .everything: "tray.2"
            case .unread: "envelope.badge"
            case .promotions: "tag"
            case .social: "person.2"
            case .updates: "bell"
            default: "tray"
            }
        case .account: "person.crop.circle"
        case .flagged: "flag"
        case .snoozed: "moon.zzz"
        case .handled: "checkmark.circle"
        case .server(let raw): MacRemoteMailboxes.Kind(rawValue: raw)?.systemImage ?? "tray"
        }
    }

    /// Lists whose rows say why each one is there.
    var showsReasons: Bool { self == .needsYou || self == .waiting }
    /// Sorted by what each conversation asks of you, so moving one takes it out.
    var isAttentionList: Bool { self == .needsYou || self == .waiting }
}

/// One line of the message list: a conversation, or a group's label.
enum MacRow: Hashable {
    case group(String)
    case thread(Correspondence)

    var thread: Correspondence? { if case .thread(let thread) = self { thread } else { nil } }
}

/// What the main window shows: the sidebar's choice, the search, the rows
/// that follow from them, and what's selected. Rows are built once per
/// change to the mail or the choice, never per redraw: a full mailbox is
/// thousands of conversations.
@MainActor @Observable
final class MacMailboxModel {
    var mailbox: MacMailbox = .needsYou {
        didSet {
            guard mailbox != oldValue else { return }
            UserDefaults.standard.set(try? JSONEncoder().encode(mailbox), forKey: Self.mailboxKey)
            selection = []
        }
    }
    var search = ""
    var selection: Set<ThreadID> = []

    private var cacheKey: CacheKey?
    private var cachedRows: [MacRow] = []
    private static let mailboxKey = "corres.mac.mailbox"

    private struct CacheKey: Equatable {
        let revision: Int
        let hidden: Set<ThreadID>
        let mailbox: MacMailbox
        let search: String
        let minute: Int
        let accounts: [String]
        let serverMatches: Set<ThreadID>
    }

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.mailboxKey),
           let saved = try? JSONDecoder().decode(MacMailbox.self, from: data) {
            mailbox = saved
        }
    }

    /// `serverMatches`: what the accounts' own search found for `search`.
    func rows(store: MailStore, accounts: [String], remote: MacRemoteMailboxes, serverMatches: Set<ThreadID> = []) -> [MacRow] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        // Mail on the server: as fetched, less anything just moved away.
        if query.isEmpty, let kind = mailbox.remoteKind {
            let hidden = store.hiddenIDs
            cachedRows = remote.items(kind).filter { !hidden.contains($0.id) }.map(MacRow.thread)
            cacheKey = nil
            return cachedRows
        }
        let key = CacheKey(revision: store.contentRevision, hidden: store.hiddenIDs, mailbox: mailbox, search: query,
                           minute: Int(Date.now.timeIntervalSince1970 / 60), accounts: accounts, serverMatches: serverMatches)
        if key == cacheKey { return cachedRows }
        cachedRows = build(store: store, query: query, accounts: accounts, serverMatches: serverMatches)
        cacheKey = key
        return cachedRows
    }

    var selectedThreads: [Correspondence] {
        cachedRows.compactMap(\.thread).filter { selection.contains($0.id) }
    }

    /// The conversation after (or, at the end, before) the selection, for
    /// selecting once the selection is archived or deleted, as Mail does.
    func neighbor(after ids: Set<ThreadID>) -> ThreadID? {
        let threads = cachedRows.compactMap(\.thread)
        guard let last = threads.lastIndex(where: { ids.contains($0.id) }) else { return nil }
        if let next = threads[(last + 1)...].first(where: { !ids.contains($0.id) }) { return next.id }
        return threads[..<last].last(where: { !ids.contains($0.id) })?.id
    }

    private func build(store: MailStore, query: String, accounts: [String], serverMatches: Set<ThreadID>) -> [MacRow] {
        let threads = store.threads
        // Searching looks through everything, in every list, as Mail does.
        if !query.isEmpty {
            return MailQuery.filter(store.searchableThreads, search: query, serverMatches: serverMatches).map(MacRow.thread)
        }
        switch mailbox {
        case .needsYou:
            let all = MailQuery.prioritized(threads, attention: .needsYou)
            let horizon = Date.now.addingTimeInterval(3 * 86_400)
            let soon = all.filter { ($0.dueAt ?? .distantFuture) <= horizon }
            guard !soon.isEmpty, soon.count < all.count else { return all.map(MacRow.thread) }
            let rest = all.filter { ($0.dueAt ?? .distantFuture) > horizon }
            return [.group("Due soon")] + soon.map(MacRow.thread) + [.group("When you can")] + rest.map(MacRow.thread)
        case .waiting:
            return MailQuery.prioritized(threads, attention: .waiting).map(MacRow.thread)
        case .newSenders:
            return store.pendingSenderThreads.sorted { $0.receivedAt > $1.receivedAt }.map(MacRow.thread)
        case .filter(let raw):
            let all = MailQuery.filter(threads)
            guard let filter = MailFilter(rawValue: raw), filter != .everything else { return all.map(MacRow.thread) }
            let context = CategoryContextCache.context(store)
            return all.filter { filter.includes($0, context: context) }.map(MacRow.thread)
        case .account(let email):
            let context = CategoryContextCache.context(store)
            return MailQuery.filter(threads).filter {
                $0.id.account == email && MailFilter.primary.includes($0, context: context)
            }.map(MacRow.thread)
        case .flagged:
            return MailQuery.filter(threads).filter(\.isFlagged).map(MacRow.thread)
        case .snoozed:
            return store.threadsIncludingHidden.filter { $0.isSnoozed(at: .now) }
                .sorted { ($0.snoozedUntil ?? .distantFuture) < ($1.snoozedUntil ?? .distantFuture) }.map(MacRow.thread)
        case .handled:
            return MailQuery.filter(threads).filter { $0.attention == .handled }.map(MacRow.thread)
        case .server:
            return []
        }
    }
}
