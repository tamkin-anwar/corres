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
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Their mail reaches Corres only once you allow them. Blocking hides them quietly, for good. Neither changes your Gmail account.")
                                .font(.subheadline).foregroundStyle(CorresPalette.secondary)
                                .padding(.horizontal, 4).padding(.bottom, 4)
                            ForEach(groups) { group in card(for: group) }
                        }
                        .padding(.horizontal, CorresSpace.page).padding(.vertical, 8)
                        .readableWidth()
                        .frame(maxWidth: .infinity)
                    }
                }
            }
            .background(CorresPalette.canvas)
            .navigationTitle("New senders")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func card(for group: SenderGroup) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                CorrespondentAvatar(initials: initials(for: group.sender))
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.sender).font(.body.weight(.semibold)).lineLimit(1)
                    Text(group.senderEmail).font(.subheadline).foregroundStyle(CorresPalette.secondary).lineLimit(1)
                }
            }
            Text(group.messageCount == 1 ? group.latestSubject
                                          : "\(group.messageCount) messages, including \u{201C}\(group.latestSubject)\u{201D}")
                .font(.subheadline).foregroundStyle(CorresPalette.ink).lineLimit(2)
            HStack(spacing: 10) {
                Button {
                    Task { await store.approveSender(group.senderEmail, account: group.account) }
                } label: {
                    Text("Allow").frame(maxWidth: .infinity)
                }
                .buttonStyle(CorresMetalCapsuleStyle(minHeight: 44))
                .accessibilityLabel("Allow \(group.sender)")
                Button {
                    Task { await store.blockSender(group.senderEmail, account: group.account) }
                } label: {
                    Text("Block").frame(maxWidth: .infinity)
                }
                .buttonStyle(CorresPillStyle(minHeight: 44))
                .accessibilityLabel("Block \(group.sender)")
            }
        }
        .padding(16)
        .corresSurface()
    }

    private func initials(for sender: String) -> String {
        sender.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined()
    }
}
