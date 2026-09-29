import SwiftUI

/// A flat, dense row in the Mail/Spark list anatomy: unread dot, a round
/// monogram, sender and time, subject, a one-line preview, and, in the
/// curated lists, the one-line reason it's there.
struct CorrespondenceRow: View {
    let thread: Correspondence
    /// The "why this is here" line; shown in Needs You, Waiting, and the Brief.
    var showsReason = false
    /// A short account marker, shown only in the merged view of several accounts.
    var accountTag: String?
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
            if showAvatars { CorrespondentAvatar(initials: thread.initials) }
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(sentTo.map { "To: \($0)" } ?? thread.sender)
                        .font(.body.weight(thread.isUnread ? .semibold : .medium))
                        .foregroundStyle(thread.isUnread ? CorresPalette.ink : CorresPalette.secondary)
                        .lineLimit(typeSize.isAccessibilitySize ? 2 : 1)
                    if thread.isFlagged {
                        Image(systemName: "flag.fill").font(.caption2).foregroundStyle(CorresPalette.flag)
                            .accessibilityLabel("Flagged")
                    }
                    if thread.isPinned {
                        Image(systemName: "pin.fill").font(.caption2).foregroundStyle(CorresPalette.tertiary)
                            .accessibilityLabel("Pinned")
                    }
                    if !thread.attachments.isEmpty {
                        Image(systemName: "paperclip").font(.caption2).foregroundStyle(CorresPalette.tertiary)
                            .accessibilityLabel("Has attachments")
                    }
                    Spacer(minLength: 6)
                    if let accountTag {
                        Text(accountTag)
                            .font(.caption2.weight(.semibold)).tracking(0.4)
                            .foregroundStyle(CorresPalette.tertiary)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(CorresPalette.line, lineWidth: 1))
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
                            DueChip(date: due)
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
enum MailFilter: String, CaseIterable, Identifiable {
    case everything = "Everything", unread = "Unread", people = "People", flagged = "Flagged", sent = "Sent", updates = "Updates"
    var id: String { rawValue }

    func includes(_ thread: Correspondence) -> Bool {
        switch self {
        case .everything: true
        case .unread: thread.isUnread
        case .flagged: thread.isFlagged
        case .sent: thread.lastSentAt != nil
        case .people: InboxClassifier.bulkKind(labelIds: thread.labelIds, looksAutomated: thread.looksAutomated) == nil
        case .updates: InboxClassifier.bulkKind(labelIds: thread.labelIds, looksAutomated: thread.looksAutomated) != nil
        }
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
    @State private var search = ""
    @State private var mailFilter = MailFilter.everything
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
        guard let accountFilter else { return store.threads }
        return store.threads.filter { $0.id.account == accountFilter }
    }

    private var results: [Correspondence] {
        let all: [Correspondence]
        if let attention = destination.attention, search.trimmingCharacters(in: .whitespaces).isEmpty {
            all = MailQuery.prioritized(scopedThreads, attention: attention)
        } else {
            all = MailQuery.filter(scopedThreads, attention: destination.attention, search: search)
        }
        guard destination == .mail, mailFilter != .everything else { return all }
        let filtered = all.filter(mailFilter.includes)
        // Sent reads like a Sent mailbox: by when you sent, newest first.
        guard mailFilter == .sent else { return filtered }
        return filtered.sorted { ($0.lastSentAt ?? .distantPast) > ($1.lastSentAt ?? .distantPast) }
    }

    /// Needs You splits into what's due within three days and the rest,
    /// keeping the chronological order inside each group.
    private var dueSoonIDs: Set<ThreadID> {
        guard destination == .needsYou else { return [] }
        let horizon = Date.now.addingTimeInterval(3 * 86_400)
        return Set(results.filter { ($0.dueAt ?? .distantFuture) <= horizon }.map(\.id))
    }

    private var showingSent: Bool { destination == .mail && mailFilter == .sent }

    /// Who you wrote to: the person who answered, or the first person you
    /// sent it to, by name when Corres has seen them write.
    private func recipientName(for thread: Correspondence) -> String {
        if !thread.isFromAccountOwner { return thread.sender }
        guard let address = thread.toRecipients.first ?? thread.ccRecipients.first else { return thread.sender }
        let name = store.threads.first { $0.senderEmail?.lowercased() == address }?.sender
        let others = thread.toRecipients.count + thread.ccRecipients.count - 1
        return (name ?? address) + (others > 0 ? " +\(others)" : "")
    }

    private var showsAccountTags: Bool { accountFilter == nil && (auth?.accounts.count ?? 0) > 1 }

    private func accountTag(for thread: Correspondence) -> String? {
        guard showsAccountTags else { return nil }
        let local = thread.id.account.components(separatedBy: "@").first ?? thread.id.account
        return String(local.prefix(8)).uppercased()
    }

