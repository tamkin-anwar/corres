import SwiftUI
import TipKit

/// Waits for `task` up to `limit`: what it returned, or nil if it's still
/// going (it carries on). A task group can't do this, since it waits for
/// every child, so awaiting the task inside one waited for all of it.
@MainActor
func waitBriefly<T: Sendable>(for task: Task<T, Never>, upTo limit: Duration) async -> T? {
    let once = OnceFlag()
    return await withCheckedContinuation { continuation in
        let timer = Task { @MainActor in
            // Cancelled: the task finished first.
            guard (try? await Task.sleep(for: limit)) != nil else { return }
            if once.claim() { continuation.resume(returning: nil) }
        }
        Task { @MainActor in
            let value = await task.value
            timer.cancel()
            if once.claim() { continuation.resume(returning: value) }
        }
    }
}

/// True the first time it's claimed, false after.
@MainActor private final class OnceFlag {
    private var claimed = false
    func claim() -> Bool {
        defer { claimed = true }
        return !claimed
    }
}

/// Which account an email in All Inboxes came from: the account's name,
/// and its colour when colour coding is on (Settings → the account).
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// "Tina K. Rotolo +2" → "TK": letters from the first two words of a
    /// name, leaving off the count of others.
    static func initials(of name: String) -> String {
        name.split(separator: " ").filter { !$0.hasPrefix("+") }
            .compactMap { $0.first(where: { $0.isLetter || $0.isNumber }) }
            .prefix(2).map { String($0).uppercased() }.joined()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(thread.isUnread ? CorresPalette.accent : .clear)
                .frame(width: 7, height: 7)
                .scaleEffect(thread.isUnread || reduceMotion ? 1 : 0.4)
                .animation(.snappy(duration: 0.25), value: thread.isUnread)
                .padding(.top, 17)
                .accessibilityHidden(true)
            if showAvatars {
                // Your own email shows who it went to, as its name does.
                if let recipient = sentTo ?? (thread.isFromAccountOwner ? thread.counterpartName() : nil) {
                    CorrespondentAvatar(initials: Self.initials(of: recipient), email: thread.toRecipients.first)
                } else {
                    CorrespondentAvatar(initials: thread.initials, email: thread.senderEmail)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    // Your own latest message: who it went to, never your
                    // name (or theirs as if they'd written to you).
                    Text(sentTo.map { String(localized: "To: \($0)") }
                         ?? (thread.isFromAccountOwner ? String(localized: "To: \(thread.counterpartName())") : nil)
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
                    // A sender you haven't allowed or blocked yet, while the
                    // mail is new. Every unreviewed sender used to carry
                    // it, which on a busy inbox was half the rows.
                    if thread.showsAsNewSender, thread.receivedAt > .now.addingTimeInterval(-3 * 86_400) {
                        Text("NEW")
                            .font(.caption2.weight(.semibold)).letterSpacing(0.4)
                            .foregroundStyle(CorresPalette.accent)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(CorresPalette.accent.opacity(0.5), lineWidth: 1))
                            .accessibilityLabel("New sender")
                    }
                    if let accountTag {
                        // Which account, at a glance and quietly: its colour
                        // as a dot beside the time, as Mail and Spark mark
                        // accounts; its name only when colours are off.
                        Group {
                            if let color = accountTag.color {
                                Circle().fill(color).frame(width: 7, height: 7)
                            } else {
                                Text(accountTag.text).font(.caption2.weight(.semibold)).letterSpacing(0.4)
                                    .foregroundStyle(CorresPalette.tertiary)
                            }
                        }
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
                    // The same time as above: in Sent, when you sent it.
                    Text(Self.timestamp(sentTo != nil ? (thread.lastSentAt ?? thread.receivedAt) : thread.receivedAt))
                        .font(.footnote).monospacedDigit()
                        .foregroundStyle(CorresPalette.tertiary)
                }
                Text(thread.subject)
                    .font(.subheadline.weight(thread.isUnread ? .medium : .regular))
                    .foregroundStyle(thread.isUnread ? CorresPalette.ink : CorresPalette.secondary)
                    .lineLimit(1)
                // Settings → Lists → Preview; the curated lists keep it to a
                // line so the reason has room.
                // The email's own words: summaries stay inside the email,
                // where they're checked against it, never in place of it.
                if previewLines > 0 {
                    Text(thread.excerpt)
                        .font(.subheadline)
                        .foregroundStyle(CorresPalette.secondary)
                        .lineLimit(showsReason ? 1 : previewLines)
                }
                if showsReason, !thread.reason.isEmpty {
                    // Side by side normally; stacked at the largest text
                    // sizes, where both would otherwise squeeze to a word.
                    let layout = typeSize.isAccessibilitySize
                        ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
                        : AnyLayout(HStackLayout(spacing: 8))
                    layout {
                        ReasonLine(text: thread.displayReason, isIntelligence: thread.isIntelligenceReason)
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
        .mailEntity(thread.id)
    }

    /// Today shows the time, this week the weekday, older the date, the
    /// same ladder Apple Mail uses.
    static func timestamp(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return date.formatted(date: .omitted, time: .shortened) }
        if calendar.isDateInYesterday(date) { return String(localized: "Yesterday") }
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

struct CorrespondenceList: View {
    @Environment(\.dynamicTypeSize) private var typeSize
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
    @State private var searchPresented = false
    /// What the rows are filtered by: `search` once typing pauses. Every
    /// keystroke filtered the whole mailbox on the main thread.
    @State private var appliedSearch = ""
    /// Finds `appliedSearch`'s matches, away from the main thread in a
    /// large mailbox; `searchFound` changes when they arrive.
    @State private var searcher = MailSearch()
    @State private var searchFound = 0
    @Environment(PeopleDirectory.self) private var people: PeopleDirectory?
    @Environment(AskService.self) private var ask: AskService?
    @Environment(\.horizontalSizeClass) private var sizeClass
    /// Remembered: Mail opens where you left it, Primary at first.
    @AppStorage("corres.mailFilter") private var mailFilter = MailFilter.needsYou
    @AppStorage(MailFilter.unreadOnlyKey) private var unreadOnly = false
    /// Settings › Customize › Lists › Tabs.
    @AppStorage(CorresSettings.tabsAtBottomKey) private var tabsAtBottom = false
    @AppStorage(CorresSettings.tabsPinnedKey) private var tabsPinned = true
    @State private var listWidth: CGFloat = 0
    /// Needs You is part of Pro: without it the split shows what it does.
    var needsYouLocked = false
    var onUnlockPro: (() -> Void)?
    var showingScreener: Binding<Bool>?
    var onOpenWaiting: (() -> Void)?

    /// What this list is showing: Mail on its Needs You split behaves as
    /// Needs You (its order, reasons, swipes and footer). Searching always
    /// looks through all of Mail.
    private var kind: Destination {
        destination == .mail && mailFilter == .needsYou && appliedSearch.isEmpty ? .needsYou : destination
    }
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

    private var scopedThreads: [Correspondence] {
        // All Inboxes leaves out accounts turned off for it in Settings.
        // Searching reaches archived mail too; the lists never show it.
        let source = appliedSearch.trimmingCharacters(in: .whitespaces).isEmpty ? store.listedIncludingHidden : store.threadsIncludingHidden
        return AccountPreferences.scope(source, account: accountFilter, all: auth?.accounts.map(\.email) ?? [], by: \.id.account)
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
            let unreadOnly: Bool
            /// What the providers' search found, as more of it arrives.
            let serverMatches: Int
            /// A search's matches arriving.
            let searchFound: Int
            /// The Daily Brief is showing, so its card is worth building.
            let brief: Bool
        }
        var key: Key?
        var rows: [Correspondence] = []
        var ids: [ThreadID] = []
        var dueSoon: Set<ThreadID> = []
        var unread = 0
        /// Each account's marker, for the merged view.
        var tags: [String: AccountTag] = [:]
        /// On the Needs You split: Waiting and new senders, for the rows on top.
        var waitingCount = 0
        var longestWait: String?
        var pendingSenders = 0
        /// On the Needs You split with the Daily Brief on: today's card.
        var brief = TodayBrief.empty
        /// Searching: the best few matches, shown above the rest.
        var top: [Correspondence] = []
        /// Built with hidden rows still in; `rows` leaves out `hidden`.
        var full: [Correspondence] = []
        var hidden: Set<ThreadID> = []
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
        let key = RowsCache.Key(revision: store.contentRevision, minute: Int(Date.now.timeIntervalSince1970 / 60),
                                account: accountFilter, accounts: accountsRevision, destination: kind,
                                search: appliedSearch, filter: mailFilter, unreadOnly: filtersUnread,
                                serverMatches: serverMatches.count, searchFound: searchFound,
                                brief: showsBrief)
        let hidden = store.hiddenFromLists
        if cache.key == key, cache.hidden == hidden { return cache }
        if cache.key != key {
            // Unread Only keeps what it already showed, until you change
            // split, account or the filter itself.
            let old = cache.key
            let sameView = old.map { $0.filter == key.filter && $0.destination == key.destination
                && $0.account == key.account && $0.unreadOnly && key.unreadOnly && $0.search == key.search } ?? false
            // Still searching: the rows stay as they were until the matches arrive.
            guard let full = buildResults(keeping: sameView ? Set(cache.full.map(\.id)) : []) else { return cache }
            cache.full = full
            cache.key = key
            if kind == .needsYou {
                let waiting = MailQuery.prioritized(scopedThreads, attention: .waiting)
                cache.waitingCount = waiting.count
                cache.longestWait = waiting.map(\.waitingReference).min().map { oldest in
                    let days = Calendar.current.dateComponents([.day], from: oldest, to: .now).day ?? 0
                    return days < 1 ? String(localized: "Since today")
                        : days == 1 ? String(localized: "Longest 1 day") : String(localized: "Longest \(days) days")
                }
                let pending = AccountPreferences.scope(store.pendingSenderThreads, account: accountFilter,
                                                       all: auth?.accounts.map(\.email) ?? [], by: \.id.account)
                cache.pendingSenders = Set(pending.compactMap(\.senderEmail)).count
            }
            cache.brief = key.brief ? buildBrief(needsYou: filtersUnread
                ? MailQuery.prioritized(scopedThreads, attention: .needsYou) : full) : .empty
        }
        // A swipe only hides a row: filter what's built, don't rebuild.
        let built = hidden.isEmpty ? cache.full : cache.full.filter { !hidden.contains($0.id) }
        cache.hidden = hidden
        cache.rows = built
        cache.ids = built.map(\.id)
        if kind == .needsYou {
            let horizon = Date.now.addingTimeInterval(3 * 86_400)
            cache.dueSoon = Set(built.lazy.filter { ($0.dueAt ?? .distantFuture) <= horizon }.map(\.id))
        } else {
            cache.dueSoon = []
        }
        cache.unread = built.reduce(0) { $0 + ($1.isUnread ? 1 : 0) }
        let searching = appliedSearch.trimmingCharacters(in: .whitespaces)
        cache.top = searching.isEmpty ? [] : searcher.topResults(built)
        let accounts = auth?.accounts.map(\.email) ?? []
        cache.tags = showsAccountTags ? Dictionary(uniqueKeysWithValues: accounts.map { ($0, AccountTag.make(for: $0, among: accounts)) }) : [:]
        return cache
    }

    private var results: [Correspondence] { rows.rows }

    /// What Gmail, Outlook or iCloud's own search found for what's typed.
    private var serverMatches: Set<ThreadID> {
        guard let sync, !appliedSearch.isEmpty,
              sync.moreResultsQuery == appliedSearch.trimmingCharacters(in: .whitespacesAndNewlines) else { return [] }
        return sync.serverMatches
    }

    /// Unread Only applies to Mail's splits, and not while searching:
    /// search looks through everything.
    private var filtersUnread: Bool {
        unreadOnly && destination == .mail && appliedSearch.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// nil while a search's matches are still being found.
    private func buildResults(keeping kept: Set<ThreadID> = []) -> [Correspondence]? {
        guard let results = buildSplit() else { return nil }
        return filtersUnread ? MailFilter.unreadOnly(results, keeping: kept) : results
    }

    private func buildSplit() -> [Correspondence]? {
        let all: [Correspondence]
        let search = appliedSearch
        if let attention = kind.attention, search.trimmingCharacters(in: .whitespaces).isEmpty {
            all = MailQuery.prioritized(scopedThreads, attention: attention)
        } else if search.trimmingCharacters(in: .whitespaces).isEmpty {
            all = MailQuery.filter(scopedThreads, attention: kind.attention, search: search)
        } else {
            // Searched once per change to the mail or the search, off the
            // main thread when the mailbox is large.
            let source: [AnyHashable] = [store.contentRevision, Int(Date.now.timeIntervalSince1970 / 60),
                                         accountFilter, accountsRevision, auth?.accounts.map(\.email) ?? []]
            let request = MailSearch.Request(search: search, attention: kind.attention, serverMatches: serverMatches,
                                             source: source)
            guard let found = searcher.matches(for: request, in: { scopedThreads }, onFound: { searchFound &+= 1 })
            else { return nil }
            all = found
        }
        guard kind == .mail, mailFilter != .everything, mailFilter != .needsYou else { return all }
        // Search looks in every category, as Gmail's and Mail's do: an
        // order confirmation in Updates is still found from Primary.
        let searching = !search.trimmingCharacters(in: .whitespaces).isEmpty
        guard !(searching && mailFilter.isCategory) else { return all }
        let context = CategoryContextCache.context(store)
        let filtered = all.filter { mailFilter.includes($0, context: context) }
        return filtered
    }

    /// Needs You splits into what's due within three days and the rest,
    /// keeping the chronological order inside each group.
    private var dueSoonIDs: Set<ThreadID> { rows.dueSoon }

    private var showingSent: Bool { false }

    /// Who you wrote to: the person who answered, or the first person you
    /// sent it to, by name when Corres has seen them write.
    private func recipientName(for thread: Correspondence) -> String {
        if !thread.isFromAccountOwner { return thread.sender }
        guard let address = thread.toRecipients.first ?? thread.ccRecipients.first else { return thread.sender }
        let bare = address.components(separatedBy: "<").last?.trimmingCharacters(in: CharacterSet(charactersIn: "> ")).lowercased() ?? address
        let name = store.knownSenderNames[bare] ?? thread.counterpartName()
        let others = thread.toRecipients.count + thread.ccRecipients.count - 1
        return name + (others > 0 ? " +\(others)" : "")
    }

    private var showsAccountTags: Bool { accountFilter == nil && (auth?.accounts.count ?? 0) > 1 }

    private func accountTag(for thread: Correspondence) -> AccountTag? {
        guard showsAccountTags else { return nil }
        return rows.tags[thread.id.account] ?? AccountTag.make(for: thread.id.account, among: auth?.accounts.map(\.email) ?? [])
    }

    @Environment(AppRouter.self) private var router
    @Environment(\.openWindow) private var openWindow
    @Environment(\.supportsMultipleWindows) private var supportsMultipleWindows
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
                    #if DEBUG
                    // Screenshots: -ScrollToRow N shows the list scrolled.
                    .task(id: rows.ids.count) {
                        let args = ProcessInfo.processInfo.arguments
                        guard isActive, let flag = args.firstIndex(of: "-ScrollToRow"), flag + 1 < args.count,
                              let row = Int(args[flag + 1]), rows.ids.count > row else { return }
                        try? await Task.sleep(for: .seconds(1))
                        proxy.scrollTo(rows.ids[row], anchor: .top)
                    }
                    #endif
            }
        } else {
            nonScrollingBody
        }
    }

    private func restorePosition(_ proxy: ScrollViewProxy) {
        // Only the list on screen: a tab behind it could take the anchor
        // first, and the list you came back to started at the top.
        guard isActive, let anchor = router.returnAnchor, rows.ids.contains(anchor) else { return }
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
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                Section {
                    if destination == .mail, kind == .needsYou, needsYouLocked {
                        ProLockView(destination: .needsYou, onUnlock: { onUnlockPro?() },
                                    onOpenMail: { mailFilter = .primary }, openMailTitle: String(localized: "Show Primary"))
                            .frame(minHeight: 440)
                    } else {
                        if showsBrief, !visibleBrief.isEmpty { todayBrief }
                        if showsBriefTip, briefTipShown { briefTip }
                        if destination == .mail, kind == .needsYou { needsYouShortcuts }
                        if results.isEmpty {
                            emptyState
                        } else if !rows.top.isEmpty {
                            // As Mail's search: the best matches, then
                            // everything else, newest first.
                            let topIDs = Set(rows.top.map(\.id))
                            groupLabel("Top Results")
                            conversationRows(rows.top)
                            groupLabel("Everything Else")
                            conversationRows(results.filter { !topIDs.contains($0.id) })
                        } else if !dueSoonIDs.isEmpty && dueSoonIDs.count < results.count {
                            groupLabel("Due soon")
                            conversationRows(results.filter { dueSoonIDs.contains($0.id) })
                            groupLabel("When you can")
                            conversationRows(results.filter { !dueSoonIDs.contains($0.id) })
                        } else {
                            conversationRows(results)
                        }
                        olderMailFooter
                        moreResultsFooter
                        saveSearchFooter
                        listFooter
                    }
                } header: {
                    // Pinned: the tabs stay above the mail as it scrolls,
                    // instead of leaving with the first rows.
                    if tabsOnTop, tabsPinned {
                        filterBar
                            .readableWidth()
                            // Frosted like the bar above, so the two read as
                            // one piece when mail scrolls beneath them.
                            .frame(maxWidth: .infinity)
                            .background { Rectangle().fill(CorresPalette.canvas.opacity(0.82)).background(.ultraThinMaterial) }
                            .listRowInsets(EdgeInsets())
                    }
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
            .listStyle(.plain)
            // No gap above the pinned tabs: they follow the summary line.
            .listSectionSpacing(0)
            .environment(\.defaultMinListHeaderHeight, 0)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { listWidth = $0 }
            .scrollContentBackground(.hidden)
            .background(CorresPalette.canvas)
            // The Daily Brief's offer takes a row only while TipKit would show it.
            .task(id: showsBriefTip) {
                guard showsBriefTip else { briefTipShown = false; return }
                for await shows in DailyBriefTip().shouldDisplayUpdates {
                    withAnimation(.snappy) { briefTipShown = shows }
                }
            }
            // VoiceOver's rotor: straight to the next unread or flagged email.
            .accessibilityRotor("Unread") {
                ForEach(results.filter(\.isUnread)) { thread in
                    AccessibilityRotorEntry(Text(verbatim: "\(thread.sender), \(thread.subject)"), id: thread.id)
                }
            }
            .accessibilityRotor("Flagged") {
                ForEach(results.filter(\.isFlagged)) { thread in
                    AccessibilityRotorEntry(Text(verbatim: "\(thread.sender), \(thread.subject)"), id: thread.id)
                }
            }
            // No scrollPosition here: a List keeps its place by itself as a row
            // leaves. Re-anchoring it by id inside the removal's animation
            // made it measure every row above the anchor on every frame;
            // with a few hundred conversations that froze the app on a
            // swipe to Trash until iOS ended it (build 13).
            .onChange(of: rows.ids) { _, newValue in selected.formIntersection(newValue) }
            // The top of the list, read ahead: opening one shows it at once.
            .task(id: isActive ? Array(rows.ids.prefix(8)) : []) {
                guard isActive else { return }
                try? await Task.sleep(for: .milliseconds(400))
                await store.prefetchStoredContent(Array(rows.ids.prefix(8)))
            }
            .onAppear { if !results.isEmpty, !HangReporter.launchMeasured { HangReporter.finish("launch") } }
            .onChange(of: results.isEmpty) { _, empty in if !empty, !HangReporter.launchMeasured { HangReporter.finish("launch") } }
            // Room below the last rows while the Undo pill shows, so any row
            // can be scrolled clear of it; while selecting, the action bar.
            .safeAreaInset(edge: .bottom, spacing: 0) { bottomInset }
            .modifier(TwoFingerSelect(isSelecting: isSelecting, onChange: handleTwoFingerSelect))
            // A light tick per row as a drag selects it, as in Mail.
            .sensoryFeedback(.selection, trigger: selected.count) { _, _ in dragAnchor != nil }
            .toolbar(isSelecting ? .hidden : .automatic, for: .tabBar)
            .toolbar {
                selectionToolbar
                bottomTabsToolbar
            }
            .animation(.snappy(duration: 0.25), value: isSelecting)
            .onChange(of: isSelecting) { _, value in router.isSelecting = value }
            .onDisappear { if isSelecting { endSelection() }; router.isSelecting = false }
            .onChange(of: destination) { endSelection() }
            .onChange(of: mailFilter) { endSelection() }
            .onAppear { if sizeClass == .regular, destination == .mail, mailFilter == .needsYou { mailFilter = .primary } }
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
            .searchable(text: $search, isPresented: searchOpening, prompt: "Search, or ask a question")
            // Outside the search it shrinks to a button beside the bottom tabs.
            .modifier(MinimizedSearch(isOn: tabsOnBottom && Self.hasBottomSearch))
            // Siri's "search my email for…".
            .onChange(of: router.pendingSearch, initial: true) { _, words in
                guard let words else { return }
                router.pendingSearch = nil
                searchPresented = true
                search = words
                #if DEBUG
                // Screenshots: a question is asked, not just typed.
                if ProcessInfo.processInfo.arguments.contains("-Search"), words.hasSuffix("?") { askQuestion(words) }
                #endif
            }
            .searchSuggestions {
                if search.isEmpty {
                    // Questions asked before, one tap to ask again.
                    if let ask {
                        ForEach(ask.recent, id: \.self) { question in
                            Label(question, systemImage: "clock.arrow.circlepath").searchCompletion(question)
                        }
                    }
                    // Gmail's filters work in every account.
                    Label("From someone", systemImage: "person").searchCompletion("from:")
                    Label("Has attachments", systemImage: "paperclip").searchCompletion("has:attachment ")
                    Label("Unread", systemImage: "envelope.badge").searchCompletion("is:unread ")
                    Label("Flagged", systemImage: "flag").searchCompletion("is:flagged ")
                }
            }
            .onSubmit(of: .search) { askQuestion(search.trimmingCharacters(in: .whitespaces)) }
            .onChange(of: search) { _, new in
                if new.isEmpty { ask?.reset() }
            }
            .refreshable { await pullToRefresh() }
            // Debounced: fires 450ms after typing pauses, not per keystroke,
            // and cancels automatically (`.task(id:)`'s own behavior) if the
            // person keeps typing before that. Reaches past what's already
            // synced locally; see GmailSyncService.search's doc comment.
            .task(id: search) {
                // Cleared: the full list straight back. Typing: once it pauses.
                if search.isEmpty { appliedSearch = "" } else {
                    try? await Task.sleep(for: .milliseconds(150))
                    guard !Task.isCancelled else { return }
                    appliedSearch = search
                }
                let accounts = accountFilter.map { [$0] } ?? AccountPreferences.allInboxesAccounts(auth?.accounts.map(\.email) ?? [])
                guard !accounts.isEmpty else { return }
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                if await sync?.search(search, accounts: accounts) == true {
                    await store.refresh()
                }
            }
    }

    /// The spinner waits for new mail, up to a few seconds, not for a long
    /// catch-up: a pull that joined a big first sync (or one that pushes
    /// keep extending) used to leave it spinning at the top for minutes.
    /// The sync carries on, and its mail appears as it lands, as in Mail.
    private func pullToRefresh() async {
        let accounts = auth?.accounts.map(\.email) ?? []
        let syncing = Task { @MainActor in
            #if DEBUG
            // A refresh that takes a while, to see what the screen does then.
            if ProcessInfo.processInfo.arguments.contains("-slowRefresh") { try? await Task.sleep(for: .seconds(30)) }
            #endif
            _ = await sync?.syncAll(accounts: accounts)
            await store.load()
        }
        _ = await waitBriefly(for: syncing, upTo: .seconds(6))
    }

    /// `searchPresented`, reading the mail's text ahead as Search opens
    /// so the first results are quick.
    private var searchOpening: Binding<Bool> {
        Binding(get: { searchPresented }, set: { presented in
            if presented, !searchPresented { MailSearch.prepare(store.threadsIncludingHidden) }
            searchPresented = presented
        })
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
                // An icon, so the title between the buttons ("All Inboxes")
                // always has room to show whole.
                Button { isSelecting = true } label: { Label("Select", systemImage: "checkmark.circle") }
                    .labelStyle(.iconOnly)
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

    private func bulkButton(_ icon: String, _ label: LocalizedStringKey, action: @escaping () async -> Void) -> some View {
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

    private func bulkLabel(_ icon: String, _ label: LocalizedStringKey) -> some View {
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
                    // Counts tick over rather than swap.
                    .contentTransition(.numericText())
                    .animation(.snappy, value: summaryLine)
                // Visible feedback that a search is genuinely reaching past
                // what's already synced, not just quietly finding nothing:
                // see GmailSyncService.search's doc comment.
                if sync?.isSearchingRemote == true {
                    ProgressView().controlSize(.mini)
                    Text("Searching your mail…").font(.subheadline).foregroundStyle(CorresPalette.secondary)
                }
                if destination == .mail, search.trimmingCharacters(in: .whitespaces).isEmpty {
                    Spacer(minLength: 8)
                    unreadOnlyButton
                }
            }
            .padding(.horizontal, CorresSpace.page)
            askSection
            peopleMatches
            // Or with the mail, scrolling away (Keep Tabs in View off).
            if tabsOnTop, !tabsPinned { filterBar }
        }
        .padding(.bottom, 6)
        .readableWidth()
    }

    /// A question typed in search ("when is my flight?") can be answered
    /// from your mail, above the results: Ask, without a screen of its own.
    @ViewBuilder
    private var askSection: some View {
        let typed = search.trimmingCharacters(in: .whitespaces)
        if let ask, Self.looksLikeQuestion(typed) {
            if ask.phase != .idle, ask.question.caseInsensitiveCompare(typed) == .orderedSame {
                AskAnswerCard(ask: ask).padding(.horizontal, CorresSpace.page)
            } else {
                Button { askQuestion(typed) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: needsYouLocked ? "lock" : "sparkle").foregroundStyle(CorresPalette.accent)
                        Text("Answer from your mail").font(.subheadline.weight(.medium)).foregroundStyle(CorresPalette.ink)
                        Spacer(minLength: 8)
                        Image(systemName: "return").font(.footnote).foregroundStyle(CorresPalette.tertiary)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 12)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .corresSurface()
                .padding(.horizontal, CorresSpace.page)
                .accessibilityHint("Answers your question from your own email")
            }
        }
    }

    private func askQuestion(_ question: String) {
        guard let ask, Self.looksLikeQuestion(question) else { return }
        if needsYouLocked { onUnlockPro?(); return }
        ask.ask(question)
    }

    /// "When is my flight?", "what did Sam send", "receipts from Apple
    /// this month": a question or a request, not a name to find. In each
    /// of Corres's languages: Japanese and Chinese have no spaces to count
    /// words by, so they go by their own question words and a long enough
    /// question.
    static func looksLikeQuestion(_ text: String) -> Bool {
        let lowered = text.lowercased()
        let words = lowered.split(whereSeparator: { $0.isWhitespace || $0.isSymbol || ($0.isPunctuation && $0 != "'") })
        let asks = lowered.contains { "?？¿".contains($0) }
        if lowered.unicodeScalars.contains(where: { isUnspacedScript($0) }) {
            let length = lowered.filter { !$0.isWhitespace && !$0.isPunctuation }.count
            guard length >= 4 else { return false }
            return asks || length >= 12 || unspacedQuestionWords.contains { lowered.contains($0) }
        }
        guard words.count >= 3 else { return false }
        if asks { return true }
        if openers.contains(words[0]) { return true }
        // Korean and Bengali put the question word anywhere in the sentence.
        // A one-letter word only on its own ("কি", "왜"); longer ones also
        // with an ending attached ("언제야").
        return words.contains { word in
            anywhereQuestionWords.contains { word == $0 || ($0.count > 1 && word.hasPrefix($0)) }
        }
    }

    /// Han, Hiragana and Katakana: written without spaces between words.
    private static func isUnspacedScript(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF: return true
        default: return false
        }
    }

    private static let openers: Set<Substring> = [
        // English
        "when", "what", "where", "who", "whom", "which", "how", "why", "did", "does", "do",
        "is", "are", "was", "were", "has", "have", "can", "could", "show", "find", "any",
        // German
        "wann", "was", "wo", "wer", "wem", "wen", "wie", "warum", "wieso", "welche", "welcher", "welches",
        "hat", "habe", "hatte", "ist", "sind", "gibt", "kann", "zeig", "zeige", "finde",
        // French
        "quand", "quoi", "que", "qu'est", "qu", "où", "qui", "quel", "quelle", "quels", "quelles",
        "comment", "pourquoi", "combien", "est", "ai", "montre", "trouve",
        // Spanish
        "cuándo", "cuando", "qué", "dónde", "donde", "quién", "quien", "quiénes", "cuál", "cual", "cuáles",
        "cómo", "cuánto", "cuántos", "cuánta", "hay", "tengo", "muestra", "muéstrame", "busca", "encuentra",
        // Portuguese
        "quando", "quê", "onde", "quem", "qual", "quais", "como", "quanto", "quantos", "quanta",
        "tem", "tenho", "há", "mostre", "mostra", "encontre", "ache"
    ]

    private static let anywhereQuestionWords: [String] = [
        // Korean
        "언제", "뭐", "무엇", "무슨", "어디", "누구", "누가", "어떻게", "왜", "어느", "몇", "알려", "보여", "찾아",
        // Bengali
        "কখন", "কী", "কি", "কোথায়", "কে", "কার", "কোন", "কীভাবে", "কিভাবে", "কেন", "কত", "দেখাও", "খুঁজ"
    ]

    private static let unspacedQuestionWords: [String] = [
        // Japanese
        "何", "なに", "いつ", "どこ", "誰", "だれ", "どう", "なぜ", "どれ", "どの", "いくら", "教えて", "ですか", "ますか",
        // Chinese
        "什么", "哪", "谁", "怎么", "为什么", "吗", "几", "多少", "何时", "是否", "有没有"
    ]

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
        let sample = (auth?.accounts.isEmpty ?? true) && !EntitlementStore.isScreenshotMode ? String(localized: " · Sample mail") : ""
        if filtersUnread {
            let unread = rows.unread
            return String(localized: "Unread only") + (unread > 0 ? String(localized: " · \(unread) unread") : "") + sample
        }
        switch kind {
        case .needsYou:
            let due = dueSoonIDs.count
            return (count == 1 ? String(localized: "1 conversation") : String(localized: "\(count) conversations")) + (due > 0 ? String(localized: " · \(due) due soon") : "") + sample
        case .waiting:
            return (count == 1 ? String(localized: "1 conversation waiting on a reply") : String(localized: "\(count) conversations waiting on a reply")) + sample
        default:
            let unread = rows.unread
            return String(localized: "Newest first") + (unread > 0 ? String(localized: " · \(unread) unread") : "") + sample
        }
    }

    /// Mail's filter button: the split you're on, unread only. One tap on,
    /// one tap off; it stays as you move between splits.
    private var unreadOnlyButton: some View {
        Button {
            unreadOnly.toggle()
        } label: {
            Image(systemName: unreadOnly ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                .font(.title3)
                .foregroundStyle(unreadOnly ? CorresPalette.accent : CorresPalette.secondary)
                .frame(minWidth: 44, minHeight: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Unread Only")
        .accessibilityInputLabels([Text("Unread Only"), Text("Unread"), Text("Filter")])
        .accessibilityAddTraits(unreadOnly ? .isSelected : [])
        .popoverTip(UnreadOnlyTip())
        .accessibilityHint("Shows only unread mail in this list")
        .sensoryFeedback(.selection, trigger: unreadOnly)
    }

    /// Room below the last rows while the Undo pill shows; while selecting,
    /// the action bar; before iOS 26, the bottom tabs.
    @ViewBuilder
    private var bottomInset: some View {
        if isSelecting {
            selectionBar
        } else {
            VStack(spacing: 0) {
                if let threadActions { BannerRoom(threadActions: threadActions) }
                // Before iOS 26 there's no bottom search to sit beside.
                if tabsOnBottom, !searchPresented, !Self.hasBottomSearch {
                    bottomTabs.padding(.vertical, 6).frame(maxWidth: .infinity).background(.bar)
                }
            }
        }
    }

    /// Tabs along the bottom are an iPhone choice; iPad has its sidebar.
    private var tabsOnBottom: Bool { destination == .mail && tabsAtBottom && sizeClass != .regular }
    private var tabsOnTop: Bool { destination == .mail && !tabsOnBottom }

    private var tabFilters: [MailFilter] {
        // On iPad the sidebar has Needs You; Mail's splits start at Primary.
        MailFilter.tabs.filter { sizeClass != .regular || $0 != .needsYou }
    }

    /// iOS 26 puts Search at the bottom, where it can shrink to a button
    /// beside the tabs.
    private static var hasBottomSearch: Bool {
        if #available(iOS 26.0, *) { return true }
        return false
    }

    /// The tabs at the bottom, sharing the bar with Search, as Mail's
    /// bottom bar does on iOS 26. Hidden while selecting (the action bar
    /// takes the bottom) and while searching.
    @ToolbarContentBuilder
    private var bottomTabsToolbar: some ToolbarContent {
        if #available(iOS 26.0, *), tabsOnBottom {
            // The search button stays put while searching: taking it away
            // would close the search it just opened.
            if !isSelecting, !searchPresented {
                ToolbarItem(placement: .bottomBar) {
                    // Room for the search button and the bar's margins.
                    bottomTabs.frame(width: max(160, listWidth - 120))
                }
                ToolbarSpacer(.flexible, placement: .bottomBar)
            }
            DefaultToolbarItem(kind: .search, placement: .bottomBar)
        }
    }

    /// The same tabs, as a strip of pills: an underline floats oddly on
    /// glass. The chosen tab scrolls into view.
    private var bottomTabs: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 2) {
                    ForEach(tabFilters) { filter in
                        let chosen = mailFilter == filter
                        Button {
                            mailFilter = filter
                        } label: {
                            Text(filter.title)
                                .font(.subheadline.weight(chosen ? .semibold : .medium))
                                .foregroundStyle(chosen ? CorresPalette.ink : CorresPalette.secondary)
                                .padding(.horizontal, 12)
                                .frame(minHeight: 44)
                                .background {
                                    if chosen { Capsule().fill(CorresPalette.accent.opacity(0.18)).padding(.vertical, 5) }
                                }
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .id(filter)
                        .accessibilityAddTraits(chosen ? .isSelected : [])
                    }
                }
                .padding(.horizontal, 4)
            }
            .trailingFade()
            .onAppear { proxy.scrollTo(mailFilter, anchor: .center) }
            .onChange(of: mailFilter) { _, filter in withAnimation(.snappy) { proxy.scrollTo(filter, anchor: .center) } }
        }
        .sensoryFeedback(.selection, trigger: mailFilter)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tabs")
    }

    /// Underlined text tabs, not chips: they read as views of one list,
    /// which is what they are.
    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 18) {
                ForEach(tabFilters) { filter in
                    Button {
                        mailFilter = filter
                    } label: {
                        Text(filter.title)
                            .font(.subheadline.weight(mailFilter == filter ? .semibold : .medium))
                            .foregroundStyle(mailFilter == filter ? CorresPalette.ink : CorresPalette.secondary)
                            .padding(.vertical, 10)
                            // A full 44-point target, as Apple asks, with the underline at its foot.
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
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

    // MARK: - Daily Brief

    @AppStorage(CorresSettings.briefKey) private var briefOn = false
    @AppStorage(CorresSettings.briefDoneDayKey) private var briefDoneDay = ""

    /// Settings → Sorting → Daily Brief, on Needs You (Mail's split, or
    /// the iPad sidebar's), with Pro, not searching, and not put away for
    /// today with Done for Today.
    private var showsBrief: Bool {
        briefOn && kind == .needsYou && (destination == .mail || destination == .needsYou) && !needsYouLocked
            && appliedSearch.trimmingCharacters(in: .whitespaces).isEmpty
            && briefDoneDay != CorresSettings.briefDay()
    }

    /// Where the Brief would be, while it's off: the one-time offer.
    private var showsBriefTip: Bool {
        !briefOn && kind == .needsYou && (destination == .mail || destination == .needsYou) && !needsYouLocked
            && appliedSearch.trimmingCharacters(in: .whitespaces).isEmpty
    }

    @State private var briefTipShown = false

    private var briefTip: some View {
        let tip = DailyBriefTip()
        return TipView(tip) { action in
            if action.id == DailyBriefTip.showAction {
                withAnimation(.snappy) { briefOn = true }
                tip.invalidate(reason: .actionPerformed)
            } else {
                tip.invalidate(reason: .tipClosed)
            }
        }
        .tipBackground(CorresPalette.surface)
        .padding(.horizontal, CorresSpace.page).padding(.top, 8).padding(.bottom, 2)
        .readableWidth()
        .frame(maxWidth: .infinity)
    }

    /// Built with the rows (once per change to the mail, or a minute
    /// passing), from the same Needs You list, so it never scans the
    /// mailbox on a redraw. Deliveries look only at today's mail.
    private func buildBrief(needsYou: [Correspondence]) -> TodayBrief {
        let now = Date.now
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: now)
        let shipping = scopedThreads.lazy
            .filter { $0.receivedAt >= startOfToday && $0.attention != .handled && $0.mailKind == .shipping }
            .map { thread -> (thread: Correspondence, status: String?) in
                let text = thread.body.isEmpty ? thread.excerpt : thread.body
                return (thread, MailDigest.glance(text: text, subject: thread.subject, kind: .shipping)?.status)
            }
        let deliveries = TodayBrief.arriving(from: Array(shipping)) {
            ($0.senderEmail.flatMap(BrandLogos.domain(of:)) ?? $0.sender).lowercased()
        }
        return TodayBrief.make(needsYou: needsYou, deliveries: deliveries, now: now, calendar: calendar,
                               isMeeting: Self.isMeeting, isPerson: { !$0.looksAutomated && !$0.isFromAccountOwner })
    }

    /// An invitation (it carries an .ics) or an appointment, class or
    /// flight: something that happens at a time, not a task.
    private static func isMeeting(_ thread: Correspondence) -> Bool {
        if thread.attachments.contains(where: {
            $0.mimeType.lowercased().hasPrefix("text/calendar") || $0.filename.lowercased().hasSuffix(".ics") }) { return true }
        if thread.id.account == "sample", SampleCorrespondence.invitation(for: thread) != nil { return true }
        return MailSignals.isEvent(thread.subject + "\n" + thread.excerpt)
    }

    /// What a swipe or a check already took away stays away at once.
    private var visibleBrief: TodayBrief {
        let brief = rows.brief
        let hidden = store.hiddenFromLists
        guard !hidden.isEmpty, brief.top.contains(where: { hidden.contains($0.id) }) else { return brief }
        return TodayBrief(due: brief.due, overdue: brief.overdue, meetings: brief.meetings, deliveries: brief.deliveries,
                          replies: brief.replies, top: brief.top.filter { !hidden.contains($0.id) })
    }

    private var todayBrief: some View {
        TodayBriefCard(brief: visibleBrief, onOpen: openFromBrief, onHandled: handleFromBrief)
            .padding(.horizontal, CorresSpace.page).padding(.top, 8).padding(.bottom, 2)
            .readableWidth()
            .frame(maxWidth: .infinity)
            .transition(.opacity)
    }

    /// Beside the list on iPad; pushed on iPhone, as a row would be.
    private func openFromBrief(_ thread: Correspondence) {
        let route = ConversationRoute(id: thread.id, orderedIDs: rows.ids.contains(thread.id) ? rows.ids : [thread.id])
        if let splitSelection {
            splitSelection.wrappedValue = route
        } else {
            router.pending = .thread(thread.id)
        }
    }

    /// Handled, as the list's swipe does it: out of view at once, with Undo.
    private func handleFromBrief(_ thread: Correspondence) {
        withAnimation(.snappy(duration: 0.3)) { store.hide(thread.id) }
        Task {
            await threadActions?.setAttention(.handled, for: thread)
            store.unhide(thread.id)
        }
    }

    /// Above the Needs You split: replies you're owed, and new senders to
    /// look at. What the Brief's cards were, without leaving the list.
    private var needsYouShortcuts: some View {
        let waiting = rows.waitingCount
        let senders = rows.pendingSenders
        return VStack(spacing: 0) {
            Button { onOpenWaiting?() } label: {
                shortcutRow(icon: "clock",
                            title: waiting == 0 ? "Nothing in Waiting" : waiting == 1 ? "Waiting on 1 reply" : "Waiting on \(waiting) replies",
                            detail: rows.longestWait)
            }
            .buttonStyle(.plain)
            if senders > 0, MailQuery.newSenderMode != .acceptAll, let showingScreener {
                Hairline(leading: 52)
                Button { showingScreener.wrappedValue = true } label: {
                    shortcutRow(icon: "checkmark.shield",
                                title: MailQuery.newSenderMode == .reviewEveryone
                                    ? (senders == 1 ? "1 new sender to approve" : "\(senders) new senders to approve")
                                    : (senders == 1 ? "1 new sender to review" : "\(senders) new senders to review"),
                                detail: nil)
                }
                .buttonStyle(.plain)
            }
        }
        .corresSurface()
        .padding(.horizontal, CorresSpace.page).padding(.top, 8).padding(.bottom, 6)
    }

    private func shortcutRow(icon: String, title: LocalizedStringKey, detail: String?) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon).font(.body).foregroundStyle(CorresPalette.secondary)
                .frame(width: typeSize.isAccessibilitySize ? nil : 24)
            if typeSize.isAccessibilitySize {
                // At the largest sizes the count and the wait each get
                // their own lines rather than both being cut short.
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(CorresPalette.ink)
                    if let detail { Text(detail).font(.subheadline).foregroundStyle(CorresPalette.secondary) }
                }
                Spacer(minLength: 8)
            } else {
                // Side by side when both fit whole; otherwise the wait goes
                // under the count. Neither is ever cut short ("Longest 4…").
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        Text(title).foregroundStyle(CorresPalette.ink).fixedSize()
                        Spacer(minLength: 8)
                        if let detail { Text(detail).font(.subheadline).foregroundStyle(CorresPalette.secondary).fixedSize() }
                    }
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(title).foregroundStyle(CorresPalette.ink)
                            if let detail { Text(detail).font(.subheadline).foregroundStyle(CorresPalette.secondary) }
                        }
                        Spacer(minLength: 8)
                    }
                }
            }
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(CorresPalette.tertiary)
        }
        .padding(.horizontal, 14).padding(.vertical, 13)
        .contentShape(Rectangle())
    }

    private func groupLabel(_ title: LocalizedStringKey) -> some View {
        Text(title).eyebrow()
            .padding(.horizontal, CorresSpace.page).padding(.top, 14).padding(.bottom, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder
    private var listFooter: some View {
        if kind == .needsYou && !results.isEmpty {
            Text("Email that asks something of you, sorted on this \(Device.name). Done with one? Swipe it or tap Handled: it leaves this list, stays in Mail, and waits in Mailboxes \u{2192} Handled. Wrong call? Press and hold to move it.")
                .font(.footnote).foregroundStyle(CorresPalette.tertiary)
                .padding(.horizontal, CorresSpace.page).padding(.vertical, 18)
        } else if kind == .waiting && !results.isEmpty {
            Text("Where you asked someone something, from Corres or any other app, or moved it here yourself. Longest wait first; after three days it's time to follow up. No tracking pixels, no read receipts.")
                .font(.footnote).foregroundStyle(CorresPalette.tertiary)
                .padding(.horizontal, CorresSpace.page).padding(.vertical, 18)
        }
    }

    private var emptyTitle: String {
        if filtersUnread {
            return mailFilter == .everything ? String(localized: "No unread mail") : String(localized: "Nothing unread in \(mailFilter.title)")
        }
        return switch kind {
        case .needsYou: String(localized: "Nothing in Needs You")
        case .waiting: String(localized: "Nothing in Waiting")
        default: mailFilter == .everything ? String(localized: "No mail here") : String(localized: "Nothing in \(mailFilter.title)")
        }
    }

    private var emptyDetail: String {
        if filtersUnread { return String(localized: "Turn off Unread Only to see everything here.") }
        return switch kind {
        case .needsYou: String(localized: "When an email asks something of you, it shows here. The rest of your mail is in Primary.")
        case .waiting: String(localized: "When you reply to someone, or move a conversation here, it waits here until they answer.")
        default: String(localized: "Pull down to check for new mail.")
        }
    }

    /// A question typed in Search is answered above the results; matching
    /// its words against subjects finding nothing isn't worth saying.
    @ViewBuilder
    private var emptyState: some View {
        if ask != nil, Self.looksLikeQuestion(search.trimmingCharacters(in: .whitespaces)) {
            EmptyView()
        } else {
            plainEmptyState
        }
    }

    private var plainEmptyState: some View {
        ContentUnavailableView {
            EmptyTitle(search.isEmpty ? emptyTitle : String(localized: "No conversations found"), systemImage: search.isEmpty ? "checkmark.circle" : "magnifyingglass")
        } description: {
            Text(search.isEmpty ? emptyDetail : String(localized: "Try a name, subject, or organization."))
        } actions: {
            if filtersUnread {
                Button("Show All") { unreadOnly = false }
                    .buttonStyle(.borderless)
            }
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
            SwipeVisual(title: thread.isPinned ? String(localized: "Unpin") : String(localized: "Pin"),
                       systemImage: thread.isPinned ? "pin.slash.fill" : "pin.fill", tint: CorresPalette.swipePin)
        case .unread:
            SwipeVisual(title: thread.isUnread ? String(localized: "Read") : String(localized: "Unread"),
                       systemImage: thread.isUnread ? "envelope.open.fill" : "envelope.badge.fill",
                       tint: CorresPalette.swipeUnread)
        case .flag:
            SwipeVisual(title: thread.isFlagged ? String(localized: "Unflag") : String(localized: "Flag"),
                       systemImage: thread.isFlagged ? "flag.slash.fill" : "flag.fill",
                       tint: CorresPalette.swipeFlag)
        }
    }

    /// A leading swipe as VoiceOver offers it: what it will do to this row.
    private func accessibilityName(for action: LeadingSwipeAction, thread: Correspondence) -> String {
        switch action {
        case .pin: thread.isPinned ? String(localized: "Unpin") : String(localized: "Pin")
        case .unread: thread.isUnread ? String(localized: "Mark as Read") : String(localized: "Mark as Unread")
        case .flag: thread.isFlagged ? String(localized: "Unflag") : String(localized: "Flag")
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
            let leaves = kind != .mail
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
                                           tint: trailingShortAction.tint, removesRow: trailingShortAction.removesRow(in: kind)
                                                && !(trailingShortAction == .trash && confirmTrash)),
                trailingLong: isSelecting ? nil : SwipeVisual(title: trailingLongAction.title, systemImage: trailingLongAction.systemImage,
                                          tint: trailingLongAction.tint, removesRow: trailingLongAction.removesRow(in: kind)
                                               && !(trailingLongAction == .trash && confirmTrash)),
                onLeadingShort: { perform(leadingShortAction, on: thread) },
                onLeadingLong: { perform(leadingLongAction, on: thread) },
                onTrailingShort: { perform(trailingShortAction, on: thread) },
                onTrailingLong: { perform(trailingLongAction, on: thread) }
            ) {
                let row = CorrespondenceRow(thread: thread, showsReason: kind != .mail, accountTag: accountTag(for: thread),
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
            // iPad: drag a conversation into Notes, Reminders or a message.
            .modifier(ConversationDragging(thread: thread, enabled: sizeClass == .regular && !isSelecting))
            .disabled(store.pending.contains(thread.id))
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.visible)
            .listRowSeparatorTint(CorresPalette.line)
            .listRowBackground(splitSelection?.wrappedValue?.id == thread.id ? CorresPalette.accent.opacity(0.12) : Color.clear)
            .alignmentGuide(.listRowSeparatorLeading) { [separatorInset] _ in separatorInset }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { rowFrames.frames[thread.id] = $0 }
            .onAppear {
                // A screenful ahead of the end, so older mail is usually
                // there before you reach it, instead of a spinner at the end.
                if pagesOlderMail, results.suffix(15).contains(where: { $0.id == thread.id }) { loadOlderMail() }
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
            //
            // Named for what each does to this row now ("Unpin" on a pinned
            // one), and not offered in Select mode, where a swipe isn't either.
            .accessibilityActions {
                if !isSelecting {
                    Button(accessibilityName(for: leadingShortAction, thread: thread)) {
                        guard !store.pending.contains(thread.id) else { return }
                        perform(leadingShortAction, on: thread)
                    }
                    Button(accessibilityName(for: leadingLongAction, thread: thread)) {
                        guard !store.pending.contains(thread.id) else { return }
                        perform(leadingLongAction, on: thread)
                    }
                    Button(trailingShortAction.title) {
                        guard !store.pending.contains(thread.id) else { return }
                        perform(trailingShortAction, on: thread)
                    }
                    Button(trailingLongAction.title) {
                        guard !store.pending.contains(thread.id) else { return }
                        perform(trailingLongAction, on: thread)
                    }
                }
            }
        }
    }

    /// "Wrong call?": the correction path for every sort Corres makes.
    /// Moving a thread is the person's own decision and sticks; later
    /// automatic passes never move it back (see ADR 002).
    @ViewBuilder
    private func rowMenu(for thread: Correspondence) -> some View {
        // iPad: beside your mail, in a window of its own.
        if supportsMultipleWindows && sizeClass == .regular {
            Button {
                openWindow(id: ConversationWindow.id, value: thread.id)
            } label: {
                Label("Open in New Window", systemImage: "macwindow.badge.plus")
            }
        }
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
    private var pagesOlderMail: Bool { kind == .mail && search.isEmpty && sync != nil }

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

    /// Keeps a search you'll run again as a mailbox (Mailboxes → Saved
    /// Searches).
    @ViewBuilder
    private var saveSearchFooter: some View {
        if !appliedSearch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !results.isEmpty {
            SaveSearchButton(query: appliedSearch)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(CorresPalette.accent)
                .frame(maxWidth: .infinity).padding(.vertical, 12)
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
        }
    }

    /// Past the first 50 from each account: the next page loads as you
    /// reach the end of the results, or with a tap.
    @ViewBuilder
    private var moreResultsFooter: some View {
        if let sync, !appliedSearch.isEmpty, !results.isEmpty,
           sync.moreResultsQuery == appliedSearch.trimmingCharacters(in: .whitespacesAndNewlines) {
            if sync.isSearchingRemote {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Searching your mail…").font(.footnote).foregroundStyle(CorresPalette.secondary)
                }
                .frame(maxWidth: .infinity).padding(.vertical, 16)
                .listRowSeparator(.hidden)
            } else if !sync.moreResults.isEmpty {
                Button { Task { await showMoreResults() } } label: {
                    Text("Show More Results").font(.subheadline.weight(.medium)).foregroundStyle(CorresPalette.accent)
                        .frame(maxWidth: .infinity).padding(.vertical, 16)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowSeparator(.hidden)
                .onAppear { Task { await showMoreResults() } }
            }
        }
    }

    private func showMoreResults() async {
        if await sync?.searchMore() == true { await store.refresh() }
    }

    /// Used only by the offline preview-render script; List does not render through ImageRenderer.
    /// Mirrors the same flat, divider-separated look conversationRows gets
    /// from List's own row separators, since a plain VStack has none built in.
    private var staticContent: some View {
        VStack(alignment: .leading, spacing: 24) {
            header
            if destination == .mail { filterBar }
            if results.isEmpty {
                emptyState
            } else {
                let orderedIDs = results.map(\.id)
                VStack(spacing: 0) {
                    ForEach(Array(results.enumerated()), id: \.element.id) { index, thread in
                        NavigationLink(value: ConversationRoute(id: thread.id, orderedIDs: orderedIDs)) {
                            CorrespondenceRow(thread: thread, showsReason: kind != .mail)
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
        if #available(iOS 26.0, macOS 26.0, *) {
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


/// Room under the list for the Undo pill. Its own view, so the pill coming
/// and going redraws this spacer and not the whole list on every tab.
private struct BannerRoom: View {
    let threadActions: ThreadActionService
    var body: some View {
        Color.clear.frame(height: threadActions.pendingRemoval == nil && threadActions.lastChange == nil ? 0 : 56)
    }
}

/// On iPad, a row can be dragged out as a link to the conversation. Off on
/// iPhone, where a long press is for the menu and swipes come first.
private struct ConversationDragging: ViewModifier {
    let thread: Correspondence
    let enabled: Bool

    func body(content: Content) -> some View {
        if enabled, let link = MailReminders.link(to: thread.id) {
            content.draggable(ConversationDrag(sender: thread.sender, subject: thread.subject, link: link))
        } else {
            content
        }
    }
}

/// Search as a button beside the bottom tabs (iOS 26), opening to the full
/// field when tapped.
private struct MinimizedSearch: ViewModifier {
    let isOn: Bool

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *), isOn {
            content.searchToolbarBehavior(.minimize)
        } else {
            content
        }
    }
}
