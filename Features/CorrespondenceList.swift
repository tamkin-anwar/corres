import SwiftUI

/// Which account an email in All Inboxes came from: the account's name,
/// and its colour when colour coding is on (Settings → the account).
struct AccountTag: Hashable {
    let text: String
    let color: Color?

    @MainActor static func make(for account: String, among accounts: [String]) -> AccountTag {
        AccountTag(text: AccountPreferences.tag(for: account, among: accounts),
                   color: AccountPreferences.color(for: account, among: accounts))
    }
}

/// A flat, dense row in the Mail/Spark list anatomy: unread dot, a round
/// monogram, sender and time, subject, a one-line preview, and, in the
/// curated lists, the one-line reason it's there.
struct CorrespondenceRow: View {
    let thread: Correspondence
    /// The "why this is here" line; shown in Needs You, Waiting, and the Brief.
    var showsReason = false
    /// A short account marker, shown only in the merged view of several accounts.
    var accountTag: AccountTag?
    /// In Sent: who you wrote to, shown in place of the sender, with the
    /// time you sent it.
    var sentTo: String?
    @Environment(\.dynamicTypeSize) private var typeSize
    @AppStorage(CorresSettings.previewLinesKey) private var previewLines = 2
    @AppStorage(CorresSettings.showAvatarsKey) private var showAvatars = true
    @AppStorage(CorresSettings.summaryInListKey) private var summaryInList = false
    @AppStorage(CorresSettings.summariesKey) private var summariesOn = true
    @Environment(\.proUnlocked) private var proUnlocked
    @Environment(MailIntelligence.self) private var intelligence: MailIntelligence?

    /// Settings → Lists → Summaries as preview: the summary once there is
    /// one, the email's opening words until then.
    private var summaryPreview: String? {
        guard summaryInList, summariesOn, proUnlocked else { return nil }
        return intelligence?.insight(for: thread)?.summary
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(thread.isUnread ? CorresPalette.accent : .clear)
                .frame(width: 7, height: 7)
                .padding(.top, 17)
                .accessibilityHidden(true)
            if showAvatars { CorrespondentAvatar(initials: thread.initials, email: thread.senderEmail) }
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    // Your own latest message: who it went to, never your
                    // name (or theirs as if they'd written to you).
                    Text(sentTo.map { "To: \($0)" }
                         ?? (thread.isFromAccountOwner ? "To: \(thread.counterpartName())" : nil)
                         ?? thread.sender)
                        .font(.body.weight(thread.isUnread ? .semibold : .medium))
                        .foregroundStyle(thread.isUnread ? CorresPalette.ink : CorresPalette.secondary)
                        .lineLimit(typeSize.isAccessibilitySize ? 2 : 1)
                    if thread.isFlagged {
                        Image(systemName: "flag.fill").font(.caption2).foregroundStyle(CorresPalette.flag)
                            .accessibilityLabel("Flagged")
                    }
                    if thread.isPinned {
                        Image(systemName: "pin.fill").font(.caption2).foregroundStyle(CorresPalette.pin)
                            .accessibilityLabel("Pinned")
                    }
                    // Mail you've marked Handled says so, so it's never
                    // lost among the rest (a tester's report).
                    if thread.attention == .handled {
                        Image(systemName: "checkmark.circle.fill").font(.caption2).foregroundStyle(CorresPalette.swipeHandled)
                            .accessibilityLabel("Handled")
                    }
                    if !thread.attachments.isEmpty {
                        Image(systemName: "paperclip").font(.caption2).foregroundStyle(CorresPalette.tertiary)
                            .accessibilityLabel("Has attachments")
                    }
                    Spacer(minLength: 6)
                    // A sender you haven't allowed or blocked yet, shown
                    // in the lists while new senders aren't held back.
                    if thread.senderDecision == .pending {
                        Text("NEW")
                            .font(.caption2.weight(.semibold)).tracking(0.4)
                            .foregroundStyle(CorresPalette.accent)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(CorresPalette.accent.opacity(0.5), lineWidth: 1))
                            .accessibilityLabel("New sender")
                    }
                    if let accountTag {
                        // The colour is a dot and a tinted outline, not the
                        // text: gold or teal text would fail contrast on white.
                        HStack(spacing: 4) {
                            if let color = accountTag.color {
                                Circle().fill(color).frame(width: 6, height: 6)
                            }
                            Text(accountTag.text)
                        }
                        .font(.caption2.weight(.semibold)).tracking(0.4)
                        .foregroundStyle(CorresPalette.tertiary)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .overlay(RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(accountTag.color.map { $0.opacity(0.5) } ?? CorresPalette.line, lineWidth: 1))
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(accountTag.text) account")
                    }
                    if !typeSize.isAccessibilitySize {
                        Text(Self.timestamp(sentTo != nil ? (thread.lastSentAt ?? thread.receivedAt) : thread.receivedAt))
                            .font(.footnote).monospacedDigit()
                            .foregroundStyle(CorresPalette.tertiary)
                    }
                }
                // At the largest text sizes the time gets its own line, as
                // in Mail, so the name isn't cut to a few letters.
                if typeSize.isAccessibilitySize {
                    Text(Self.timestamp(thread.receivedAt))
                        .font(.footnote).monospacedDigit()
                        .foregroundStyle(CorresPalette.tertiary)
                }
                Text(thread.subject)
                    .font(.subheadline.weight(thread.isUnread ? .medium : .regular))
                    .foregroundStyle(thread.isUnread ? CorresPalette.ink : CorresPalette.secondary)
                    .lineLimit(1)
                // Settings → Lists → Preview; the curated lists keep it to a
                // line so the reason has room.
                if previewLines > 0 {
                    if let summaryPreview {
                        (Text(Image(systemName: "sparkle")).font(.caption2).foregroundStyle(CorresPalette.accent)
                            + Text(" ") + Text(summaryPreview))
                            .font(.subheadline)
                            .foregroundStyle(CorresPalette.secondary)
                            .lineLimit(showsReason ? 1 : previewLines)
                            .accessibilityLabel("Summary: \(summaryPreview)")
                    } else {
                        Text(thread.excerpt)
                            .font(.subheadline)
                            .foregroundStyle(CorresPalette.secondary)
                            .lineLimit(showsReason ? 1 : previewLines)
                    }
                }
                if showsReason, !thread.reason.isEmpty {
                    // Side by side normally; stacked at the largest text
                    // sizes, where both would otherwise squeeze to a word.
                    let layout = typeSize.isAccessibilitySize
                        ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
                        : AnyLayout(HStackLayout(spacing: 8))
                    layout {
                        ReasonLine(text: thread.reason, isIntelligence: thread.isIntelligenceReason)
                        if !typeSize.isAccessibilitySize { Spacer(minLength: 4) }
                        if let due = thread.dueAt, thread.attention == .needsYou {
                            DueChip(date: due, isEvent: MailSignals.isEvent(thread.subject + "\n" + thread.excerpt))
                        } else if thread.attention == .waiting {
                            WaitChip(since: thread.waitingReference)
                        }
                    }
                    .padding(.top, 4)
                }
            }
        }
        .padding(.leading, 8).padding(.trailing, 18).padding(.vertical, 12)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityValue(thread.isUnread ? "Unread" : "")
    }

    /// Today shows the time, this week the weekday, older the date, the
    /// same ladder Apple Mail uses.
    static func timestamp(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        if let days = calendar.dateComponents([.day], from: date, to: .now).day, days < 7 {
            return date.formatted(.dateTime.weekday(.wide))
        }
        if calendar.isDate(date, equalTo: .now, toGranularity: .year) {
            return date.formatted(.dateTime.month(.abbreviated).day())
        }
        return date.formatted(.dateTime.month(.abbreviated).day().year(.twoDigits))
    }
}

