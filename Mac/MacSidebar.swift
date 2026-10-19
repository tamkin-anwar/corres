import SwiftUI

/// Needs You at the top, as Corres opens on it; then your mail's splits,
/// each account's own inbox, and the places mail waits.
struct MacSidebar: View {
    let services: MacServices
    @Bindable var model: MacMailboxModel

    private var store: MailStore { services.store }
    private var accounts: [String] { services.auth.accounts.map(\.email) }

    var body: some View {
        List(selection: Binding(get: { model.mailbox }, set: { if let value = $0 { model.mailbox = value } })) {
            Section {
                row(.needsYou, count: needsYouCount, prominent: true)
                row(.waiting, count: waitingCount)
                if newSendersCount > 0 { row(.newSenders, count: newSendersCount) }
            }
            Section("Mail") {
                ForEach([MailFilter.primary, .everything, .unread, .promotions, .social, .updates]) { filter in
                    row(.filter(filter.rawValue), count: filter == .primary ? primaryUnread : nil)
                }
            }
            if accounts.count > 1 {
                Section("Accounts") {
                    ForEach(accounts, id: \.self) { account in
                        Label {
                            Text(AccountPreferences.nickname(for: account))
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
                row(.server(MacRemoteMailboxes.Kind.sent.rawValue))
                row(.server(MacRemoteMailboxes.Kind.archive.rawValue))
                row(.flagged)
                row(.snoozed)
                row(.handled)
                row(.server(MacRemoteMailboxes.Kind.spam.rawValue))
                row(.server(MacRemoteMailboxes.Kind.trash.rawValue))
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) { footer }
    }

    private func row(_ mailbox: MacMailbox, count: Int? = nil, prominent: Bool = false) -> some View {
        Label(mailbox.title, systemImage: mailbox.systemImage)
            .badge(count.map { $0 > 0 ? Text("\($0)") : nil } ?? nil)
            .fontWeight(prominent ? .semibold : nil)
            .tag(mailbox)
            // The sidebar keeps a row as it was until the row itself
            // changes; the count is part of what it is.
            .id("\(mailbox.title)-\(count ?? -1)")
    }

    private var needsYouCount: Int { MailQuery.prioritized(store.threads, attention: .needsYou).count }
    private var waitingCount: Int { MailQuery.prioritized(store.threads, attention: .waiting).count }
    private var newSendersCount: Int { Set(store.pendingSenderThreads.compactMap(\.senderEmail)).count }
    private var primaryUnread: Int {
        let context = CategoryContextCache.context(store)
        return MailQuery.filter(store.threads).lazy.filter { $0.isUnread && MailFilter.primary.includes($0, context: context) }.count
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if services.sync.isSyncing {
                ProgressView().controlSize(.small)
                Text("Checking for mail…")
            } else if let last = services.sync.lastCompletedSync {
                Text("Updated \(last.formatted(.relative(presentation: .named)))")
            } else if accounts.isEmpty {
                Text("Sample mail · add an account in Settings")
            }
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(CorresPalette.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}
