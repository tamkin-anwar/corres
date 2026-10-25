import SwiftUI

/// Needs You at the top, as Corres opens on it; then your mail's splits,
/// each account's own inbox, and the places mail waits.
struct MacSidebar: View {
    let services: MacServices
    @Bindable var model: MacMailboxModel
    /// Conversations dropped on a mailbox.
    var onDrop: (MacMailbox, [ThreadID]) -> Void = { _, _ in }
    @State private var dropTarget: MacMailbox?
    @AppStorage(CorresSettings.textScaleKey) private var textScale = 1.0

    private var store: MailStore { services.store }
    private var accounts: [String] { services.auth.accounts.map(\.email) }

    var body: some View {
        List(selection: Binding(get: { model.mailbox }, set: { if let value = $0 { model.mailbox = value } })) {
            Section {
                row(.needsYou, count: needsYouCount, prominent: true)
                row(.waiting, count: waitingCount)
                if newSendersCount > 0, MailQuery.newSenderMode != .acceptAll { row(.newSenders, count: newSendersCount) }
            }
            Section("Mail") {
                ForEach([MailFilter.primary, .everything, .promotions, .social, .updates]) { filter in
                    row(.filter(filter.rawValue), count: filter == .primary ? primaryUnread : nil)
                }
            }
            if accounts.count > 1 {
                Section("Accounts") {
                    ForEach(accounts, id: \.self) { account in
                        Label {
                            Text(AccountPreferences.nickname(for: account)).macTextSize()
                        } icon: {
                            Circle().fill(AccountPreferences.color(for: account, among: accounts) ?? CorresPalette.accent)
                                .frame(width: 9, height: 9)
                        }
                        .tag(MacMailbox.account(account))
                        .help(account)
                    }
                }
            }
            Section("Mailboxes") {
                row(.server(MacRemoteMailboxes.Kind.drafts.rawValue))
                // As in Mail: there while something's waiting to go.
                if !ScheduledSends.shared.items.isEmpty || model.mailbox == .scheduled {
                    row(.scheduled, count: ScheduledSends.shared.items.count)
                }
                row(.server(MacRemoteMailboxes.Kind.sent.rawValue))
                row(.server(MacRemoteMailboxes.Kind.archive.rawValue))
                row(.flagged)
                row(.snoozed)
                row(.handled)
                row(.server(MacRemoteMailboxes.Kind.spam.rawValue))
                row(.server(MacRemoteMailboxes.Kind.trash.rawValue))
            }
            Section("Organize") {
                row(.purchases)
                row(.attachments)
                if !Organizer.shared.muted.isEmpty || model.mailbox == .muted { row(.muted) }
            }
            if !Organizer.shared.savedSearches.isEmpty {
                Section("Saved Searches") {
                    ForEach(Organizer.shared.savedSearches) { search in
                        row(.saved(search.id.uuidString))
                            .contextMenu {
                                Button("Remove Saved Search", role: .destructive) { Organizer.shared.delete(search: search.id) }
                            }
                    }
                }
            }
            // Each account's own labels or folders, folded away until
            // wanted: a Gmail account can have dozens.
            ForEach(accounts.filter { !services.labelDirectory.labels(for: $0).isEmpty }, id: \.self) { account in
                Section(isExpanded: expanded(account)) {
                    ForEach(labels(for: account)) { label in
                        row(.label(account: account, id: label.id, name: label.name))
                    }
                } header: {
                    Text(accounts.count > 1 ? AccountPreferences.nickname(for: account) : "Labels")
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) { footer }
    }

    @AppStorage("corres.mac.openLabelSections") private var openLabelSectionsRaw = ""

    private func expanded(_ account: String) -> Binding<Bool> {
        Binding(get: { openLabelSectionsRaw.split(separator: "|").contains { $0 == account } },
                set: { open in
                    var set = Set(openLabelSectionsRaw.split(separator: "|").map(String.init))
                    if open { set.insert(account) } else { set.remove(account) }
                    openLabelSectionsRaw = set.sorted().joined(separator: "|")
                })
    }

    /// Folders before categories, then by name, as on the iPhone.
    private func labels(for account: String) -> [GmailUserLabel] {
        services.labelDirectory.labels(for: account)
            .sorted { ($0.isFolder ? 0 : 1, $0.name.lowercased()) < ($1.isFolder ? 0 : 1, $1.name.lowercased()) }
    }

    private func row(_ mailbox: MacMailbox, count: Int? = nil, prominent: Bool = false) -> some View {
        // A sidebar sets its own font for a row; View › Bigger is applied
        // to the title itself, so it's seen. The symbol keeps the sidebar's
        // size: its space in the row doesn't grow with it.
        Label {
            Text(mailbox.title).macTextSize()
        } icon: {
            Image(systemName: mailbox.systemImage)
        }
            .badge(count.map { $0 > 0 ? Text("\($0)") : nil } ?? nil)
            .fontWeight(prominent ? .semibold : nil)
            .tag(mailbox)
            // The sidebar keeps a row as it was until the row itself
            // changes; the count is part of what it is.
            .id("\(mailbox.title)-\(count ?? -1)")
            .dropDestination(for: String.self) { items, _ in
                let ids = items.flatMap(MacDrag.decode)
                guard mailbox.acceptsDrop, !ids.isEmpty else { return false }
                onDrop(mailbox, ids)
                return true
            } isTargeted: { over in
                if over, mailbox.acceptsDrop { dropTarget = mailbox } else if dropTarget == mailbox { dropTarget = nil }
            }
            .listRowBackground(dropTarget == mailbox ? RoundedRectangle(cornerRadius: 6).fill(CorresPalette.accent.opacity(0.25)) : nil)
    }

    private var needsYouCount: Int { store.overview().needsYou.count }
    private var waitingCount: Int { store.overview().waitingCount }
    /// Counted once per change to the mail, not on every redraw (a drag
    /// over the sidebar redraws it as it moves).
    private final class SendersCount {
        var revision: Int?
        var count = 0
    }
    @State private var sendersCount = SendersCount()

    private var newSendersCount: Int {
        let cache = sendersCount
        if cache.revision != store.revision {
            cache.count = Set(store.pendingSenderThreads.compactMap(\.senderEmail)).count
            cache.revision = store.revision
        }
        return cache.count
    }
    private var primaryUnread: Int { store.overview().primaryUnread }

    /// What's happening with your mail, and Get New Mail one click away.
    private var footer: some View {
        let problem = accounts.lazy.compactMap { services.sync.health[$0]?.problem }.first
        return HStack(spacing: 8) {
            if !NetworkWatch.shared.isOnline {
                Image(systemName: "wifi.slash")
                Text("Offline. Mail will check when you're back.")
            } else if services.isGettingNewMail {
                ProgressView().controlSize(.small)
                Text("Checking for mail…")
            } else if let problem {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(problem).lineLimit(2).help(problem)
            } else if let last = services.sync.lastCompletedSync {
                Text("Updated \(last.formatted(.relative(presentation: .named)))")
            } else if accounts.isEmpty {
                Text("Sample mail · add an account in Settings")
            }
            Spacer(minLength: 4)
            if !accounts.isEmpty, NetworkWatch.shared.isOnline, !services.isGettingNewMail {
                Button { services.getNewMail() } label: {
                    Image(systemName: problem == nil ? "arrow.clockwise" : "arrow.clockwise.circle.fill")
                }
                .buttonStyle(.borderless)
                .help(problem == nil ? "Get New Mail (⇧⌘N)" : "Try Again (⇧⌘N)")
                .accessibilityLabel(problem == nil ? "Get New Mail" : "Try Again")
            }
        }
        .macFont(.caption)
        .foregroundStyle(CorresPalette.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        // Bigger text runs the mailboxes under it; a bar keeps both readable.
        .background(textScale > 1 ? AnyShapeStyle(.bar) : AnyShapeStyle(.clear))
    }
}