extension Correspondence {
    /// Whether the reason shown was written by Apple Intelligence on this
    /// iPhone (vs. a rule), so the row can mark it honestly.
    var isIntelligenceReason: Bool {
        triagedMessageID != nil && triagedMessageID == latestMessageID
            && !InboxClassifier.ruleReasons.contains(reason)
    }
}

/// The Mail tab's quick filters. Everything stays in one chronological
/// list; these only narrow it, and never hide mail anywhere else.
/// Where each sender's mail mostly sits, worked out once per change to the
/// mail, not once per row.
@MainActor
enum CategoryContextCache {
    private static var revision: Int?
    private(set) static var latest = InboxCategory.Context()

    static func context(_ store: MailStore) -> InboxCategory.Context {
        if revision != store.revision {
            latest = InboxCategory.context(for: store.threads)
            revision = store.revision
        }
        return latest
    }
}

/// Primary first, as Gmail's tabs and Mail's categories open; Promotions,
/// Social and Updates beside it; Everything one tap away. Where an email
/// sits follows what you've taught Corres (`SenderLessons.category`).
enum MailFilter: String, CaseIterable, Identifiable {
    case primary = "Primary", everything = "Everything", unread = "Unread", promotions = "Promotions",
         social = "Social", updates = "Updates", flagged = "Flagged", sent = "Sent"
    var id: String { rawValue }

    @MainActor func includes(_ thread: Correspondence, context: InboxCategory.Context? = nil) -> Bool {
        switch self {
        case .everything: true
        case .unread: thread.isUnread
        case .flagged: thread.isFlagged
        case .sent: thread.lastSentAt != nil
        case .primary: category(thread, context) == .primary
        case .promotions: category(thread, context) == .promotions
        case .social: category(thread, context) == .social
        case .updates: category(thread, context) == .updates
        }
    }

    var isCategory: Bool { [.primary, .promotions, .social, .updates].contains(self) }

    @MainActor private func category(_ thread: Correspondence, _ context: InboxCategory.Context?) -> InboxCategory {
        InboxCategory.of(thread, override: SenderLessons.category(for: thread), context: context ?? CategoryContextCache.latest)
    }
}

