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
            CorrespondentAvatar(initials: thread.initials)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(thread.sender).font(.subheadline.weight(.semibold)).lineLimit(1)
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
    @State private var search = ""

    private var results: [Correspondence] {
        MailQuery.filter(store.threads, attention: destination.attention, search: search)
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
            .searchable(text: $search, prompt: "Search conversations")
            .refreshable {
                _ = await sync?.syncIfConnected(account: auth?.account?.email)
                await store.load()
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
            Text("\(results.count) conversations" + (auth?.account == nil ? " · Sample mail" : ""))
                .font(CorresType.label).foregroundStyle(CorresPalette.secondary)
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
                    // SwiftUI triggers the FIRST action listed here on a full
                    // swipe. Archive first, not Trash: matches Apple Mail's
                    // own default (full swipe archives, recoverable from All
                    // Mail; trashing needs a deliberate tap), which matters
                    // more than usual right now given the trust this batch
                    // is trying to build, not erode with an accidental delete.
                    Button {
                        Task { await threadActions?.archive(thread) }
                    } label: { Label("Archive", systemImage: "archivebox") }
                    .tint(CorresPalette.swipeArchive)
                    Button(role: .destructive) {
                        Task { await threadActions?.trash(thread) }
                    } label: { Label("Trash", systemImage: "trash") }
                    .tint(CorresPalette.swipeTrash)
                    Button {
                        Task { await store.update(thread.id, to: .handled) }
                    } label: { Label("Handled", systemImage: "checkmark") }
                    .tint(CorresPalette.swipeHandled)
                    Menu {
                        ForEach(SnoozeOption.allCases, id: \.self) { option in
                            Button(option.title) { Task { await store.snooze(thread.id, until: option.date()) } }
                        }
                    } label: { Label("Snooze", systemImage: "moon") }
                    .tint(CorresPalette.swipeSnooze)
                }
                .swipeActions(edge: .leading) {
                    if thread.attention != .needsYou {
                        Button {
                            Task { await store.update(thread.id, to: .needsYou) }
                        } label: { Label("Needs You", systemImage: "exclamationmark.circle") }
                        .tint(CorresPalette.midnight)
                    }
                    Button {
                        Task { await store.setPinned(!thread.isPinned, for: thread.id) }
                    } label: { Label(thread.isPinned ? "Unpin" : "Pin", systemImage: thread.isPinned ? "pin.slash" : "pin") }
                    .tint(CorresPalette.swipePin)
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
