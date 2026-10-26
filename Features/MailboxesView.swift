import SwiftUI

/// Everything beyond the Inbox: Drafts, Snoozed, Flagged, Sent, All Mail,
/// Spam, Trash and your Gmail labels, the way Mail's Mailboxes screen and
/// Gmail's menu offer them, so nothing means switching to another app to
/// check. A screen of its own, opened from Mail, rather than a drawer that
/// slides in from the edge: that edge is iOS's swipe back and the start of
/// a row's own swipe, and Apple's guidelines steer away from hidden
/// drawers. Only what Corres doesn't already do elsewhere: Gmail's
/// categories are Mail's People and Updates, and finding receipts or
/// purchases is a question for Ask.
/// Opens the Mailboxes screen. A value on the navigation path, like a
/// conversation, with every mailbox registered beside it in CorresShell:
/// opened as a plain view instead, Mailboxes sat outside the path SwiftUI
/// tracks, and nothing on it could open (every row did nothing).
struct MailboxesRoute: Hashable {}

enum Mailbox: Hashable, Identifiable {
    case drafts, snoozed, handled, flagged, sent, allMail, spam, trash
    case label(id: String, name: String, account: String)

    var id: String {
        switch self {
        case let .label(id, _, account): "label|\(account)|\(id)"
        default: title
        }
    }

    var title: String {
        switch self {
        case .drafts: String(localized: "Drafts")
        case .snoozed: String(localized: "Snoozed")
        case .handled: String(localized: "Handled")
        case .flagged: String(localized: "Flagged")
        case .sent: String(localized: "Sent")
        case .allMail: String(localized: "All Mail")
        case .spam: String(localized: "Spam")
        case .trash: String(localized: "Trash")
        case let .label(_, name, _): name.components(separatedBy: "/").last ?? name
        }
    }

    var systemImage: String {
        switch self {
        case .drafts: "doc"
        case .snoozed: "clock"
        case .handled: "checkmark.circle"
        case .flagged: "flag"
        case .sent: "paperplane"
        case .allMail: "archivebox"
        case .spam: "xmark.bin"
        case .trash: "trash"
        case .label(let id, _, _): id.hasPrefix("folder:") ? "folder" : "tag"
        }
    }

    /// The Gmail label the mailbox lists; nil is All Mail.
    var labelId: String? {
        switch self {
        case .flagged: "STARRED"
        case .sent: "SENT"
        case .spam: "SPAM"
        case .trash: "TRASH"
        case let .label(id, _, _): id
        case .allMail, .drafts, .snoozed, .handled: nil
        }
    }

    /// Mail here can go back to the Inbox from the list.
    var offersMoveToInbox: Bool { self != .drafts && !isLocal && self != .sent }

    /// Kept by Corres on this iPhone rather than fetched from Gmail.
    var isLocal: Bool { self == .snoozed || self == .handled }

    var emptyMessage: String {
        switch self {
        case .drafts: String(localized: "Drafts you start anywhere show up here.")
        case .snoozed: String(localized: "Snoozed conversations wait here until they come back.")
        case .handled: String(localized: "When you're done with something in Needs You or Waiting, mark it Handled. It leaves those lists, stays in Mail, and is kept here.")
        case .flagged: String(localized: "Flag a conversation to keep it here.")
        case .spam: String(localized: "No spam. Spam is emptied after 30 days.")
        case .trash: String(localized: "Trash is empty. It's emptied after 30 days.")
        default: String(localized: "Nothing here.")
        }
    }
}

struct MailboxesView: View {
    let store: MailStore
    let threadActions: ThreadActionService
    let labelDirectory: LabelDirectory
    let outbox: OutboxService
    let auth: GoogleAuthService
    /// Which accounts' mailboxes: one, or every connected account.
    let accounts: [String]
    /// Opens a conversation from Purchases or Attachments.
    var open: (ThreadID) -> Void = { _ in }