struct CorrespondenceList: View {
    var scrolls = true
    let store: MailStore
    /// Optional: nil only for the offline preview-render script, which never
    /// exercises the scrolls==true/refreshable path that uses these.
    var sync: GmailSyncService?
    var auth: GoogleAuthService?
    /// Optional for the same reason as `sync`/`auth`: nil only for the
    /// offline preview-render script, which never exercises swipe actions.
    var threadActions: ThreadActionService?
    let destination: Destination
    /// nil shows every connected account's mail merged together (the
    /// unified view); a specific email filters down to just that account,
    /// matching Superhuman's per-account view. See `CorresShell`'s account
    /// switcher.
    var accountFilter: String?
    /// False while another tab is showing: the list keeps its rows as they
    /// were instead of rebuilding behind the tab you're using (the tabs
    /// all stay alive), and catches up the moment it's shown again.
    var isActive = true
    @State private var search = ""
    @Environment(PeopleDirectory.self) private var people: PeopleDirectory?
    /// Remembered: Mail opens where you left it, Primary at first.
    @AppStorage("corres.mailFilter") private var mailFilter = MailFilter.primary
    @State private var categoryChoice: CategoryChoice?
    @State private var snoozeTarget: Correspondence?
    @Environment(\.conversationSelection) private var splitSelection
    /// Same four `UserDefaults` keys `PreferencesView`'s own pickers
    /// read/write; `@AppStorage` keeps both in sync automatically, the same
    /// pattern `corres.appearance` already uses across multiple independent
    /// views. Four independent slots, not one: Spark's own short/long swipe
    /// model (researched directly before building `PremiumSwipeRow`) means
    /// a short and a long swipe in the same direction can fire two
    /// genuinely different actions, not just "the same action, sooner or
    /// later."
    @AppStorage("corres.trailingShortSwipeAction") private var trailingShortRaw = PrimarySwipeAction.archive.rawValue
    @AppStorage("corres.trailingLongSwipeAction") private var trailingLongRaw = PrimarySwipeAction.trash.rawValue
    @AppStorage("corres.leadingShortSwipeAction") private var leadingShortRaw = LeadingSwipeAction.pin.rawValue
    @AppStorage("corres.leadingLongSwipeAction") private var leadingLongRaw = LeadingSwipeAction.unread.rawValue
    private var trailingShortAction: PrimarySwipeAction { PrimarySwipeAction(rawValue: trailingShortRaw) ?? .archive }
    private var trailingLongAction: PrimarySwipeAction { PrimarySwipeAction(rawValue: trailingLongRaw) ?? .trash }
    private var leadingShortAction: LeadingSwipeAction { LeadingSwipeAction(rawValue: leadingShortRaw) ?? .pin }
    private var leadingLongAction: LeadingSwipeAction { LeadingSwipeAction(rawValue: leadingLongRaw) ?? .unread }
    /// Tracks whichever thread is currently anchoring the visible scroll
    /// position (SwiftUI keeps this in sync as the person scrolls). Needed
    /// because archiving/trashing from *inside* a conversation removes the
    /// thread from `store.threads` while this list isn't the active screen,
    /// and a plain data reload has no anchor left to restore to once that
    /// exact thread is gone, so it silently falls back to the top. Reported
    /// directly: deleting from a conversation's own action bar sent the
    /// list back to its very top instead of staying where the person was,
    /// losing their place in whatever they were triaging. Swiping to
    /// archive/trash a row directly in this list, by contrast, never had
    /// this problem: the list is already the visible, live view when that
    /// happens, so its own row-removal animation naturally keeps everything
    /// else in place.
    @State private var scrollPosition: ThreadID?

    private var scopedThreads: [Correspondence] {
        // All Inboxes leaves out accounts turned off for it in Settings.
        AccountPreferences.scope(store.threads, account: accountFilter, all: auth?.accounts.map(\.email) ?? [], by: \.id.account)
    }

    /// The rows as last built, and what they were built from. A plain
    /// class, not observed: reading it never redraws anything.
    private final class RowsCache {
        struct Key: Equatable {
            let revision: Int
            /// The minute, so snoozes waking and "due soon" still move on
            /// their own on the next redraw, as they did before caching.
            let minute: Int
            let account: String?
            /// Settings → an account: its name, colour, All Inboxes.
            let accounts: Int
            let destination: Destination
            let search: String
            let filter: MailFilter
        }
        var key: Key?
        var rows: [Correspondence] = []
        var ids: [ThreadID] = []
        var dueSoon: Set<ThreadID> = []
        var unread = 0
    }
    @State private var rowsCache = RowsCache()
    @AppStorage(AccountPreferences.revisionKey) private var accountsRevision = 0

    /// Filtered and sorted once per change to the mail or the view, not on
    /// every read: `results` is read a dozen times per redraw and once per
    /// row scrolling into view, and each fresh build filtered and sorted
    /// the whole mailbox, which is what made scrolling and every swipe
    /// hitch on a real inbox.
    private var rows: RowsCache {
        let cache = rowsCache
        if !isActive, cache.key != nil { return cache }
        let key = RowsCache.Key(revision: store.revision, minute: Int(Date.now.timeIntervalSince1970 / 60),
                                account: accountFilter, accounts: accountsRevision, destination: destination,
                                search: search, filter: mailFilter)
        guard cache.key != key else { return cache }
        let built = buildResults()
        cache.key = key
        cache.rows = built
        cache.ids = built.map(\.id)
        if destination == .needsYou {
            let horizon = Date.now.addingTimeInterval(3 * 86_400)
            cache.dueSoon = Set(built.lazy.filter { ($0.dueAt ?? .distantFuture) <= horizon }.map(\.id))
        } else {
            cache.dueSoon = []
        }
        cache.unread = built.reduce(0) { $0 + ($1.isUnread ? 1 : 0) }
        return cache
    }

    private var results: [Correspondence] { rows.rows }

    private func buildResults() -> [Correspondence] {
        let all: [Correspondence]
        if let attention = destination.attention, search.trimmingCharacters(in: .whitespaces).isEmpty {
            all = MailQuery.prioritized(scopedThreads, attention: attention)
        } else {
            all = MailQuery.filter(scopedThreads, attention: destination.attention, search: search)
        }
        guard destination == .mail, mailFilter != .everything else { return all }
        // Search looks in every category, as Gmail's and Mail's do: an
        // order confirmation in Updates is still found from Primary.
        let searching = !search.trimmingCharacters(in: .whitespaces).isEmpty
        guard !(searching && mailFilter.isCategory) else { return all }
        let context = CategoryContextCache.context(store)
        let filtered = all.filter { mailFilter.includes($0, context: context) }
        // Sent reads like a Sent mailbox: by when you sent, newest first.
        guard mailFilter == .sent else { return filtered }
        return filtered.sorted { ($0.lastSentAt ?? .distantPast) > ($1.lastSentAt ?? .distantPast) }
    }

    /// Needs You splits into what's due within three days and the rest,
    /// keeping the chronological order inside each group.
    private var dueSoonIDs: Set<ThreadID> { rows.dueSoon }

    private var showingSent: Bool { destination == .mail && mailFilter == .sent }

