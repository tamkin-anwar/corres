import SwiftUI

/// A place in the sidebar.
enum MacMailbox: Hashable, Codable {
    case needsYou, waiting, newSenders
    case filter(String)   // a MailFilter's raw value: Primary, Everything, Unread…
    case account(String)  // one account's inbox
    case flagged, snoozed, handled, scheduled
    case server(String)   // a MacRemoteMailboxes.Kind: Sent, Drafts, Archive, Spam, Trash
    case label(account: String, id: String, name: String)  // one account's label or folder
    case purchases, attachments, muted
    case saved(String)    // a SavedSearch's id

    static let primary = MacMailbox.filter(MailFilter.primary.rawValue)

    @MainActor var title: String {
        switch self {
        case .needsYou: String(localized: "Needs You")
        case .waiting: String(localized: "Waiting")
        case .newSenders: String(localized: "New Senders")
        case .filter(let raw): MailFilter(rawValue: raw)?.title ?? raw
        case .account(let email): AccountPreferences.nickname(for: email)
        case .flagged: String(localized: "Flagged")
        case .snoozed: String(localized: "Snoozed")
        case .handled: String(localized: "Handled")
        case .scheduled: String(localized: "Send Later")
        case .server(let raw): MacRemoteMailboxes.Kind(rawValue: raw)?.title ?? raw
        case .label(_, _, let name): name
        case .purchases: String(localized: "Purchases")
        case .attachments: String(localized: "Attachments")
        case .muted: String(localized: "Muted")
        case .saved(let id): Organizer.shared.savedSearches.first { $0.id.uuidString == id }?.name ?? String(localized: "Saved Search")
        }
    }

    var remoteKind: MacRemoteMailboxes.Kind? {
        if case .server(let raw) = self { MacRemoteMailboxes.Kind(rawValue: raw) } else { nil }
    }

