import SwiftUI

/// Settings → Senders: everyone who has emailed you, in one place, where an
/// allow, a block or a subscription can be changed any time. HEY's
/// Screener History shows only who you screened out, Gmail's blocked list
/// is web-only, and iOS keeps blocked contacts under Privacy & Security;
/// here it's every sender, searchable, with what you decided about each.
struct SendersView: View {
    let store: MailStore
    var unsubscriber: UnsubscribeService?
    @State private var filter = SenderDirectory.Filter.all
    @State private var order = SenderDirectory.Order.recent
    @State private var search = ""
    @State private var confirmingUnsubscribe: SenderSummary?
    @State private var note: String?

    private var all: [SenderSummary] { SenderDirectory.summaries(store.threads) }

    var body: some View {
        let senders = all
        let shown = SenderDirectory.filtered(senders, filter, search: search, order: order)
        List {
            Section {
                Picker("Show", selection: $filter) {
                    ForEach(SenderDirectory.Filter.allCases, id: \.self) { item in
                        Text(title(item, count: SenderDirectory.filtered(senders, item).count)).tag(item)
                    }
                }
                .pickerStyle(.menu)
                Picker("Sort By", selection: $order) {
                    Text("Most Recent").tag(SenderDirectory.Order.recent)
                    Text("Most Email").tag(SenderDirectory.Order.most)
                    Text("Name").tag(SenderDirectory.Order.name)
                }
                .pickerStyle(.menu)
            } footer: {
                Text(footer)
            }
            Section {
                if shown.isEmpty {
                    Text(search.isEmpty ? emptyText : "No senders match \u{201C}\(search)\u{201D}.")
                        .foregroundStyle(CorresPalette.secondary)
                }
                ForEach(shown) { sender in
                    row(sender)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            if sender.decision == .blocked {
                                Button("Allow") { allow(sender) }.tint(CorresPalette.accent)
                            } else {
                                Button("Block", role: .destructive) { block(sender) }
                            }
                        }
                        .swipeActions(edge: .leading) {
                            if sender.isList, !sender.isUnsubscribed, unsubscriber != nil {
                                Button("Unsubscribe") { confirmingUnsubscribe = sender }.tint(.orange)
                            }
                        }
                        .contextMenu { menu(for: sender) }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(CorresPalette.canvas)
        .searchable(text: $search, prompt: "Name or address")
        .navigationTitle("Senders")
        .navigationBarTitleDisplayMode(.inline)
        .overlay(alignment: .bottom) {
            if let note {
                Text(note).font(.subheadline.weight(.medium))
                    .padding(.horizontal, 18).frame(minHeight: 44)
                    .corresGlass(in: Capsule())
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: note)
        .confirmationDialog(confirmingUnsubscribe.map { "Unsubscribe from \($0.name)?" } ?? "",
                            isPresented: Binding(get: { confirmingUnsubscribe != nil }, set: { if !$0 { confirmingUnsubscribe = nil } }),
                            titleVisibility: .visible) {
            Button("Unsubscribe") { if let sender = confirmingUnsubscribe { unsubscribe(sender) } }
            Button("Unsubscribe and Block") {
                if let sender = confirmingUnsubscribe { unsubscribe(sender); block(sender, quietly: true) }
            }
        } message: {
            Text("Corres asks them to stop, the way their own unsubscribe link does. Block also hides anything they still send.")
        }
    }

    private func row(_ sender: SenderSummary) -> some View {
        HStack(spacing: 12) {
            CorrespondentAvatar(initials: Self.initials(sender.name), email: sender.email, size: CGSize(width: 36, height: 36))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(sender.name).font(.body).lineLimit(1)
                    if InboxClassifier.isVIP(sender.email) {
                        Image(systemName: "star.fill").font(.caption).foregroundStyle(CorresPalette.accent)
                            .accessibilityLabel("VIP")
                    }
                }
                Text(sender.email).font(.footnote).foregroundStyle(CorresPalette.secondary).lineLimit(1)
                Text(detail(sender)).font(.caption).foregroundStyle(CorresPalette.tertiary)
            }
            Spacer(minLength: 8)
            if let badge = badge(sender) {
                Text(badge.text)
                    .font(.caption.weight(.semibold)).foregroundStyle(badge.color)
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .overlay(Capsule().strokeBorder(badge.color.opacity(0.5), lineWidth: 1))
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func menu(for sender: SenderSummary) -> some View {
        Section(sender.email) {
            if sender.decision == .blocked {
                Button { allow(sender) } label: { Label("Allow", systemImage: "checkmark.circle") }
            } else {
                if sender.decision == .pending {
                    Button { allow(sender) } label: { Label("Allow", systemImage: "checkmark.circle") }
                }
                Button(role: .destructive) { block(sender) } label: { Label("Block", systemImage: "hand.raised") }
            }
            if sender.isList, !sender.isUnsubscribed, unsubscriber != nil {
                Button { confirmingUnsubscribe = sender } label: { Label("Unsubscribe", systemImage: "envelope.badge.shield.half.filled") }
            }
            let isVIP = InboxClassifier.isVIP(sender.email)
            Button {
                Task { await store.setVIP(sender.email, account: sender.account, isVIP: !isVIP) }
            } label: { Label(isVIP ? "Remove from VIPs" : "Make VIP", systemImage: isVIP ? "star.slash" : "star") }
            Button { UIPasteboard.general.string = sender.email } label: { Label("Copy Address", systemImage: "doc.on.doc") }
        }
    }

    // MARK: Actions

    private func allow(_ sender: SenderSummary) {
        Task {
            await store.approveSender(sender.email, account: sender.account)
            show(sender.decision == .blocked
                 ? "\(sender.name) is allowed. Their \(sender.count == 1 ? "email is" : "\(sender.count) emails are") back in Mail."
                 : "\(sender.name) is allowed")
        }
    }

    private func block(_ sender: SenderSummary, quietly: Bool = false) {
        Task {
            await store.blockSender(sender.email, account: sender.account)
            if !quietly { show("\(sender.name) is blocked. You can allow them here any time.") }
        }
    }

    private func unsubscribe(_ sender: SenderSummary) {
        guard let unsubscriber,
              let latest = store.threads.filter({ $0.senderEmail?.lowercased() == sender.email && $0.id.account == sender.account })
                .max(by: { $0.receivedAt < $1.receivedAt }) else { return }
        Task {
            let outcome = await unsubscriber.unsubscribe(from: latest, store: store)
            show(outcome == .done ? "Unsubscribed from \(sender.name)" : "Finish unsubscribing on their page")
        }
    }

    private func show(_ text: String) {
        note = text
        Task {
            try? await Task.sleep(for: .seconds(3))
            if note == text { note = nil }
        }
    }

    // MARK: Text

    private func title(_ filter: SenderDirectory.Filter, count: Int) -> String {
        let name = switch filter {
        case .all: "All"
        case .allowed: "Allowed"
        case .blocked: "Blocked"
        case .new: "New"
        case .subscriptions: "Subscriptions"
        }
        return "\(name) (\(count))"
    }

    private var footer: String {
        switch filter {
        case .subscriptions: "Newsletters, stores and services: anyone who sends with an unsubscribe link. Swipe right to unsubscribe."
        case .blocked: "Blocked senders' mail stays out of every list on this \(Device.name), and they're never told. Swipe to allow one again."
        case .new: "First emails from people you haven't allowed or blocked yet."
        default: "Everyone who has emailed you, from mail on this \(Device.name). Swipe left to block or allow, right to unsubscribe, or press and hold for more."
        }
    }

    private var emptyText: String {
        switch filter {
        case .blocked: "Nobody blocked."
        case .new: "No new senders waiting."
        case .subscriptions: "No subscriptions yet."
        default: "No senders yet."
        }
    }

    private func detail(_ sender: SenderSummary) -> String {
        let count = sender.count == 1 ? "1 email" : "\(sender.count) emails"
        let unread = sender.unread > 0 ? " · \(sender.unread) unread" : ""
        return "\(count)\(unread) · last \(sender.lastReceived.formatted(.relative(presentation: .named)))"
    }

    private func badge(_ sender: SenderSummary) -> (text: String, color: Color)? {
        if sender.decision == .blocked { return ("Blocked", CorresPalette.alert) }
        if sender.decision == .pending { return ("New", CorresPalette.accent) }
        if sender.isUnsubscribed { return ("Unsubscribed", CorresPalette.tertiary) }
        return nil
    }

    private static func initials(_ name: String) -> String {
        name.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined()
    }
}