    /// Who you wrote to: the person who answered, or the first person you
    /// sent it to, by name when Corres has seen them write.
    private func recipientName(for thread: Correspondence) -> String {
        if !thread.isFromAccountOwner { return thread.sender }
        guard let address = thread.toRecipients.first ?? thread.ccRecipients.first else { return thread.sender }
        let bare = address.components(separatedBy: "<").last?.trimmingCharacters(in: CharacterSet(charactersIn: "> ")).lowercased() ?? address
        let name = store.threads.first { $0.senderEmail?.lowercased() == bare && !$0.isFromAccountOwner }?.sender
            ?? thread.counterpartName()
        let others = thread.toRecipients.count + thread.ccRecipients.count - 1
        return name + (others > 0 ? " +\(others)" : "")
    }

    private var showsAccountTags: Bool { accountFilter == nil && (auth?.accounts.count ?? 0) > 1 }

    private func accountTag(for thread: Correspondence) -> AccountTag? {
        guard showsAccountTags else { return nil }
        return AccountTag.make(for: thread.id.account, among: auth?.accounts.map(\.email) ?? [])
    }

    @Environment(AppRouter.self) private var router
    @AppStorage(CorresSettings.confirmTrashKey) private var confirmTrash = false
    @State private var confirmingTrash: Correspondence?
    @AppStorage(CorresSettings.showAvatarsKey) private var showAvatarsInList = true
    @State private var isSelecting = false
    @State private var rowFrames = RowFrames()
    /// The two-finger drag's starting row and what was selected before it.
    /// Where a selection drag started, what was selected then, and whether
    /// it selects (started on an empty circle) or unselects (on a checked one).
    @State private var dragAnchor: (id: ThreadID, before: Set<ThreadID>, selects: Bool)?
    @State private var confirmingBulkTrash = false
    @State private var selected: Set<ThreadID> = []

    var body: some View {
        if scrolls {
            ScrollViewReader { proxy in
                scrollingList
                    // Back from a conversation: bring the row you were on
                    // (or, after an archive, its neighbour) into view, so
                    // the list picks up where you left off, not at the top.
                    .onAppear { restorePosition(proxy) }
                    .onChange(of: router.returnAnchor) { restorePosition(proxy) }
            }
        } else {
            nonScrollingBody
        }
    }

    private func restorePosition(_ proxy: ScrollViewProxy) {
        guard let anchor = router.returnAnchor, results.contains(where: { $0.id == anchor }) else { return }
        router.returnAnchor = nil
        // Instantly, with no animation: this runs while the list is still
        // under the conversation, so there's nothing to watch move.
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { proxy.scrollTo(anchor, anchor: .center) }
    }

    @ViewBuilder
    private var scrollingList: some View {
            listContainer {
                Section {
                    header
                    if results.isEmpty {
                        emptyState
                    } else if !dueSoonIDs.isEmpty && dueSoonIDs.count < results.count {
                        groupLabel("Due soon")
                        conversationRows(results.filter { dueSoonIDs.contains($0.id) })
                        groupLabel("When you can")
                        conversationRows(results.filter { !dueSoonIDs.contains($0.id) })
                    } else {
                        conversationRows(results)
                    }
                    olderMailFooter
                    listFooter
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(CorresPalette.canvas)
            .scrollPosition(id: $scrollPosition)
            .onChange(of: rows.ids) { oldValue, newValue in
                selected.formIntersection(newValue)
                guard let anchor = scrollPosition, !newValue.contains(anchor),
                      let oldIndex = oldValue.firstIndex(of: anchor) else { return }
                // Whatever the disappeared thread's own former neighbor is
                // now sits at (or near) the same index; re-anchor to it so
                // the list holds its position instead of resetting, the
                // same "next email is right where I left it" continuity a
                // premium mail client is expected to have.
                if newValue.indices.contains(oldIndex) {
                    scrollPosition = newValue[oldIndex]
                } else {
                    scrollPosition = newValue.last
                }
            }
            // Room below the last rows while the Undo pill shows, so any row
            // can be scrolled clear of it; while selecting, the action bar.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if isSelecting {
                    selectionBar
                } else {
                    Color.clear.frame(height: threadActions?.pendingRemoval == nil && threadActions?.lastChange == nil ? 0 : 56)
                }
            }
            .modifier(TwoFingerSelect(isSelecting: isSelecting, onChange: handleTwoFingerSelect))
            // A light tick per row as a drag selects it, as in Mail.
            .sensoryFeedback(.selection, trigger: selected.count) { _, _ in dragAnchor != nil }
            .toolbar(isSelecting ? .hidden : .automatic, for: .tabBar)
            .toolbar { selectionToolbar }
            .animation(.snappy(duration: 0.25), value: isSelecting)
            .onChange(of: isSelecting) { _, value in router.isSelecting = value }
            .onDisappear { if isSelecting { endSelection() }; router.isSelecting = false }
            .onChange(of: destination) { endSelection() }
            .onChange(of: mailFilter) { endSelection() }
            .confirmationDialog("Move this conversation to Trash?",
                                isPresented: Binding(get: { confirmingTrash != nil }, set: { if !$0 { confirmingTrash = nil } }),
                                titleVisibility: .visible) {
                Button("Move to Trash", role: .destructive) {
                    if let thread = confirmingTrash { Task { await threadActions?.trash(thread) } }
                    confirmingTrash = nil
                }
            }
            .sheet(item: $snoozeTarget) { thread in
                SnoozeSheet(kind: thread.mailKind) { date in Task { await store.snooze(thread.id, until: date) } }
            }
            .categoryMoveDialog($categoryChoice, threadActions: threadActions)
            .searchable(text: $search, prompt: "Search conversations")
            .refreshable {
                _ = await sync?.syncAll(accounts: auth?.accounts.map(\.email) ?? [])
                await store.load()
            }
            // Debounced: fires 450ms after typing pauses, not per keystroke,
            // and cancels automatically (`.task(id:)`'s own behavior) if the
            // person keeps typing before that. Reaches past what's already
            // synced locally; see GmailSyncService.search's doc comment.
            .task(id: search) {
                let accounts = accountFilter.map { [$0] } ?? AccountPreferences.allInboxesAccounts(auth?.accounts.map(\.email) ?? [])
                guard !accounts.isEmpty else { return }
                try? await Task.sleep(for: .milliseconds(450))
                guard !Task.isCancelled else { return }
                if await sync?.search(search, accounts: accounts) == true {
                    await store.refresh()
                }
            }
    }