    @Environment(AppRouter.self) private var router
    @AppStorage(CorresSettings.confirmTrashKey) private var confirmTrash = false
    @State private var confirmingTrash: Correspondence?
    @AppStorage(CorresSettings.showAvatarsKey) private var showAvatarsInList = true
    @State private var isSelecting = false
    @State private var rowFrames = RowFrames()
    /// The two-finger drag's starting row and what was selected before it.
    @State private var dragAnchor: (index: Int, before: Set<ThreadID>)?
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
            .onChange(of: results) { oldValue, newValue in
                guard let anchor = scrollPosition, !newValue.contains(where: { $0.id == anchor }),
                      let oldIndex = oldValue.firstIndex(where: { $0.id == anchor }) else { return }
                // Whatever the disappeared thread's own former neighbor is
                // now sits at (or near) the same index; re-anchor to it so
                // the list holds its position instead of resetting, the
                // same "next email is right where I left it" continuity a
                // premium mail client is expected to have.
                if newValue.indices.contains(oldIndex) {
                    scrollPosition = newValue[oldIndex].id
                } else {
                    scrollPosition = newValue.last?.id
                }
            }
            // Room below the last rows while the Undo pill shows, so any row
            // can be scrolled clear of it; while selecting, the action bar.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if isSelecting {
                    selectionBar
                } else {
                    Color.clear.frame(height: threadActions?.pendingRemoval == nil ? 0 : 56)
                }
            }
            .modifier(TwoFingerSelect(onChange: handleTwoFingerSelect))
            .toolbar(isSelecting ? .hidden : .automatic, for: .tabBar)
            .toolbar { selectionToolbar }
            .animation(.snappy(duration: 0.25), value: isSelecting)
            .onChange(of: results.map(\.id)) { _, ids in selected.formIntersection(ids) }
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
                SnoozeSheet { date in Task { await store.snooze(thread.id, until: date) } }
            }
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
                let accounts = accountFilter.map { [$0] } ?? (auth?.accounts.map(\.email) ?? [])
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

    /// Two fingers down a list: select everything from the row where they
    /// started to the row under them now, as in Mail. Dragging back up
    /// unselects the rows left behind; what was already selected stays.
    private func handleTwoFingerSelect(_ state: UIGestureRecognizer.State, _ point: CGPoint) {
        let order = results.map(\.id)
        switch state {
        case .began:
            guard let id = rowFrames.id(at: point, in: order), let index = order.firstIndex(of: id) else { return }
            if !isSelecting { isSelecting = true }
            dragAnchor = (index, selected)
            selected.insert(id)
        case .changed:
            guard let anchor = dragAnchor, let id = rowFrames.id(at: point, in: order),
                  let index = order.firstIndex(of: id) else { return }
            let run = order[min(anchor.index, index)...max(anchor.index, index)]
            let next = anchor.before.union(run)
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
                for thread in chosen { await threadActions?.setUnread(!anyUnread, for: thread) }
            }
            bulkButton(anyUnflagged ? "flag" : "flag.slash", anyUnflagged ? "Flag" : "Unflag") {
                for thread in chosen { await threadActions?.setFlagged(anyUnflagged, for: thread) }
            }
            Menu {
                ForEach([Attention.needsYou, .waiting, .quiet, .handled], id: \.self) { attention in
                    Button(attention.title) {
                        Task {
                            for thread in chosen { await store.update(thread.id, to: attention) }
                            endSelection()
                        }
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
                    Text("Searching Gmail…").font(.subheadline).foregroundStyle(CorresPalette.secondary)
                }
            }
            .padding(.horizontal, CorresSpace.page)
            if destination == .mail { filterBar }
        }
        .padding(.bottom, 6)
        .readableWidth()
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
            let unread = results.filter(\.isUnread).count
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
            Text("Sorted on this iPhone. Wrong call? Press and hold a conversation to move it.")
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
                await store.update(thread.id, to: .handled)
                if leaves { store.unhide(thread.id) }
            }
        }
    }

    private func perform(_ action: LeadingSwipeAction, on thread: Correspondence) {
        switch action {
        case .pin: Task { await store.setPinned(!thread.isPinned, for: thread.id) }
        case .unread: Task { await threadActions?.setUnread(!thread.isUnread, for: thread) }
        case .flag: Task { await threadActions?.setFlagged(!thread.isFlagged, for: thread) }
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
        let orderedIDs = results.map(\.id)
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
                                            sentTo: showingSent ? recipientName(for: thread) : nil)
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
            .alignmentGuide(.listRowSeparatorLeading) { _ in showAvatarsInList ? 77 : 25 }
            .id(thread.id)
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
        Section("Move to") {
            ForEach([Attention.needsYou, .waiting, .quiet, .handled], id: \.self) { attention in
                if attention != thread.attention {
                    Button(attention.title) { Task { await store.update(thread.id, to: attention) } }
                }
            }
        }
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
            Task { await threadActions?.setFlagged(!thread.isFlagged, for: thread) }
        } label: {
            Label(thread.isFlagged ? "Unflag" : "Flag", systemImage: thread.isFlagged ? "flag.slash" : "flag")
        }
        Button {
            Task { await threadActions?.setUnread(!thread.isUnread, for: thread) }
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
        let accounts = accountFilter.map { [$0] } ?? auth.accounts.map(\.email)
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


/// The two-finger selection drag where it exists (iOS 18+).
private struct TwoFingerSelect: ViewModifier {
    let onChange: (UIGestureRecognizer.State, CGPoint) -> Void

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.gesture(TwoFingerSelectGesture(onChange: onChange))
        } else {
            content
        }
    }
}
