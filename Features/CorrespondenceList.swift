import SwiftUI

/// A flat, dense row (avatar, sender, date, subject, one-line preview),
/// matching Mail and Spark's actual list anatomy rather than the card-heavy,
/// four-line row this replaced: no per-row bordered/shadowed card, no
/// trailing chevron (neither reference shows one in a plain list), and a
/// date now shown on every row (previously missing entirely). The attention
/// text pill is also gone; a destination-filtered list (Needs You, Waiting)
/// already tells you the attention state by which screen you're on, and
/// neither Mail nor Spark labels attention with per-row text, they use
/// color, which corresSurface's list styling doesn't have a slot for yet.
struct CorrespondenceRow: View {
    let thread: Correspondence

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack(alignment: .topTrailing) {
                CorrespondentAvatar(initials: thread.initials)
                if thread.isUnread {
                    Circle().fill(CorresPalette.accent).frame(width: 9, height: 9)
                        .accessibilityLabel("Unread")
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(thread.sender).font(.subheadline.weight(thread.isUnread ? .bold : .semibold)).lineLimit(1)
                    if thread.isPinned {
                        Image(systemName: "pin.fill").font(.caption2).foregroundStyle(CorresPalette.champagne)
                            .accessibilityLabel("Pinned")
                    }
                    Spacer(minLength: 8)
                    if thread.dueAt != nil && thread.attention == .needsYou {
                        Image(systemName: "clock").font(.caption2).foregroundStyle(CorresPalette.secondary)
                            .accessibilityLabel("Due soon")
                    }
                    Text(thread.receivedAt, format: .dateTime.month(.abbreviated).day())
                        .font(.caption).foregroundStyle(CorresPalette.secondary)
                }
                Text(thread.subject).font(.subheadline.weight(.medium)).lineLimit(1)
                Text(thread.excerpt).font(.footnote)
                    .foregroundStyle(CorresPalette.secondary).lineLimit(1)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
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
        MailQuery.filter(scopedThreads, attention: destination.attention, search: search)
    }

    var body: some View {
        if scrolls {
            List {
                Section {
                    header
                    if results.isEmpty { emptyState } else { conversationRows }
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
        } else {
            ScrollView { staticContent }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            SculptedBadge(glyph: destination.glyph).padding(.bottom, 8)
            Text(destination.rawValue).font(CorresType.display)
            Text(subtitle).foregroundStyle(CorresPalette.secondary)
            HStack(spacing: 6) {
                Text("\(results.count) conversations" + ((auth?.accounts.isEmpty ?? true) ? " · Sample mail" : ""))
                    .font(CorresType.label).foregroundStyle(CorresPalette.secondary)
                // Visible feedback that a search is genuinely reaching past
                // what's already synced, not just quietly finding nothing:
                // see GmailSyncService.search's doc comment.
                if sync?.isSearchingRemote == true {
                    ProgressView().controlSize(.mini)
                    Text("Searching Gmail…").font(CorresType.label).foregroundStyle(CorresPalette.secondary)
                }
            }
        }
        .padding(.horizontal, CorresSpace.page).padding(.top, CorresSpace.page).padding(.bottom, CorresSpace.medium)
        // Order matters: expand to fill the available width (left-aligned)
        // FIRST, then cap that already-full-width box at 680pt. The reverse
        // order (cap first, expand second) caps a box that's still only as
        // wide as its own text content, then centers that narrow box in the
        // remaining space by .frame(maxWidth: .infinity)'s own default
        // alignment, exactly the "header floating in the middle of the
        // screen while the list below is flush left" bug this was.
        .frame(maxWidth: .infinity, alignment: .leading).frame(maxWidth: 680)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(search.isEmpty ? "Room to breathe" : "No conversations found", systemImage: search.isEmpty ? "checkmark.circle" : "magnifyingglass")
        } description: {
            Text(search.isEmpty ? "There is nothing here that needs attention." : "Try a name, subject, or organization.")
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
                       tint: CorresPalette.swipeSnooze)
        }
    }

    private func perform(_ action: PrimarySwipeAction, on thread: Correspondence) {
        switch action {
        case .archive: Task { await threadActions?.archive(thread) }
        case .trash: Task { await threadActions?.trash(thread) }
        case .handled: Task { await store.update(thread.id, to: .handled) }
        }
    }

    private func perform(_ action: LeadingSwipeAction, on thread: Correspondence) {
        switch action {
        case .pin: Task { await store.setPinned(!thread.isPinned, for: thread.id) }
        case .unread: Task { await threadActions?.setUnread(!thread.isUnread, for: thread) }
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
    private var conversationRows: some View {
        let orderedIDs = results.map(\.id)
        return ForEach(results) { thread in
            PremiumSwipeRow(
                leadingShort: leadingVisual(for: leadingShortAction, thread: thread),
                leadingLong: leadingVisual(for: leadingLongAction, thread: thread),
                trailingShort: SwipeVisual(title: trailingShortAction.title, systemImage: trailingShortAction.systemImage, tint: trailingShortAction.tint),
                trailingLong: SwipeVisual(title: trailingLongAction.title, systemImage: trailingLongAction.systemImage, tint: trailingLongAction.tint),
                onLeadingShort: { perform(leadingShortAction, on: thread) },
                onLeadingLong: { perform(leadingLongAction, on: thread) },
                onTrailingShort: { perform(trailingShortAction, on: thread) },
                onTrailingLong: { perform(trailingLongAction, on: thread) }
            ) {
                NavigationLink(value: ConversationRoute(id: thread.id, orderedIDs: orderedIDs)) {
                    CorrespondenceRow(thread: thread)
                }
            }
            .disabled(store.pending.contains(thread.id))
            .listRowInsets(EdgeInsets())
            .listRowSeparator(.visible)
            .listRowSeparatorTint(CorresPalette.line)
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
                            CorrespondenceRow(thread: thread)
                        }
                        if index < results.count - 1 { Divider().padding(.leading, 76) }
                    }
                }
                .corresSurface()
                .padding(.horizontal, CorresSpace.page)
                .frame(maxWidth: .infinity, alignment: .leading).frame(maxWidth: 680)
            }
        }
    }

    private var subtitle: String {
        switch destination {
        case .needsYou: "Decisions, invitations, and promises to keep."
        case .waiting: "The conversations you have moved forward."
        default: "Every conversation, in its place."
        }
    }
}