    private var nonScrollingBody: some View {
        ScrollView { staticContent }
    }

    // MARK: - Select

    private func toggleSelection(_ id: ThreadID) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    /// Two fingers down a list, or one down the circles in Select: select
    /// (or, starting on a checked circle, unselect) everything from the row
    /// where the drag started to the row under it now, as in Mail. Dragging
    /// back up restores the rows left behind; the rest stays as it was.
    private func handleTwoFingerSelect(_ state: UIGestureRecognizer.State, _ point: CGPoint) {
        let order = rows.ids
        switch state {
        case .began:
            guard let id = rowFrames.id(at: point, in: order) else { return }
            if !isSelecting { isSelecting = true }
            let selects = !selected.contains(id)
            dragAnchor = (id, selected, selects)
            if selects { selected.insert(id) } else { selected.remove(id) }
        case .changed:
            // By id, found again in the list as it is now: new mail or a
            // re-sort mid-drag left a remembered position past the end of
            // the list, and the range crashed.
            guard let anchor = dragAnchor, let id = rowFrames.id(at: point, in: order),
                  let index = order.firstIndex(of: id), let start = order.firstIndex(of: anchor.id) else { return }
            let run = order[min(start, index)...max(start, index)]
            let next = anchor.selects ? anchor.before.union(run) : anchor.before.subtracting(run)
            if next != selected { selected = next }
        default:
            dragAnchor = nil
        }
    }

    private func endSelection() {
        isSelecting = false
        selected = []
    }

    private var selectedThreads: [Correspondence] { results.filter { selected.contains($0.id) } }