    /// Edit, as in Mail: tick what shows, drag to reorder. Stored as ids
    /// (`Mailbox.id`), so a new label appears at the end of its list,
    /// shown, until it's moved or hidden.
    @AppStorage(CorresSettings.mailboxOrderKey) private var orderRaw = ""
    @AppStorage(CorresSettings.mailboxHiddenKey) private var hiddenRaw = ""
    @State private var isEditing = false
    @State private var counts = Counts()

    private var order: [String] { orderRaw.isEmpty ? [] : orderRaw.components(separatedBy: "\n") }
    private var hidden: Set<String> { Set(hiddenRaw.isEmpty ? [] : hiddenRaw.components(separatedBy: "\n")) }

    /// Handled and Snoozed counted together, once per change to the mail
    /// (or minute, for snoozes that end), not twice per row on each redraw.
    private final class Counts {
        var key: String?
        var handled = 0
        var snoozed = 0
    }

    private var currentCounts: Counts {
        let counts = counts
        let key = "\(store.revision)|\(Int(Date.now.timeIntervalSince1970 / 60))|\(accounts.joined(separator: ","))"
        guard counts.key != key else { return counts }
        let now = Date.now
        var handled = 0, snoozed = 0
        for thread in store.threads where accounts.isEmpty || accounts.contains(thread.id.account) {
            if thread.attention == .handled { handled += 1 }
            if thread.isSnoozed(at: now) { snoozed += 1 }
        }
        counts.handled = handled
        counts.snoozed = snoozed
        counts.key = key
        return counts
    }

    private var handledCount: Int { currentCounts.handled }
    private var snoozedCount: Int { currentCounts.snoozed }

    /// The built-in mailboxes there are to show: Gmail's only with Gmail.
    private var builtIns: [Mailbox] {
        accounts.isEmpty ? [.snoozed, .handled] : [.drafts, .snoozed, .handled, .flagged, .sent, .allMail, .spam, .trash]
    }

    private func labels(for account: String) -> [Mailbox] {
        // Outlook's folders before its categories; within each, by name.
        labelDirectory.labels(for: account)
            .sorted { ($0.isFolder ? 0 : 1, $0.name.lowercased()) < ($1.isFolder ? 0 : 1, $1.name.lowercased()) }
            .map { .label(id: $0.id, name: $0.name, account: account) }
    }

    /// In the saved order; anything not placed yet keeps its usual place
    /// at the end.
    private func arranged(_ mailboxes: [Mailbox]) -> [Mailbox] {
        let position = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return mailboxes.enumerated().sorted { lhs, rhs in
            let a = position[lhs.element.id], b = position[rhs.element.id]
            switch (a, b) {
            case let (a?, b?): return a < b
            case (.some, nil): return true
            case (nil, .some): return false
            default: return lhs.offset < rhs.offset
            }
        }.map(\.element)
    }