    /// Mail fetched from the server as you open it, not Corres's own lists.
    var remoteSource: MacRemoteMailboxes.Source? {
        switch self {
        case .server(let raw): MacRemoteMailboxes.Kind(rawValue: raw).map { .kind($0) }
        case .label(let account, let id, _): .label(account: account, id: id)
        default: nil
        }
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
        case .scheduled: "clock.arrow.circlepath"
        case .server(let raw): MacRemoteMailboxes.Kind(rawValue: raw)?.systemImage ?? "tray"
        case .label(_, let id, _): id.hasPrefix("folder:") ? "folder" : "tag"
        case .purchases: "bag"
        case .attachments: "paperclip"
        case .muted: "bell.slash"
        case .saved: "magnifyingglass"
        }
    }

    var isSavedSearch: Bool { if case .saved = self { true } else { false } }

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
    /// The conversation's id alone, without copying it out whole.
    var threadID: ThreadID? {
        switch self {
        case .group: nil
        case .thread(let thread): thread.id
        }
    }
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
    /// A Focus set to Show One Account (`CorresFocusFilter`): every list
    /// and search shows that account's mail only, as on the iPhone.
    var focusAccount: String?

    private var cacheKey: CacheKey?
    /// The rows as built, hidden conversations still in where they're
    /// left out after (`excluded`).
    @ObservationIgnored private var builtRows: [MacRow] = []
    /// What `cachedRows` leaves out of `builtRows`.
    @ObservationIgnored private var excluded: Set<ThreadID> = []
    /// Not compared when set: an observed array of rows was compared row
    /// by row, every conversation whole, each time the list changed.
    @ObservationIgnored private var cachedRows: [MacRow] = [] {
        didSet {
            rowsVersion &+= 1
            rowIndex = nil
        }
    }
    /// Bumped each time the rows are made again: what views watch, and
    /// what `visible` keys on.
    private var rowsVersion = 0
    /// Where each conversation is in `cachedRows`, made when first asked.
    @ObservationIgnored private var rowIndex: [ThreadID: Int]?
    @ObservationIgnored private var visibleKey: VisibleKey?
    @ObservationIgnored private var visibleCache = Visible()
    /// Finds a search's matches, away from the main thread in a large
    /// mailbox; `searchFound` changes when they arrive.
    @ObservationIgnored private let searcher = MailSearch()
    private var searchFound = 0
    private static let mailboxKey = "corres.mac.mailbox"

    private struct CacheKey: Equatable {
        let revision: Int
        /// Only for lists that can't leave hidden ones out after (search).
        let hidden: Set<ThreadID>
        let mailbox: MacMailbox
        let search: String
        let minute: Int
        let accounts: [String]
        let focusAccount: String?
        let serverMatches: Set<ThreadID>
        let searchFound: Int
    }

    /// The rows on screen, and how many conversations and unread ones
    /// they hold, for the window's subtitle.
    struct Visible {
        var rows: [MacRow] = []
        var count = 0
        var unread = 0
        /// Different each time the rows are made, for `MessageList`.
        var version = 0
    }
    @ObservationIgnored private var visibleVersion = 0

    private struct VisibleKey: Equatable {
        let version: Int
        let unreadOnly: Bool
        let kept: Set<ThreadID>
    }

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.mailboxKey),
           let saved = try? JSONDecoder().decode(MacMailbox.self, from: data) {
            // The Unread mailbox became Unread Only (⌘L), as on the iPhone.
            if saved == .filter(MailFilter.unread.rawValue) {
                mailbox = .filter(MailFilter.everything.rawValue)
                UserDefaults.standard.set(true, forKey: MailFilter.unreadOnlyKey)
            } else {
                mailbox = saved
            }
        }
    }

    /// `serverMatches`: what the accounts' own search found for `search`.
    func rows(store: MailStore, accounts: [String], remote: MacRemoteMailboxes, serverMatches: Set<ThreadID> = []) -> [MacRow] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        // Mail on the server: as fetched, less anything just moved away,
        // each as it is now (read, flagged), not as the page first had it,
        // so the dot changes and a toggle doesn't go the wrong way.
        if query.isEmpty, let source = mailbox.remoteSource {
            let hidden = store.hiddenIDs
            let rows = remote.items(source).filter { !hidden.contains($0.id) && inFocus($0) }.map { MacRow.thread(store.thread($0.id) ?? $0) }
            // A page from the server, so comparing is cheap; setting the
            // same rows again would redraw the list each time.
            if rows != cachedRows { cachedRows = rows }
            cacheKey = nil
            return cachedRows
        }
        // Built with hidden conversations in, and those left out after, so
        // Archive or Delete doesn't filter and sort the whole mailbox again.
        // Search (and a saved one) picks its top results from what's
        // shown, so it's built again.
        let leavesOutAfter = query.isEmpty && !mailbox.isSavedSearch
        let key = CacheKey(revision: store.contentRevision, hidden: leavesOutAfter ? [] : store.hiddenFromLists,
                           mailbox: mailbox, search: query, minute: Int(Date.now.timeIntervalSince1970 / 60),
                           accounts: accounts, focusAccount: focusAccount, serverMatches: serverMatches, searchFound: searchFound)
        // Snoozed lists every snoozed conversation, hidden ones included,
        // as it always has; only what's gone for good leaves it.
        let leaving = leavesOutAfter ? (mailbox == .snoozed ? store.removedIDs : store.hiddenFromLists) : []
        if key == cacheKey {
            if leaving != excluded {
                excluded = leaving
                cachedRows = ListExclusion.rows(builtRows, leaving: leaving, id: \.threadID, pairedHeadings: mailbox == .needsYou)
            }
            return cachedRows
        }
        // Still searching: the rows stay as they were until the matches arrive.
        guard let rows = build(store: store, query: query, accounts: accounts, serverMatches: serverMatches) else { return cachedRows }
        builtRows = rows
        excluded = leaving
        cachedRows = ListExclusion.rows(rows, leaving: leaving, id: \.threadID, pairedHeadings: mailbox == .needsYou)
        cacheKey = key
        return cachedRows
    }

    /// The rows less what Unread Only leaves out, which is never what's
    /// selected or was read with it on (`kept`), with their counts. Made
    /// once per change to the rows or the filter: a full mailbox is
    /// thousands of rows, and the selection changes with every arrow key.
    func visible(store: MailStore, accounts: [String], remote: MacRemoteMailboxes, serverMatches: Set<ThreadID>,
                 unreadOnly: Bool, kept: Set<ThreadID>) -> Visible {
        let rows = rows(store: store, accounts: accounts, remote: remote, serverMatches: serverMatches)
        let kept = unreadOnly ? kept.union(selection) : []
        let key = VisibleKey(version: rowsVersion, unreadOnly: unreadOnly, kept: kept)
        if key == visibleKey { return visibleCache }
        var shown = rows
        if unreadOnly {
            let unreadOrKept = rows.filter { row in
                guard let thread = row.thread else { return true }
                return thread.isUnread || kept.contains(thread.id)
            }
            // A heading ("Due soon") with nothing under it goes too.
            shown = unreadOrKept.enumerated().filter { index, row in
                row.threadID != nil || (index + 1 < unreadOrKept.count && unreadOrKept[index + 1].threadID != nil)
            }.map(\.element)
        }
        var count = 0, unread = 0
        for row in shown {
            guard case .thread(let thread) = row else { continue }
            count += 1
            if thread.isUnread { unread += 1 }
        }
        visibleVersion &+= 1
        visibleCache = Visible(rows: shown, count: count, unread: unread, version: visibleVersion)
        visibleKey = key
        return visibleCache
    }

    /// In list order. Looked up by id: going through every row copied each
    /// conversation out whole, on every redraw of the reading pane.
    var selectedThreads: [Correspondence] {
        guard !selection.isEmpty else { return [] }
        let index = rowIndex ?? makeRowIndex()
        return selection.compactMap { index[$0] }.sorted().compactMap { cachedRows[$0].thread }
    }

    private func makeRowIndex() -> [ThreadID: Int] {
        var index: [ThreadID: Int] = [:]
        index.reserveCapacity(cachedRows.count)
        for (position, row) in cachedRows.enumerated() {
            if let id = row.threadID, index[id] == nil { index[id] = position }
        }
        rowIndex = index
        return index
    }

    /// The selection's conversations, or, when they aren't in this list's
    /// rows (Purchases, Attachments, one opened from a notification or
    /// moved by a sync), from the store, so actions still reach them.
    func selectedThreads(in store: MailStore) -> [Correspondence] {
        let listed = selectedThreads
        return listed.isEmpty ? selection.compactMap { store.thread($0) } : listed
    }

    /// The conversation after (or, at the end, before) the selection, for
    /// selecting once the selection is archived or deleted, as Mail does.
    /// `rows`: the ones on screen (less what Unread Only hides), so a
    /// hidden conversation isn't the one chosen.
    func neighbor(after ids: Set<ThreadID>, in rows: [MacRow]? = nil) -> ThreadID? {
        // Ids only: copying every conversation out of its row took as long
        // as the Delete itself.
        let threads = (rows ?? cachedRows).compactMap(\.threadID)
        guard let last = threads.lastIndex(where: { ids.contains($0) }) else { return nil }
        if let next = threads[(last + 1)...].first(where: { !ids.contains($0) }) { return next }
        return threads[..<last].last(where: { !ids.contains($0) })
    }

    /// nil while a search's matches are still being found.
    private func build(store: MailStore, query: String, accounts: [String], serverMatches: Set<ThreadID>) -> [MacRow]? {
        // Hidden ones in: `rows` leaves them out after.
        let threads = focusAccount == nil ? store.listedIncludingHidden : store.listedIncludingHidden.filter(inFocus)
        // Searching looks through everything, in every list, as Mail does.
        if !query.isEmpty {
            guard let matches = searchMatches(query, store: store, serverMatches: serverMatches) else { return nil }
            // The best few first, as Mail's Top Results, then the rest.
            let top = searcher.topResults(matches)
            guard !top.isEmpty else { return matches.map(MacRow.thread) }
            let topIDs = Set(top.map(\.id))
            return [.group(String(localized: "Top Results"))] + top.map(MacRow.thread)
                + [.group(String(localized: "Everything Else"))] + matches.filter { !topIDs.contains($0.id) }.map(MacRow.thread)
        }
        switch mailbox {
        case .needsYou:
            let all = MailQuery.prioritized(threads, attention: .needsYou)
            let horizon = Date.now.addingTimeInterval(3 * 86_400)
            let soon = all.filter { ($0.dueAt ?? .distantFuture) <= horizon }
            guard !soon.isEmpty, soon.count < all.count else { return all.map(MacRow.thread) }
            let rest = all.filter { ($0.dueAt ?? .distantFuture) > horizon }
            return [.group(String(localized: "Due soon"))] + soon.map(MacRow.thread)
                + [.group(String(localized: "When you can"))] + rest.map(MacRow.thread)
        case .waiting:
            return MailQuery.prioritized(threads, attention: .waiting).map(MacRow.thread)
        case .newSenders:
            return threads.filter { $0.senderDecision == .pending }.sorted { $0.receivedAt > $1.receivedAt }.map(MacRow.thread)
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
        case .muted:
            return store.threadsIncludingHidden.filter { Organizer.shared.isMuted($0.id) }
                .sorted { $0.receivedAt > $1.receivedAt }.map(MacRow.thread)
        case .saved(let id):
            guard let saved = Organizer.shared.savedSearches.first(where: { $0.id.uuidString == id }) else { return [] }
            return searchMatches(saved.query, store: store)?.map(MacRow.thread)
        case .server, .label, .scheduled, .purchases, .attachments:
            return []
        }
    }

    /// In the account a Focus shows, or no Focus is limiting it.
    private func inFocus(_ thread: Correspondence) -> Bool {
        focusAccount.map { $0 == thread.id.account } ?? true
    }

    /// What `query` finds, or nil while that's still being worked out.
    /// Hidden ones (waiting out Undo) are left out after, so a swipe
    /// doesn't search again.
    private func searchMatches(_ query: String, store: MailStore, serverMatches: Set<ThreadID> = []) -> [Correspondence]? {
        let request = MailSearch.Request(search: query, serverMatches: serverMatches,
                                         source: [store.contentRevision, Int(Date.now.timeIntervalSince1970 / 60)])
        guard let found = searcher.matches(for: request, in: { store.threadsIncludingHidden },
                                           onFound: { [weak self] in self?.searchFound &+= 1 }) else { return nil }
        return ListExclusion.threads(found, leaving: store.hiddenFromLists).filter(inFocus)
    }
}

/// Conversations dragged from the list, as plain text so SwiftUI's drop
/// targets read them.
enum MacDrag {
    static let prefix = "corres-conversations:"

    static func encode(_ ids: Set<ThreadID>) -> String {
        prefix + ids.map { $0.account + "\u{1F}" + $0.providerID }.joined(separator: "\u{1E}")
    }

    static func decode(_ text: String) -> [ThreadID] {
        guard text.hasPrefix(prefix) else { return [] }
        return text.dropFirst(prefix.count).split(separator: "\u{1E}").compactMap { pair in
            let parts = pair.split(separator: "\u{1F}", maxSplits: 1)
            return parts.count == 2 ? ThreadID(account: String(parts[0]), providerID: String(parts[1])) : nil
        }
    }
}

extension MacMailbox {
    /// What dropping conversations here does, if anything.
    var acceptsDrop: Bool {
        switch self {
        case .needsYou, .waiting, .handled, .flagged, .label: true
        case .server(let raw): raw == MacRemoteMailboxes.Kind.archive.rawValue || raw == MacRemoteMailboxes.Kind.trash.rawValue
                || raw == MacRemoteMailboxes.Kind.spam.rawValue
        default: false
        }
    }
}