    @ToolbarContentBuilder
    private var selectionToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            if isSelecting {
                Button(selected.count == results.count && !results.isEmpty ? "Deselect All" : "Select All") {
                    selected = selected.count == results.count ? [] : Set(results.map(\.id))
                }
            } else if !results.isEmpty {
                Button("Select") { isSelecting = true }
            }
        }
        if isSelecting {
            ToolbarItem(placement: .principal) {
                Text(selected.isEmpty ? "Select Conversations" : "\(selected.count) Selected")
                    .font(.headline).monospacedDigit()
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { endSelection() }.fontWeight(.semibold)
            }
        }
    }

    /// Mail's selection actions: Mark, Move, Archive, Trash, for every
    /// selected conversation at once, with one Undo.
    private var selectionBar: some View {
        let chosen = selectedThreads
        let anyUnread = chosen.contains(where: \.isUnread)
        let anyUnflagged = chosen.contains { !$0.isFlagged }
        return HStack(spacing: 0) {
            bulkButton(anyUnread ? "envelope.open" : "envelope.badge", anyUnread ? "Mark as Read" : "Mark as Unread") {
                await threadActions?.toggleUnread(!anyUnread, for: chosen)
            }
            bulkButton(anyUnflagged ? "flag" : "flag.slash", anyUnflagged ? "Flag" : "Unflag") {
                await threadActions?.toggleFlagged(anyUnflagged, for: chosen)
            }
            Menu {
                AttentionChoices(current: nil) { attention in
                    Task {
                        await threadActions?.setAttention(attention, for: chosen)
                        endSelection()
                    }
                }
            } label: {
                bulkLabel("arrow.up.and.down.text.horizontal", "Move to")
            }
            .disabled(chosen.isEmpty)
            bulkButton("archivebox", "Archive") { await threadActions?.archive(chosen) }
            bulkButton("trash", "Move to Trash") {
                if confirmTrash { confirmingBulkTrash = true } else { await threadActions?.trash(chosen) }
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 56)
        .corresGlass(in: Capsule())
        .padding(.horizontal, CorresSpace.page).padding(.bottom, 8)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .confirmationDialog(chosen.count == 1 ? "Move this conversation to Trash?" : "Move \(chosen.count) conversations to Trash?",
                            isPresented: $confirmingBulkTrash, titleVisibility: .visible) {
            Button("Move to Trash", role: .destructive) {
                Task { await threadActions?.trash(chosen); endSelection() }
            }
        }
    }

    private func bulkButton(_ icon: String, _ label: String, action: @escaping () async -> Void) -> some View {
        Button {
            Task {
                await action()
                if !confirmingBulkTrash { endSelection() }
            }
        } label: {
            bulkLabel(icon, label)
        }
        .disabled(selected.isEmpty)
    }

    private func bulkLabel(_ icon: String, _ label: String) -> some View {
        Image(systemName: icon)
            .font(.body.weight(.medium))
            .frame(maxWidth: .infinity, minHeight: 50)
            .contentShape(Rectangle())
            .accessibilityLabel(label)
    }

    /// On iPhone a plain List, so rows push; in the split layout a List
    /// bound to the detail column's selection, so rows select into it.
    @ViewBuilder
    private func listContainer<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        if let splitSelection {
            List(selection: splitSelection) { content() }
        } else {
            List { content() }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Text(summaryLine).font(.subheadline).foregroundStyle(CorresPalette.secondary)
                // Visible feedback that a search is genuinely reaching past
                // what's already synced, not just quietly finding nothing:
                // see GmailSyncService.search's doc comment.
                if sync?.isSearchingRemote == true {
                    ProgressView().controlSize(.mini)
                    Text("Searching your mail…").font(.subheadline).foregroundStyle(CorresPalette.secondary)
                }
            }
            .padding(.horizontal, CorresSpace.page)
            peopleMatches
            if destination == .mail { filterBar }
        }
        .padding(.bottom, 6)
        .readableWidth()
    }

    /// Typing a name in search offers the person, as Spark does: tap and
    /// you see everything with them, to and from, the whole mailbox
    /// (Gmail is searched for their address).
    @ViewBuilder
    private var peopleMatches: some View {
        let typed = search.trimmingCharacters(in: .whitespaces)
        let found = typed.count >= 2 && !typed.contains("@") ? (people?.suggestions(for: typed, limit: 3) ?? []) : []
        if !found.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(found) { person in
                    Button { search = person.email } label: {
                        HStack(spacing: 10) {
                            CorrespondentAvatar(initials: person.displayName.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined(),
                                                email: person.email, size: CGSize(width: 32, height: 32))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(person.displayName).font(.subheadline.weight(.medium)).foregroundStyle(CorresPalette.ink).lineLimit(1)
                                Text(person.email).font(.caption).foregroundStyle(CorresPalette.secondary).lineLimit(1)
                            }
                            Spacer(minLength: 8)
                            Text("All mail").font(.caption.weight(.medium)).foregroundStyle(CorresPalette.accent)
                        }
                        .padding(.horizontal, CorresSpace.page).padding(.vertical, 7)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(person.displayName), \(person.email)")
                    .accessibilityHint("Shows all mail with them")
                }
            }
        }
    }

    private var summaryLine: String {
        let count = results.count
        let noun = count == 1 ? "conversation" : "conversations"
        let sample = (auth?.accounts.isEmpty ?? true) ? " · Sample mail" : ""
        switch destination {
        case .needsYou:
            let due = dueSoonIDs.count
            return "\(count) \(noun)" + (due > 0 ? " · \(due) due soon" : "") + sample
        case .waiting:
            return (count == 1 ? "1 conversation waiting on a reply" : "\(count) conversations waiting on a reply") + sample
        default:
            let unread = rows.unread
            return "Newest first" + (unread > 0 ? " · \(unread) unread" : "") + sample
        }
    }

    /// Underlined text tabs, not chips: they read as views of one list,
    /// which is what they are.
    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 18) {
                ForEach(MailFilter.allCases) { filter in
                    Button {
                        mailFilter = filter
                    } label: {
                        Text(filter.rawValue)
                            .font(.subheadline.weight(mailFilter == filter ? .semibold : .medium))
                            .foregroundStyle(mailFilter == filter ? CorresPalette.ink : CorresPalette.secondary)
                            .padding(.vertical, 10)
                            .overlay(alignment: .bottom) {
                                if mailFilter == filter {
                                    Capsule().fill(CorresPalette.accent).frame(height: 2)
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(mailFilter == filter ? .isSelected : [])
                }
            }
            .padding(.horizontal, CorresSpace.page)
        }
        // At larger text sizes the tabs scroll; a soft edge says so instead
        // of cutting the last one off mid-word.
        .trailingFade()
        .overlay(alignment: .bottom) { Hairline() }
        .sensoryFeedback(.selection, trigger: mailFilter)
    }

    private func groupLabel(_ title: String) -> some View {
        Text(title).eyebrow()
            .padding(.horizontal, CorresSpace.page).padding(.top, 14).padding(.bottom, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder
    private var listFooter: some View {
        if destination == .needsYou && !results.isEmpty {
            Text("Email that asks something of you, sorted on this iPhone. Done with one? Swipe it or tap Handled: it leaves this list, stays in Mail, and waits in Mailboxes \u{2192} Handled. Wrong call? Press and hold to move it.")
                .font(.footnote).foregroundStyle(CorresPalette.tertiary)
                .padding(.horizontal, CorresSpace.page).padding(.vertical, 18)
        } else if destination == .waiting && !results.isEmpty {
            Text("Where you asked someone something, from Corres or any other app, or moved it here yourself. Longest wait first; after three days it's time to follow up. No tracking pixels, no read receipts.")
                .font(.footnote).foregroundStyle(CorresPalette.tertiary)
                .padding(.horizontal, CorresSpace.page).padding(.vertical, 18)
        }
    }

    private var emptyTitle: String {
        switch destination {
        case .needsYou: "Nothing in Needs You"
        case .waiting: "Nothing in Waiting"
        default: mailFilter == .everything ? "No mail here" : "Nothing in \(mailFilter.rawValue)"
        }
    }

    private var emptyDetail: String {
        switch destination {
        case .needsYou: "Anything Corres files here asks something of you. Everything else is in Mail."
        case .waiting: "When you reply to someone, or move a conversation here, it waits here until they answer."
        default: mailFilter == .sent ? "Conversations you've written in, from Corres or any other app, show here."
                                     : "Pull down to check for new mail."
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(search.isEmpty ? emptyTitle : "No conversations found", systemImage: search.isEmpty ? "checkmark.circle" : "magnifyingglass")
        } description: {
            Text(search.isEmpty ? emptyDetail : "Try a name, subject, or organization.")
        }
        .padding(.horizontal, CorresSpace.page)
    }

    /// `PrimarySwipeAction`'s title/icon/tint are fixed, state-independent
    /// (see `SwipePreferences.swift`); `LeadingSwipeAction`'s aren't (Pin
    /// needs to say "Unpin" once already pinned, the same way the row's own
    /// old swipe buttons already did), so this one needs the thread.
    private func leadingVisual(for action: LeadingSwipeAction, thread: Correspondence) -> SwipeVisual {
        switch action {
        case .pin:
            SwipeVisual(title: thread.isPinned ? "Unpin" : "Pin",
                       systemImage: thread.isPinned ? "pin.slash.fill" : "pin.fill", tint: CorresPalette.swipePin)
        case .unread:
            SwipeVisual(title: thread.isUnread ? "Read" : "Unread",
                       systemImage: thread.isUnread ? "envelope.open.fill" : "envelope.badge.fill",
                       tint: CorresPalette.swipeUnread)
        case .flag:
            SwipeVisual(title: thread.isFlagged ? "Unflag" : "Flag",
                       systemImage: thread.isFlagged ? "flag.slash.fill" : "flag.fill",
                       tint: CorresPalette.swipeFlag)
        }
    }

    private func perform(_ action: PrimarySwipeAction, on thread: Correspondence) {
        switch action {
        case .archive: Task { await threadActions?.archive(thread) }
        case .trash:
            // Settings → Reading → Ask before moving to Trash.
            if confirmTrash { confirmingTrash = thread } else { Task { await threadActions?.trash(thread) } }
        case .handled:
            // Out of view the moment the swipe lands, not once the write
            // finishes, so the row collapses right after it slides off.
            let leaves = destination != .mail
            if leaves { withAnimation(.snappy(duration: 0.3)) { store.hide(thread.id) } }
            Task {
                await threadActions?.setAttention(.handled, for: thread)
                if leaves { store.unhide(thread.id) }
            }
        }
    }

    private func perform(_ action: LeadingSwipeAction, on thread: Correspondence) {
        switch action {
        case .pin: Task { await threadActions?.togglePinned(thread) }
        case .unread: Task { await threadActions?.toggleUnread(!thread.isUnread, for: [thread]) }
        case .flag: Task { await threadActions?.toggleFlagged(!thread.isFlagged, for: [thread]) }
        }
    }

    /// Snooze (a menu of options, not a single action) and "mark as Needs
    /// You" both lost their old place in the reveal-then-tap swipe when it
    /// was replaced by `PremiumSwipeRow`'s real Spark-style short/long
    /// model: a swipe fires exactly one action immediately on release, with
    /// no room for a submenu, the same real constraint Spark's own swipe
    /// design has. Both stay one tap away regardless, in the conversation's
    /// own Mark As/Snooze menus — a deliberate trade for matching the
    /// requested interaction model, not an oversight.
    private func conversationRows(_ threads: [Correspondence]) -> some View {
        let orderedIDs = rows.ids
        // Read here, on the main actor; the guide's closure isn't.
        let separatorInset: CGFloat = showAvatarsInList ? 77 : 25
        return ForEach(threads) { thread in
            PremiumSwipeRow(
                leadingShort: isSelecting ? nil : leadingVisual(for: leadingShortAction, thread: thread),
                leadingLong: isSelecting ? nil : leadingVisual(for: leadingLongAction, thread: thread),
                trailingShort: isSelecting ? nil : SwipeVisual(title: trailingShortAction.title, systemImage: trailingShortAction.systemImage,
                                           tint: trailingShortAction.tint, removesRow: trailingShortAction.removesRow(in: destination)
                                                && !(trailingShortAction == .trash && confirmTrash)),
                trailingLong: isSelecting ? nil : SwipeVisual(title: trailingLongAction.title, systemImage: trailingLongAction.systemImage,
                                          tint: trailingLongAction.tint, removesRow: trailingLongAction.removesRow(in: destination)
                                               && !(trailingLongAction == .trash && confirmTrash)),
                onLeadingShort: { perform(leadingShortAction, on: thread) },
                onLeadingLong: { perform(leadingLongAction, on: thread) },
                onTrailingShort: { perform(trailingShortAction, on: thread) },
                onTrailingLong: { perform(trailingLongAction, on: thread) }
            ) {
                let row = CorrespondenceRow(thread: thread, showsReason: destination != .mail, accountTag: accountTag(for: thread),
                                            sentTo: showingSent || thread.isFromAccountOwner ? recipientName(for: thread) : nil)
                if isSelecting {
                    // Tapping selects, the way Mail's Select works.
                    Button { toggleSelection(thread.id) } label: {
                        HStack(spacing: 0) {
                            Image(systemName: selected.contains(thread.id) ? "checkmark.circle.fill" : "circle")
                                .font(.title3)
                                .foregroundStyle(selected.contains(thread.id) ? CorresPalette.accent : CorresPalette.tertiary)
                                .padding(.leading, 14)
                                .transition(.move(edge: .leading).combined(with: .opacity))
                            row
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected.contains(thread.id) ? .isSelected : [])
                } else {
                    NavigationLink(value: ConversationRoute(id: thread.id, orderedIDs: orderedIDs)) { row }
                        .hidingDisclosureIndicator()
                }
            }
            .contextMenu { if !isSelecting { rowMenu(for: thread) } }
            .disabled(store.pending.contains(thread.id))
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.visible)
            .listRowSeparatorTint(CorresPalette.line)
            .listRowBackground(splitSelection?.wrappedValue?.id == thread.id ? CorresPalette.accent.opacity(0.12) : Color.clear)
            .alignmentGuide(.listRowSeparatorLeading) { [separatorInset] _ in separatorInset }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { rowFrames.frames[thread.id] = $0 }
            .onAppear {
                if pagesOlderMail, thread.id == results.last?.id { loadOlderMail() }
            }
            .onDisappear { rowFrames.frames[thread.id] = nil }
            // A hand-built drag gesture gets none of what Apple's own
            // `.swipeActions` gave VoiceOver for free: every button it
            // exposes is automatically reachable through the accessibility
            // rotor's Actions menu, with no swipe gesture required at all.
            // `PremiumSwipeRow` replacing that API outright, on its own,
            // would have silently taken away the *only* way a VoiceOver
            // user could reach Archive/Trash/Pin/etc. from this list —
            // found in the same full-sweep pass that shipped the gesture
            // itself, not discovered later. These four actions mirror
            // exactly what the swipe gesture does, so a VoiceOver user and
            // a sighted swiping user reach the same four outcomes.
            // `.disabled()` above stops the drag gesture from firing while
            // this row is already mid-action (`store.pending`), but that
            // guard doesn't automatically extend to custom
            // `.accessibilityAction`s the same way it does for a real
            // `Button` — checked explicitly here so a VoiceOver user can't
            // double-fire an action through the accessibility path in the
            // same narrow window a sighted swipe is already blocked from.
            .accessibilityAction(named: Text(leadingShortAction.settingsTitle)) {
                guard !store.pending.contains(thread.id) else { return }
                perform(leadingShortAction, on: thread)
            }
            .accessibilityAction(named: Text(leadingLongAction.settingsTitle)) {
                guard !store.pending.contains(thread.id) else { return }
                perform(leadingLongAction, on: thread)
            }
            .accessibilityAction(named: Text(trailingShortAction.title)) {
                guard !store.pending.contains(thread.id) else { return }
                perform(trailingShortAction, on: thread)
            }
            .accessibilityAction(named: Text(trailingLongAction.title)) {
                guard !store.pending.contains(thread.id) else { return }
                perform(trailingLongAction, on: thread)
            }
        }
    }

    /// "Wrong call?": the correction path for every sort Corres makes.
    /// Moving a thread is the person's own decision and sticks; later
    /// automatic passes never move it back (see ADR 002).
    @ViewBuilder
    private func rowMenu(for thread: Correspondence) -> some View {
        // Mail's "Select": starts Select with this conversation checked.
        Button {
            isSelecting = true
            selected = [thread.id]
        } label: {
            Label("Select", systemImage: "checkmark.circle")
        }
        Section("Move To") {
            AttentionChoices(current: thread.attention) { attention in
                Task { await threadActions?.setAttention(attention, for: thread) }
            }
        }
        CategoryMenuItems(thread: thread) { categoryChoice = $0 }
        Button {
            snoozeTarget = thread
        } label: {
            Label("Snooze…", systemImage: "clock")
        }
        if let email = thread.senderEmail, !thread.isFromAccountOwner {
                let isVIP = InboxClassifier.isVIP(email)
                Button {
                    Task { await store.setVIP(email, account: thread.id.account, isVIP: !isVIP) }
                } label: {
                    Label(isVIP ? "Remove from VIPs" : "Add \(thread.sender) to VIPs", systemImage: isVIP ? "star.slash" : "star")
                }
            }

        Button {
            Task { await threadActions?.toggleFlagged(!thread.isFlagged, for: [thread]) }
        } label: {
            Label(thread.isFlagged ? "Unflag" : "Flag", systemImage: thread.isFlagged ? "flag.slash" : "flag")
        }
        Button {
            Task { await threadActions?.toggleUnread(!thread.isUnread, for: [thread]) }
        } label: {
            Label(thread.isUnread ? "Mark as Read" : "Mark as Unread", systemImage: thread.isUnread ? "envelope.open" : "envelope.badge")
        }
        Button {
            Task { await threadActions?.archive(thread) }
        } label: {
            Label("Archive", systemImage: "archivebox")
        }
    }

    /// Mail is the everything view, so it keeps going past what the first
    /// sync pulled: reaching the bottom pages older Inbox mail in, the way
    /// Gmail's own app does, instead of the list simply ending at however
    /// far back the first sync happened to reach. Not during a search,
    /// which already reaches the whole mailbox through Gmail's own search.
    private var pagesOlderMail: Bool { destination == .mail && search.isEmpty && sync != nil }

    private func loadOlderMail() {
        guard let sync, let auth else { return }
        let accounts = accountFilter.map { [$0] } ?? AccountPreferences.allInboxesAccounts(auth.accounts.map(\.email))
        guard sync.hasOlderMail(accounts: accounts) else { return }
        Task {
            if await sync.loadOlder(accounts: accounts) { await store.refresh() }
        }
    }

    @ViewBuilder
    private var olderMailFooter: some View {
        if pagesOlderMail, sync?.isLoadingOlder == true {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Loading older mail…").font(.footnote).foregroundStyle(CorresPalette.secondary)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 16)
            .listRowSeparator(.hidden)
        }
    }

    /// Used only by the offline preview-render script; List does not render through ImageRenderer.
    /// Mirrors the same flat, divider-separated look conversationRows gets
    /// from List's own row separators, since a plain VStack has none built in.
    private var staticContent: some View {
        VStack(alignment: .leading, spacing: 24) {
            header
            if results.isEmpty {
                emptyState
            } else {
                let orderedIDs = results.map(\.id)
                VStack(spacing: 0) {
                    ForEach(Array(results.enumerated()), id: \.element.id) { index, thread in
                        NavigationLink(value: ConversationRoute(id: thread.id, orderedIDs: orderedIDs)) {
                            CorrespondenceRow(thread: thread, showsReason: destination != .mail)
                        }
                        if index < results.count - 1 { Hairline(leading: 76) }
                    }
                }
                .corresSurface()
                .padding(.horizontal, CorresSpace.page)
                .frame(maxWidth: .infinity, alignment: .leading).frame(maxWidth: 680)
            }
        }
    }
}

extension View {
    /// No mail app shows a disclosure chevron on its rows.
    @ViewBuilder
    func hidingDisclosureIndicator() -> some View {
        if #available(iOS 26.0, *) {
            self.navigationLinkIndicatorVisibility(.hidden)
        } else {
            self
        }
    }
}


/// The selection drags where they exist (iOS 18+): two fingers anywhere,
/// and in Select, one finger down the circles, as in Mail.
private struct TwoFingerSelect: ViewModifier {
    var isSelecting = false
    let onChange: (UIGestureRecognizer.State, CGPoint) -> Void

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content
                .gesture(TwoFingerSelectGesture(onChange: onChange))
                .gesture(TwoFingerSelectGesture(fingers: 1, leadingZone: 56, isEnabled: isSelecting, onChange: onChange))
        } else {
            content
        }
    }
}
