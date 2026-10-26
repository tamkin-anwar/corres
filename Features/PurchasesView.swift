import SwiftUI

/// Mailboxes → Purchases: your receipts and deliveries in one place, by
/// where they stand, the way Gmail's Purchases view groups them. A problem
/// first (a failed payment, a missed delivery), then what's on its way,
/// then everything ordered and paid. Read from the emails on this device;
/// nothing is looked up with a carrier or a shop.
struct PurchasesView: View {
    let store: MailStore
    let accounts: [String]
    let open: (ThreadID) -> Void
    @State private var items: [Item] = []
    @State private var loaded = false

    struct Item: Identifiable {
        let thread: Correspondence
        let status: String?
        let stage: PurchaseStage
        let amount: String?
        var id: ThreadID { thread.id }
    }

    var body: some View {
        let stages: [PurchaseStage] = [.problem, .onTheWay, .delivered, .ordered]
        let groups: [(PurchaseStage, [Item])] = stages.compactMap { stage in
            let matching = items.filter { $0.stage == stage }
            return matching.isEmpty ? nil : (stage, matching)
        }
        List {
            ForEach(groups, id: \.0) { stage, items in
                Section(stage.title) {
                    ForEach(items) { item in
                        Button { open(item.thread.id) } label: { PurchaseRow(item: item) }
                            .buttonStyle(.plain)
                            .listRowBackground(CorresPalette.surface)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(CorresPalette.canvas)
        .navigationTitle("Purchases")
        .overlay {
            if loaded && items.isEmpty {
                ContentUnavailableView {
                    EmptyTitle("No Purchases", systemImage: "bag")
                } description: {
                    Text("Receipts and delivery updates from the last four months show here.")
                }
            } else if !loaded {
                ProgressView()
            }
        }
        .task(id: store.contentRevision) { await load() }
    }

    private func load() async {
        let cutoff = Date.now.addingTimeInterval(-120 * 86_400)
        let recent = store.searchableThreads
            .filter { (accounts.isEmpty || accounts.contains($0.id.account)) && $0.receivedAt > cutoff }
        let computed = await Task.detached(priority: .userInitiated) {
            // What kind each one is, off the main thread too (and kept per
            // message, see `mailKind`).
            let snapshot = recent
                .map { ($0, $0.mailKind) }
                .filter { [.receipt, .shipping].contains($0.1) }
                .sorted { $0.0.receivedAt > $1.0.receivedAt }
                .prefix(200)
            return snapshot.map { thread, kind -> Item in
                let text = thread.body.isEmpty ? thread.excerpt : thread.body
                let glance = MailDigest.glance(text: text, subject: thread.subject, kind: kind, html: thread.htmlBody)
                // Any currency, however it's written: "500円", "Tk 1,250", "R$ 89,90".
                let amount = glance?.facts.first { fact in MailDigest.isAmount(fact.value) || fact.label == "Amount" }?.value
                var stage = PurchaseStage.from(status: glance?.status, isAlert: glance?.isAlert ?? false)
                // A delivery more than two weeks ago is just an order now.
                if stage == .delivered, thread.receivedAt < .now.addingTimeInterval(-14 * 86_400) { stage = .ordered }
                // "On its way" that old has surely arrived.
                if stage == .onTheWay, thread.receivedAt < .now.addingTimeInterval(-21 * 86_400) { stage = .ordered }
                return Item(thread: thread, status: glance?.status, stage: stage, amount: amount)
            }
        }.value
        items = computed
        loaded = true
    }
}

private struct PurchaseRow: View {
    let item: PurchasesView.Item

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: item.stage.systemImage)
                .font(.body)
                .foregroundStyle(item.stage == .problem ? CorresPalette.alert : CorresPalette.accent)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(item.thread.sender).font(.body.weight(.semibold)).foregroundStyle(CorresPalette.ink).lineLimit(1)
                    Spacer(minLength: 8)
                    if let amount = item.amount {
                        Text(amount).font(.body.weight(.semibold)).monospacedDigit().foregroundStyle(CorresPalette.ink)
                    }
                }
                Text(item.thread.subject).font(.subheadline).foregroundStyle(CorresPalette.secondary).lineLimit(1)
                HStack(spacing: 6) {
                    if let status = item.status {
                        Text(Glance.display(status)).font(.caption.weight(.semibold))
                            .foregroundStyle(item.stage == .problem ? CorresPalette.alert : CorresPalette.accent)
                        Text("·").font(.caption).foregroundStyle(CorresPalette.tertiary)
                    }
                    Text(item.thread.receivedAt, format: .dateTime.month(.abbreviated).day())
                        .font(.caption).foregroundStyle(CorresPalette.tertiary)
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the email")
    }
}

extension PurchaseStage {
    var title: String {
        switch self {
        case .problem: String(localized: "Needs Attention")
        case .onTheWay: String(localized: "On the Way")
        case .delivered: String(localized: "Delivered")
        case .ordered: String(localized: "Orders and Receipts")
        }
    }

    var systemImage: String {
        switch self {
        case .problem: "exclamationmark.circle.fill"
        case .onTheWay: "shippingbox"
        case .delivered: "checkmark.circle"
        case .ordered: "bag"
        }
    }
}
