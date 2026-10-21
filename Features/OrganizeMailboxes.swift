import SwiftUI

/// Mailboxes → Muted: conversations you muted, to bring one back.
struct MutedView: View {
    let store: MailStore
    let accounts: [String]
    private var organizer: Organizer { .shared }

    private var rows: [Correspondence] {
        store.searchableThreads
            .filter { (accounts.isEmpty || accounts.contains($0.id.account)) && organizer.isMuted($0.id) }
            .sorted { $0.receivedAt > $1.receivedAt }
    }

    var body: some View {
        let rows = rows
        let ids = rows.map(\.id)
        List {
            ForEach(rows) { thread in
                NavigationLink(value: ConversationRoute(id: thread.id, orderedIDs: ids)) {
                    CorrespondenceRow(thread: thread, accountTag: nil)
                }
                .hidingDisclosureIndicator()
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                    Button { organizer.unmute(thread.id) } label: { Label("Unmute", systemImage: "bell") }
                        .tint(CorresPalette.accent)
                }
                .contextMenu {
                    Button { organizer.unmute(thread.id) } label: { Label("Unmute", systemImage: "bell") }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(CorresPalette.canvas)
        .navigationTitle("Muted")
        .overlay {
            if rows.isEmpty {
                ContentUnavailableView {
                    EmptyTitle("Nothing Muted", systemImage: "bell.slash")
                } description: {
                    Text("Mute a conversation from its ⋯ menu. New replies stay out of your lists and silent, unless one is written to you alone.")
                }
            }
        }
    }
}

/// A saved search, run again each time it's opened.
struct SavedSearchView: View {
    let search: SavedSearch
    let store: MailStore
    let accounts: [String]
    @State private var confirmingDelete = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let rows = MailQuery.filter(store.searchableThreads.filter { accounts.isEmpty || accounts.contains($0.id.account) },
                                    search: search.query)
        let ids = rows.map(\.id)
        List {
            Section {
                ForEach(rows) { thread in
                    NavigationLink(value: ConversationRoute(id: thread.id, orderedIDs: ids)) {
                        CorrespondenceRow(thread: thread, accountTag: nil)
                    }
                    .hidingDisclosureIndicator()
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }
            } header: {
                Text(search.query).textCase(nil).font(.subheadline.monospaced())
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(CorresPalette.canvas)
        .navigationTitle(search.name)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Remove Saved Search", role: .destructive) { confirmingDelete = true }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .accessibilityLabel("More")
            }
        }
        .confirmationDialog("Remove \u{201C}\(search.name)\u{201D}?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                Organizer.shared.delete(search: search.id)
                dismiss()
            }
        } message: {
            Text("Only the saved search goes. Your mail isn't changed.")
        }
        .overlay {
            if rows.isEmpty {
                ContentUnavailableView {
                    EmptyTitle("Nothing Matches", systemImage: "magnifyingglass")
                } description: {
                    Text("Mail matching \u{201C}\(search.query)\u{201D} shows here as it arrives.")
                }
            }
        }
    }
}