    var body: some View {
        List {
            // What's waiting to go (Send Later), only while there is some.
            if !ScheduledSends.shared.items.isEmpty, !isEditing {
                Section {
                    NavigationLink {
                        ScheduledView(store: store, outbox: outbox, auth: auth)
                    } label: {
                        LabeledContent {
                            Text(ScheduledSends.shared.items.count, format: .number).monospacedDigit()
                        } label: {
                            Label("Send Later", systemImage: "clock.arrow.circlepath")
                        }
                    }
                    .listRowBackground(CorresPalette.surface)
                }
            }
            section(arranged(builtIns), header: nil)
            if !isEditing { organizeSection }
            if accounts.isEmpty {
                Section {} footer: {
                    Text("Connect an account to see Drafts, Sent, All Mail, Spam, Trash and your labels.")
                }
            }
            ForEach(accounts, id: \.self) { account in
                let labels = arranged(labels(for: account))
                if !labels.isEmpty {
                    section(labels, header: accounts.count > 1 ? account : "Labels")
                }
            }
        }
        .environment(\.editMode, .constant(isEditing ? .active : .inactive))
        .navigationTitle("Mailboxes")
        .navigationBarTitleDisplayMode(.large)
        .scrollContentBackground(.hidden)
        .background(CorresPalette.canvas)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(isEditing ? "Done" : "Edit") {
                    withAnimation(.snappy(duration: 0.25)) { isEditing.toggle() }
                }
                .fontWeight(isEditing ? .semibold : .regular)
            }
        }
        .task { await labelDirectory.refreshIfConnected(accounts: accounts) }
    }

    /// Corres's own views across every account: purchases, files, what
    /// you muted, and the searches you saved.
    @ViewBuilder
    private var organizeSection: some View {
        let organizer = Organizer.shared
        Section {
            NavigationLink {
                PurchasesView(store: store, accounts: accounts, open: open)
            } label: { Label("Purchases", systemImage: "bag") }
            .listRowBackground(CorresPalette.surface)
            NavigationLink {
                AttachmentsView(store: store, accounts: accounts, open: open)
            } label: { Label("Attachments", systemImage: "paperclip") }
            .listRowBackground(CorresPalette.surface)
            if !organizer.muted.isEmpty {
                NavigationLink {
                    MutedView(store: store, accounts: accounts)
                } label: {
                    LabeledContent {
                        Text(organizer.muted.count, format: .number).monospacedDigit()
                    } label: { Label("Muted", systemImage: "bell.slash") }
                }
                .listRowBackground(CorresPalette.surface)
            }
        }
        if !organizer.savedSearches.isEmpty {
            Section("Saved Searches") {
                ForEach(organizer.savedSearches) { search in
                    NavigationLink {
                        SavedSearchView(search: search, store: store, accounts: accounts)
                    } label: { Label(search.name, systemImage: "magnifyingglass") }
                    .listRowBackground(CorresPalette.surface)
                }
                .onMove { organizer.moveSearches(from: $0, to: $1) }
            }
        }
    }

    @ViewBuilder
    private func section(_ mailboxes: [Mailbox], header: String?) -> some View {
        // Editing shows everything, hidden ones unticked; otherwise only
        // what's ticked.
        let shown = isEditing ? mailboxes : mailboxes.filter { !hidden.contains($0.id) }
        if !shown.isEmpty {
            Section {
                ForEach(shown) { mailbox in
                    if isEditing { editRow(mailbox) } else { row(mailbox) }
                }
                .onMove { from, to in move(within: mailboxes, from: from, to: to) }
            } header: {
                if let header { Text(header) }
            }
        }
    }

    private func row(_ mailbox: Mailbox) -> some View {
        NavigationLink(value: mailbox) {
            LabeledContent {
                if mailbox == .snoozed, snoozedCount > 0 { Text(snoozedCount, format: .number).monospacedDigit() }
                if mailbox == .handled, handledCount > 0 { Text(handledCount, format: .number).monospacedDigit() }
            } label: {
                Label(mailbox.title, systemImage: mailbox.systemImage)
            }
        }
        .padding(.leading, indent(of: mailbox))
        .listRowBackground(CorresPalette.surface)
    }

    private func editRow(_ mailbox: Mailbox) -> some View {
        let isShown = !hidden.contains(mailbox.id)
        return Button {
            var set = hidden
            if isShown { set.insert(mailbox.id) } else { set.remove(mailbox.id) }
            hiddenRaw = set.sorted().joined(separator: "\n")
        } label: {
            HStack(spacing: 12) {
                Image(systemName: isShown ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isShown ? CorresPalette.accent : CorresPalette.tertiary)
                Label(mailbox.title, systemImage: mailbox.systemImage)
                    .foregroundStyle(isShown ? CorresPalette.ink : CorresPalette.secondary)
                    .padding(.leading, indent(of: mailbox))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(CorresPalette.surface)
        .accessibilityValue(isShown ? "Shown" : "Hidden")
        .accessibilityHint(isShown ? "Hides this mailbox" : "Shows this mailbox")
    }

    /// Labels inside labels ("Unroll.me/Unsubscribed") sit indented.
    private func indent(of mailbox: Mailbox) -> CGFloat {
        guard case let .label(_, name, _) = mailbox else { return 0 }
        return CGFloat(min(name.filter { $0 == "/" }.count, 3)) * 18
    }

    /// Reorders one section and saves it, keeping every other section's
    /// saved order as it was.
    private func move(within mailboxes: [Mailbox], from: IndexSet, to: Int) {
        var ids = mailboxes.map(\.id)
        ids.move(fromOffsets: from, toOffset: to)
        let others = order.filter { !ids.contains($0) }
        orderRaw = (others + ids).joined(separator: "\n")
    }
}

/// Each mailbox as it was last seen this session, so opening it again shows
/// it at once (as Mail and Gmail do) while it refreshes behind.
@MainActor
private enum MailboxPageCache {
    struct Page {
        var items: [Correspondence]
        var nextPages: [String: String]
        var exhausted: Set<String>
    }
    static var pages: [String: Page] = [:]
    static func key(_ mailbox: Mailbox, _ accounts: [String]) -> String { "\(mailbox.id)|\(accounts.joined(separator: ","))" }
}

/// One mailbox's conversations, newest first, fetched from Gmail a page at
/// a time as you scroll. Opening one reads it like any other; it's kept
/// in memory only (`MailStore.keepBrowsed`), so Trash and Spam never leak
/// into Mail or Needs You.
struct MailboxView: View {
    let mailbox: Mailbox
    let store: MailStore
    let threadActions: ThreadActionService
    let accounts: [String]
    @State private var items: [Correspondence] = []
    @State private var nextPages: [String: String] = [:]
    @State private var exhausted: Set<String> = []
    @State private var isLoading = false
    @State private var loadFailed = false
    @State private var loadedOnce = false
    @State private var removed: Set<ThreadID> = []
    @Environment(\.conversationSelection) private var splitSelection
    private let client = MailClient()

    private var mailboxAccounts: [String] {
        if case let .label(_, _, account) = mailbox { return [account] }
        return accounts
    }

    private var cacheKey: String { MailboxPageCache.key(mailbox, mailboxAccounts) }

    /// Synced mail that belongs here (Sent, Flagged, a label or folder, All
    /// Mail), newest first: what can show before the service answers.
    /// Never for Spam or Trash, which Corres doesn't keep.
    private var localMatches: [Correspondence] {
        guard mailbox != .spam, mailbox != .trash else { return [] }
        let accounts = Set(mailboxAccounts)
        let label = mailbox.labelId
        return Array(store.threads
            .filter { accounts.contains($0.id.account) && (label.map($0.labelIds.contains) ?? true) }
            .sorted { $0.receivedAt > $1.receivedAt }
            .prefix(40))
    }

    /// Snoozed and Handled, kept until the mail changes (or a minute
    /// passes, for snoozes that end), so selecting or loading doesn't go
    /// through the whole mailbox again.
    private final class LocalRows {
        var key: String?
        var rows: [Correspondence] = []
    }
    @State private var localRows = LocalRows()

    private var rows: [Correspondence] {
        if mailbox == .snoozed || mailbox == .handled {
            let cache = localRows
            let key = "\(store.revision)|\(Int(Date.now.timeIntervalSince1970 / 60))|\(mailbox.id)|\(accounts.joined(separator: ","))"
            if cache.key == key { return cache.rows }
            if mailbox == .snoozed {
                let now = Date.now
                cache.rows = store.threads.filter { (accounts.isEmpty || accounts.contains($0.id.account)) && $0.isSnoozed(at: now) }
                    .sorted { ($0.snoozedUntil ?? .distantFuture) < ($1.snoozedUntil ?? .distantFuture) }
            } else {
                cache.rows = store.threads.filter { (accounts.isEmpty || accounts.contains($0.id.account)) && $0.attention == .handled }
                    .sorted { $0.receivedAt > $1.receivedAt }
            }
            cache.key = key
            return cache.rows
        }
        // Trashed here: out of sight while Undo is offered (the store hides
        // it), back if you undo, gone once it's done (the store lets it go).
        return items.filter { !removed.contains($0.id) && !store.hiddenIDs.contains($0.id) }.compactMap { store.thread($0.id) }
    }

    var body: some View {
        let rows = rows
        let orderedIDs = rows.map(\.id)
        Group {
            if let splitSelection {
                List(selection: splitSelection) { content(rows, orderedIDs: orderedIDs) }
            } else {
                List { content(rows, orderedIDs: orderedIDs) }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(CorresPalette.canvas)
        .navigationTitle(mailbox.title)
        .navigationBarTitleDisplayMode(.large)
        .overlay {
            if rows.isEmpty && (loadedOnce || mailbox.isLocal) && !isLoading {
                if loadFailed {
                    ContentUnavailableView {
                        EmptyTitle("Couldn't load \(mailbox.title)", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text("Check your connection and try again.")
                    } actions: {
                        Button("Try Again") { Task { await reload() } }
                    }
                } else {
                    ContentUnavailableView {
                        EmptyTitle(mailbox.title, systemImage: mailbox.systemImage)
                    } description: {
                        Text(mailbox.emptyMessage)
                    }
                }
            } else if rows.isEmpty && isLoading {
                ProgressView()
            }
        }
        .refreshable { if !mailbox.isLocal { await reload() } }
        .task {
            guard !loadedOnce && !mailbox.isLocal else { return }
            // Something on screen at once: this mailbox as last seen, or
            // the mail already on this iPhone that belongs in it. Then the
            // real list from the service replaces it.
            if let cached = MailboxPageCache.pages[cacheKey] {
                items = cached.items
                loadedOnce = true
                await reload()
            } else {
                items = localMatches
                await loadMore(replacing: true)
            }
        }
    }

    @ViewBuilder
    private func content(_ rows: [Correspondence], orderedIDs: [ThreadID]) -> some View {
        ForEach(rows) { thread in
            NavigationLink(value: ConversationRoute(id: thread.id, orderedIDs: orderedIDs)) {
                CorrespondenceRow(thread: thread, accountTag: accounts.count > 1 ? AccountTag.make(for: thread.id.account, among: accounts) : nil,
                                  sentTo: mailbox == .sent ? recipient(of: thread) : nil)
            }
            .hidingDisclosureIndicator()
            .listRowInsets(EdgeInsets())
            .listRowBackground(splitSelection?.wrappedValue?.id == thread.id ? CorresPalette.accent.opacity(0.12) : Color.clear)
            .listRowSeparatorTint(CorresPalette.line)
            .swipeActions(edge: .leading, allowsFullSwipe: true) { leadingActions(for: thread) }
            .swipeActions(edge: .trailing, allowsFullSwipe: true) { trailingActions(for: thread) }
            .contextMenu {
                leadingActions(for: thread)
                trailingActions(for: thread)
            }
            .onAppear {
                if thread.id == rows.last?.id { Task { await loadMore() } }
            }
        }
        if isLoading && !rows.isEmpty {
            ProgressView().frame(maxWidth: .infinity).padding().listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
        }
    }

    @ViewBuilder
    private func leadingActions(for thread: Correspondence) -> some View {
        if mailbox == .snoozed {
            Button { Task { await store.snooze(thread.id, until: nil) } } label: {
                Label("Unsnooze", systemImage: "clock.arrow.circlepath")
            }
            .tint(CorresPalette.accent)
        } else if mailbox == .handled {
            // Not done after all: back where it asks for you.
            Button { Task { await threadActions.setAttention(.needsYou, for: thread) } } label: {
                Label("Needs You", systemImage: "exclamationmark.circle")
            }
            .tint(CorresPalette.accent)
            Button { Task { await threadActions.setAttention(.waiting, for: thread) } } label: {
                Label("Waiting", systemImage: "clock")
            }
            .tint(CorresPalette.swipeUnread)
        } else if mailbox.offersMoveToInbox && !thread.labelIds.contains("INBOX") {
            Button {
                Task {
                    // Trash and Spam no longer hold it; the others still do.
                    // Only once the server agreed: a failed Restore keeps the row.
                    if await threadActions.moveToInbox(thread), mailbox == .trash || mailbox == .spam {
                        removed.insert(thread.id)
                    }
                }
            } label: {
                Label(mailbox == .spam ? "Not Spam" : mailbox == .trash ? "Restore" : "Move to Inbox",
                      systemImage: "tray.and.arrow.down")
            }
            .tint(CorresPalette.accent)
        }
    }

    @ViewBuilder
    private func trailingActions(for thread: Correspondence) -> some View {
        if mailbox != .trash {
            Button(role: .destructive) {
                Task { await threadActions.trash(thread) }
            } label: {
                Label("Trash", systemImage: "trash")
            }
        }
        if mailbox == .flagged {
            Button {
                removed.insert(thread.id)
                // Back in the list if the server refused it.
                Task { if !(await threadActions.setFlagged(false, for: thread)) { removed.remove(thread.id) } }
            } label: {
                Label("Unflag", systemImage: "flag.slash")
            }
            .tint(CorresPalette.flag)
        }
    }

    private func recipient(of thread: Correspondence) -> String? {
        guard let first = thread.toRecipients.first else { return nil }
        let name = first.components(separatedBy: "<").first?.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "\"")))
        return (name?.isEmpty == false ? name : first) ?? first
    }

    private func reload() async {
        nextPages = [:]
        exhausted = []
        removed = []
        await loadMore(replacing: true)
    }

    /// The next page from each account, merged newest first.
    private func loadMore(replacing: Bool = false) async {
        guard !isLoading else { return }
        let pending = mailboxAccounts.filter { !exhausted.contains($0) }
        guard !pending.isEmpty else { return }
        isLoading = true
        defer { isLoading = false; loadedOnce = true }
        var fetched: [Correspondence] = []
        var failed = false
        let client = client, labelId = mailbox.labelId
        await withTaskGroup(of: (String, [Correspondence]?, String?).self) { group in
            for account in pending {
                let token = nextPages[account]
                group.addTask {
                    guard let page = try? await client.listMailbox(labelId: labelId, account: account, pageToken: token)
                    else { return (account, nil, nil) }
                    return (account, page.items, page.nextPageToken)
                }
            }
            for await (account, page, next) in group {
                guard let page else { failed = true; continue }
                fetched += page
                if let next { nextPages[account] = next } else { exhausted.insert(account) }
            }
        }
        loadFailed = failed && fetched.isEmpty
        store.keepBrowsed(fetched)
        // A failed refresh keeps what's on screen rather than emptying it.
        if replacing && failed && fetched.isEmpty { return }
        let base = replacing ? [] : items
        let known = Set(base.map(\.id))
        // A conversation split across two pages shows once.
        var merged = base
        for item in fetched.sorted(by: { $0.receivedAt > $1.receivedAt }) where !known.contains(item.id) {
            if !merged.contains(where: { $0.id == item.id }) { merged.append(item) }
        }
        items = merged
        MailboxPageCache.pages[cacheKey] = .init(items: merged, nextPages: nextPages, exhausted: exhausted)
    }
}

/// Drafts from Gmail (started on the web or in another app). Opening one
/// continues it in Compose, as a reply in its conversation when it is one;
/// once it's sent, the Gmail draft is deleted (`Draft.gmailDraftID`).
struct DraftsView: View {
    let store: MailStore
    let outbox: OutboxService
    let auth: GoogleAuthService
    let accounts: [String]
    @State private var drafts: [(draftID: String, message: Correspondence)] = []
    @State private var isLoading = false
    @State private var loadedOnce = false
    @State private var loadFailed = false
    @State private var opening: String?
    @State private var composing: Draft?
    @State private var replyingTo: Correspondence?
    @State private var openFailed = false
    private let client = MailClient()

    var body: some View {
        List {
            ForEach(drafts, id: \.draftID) { item in
                Button { Task { await open(item) } } label: {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.message.toRecipients.isEmpty ? String(localized: "No recipients")
                                 : String(localized: "To: \(item.message.toRecipients.joined(separator: ", "))"))
                                .font(.body.weight(.medium)).foregroundStyle(CorresPalette.ink).lineLimit(1)
                            Text(item.message.subject.isEmpty ? String(localized: "(no subject)") : item.message.subject)
                                .font(.subheadline).foregroundStyle(CorresPalette.ink).lineLimit(1)
                            Text(item.message.excerpt).font(.subheadline).foregroundStyle(CorresPalette.secondary).lineLimit(2)
                        }
                        Spacer(minLength: 8)
                        if opening == item.draftID {
                            ProgressView()
                        } else {
                            Text(CorrespondenceRow.timestamp(item.message.receivedAt))
                                .font(.caption).monospacedDigit().foregroundStyle(CorresPalette.tertiary)
                        }
                    }
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(opening != nil)
                .listRowBackground(Color.clear)
                .listRowSeparatorTint(CorresPalette.line)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(CorresPalette.canvas)
        .navigationTitle("Drafts")
        .navigationBarTitleDisplayMode(.large)
        .overlay {
            if drafts.isEmpty && loadedOnce && !isLoading {
                if loadFailed {
                    ContentUnavailableView {
                        EmptyTitle("Couldn't load Drafts", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text("Check your connection and try again.")
                    } actions: {
                        Button("Try Again") { Task { await load() } }
                    }
                } else {
                    ContentUnavailableView {
                        EmptyTitle("Drafts", systemImage: "doc")
                    } description: {
                        Text(Mailbox.drafts.emptyMessage)
                    }
                }
            } else if drafts.isEmpty && isLoading {
                ProgressView()
            }
        }
        .refreshable { await load() }
        .task { if !loadedOnce { await load() } }
        .alert("Couldn't Open Draft", isPresented: $openFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Check your connection and try again.")
        }
        .sheet(item: $composing, onDismiss: { Task { await load() } }) { draft in
            ComposeView(store: store, outbox: outbox, auth: auth, draft: draft, sourceThread: replyingTo)
        }
    }

    private func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false; loadedOnce = true }
        var found: [(draftID: String, message: Correspondence)] = []
        var failed = false
        let client = client
        await withTaskGroup(of: [(draftID: String, message: Correspondence)]?.self) { group in
            for account in accounts {
                group.addTask { try? await client.listDrafts(account: account, pageToken: nil, pageSize: 50).items }
            }
            for await page in group {
                if let page { found += page } else { failed = true }
            }
        }
        loadFailed = failed && found.isEmpty
        drafts = found.sorted { $0.message.receivedAt > $1.message.receivedAt }
    }

    /// Continues a draft in Compose. A reply keeps its conversation: the
    /// message it answers is found so it sends threaded, like any reply.
    private func open(_ item: (draftID: String, message: Correspondence)) async {
        opening = item.draftID
        defer { opening = nil }
        var message = item.message
        let account = message.id.account
        // Outlook and IMAP list drafts with a preview only (Gmail's come
        // whole): fetch the full text, or saving would replace the draft
        // with its first line.
        if MailAccounts.provider(for: account) != .google, let messageID = message.latestMessageID {
            guard let full = try? await client.fetchFull(ids: [messageID], account: account).items.first else {
                openFailed = true
                return
            }
            message = full
        }
        // Without its conversation, a reply draft would go out as a new,
        // unthreaded email: say so rather than open it wrong.
        guard let conversation = try? await client.fetchThreadMessages(threadId: message.id.providerID, account: account) else {
            openFailed = true
            return
        }
        let answered = conversation.last { !$0.labelIds.contains("DRAFT") }
        var draft = Draft(kind: answered == nil ? .new : .reply, threadID: answered?.id, fromAccount: account,
                          to: message.toRecipients.joined(separator: ", "),
                          cc: message.ccRecipients.isEmpty ? nil : message.ccRecipients.joined(separator: ", "),
                          subject: [String(localized: "(no subject)"), "(no subject)"].contains(message.subject) ? "" : message.subject, body: message.body)
        draft.gmailDraftID = item.draftID
        replyingTo = answered
        composing = draft
    }
}
