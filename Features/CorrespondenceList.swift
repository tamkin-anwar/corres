import SwiftUI

struct CorrespondenceRow: View {
    let thread: Correspondence

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            CorrespondentAvatar(initials: thread.initials)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Text(thread.sender).font(.subheadline.weight(.semibold))
                    if thread.isPinned {
                        Image(systemName: "pin.fill").font(.caption2).foregroundStyle(CorresPalette.champagne)
                            .accessibilityLabel("Pinned")
                    }
                }
                Text(thread.organization).font(.caption).foregroundStyle(CorresPalette.secondary)
                Text(thread.subject).font(.body.weight(.medium)).fixedSize(horizontal: false, vertical: true)
                Text(thread.excerpt).font(.subheadline)
                    .foregroundStyle(CorresPalette.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 5) {
                    if thread.dueAt != nil && thread.attention == .needsYou {
                        Image(systemName: "clock").accessibilityLabel("Due soon")
                    }
                    Text(thread.attention.title)
                }
                .font(.caption.weight(.medium)).foregroundStyle(CorresPalette.accent)
                .padding(.horizontal, 9).padding(.vertical, 5)
                .background(CorresPalette.accent.opacity(0.07), in: Capsule()).padding(.top, 3)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption2.weight(.semibold))
                .foregroundStyle(CorresPalette.secondary).padding(.top, 6).accessibilityHidden(true)
        }
        .padding(20)
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
            Text("\(results.count) conversations · Sample mail")
                .font(CorresType.label).foregroundStyle(CorresPalette.secondary)
        }
        .padding(.horizontal, CorresSpace.page).padding(.top, CorresSpace.page).padding(.bottom, CorresSpace.medium)
        .frame(maxWidth: 680).frame(maxWidth: .infinity)
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
        ForEach(results) { thread in
            NavigationLink(value: thread.id) { CorrespondenceRow(thread: thread).corresSurface() }
                .buttonStyle(CorresRowButtonStyle())
                .disabled(store.pending.contains(thread.id))
                .padding(.horizontal, CorresSpace.page).padding(.vertical, 7)
                .frame(maxWidth: 680).frame(maxWidth: .infinity)
                .swipeActions(edge: .trailing) {
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
    private var staticContent: some View {
        VStack(alignment: .leading, spacing: 24) {
            header
            if results.isEmpty {
                emptyState
            } else {
                VStack(spacing: 14) {
                    ForEach(results) { thread in
                        NavigationLink(value: thread.id) { CorrespondenceRow(thread: thread).corresSurface() }
                            .buttonStyle(CorresRowButtonStyle())
                    }
                }
                .padding(.horizontal, CorresSpace.page).frame(maxWidth: 680).frame(maxWidth: .infinity)
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
