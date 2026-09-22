import SwiftUI

/// The Screener: review senders the Screener has held back, one decision
/// per sender (not per message), matching HEY's own model. Approving lets
/// everything from them through, now and any future mail too; blocking
/// hides them silently, permanently, with no notification, ever again.
/// Neither touches the real Gmail account (ADR 002/005): this is purely
/// Corres's own local visibility decision.
struct ScreenerView: View {
    let store: MailStore
    @Environment(\.dismiss) private var dismiss

    private struct SenderGroup: Identifiable {
        let senderEmail: String
        let account: String
        let sender: String
        let organization: String
        let latestSubject: String
        let messageCount: Int
        var id: String { "\(account)|\(senderEmail)" }
    }

    private var groups: [SenderGroup] {
        let byKey = Dictionary(grouping: store.pendingSenderThreads) { thread in
            "\(thread.id.account)|\(thread.senderEmail ?? "")"
        }
        return byKey.values.compactMap { threads -> SenderGroup? in
            guard let first = threads.first, let senderEmail = first.senderEmail else { return nil }
            let latest = threads.max { $0.receivedAt < $1.receivedAt } ?? first
            return SenderGroup(senderEmail: senderEmail, account: first.id.account, sender: first.sender,
                                organization: first.organization, latestSubject: latest.subject, messageCount: threads.count)
        }.sorted { $0.sender.localizedStandardCompare($1.sender) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            Group {
                if groups.isEmpty {
                    ContentUnavailableView {
                        Label("No new senders", systemImage: "checkmark.shield")
                    } description: {
                        Text("Everyone who's reached you so far has already been reviewed.")
                    }
                } else {
                    List {
                        Section {
                            ForEach(groups) { group in row(for: group) }
                        } footer: {
                            Text("A new sender's mail stays out of Brief, Needs You, Waiting, and Mail until you decide. Approving lets everything from them through, now and later. Blocking hides them silently, no notification, ever again. Neither touches your real Gmail account.")
                        }
                    }
                    .listStyle(.insetGrouped)
                    .scrollContentBackground(.hidden)
                }
            }
            .background(CorresPalette.canvas)
            .navigationTitle("New Senders")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func row(for group: SenderGroup) -> some View {
        HStack(spacing: 14) {
            CorrespondentAvatar(initials: initials(for: group.sender))
            VStack(alignment: .leading, spacing: 3) {
                Text(group.sender).font(.subheadline.weight(.semibold))
                Text(group.organization).font(.caption).foregroundStyle(CorresPalette.secondary)
                Text(group.messageCount == 1 ? group.latestSubject
                                              : "\(group.messageCount) messages, including \u{201C}\(group.latestSubject)\u{201D}")
                    .font(.footnote).foregroundStyle(CorresPalette.secondary).lineLimit(2)
            }
            Spacer(minLength: 8)
            VStack(spacing: 8) {
                Button {
                    Task { await store.approveSender(group.senderEmail, account: group.account) }
                } label: {
                    Image(systemName: "checkmark").frame(width: 44, height: 44)
                }
                .buttonStyle(.bordered).tint(CorresPalette.accent)
                .accessibilityLabel("Approve \(group.sender)")
                Button {
                    Task { await store.blockSender(group.senderEmail, account: group.account) }
                } label: {
                    Image(systemName: "xmark").frame(width: 44, height: 44)
                }
                .buttonStyle(.bordered).tint(.red)
                .accessibilityLabel("Block \(group.sender)")
            }
        }
        .padding(.vertical, 6)
    }

    private func initials(for sender: String) -> String {
        sender.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined()
    }
}
