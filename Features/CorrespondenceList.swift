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
    /// Same `UserDefaults` key `PreferencesView`'s own picker reads/writes;
    /// `@AppStorage` keeps both in sync automatically, the same pattern
    /// `corres.appearance` already uses across multiple independent views.
    @AppStorage("corres.primarySwipeAction") private var primarySwipeActionRaw = PrimarySwipeAction.archive.rawValue
    private var primarySwipeAction: PrimarySwipeAction { PrimarySwipeAction(rawValue: primarySwipeActionRaw) ?? .archive }
    @AppStorage("corres.primaryLeadingSwipeAction") private var primaryLeadingSwipeActionRaw = LeadingSwipeAction.pin.rawValue
    private var primaryLeadingSwipeAction: LeadingSwipeAction { LeadingSwipeAction(rawValue: primaryLeadingSwipeActionRaw) ?? .pin }
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

    // Archive/Trash/Handled/Pin/Unread are each their own `@ViewBuilder`
    // property (not one switch-based helper called through a `ForEach`,
    // which is how these were first written): reported directly against a
    // real device that only the full-swipe trigger worked and the partial
    // swipe never revealed the row of buttons at all. `ForEach`-generated
    // swipe actions are a documented-fragile pattern — SwiftUI's own
    // swipe-action recognition wants literal `Button` values directly in
    // the `.swipeActions` closure, not values produced through a dynamic
    // `ForEach`/indirection, even when the type-checker is perfectly happy
    // with it. `orderedTrailingActions`/`orderedLeadingActions` below still
    // decide the order; `.swipeActions` just gets each button written out
    // directly per branch instead of iterated.
    @ViewBuilder
    private func archiveButton(_ thread: Correspondence) -> some View {
        Button {
            Task { await threadActions?.archive(thread) }
        } label: { Label("Archive", systemImage: "archivebox") }
        .tint(CorresPalette.swipeArchive)
    }

    @ViewBuilder
    private func trashButton(_ thread: Correspondence) -> some View {
        Button(role: .destructive) {
            Task { await threadActions?.trash(thread) }
        } label: { Label("Trash", systemImage: "trash") }
        .tint(CorresPalette.swipeTrash)
    }

    @ViewBuilder
    private func handledButton(_ thread: Correspondence) -> some View {
        Button {
            Task { await store.update(thread.id, to: .handled) }
        } label: { Label("Handled", systemImage: "checkmark") }
        .tint(CorresPalette.swipeHandled)
    }

    @ViewBuilder
    private func pinButton(_ thread: Correspondence) -> some View {
        Button {
            Task { await store.setPinned(!thread.isPinned, for: thread.id) }
        } label: { Label(thread.isPinned ? "Unpin" : "Pin", systemImage: thread.isPinned ? "pin.slash" : "pin") }
        .tint(CorresPalette.swipePin)
    }

    @ViewBuilder
    private func unreadButton(_ thread: Correspondence) -> some View {
        Button {
            Task { await threadActions?.setUnread(!thread.isUnread, for: thread) }
        } label: {
            Label(thread.isUnread ? "Read" : "Unread",
                  systemImage: thread.isUnread ? "envelope.open" : "envelope.badge")
        }
        .tint(CorresPalette.swipeSnooze)
    }

    @ViewBuilder
    private func trailingSwipeButtons(for thread: Correspondence) -> some View {
        // Each branch lists the same three buttons directly, just
        // reordered, rather than looking the order up dynamically: see the
        // doc comment above these buttons for why.
        switch primarySwipeAction {
        case .archive:
            archiveButton(thread)
            trashButton(thread)
            handledButton(thread)
        case .trash:
            trashButton(thread)
            archiveButton(thread)
            handledButton(thread)
        case .handled:
            handledButton(thread)
            archiveButton(thread)
            trashButton(thread)
        }
    }

    @ViewBuilder
    private func leadingSwipeButtons(for thread: Correspondence) -> some View {
        switch primaryLeadingSwipeAction {
        case .pin:
            pinButton(thread)
            unreadButton(thread)
        case .unread:
            unreadButton(thread)
            pinButton(thread)
        }
    }

    private var conversationRows: some View {
        let orderedIDs = results.map(\.id)
        return ForEach(results) { thread in
            NavigationLink(value: ConversationRoute(id: thread.id, orderedIDs: orderedIDs)) {
                CorrespondenceRow(thread: thread)
            }
                .disabled(store.pending.contains(thread.id))
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.visible)
                .listRowSeparatorTint(CorresPalette.line)
                .swipeActions(edge: .trailing) {
                    // SwiftUI triggers whichever action is listed FIRST on a
                    // full swipe; `trailingSwipeButtons` puts the person's
                    // own chosen primary action there (Preferences → Swipe
                    // Actions), defaulting to Archive, matching Apple Mail's
                    // own default (recoverable from All Mail, unlike a full
                    // swipe defaulting straight to Trash).
                    trailingSwipeButtons(for: thread)
                    Menu {
                        ForEach(SnoozeOption.allCases, id: \.self) { option in
                            Button(option.title) { Task { await store.snooze(thread.id, until: option.date()) } }
                        }
                    } label: { Label("Snooze", systemImage: "moon") }
                    .tint(CorresPalette.swipeSnooze)
                }
                .swipeActions(edge: .leading) {
                    // The person's chosen primary (Preferences → Swipe
                    // Actions) always leads, so it's genuinely what a full
                    // swipe does; "Needs You" moves to last rather than
                    // first (its old fixed position) specifically so it
                    // never silently overrides that choice on a full swipe
                    // whenever it happens to be showing.
                    leadingSwipeButtons(for: thread)
                    if thread.attention != .needsYou {
                        Button {
                            Task { await store.update(thread.id, to: .needsYou) }
                        } label: { Label("Needs You", systemImage: "exclamationmark.circle") }
                        .tint(CorresPalette.midnight)
                    }
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
