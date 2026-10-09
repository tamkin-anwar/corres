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
enum Mailbox: Hashable, Identifiable {
    case drafts, snoozed, flagged, sent, allMail, spam, trash
    case label(id: String, name: String, account: String)

    var id: String {
        switch self {
        case let .label(id, _, account): "label|\(account)|\(id)"
        default: title
        }
    }

    var title: String {
        switch self {
        case .drafts: "Drafts"
        case .snoozed: "Snoozed"
        case .flagged: "Flagged"
        case .sent: "Sent"
        case .allMail: "All Mail"
        case .spam: "Spam"
        case .trash: "Trash"
        case let .label(_, name, _): name.components(separatedBy: "/").last ?? name
        }
    }

    var systemImage: String {
        switch self {
        case .drafts: "doc"
        case .snoozed: "clock"
        case .flagged: "flag"
        case .sent: "paperplane"
        case .allMail: "archivebox"
        case .spam: "xmark.bin"
        case .trash: "trash"
        case .label: "tag"
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
        case .allMail, .drafts, .snoozed: nil
        }
    }

    /// Mail here can go back to the Inbox from the list.
    var offersMoveToInbox: Bool { self != .drafts && self != .snoozed && self != .sent }

    var emptyMessage: String {
        switch self {
        case .drafts: "Drafts you start in Gmail show up here."
        case .snoozed: "Snoozed conversations wait here until they come back."
        case .flagged: "Flag a conversation to keep it here."
        case .spam: "No spam. Gmail empties Spam after 30 days."
        case .trash: "Trash is empty. Gmail empties it after 30 days."
        default: "Nothing here."
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

    private var snoozedCount: Int {
        let now = Date.now
        return store.threads.filter { accounts.contains($0.id.account) && $0.isSnoozed(at: now) }.count
    }

    var body: some View {
        List {
            Section {
                if !accounts.isEmpty { row(.drafts) }
                row(.snoozed, count: snoozedCount)
                if !accounts.isEmpty {
                    row(.flagged)
                    row(.sent)
                    row(.allMail)
                    row(.spam)
                    row(.trash)
                }
            } footer: {
                if accounts.isEmpty {
                    Text("Connect Gmail to see Drafts, Sent, All Mail, Spam, Trash and your labels.")
                }
            }
            ForEach(accounts, id: \.self) { account in
                let labels = labelDirectory.labels(for: account)
                    .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                if !labels.isEmpty {
                    Section(accounts.count > 1 ? account : "Labels") {
                        ForEach(labels) { label in
                            let depth = label.name.filter { $0 == "/" }.count
                            row(.label(id: label.id, name: label.name, account: account))
                                .padding(.leading, CGFloat(min(depth, 3)) * 18)
                        }
                    }
                }
            }
        }
        .navigationTitle("Mailboxes")
        .navigationBarTitleDisplayMode(.large)
        .scrollContentBackground(.hidden)
        .background(CorresPalette.canvas)
        .navigationDestination(for: Mailbox.self) { mailbox in
            if mailbox == .drafts {
                DraftsView(store: store, outbox: outbox, auth: auth, accounts: accounts)
            } else {
                MailboxView(mailbox: mailbox, store: store, threadActions: threadActions, accounts: accounts)
            }
        }
        .task { await labelDirectory.refreshIfConnected(accounts: accounts) }
    }

    private func row(_ mailbox: Mailbox, count: Int? = nil) -> some View {
        NavigationLink(value: mailbox) {
            LabeledContent {
                if let count, count > 0 { Text(count, format: .number).monospacedDigit() }
            } label: {
                Label(mailbox.title, systemImage: mailbox.systemImage)
            }
        }
        .listRowBackground(CorresPalette.surface)
    }
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
    private let client = GmailAPIClient()

    private var mailboxAccounts: [String] {
        if case let .label(_, _, account) = mailbox { return [account] }
        return accounts
    }

    private var rows: [Correspondence] {
        if mailbox == .snoozed {
            let now = Date.now
            return store.threads.filter { accounts.contains($0.id.account) && $0.isSnoozed(at: now) }
                .sorted { ($0.snoozedUntil ?? .distantFuture) < ($1.snoozedUntil ?? .distantFuture) }
        }
        return items.filter { !removed.contains($0.id) }.map { store.thread($0.id) ?? $0 }
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
            if rows.isEmpty && (loadedOnce || mailbox == .snoozed) && !isLoading {
                if loadFailed {
                    ContentUnavailableView {
                        Label("Couldn't load \(mailbox.title)", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text("Check your connection and try again.")
                    } actions: {
                        Button("Try Again") { Task { await reload() } }
                    }
                } else {
                    ContentUnavailableView(mailbox.title, systemImage: mailbox.systemImage,
                                           description: Text(mailbox.emptyMessage))
                }
            } else if rows.isEmpty && isLoading {
                ProgressView()
            }
        }
        .refreshable { if mailbox != .snoozed { await reload() } }
        .task { if !loadedOnce && mailbox != .snoozed { await loadMore() } }
    }

    @ViewBuilder
    private func content(_ rows: [Correspondence], orderedIDs: [ThreadID]) -> some View {
        ForEach(rows) { thread in
            NavigationLink(value: ConversationRoute(id: thread.id, orderedIDs: orderedIDs)) {
                CorrespondenceRow(thread: thread, accountTag: accounts.count > 1 ? String(thread.id.account.prefix(1)).uppercased() : nil,
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
        } else if mailbox.offersMoveToInbox && !thread.labelIds.contains("INBOX") {
            Button {
                Task {
                    await threadActions.moveToInbox(thread)
                    // Trash and Spam no longer hold it; the others still do.
                    if mailbox == .trash || mailbox == .spam { removed.insert(thread.id) }
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
                removed.insert(thread.id)
                Task { await threadActions.trash(thread) }
            } label: {
                Label("Trash", systemImage: "trash")
            }
        }
        if mailbox == .flagged {
            Button {
                removed.insert(thread.id)
                Task { await threadActions.setFlagged(false, for: thread) }
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
        let base = replacing ? [] : items
        let known = Set(base.map(\.id))
        // A conversation split across two pages shows once.
        var merged = base
        for item in fetched.sorted(by: { $0.receivedAt > $1.receivedAt }) where !known.contains(item.id) {
            if !merged.contains(where: { $0.id == item.id }) { merged.append(item) }
        }
        items = merged
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
    private let client = GmailAPIClient()

    var body: some View {
        List {
            ForEach(drafts, id: \.draftID) { item in
                Button { Task { await open(item) } } label: {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.message.toRecipients.isEmpty ? "No recipients" : "To: " + item.message.toRecipients.joined(separator: ", "))
                                .font(.body.weight(.medium)).foregroundStyle(CorresPalette.ink).lineLimit(1)
                            Text(item.message.subject.isEmpty ? "(no subject)" : item.message.subject)
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
                        Label("Couldn't load Drafts", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text("Check your connection and try again.")
                    } actions: {
                        Button("Try Again") { Task { await load() } }
                    }
                } else {
                    ContentUnavailableView("Drafts", systemImage: "doc", description: Text(Mailbox.drafts.emptyMessage))
                }
            } else if drafts.isEmpty && isLoading {
                ProgressView()
            }
        }
        .refreshable { await load() }
        .task { if !loadedOnce { await load() } }
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
        let message = item.message
        let account = message.id.account
        let conversation = (try? await client.fetchThreadMessages(threadId: message.id.providerID, account: account)) ?? []
        let answered = conversation.last { !$0.labelIds.contains("DRAFT") }
        var draft = Draft(kind: answered == nil ? .new : .reply, threadID: answered?.id, fromAccount: account,
                          to: message.toRecipients.joined(separator: ", "),
                          cc: message.ccRecipients.isEmpty ? nil : message.ccRecipients.joined(separator: ", "),
                          subject: message.subject == "(no subject)" ? "" : message.subject, body: message.body)
        draft.gmailDraftID = item.draftID
        replyingTo = answered
        composing = draft
    }
}
