import SwiftUI

/// The Screener: review senders the Screener has held back, one decision
/// per sender (not per message), matching HEY's own model. Approving lets
/// everything from them through, now and any future mail too; blocking
/// hides them silently, permanently, with no notification, ever again.
/// Neither touches the real email account (ADR 002/005): this is purely
/// Corres's own local visibility decision.
///
/// People and companies are split, since they're decided differently: a
/// person is read one at a time, while a pile of brands is usually cleared
/// at once (Allow All, Block All) or by company ("everyone from
/// amazon.com", which also decides their future senders). Every bulk
/// decision can be undone.
struct ScreenerView: View {
    let store: MailStore
    @Environment(\.dismiss) private var dismiss
    @State private var tab: Tab = .people
    @State private var confirming: SenderDecision?
    @State private var undo: Undo?
    @State private var rules = CorresSettings.domainRules

    enum Tab: String, CaseIterable, Identifiable {
        case people = "People", companies = "Companies"
        var id: String { rawValue }
    }

    /// What the last bulk decision did, so it can be taken back.
    private struct Undo: Equatable {
        let message: String
        let senders: [Sender]
        let domain: String?
        static func == (lhs: Undo, rhs: Undo) -> Bool { lhs.message == rhs.message && lhs.senders.map(\.id) == rhs.senders.map(\.id) }
    }

    private struct Sender: Identifiable {
        let email: String
        let account: String
        var id: String { "\(account)|\(email)" }
    }

    private struct SenderGroup: Identifiable {
        let senderEmail: String
        let account: String
        let sender: String
        let latestSubject: String
        let latestDate: Date
        let messageCount: Int
        let isCompany: Bool
        var id: String { "\(account)|\(senderEmail)" }
        var domain: String? { InboxClassifier.companyDomain(of: senderEmail) }
    }

    /// Newest first: the sender who just wrote is the one you're most
    /// likely to be looking for.
    private var groups: [SenderGroup] {
        let byKey = Dictionary(grouping: store.pendingSenderThreads) { thread in
            "\(thread.id.account)|\(thread.senderEmail ?? "")"
        }
        return byKey.values.compactMap { threads -> SenderGroup? in
            guard let first = threads.first, let senderEmail = first.senderEmail else { return nil }
            let latest = threads.max { $0.receivedAt < $1.receivedAt } ?? first
            let isCompany = threads.contains {
                InboxClassifier.bulkKind(labelIds: $0.labelIds, looksAutomated: $0.looksAutomated) != nil
            }
            return SenderGroup(senderEmail: senderEmail, account: first.id.account, sender: first.sender,
                               latestSubject: latest.subject, latestDate: latest.receivedAt,
                               messageCount: threads.count, isCompany: isCompany)
        }.sorted { $0.latestDate > $1.latestDate }
    }

    var body: some View {
        let all = groups
        let people = all.filter { !$0.isCompany }
        let companies = all.filter(\.isCompany)
        let shown = tab == .people ? people : companies
        NavigationStack {
            Group {
                if all.isEmpty {
                    ContentUnavailableView {
                        EmptyTitle("No new senders", systemImage: "checkmark.shield")
                    } description: {
                        Text("Everyone who's reached you so far has already been reviewed.")
                    }
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            Picker("Senders", selection: $tab) {
                                Text("People · \(people.count)").tag(Tab.people)
                                Text("Companies · \(companies.count)").tag(Tab.companies)
                            }
                            .pickerStyle(.segmented)
                            .padding(.bottom, 4)

                            Text(MailQuery.holdsNewSenders
                                 ? "Their mail reaches Corres only once you allow them. Blocking hides them quietly, for good. Neither changes your email account."
                                 : "Their mail already shows in Corres. Allow marks them as known; Block hides them quietly, for good. Neither changes your email account.")
                                .font(.subheadline).foregroundStyle(CorresPalette.secondary)
                                .padding(.horizontal, 4)

                            if shown.count > 1 { bulkActions(for: shown) }

                            if shown.isEmpty {
                                Text(tab == .people ? "No new people." : "No new companies.")
                                    .font(.subheadline).foregroundStyle(CorresPalette.tertiary)
                                    .frame(maxWidth: .infinity).padding(.vertical, 32)
                            }
                            ForEach(shown) { group in card(for: group) }

                            if !rules.isEmpty { rulesSection }
                        }
                        .padding(.horizontal, CorresSpace.page).padding(.vertical, 8)
                        .padding(.bottom, undo == nil ? 0 : 72)
                        .readableWidth()
                        .frame(maxWidth: .infinity)
                    }
                }
            }
            .background(CorresPalette.canvas)
            .overlay(alignment: .bottom) { undoBar }
            .animation(.easeOut(duration: 0.2), value: undo)
            .navigationTitle("New Senders")
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                // Open on whichever side has someone waiting.
                if people.isEmpty, !companies.isEmpty { tab = .companies }
            }
            .confirmationDialog(confirmTitle(count: shown.count), isPresented: Binding(
                get: { confirming != nil }, set: { if !$0 { confirming = nil } }
            ), titleVisibility: .visible) {
                if let decision = confirming {
                    Button(decision == .approved ? "Allow \(shown.count)" : "Block \(shown.count)",
                           role: decision == .blocked ? .destructive : nil) {
                        decideAll(shown, decision)
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(confirming == .blocked ? "Their mail will be hidden quietly. You can undo this right after."
                                            : "Their mail will show in Corres. You can undo this right after.")
            }
        }
    }

    private func confirmTitle(count: Int) -> String {
        switch (confirming == .blocked, tab == .people, count == 1) {
        case (true, true, true): String(localized: "Block 1 person?")
        case (true, true, false): String(localized: "Block all \(count) people?")
        case (true, false, true): String(localized: "Block 1 company?")
        case (true, false, false): String(localized: "Block all \(count) companies?")
        case (false, true, true): String(localized: "Allow 1 person?")
        case (false, true, false): String(localized: "Allow all \(count) people?")
        case (false, false, true): String(localized: "Allow 1 company?")
        case (false, false, false): String(localized: "Allow all \(count) companies?")
        }
    }

    private func bulkActions(for shown: [SenderGroup]) -> some View {
        HStack(spacing: 10) {
            Button { confirming = .approved } label: {
                Text("Allow All").frame(maxWidth: .infinity)
            }
            .buttonStyle(CorresMetalCapsuleStyle(minHeight: 40))
            Button { confirming = .blocked } label: {
                Text("Block All").frame(maxWidth: .infinity)
            }
            .buttonStyle(CorresPillStyle(minHeight: 40))
        }
    }

    private static func timestamp(_ date: Date) -> String {
        #if os(iOS)
        CorrespondenceRow.timestamp(date)
        #else
        MacDates.short(date)
        #endif
    }

    private func card(for group: SenderGroup) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                CorrespondentAvatar(initials: initials(for: group.sender), email: group.senderEmail)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(group.sender).font(.body.weight(.semibold)).lineLimit(1)
                        Spacer(minLength: 8)
                        Text(Self.timestamp(group.latestDate))
                            .font(.footnote).foregroundStyle(CorresPalette.tertiary)
                    }
                    Text(group.senderEmail).font(.subheadline).foregroundStyle(CorresPalette.secondary).lineLimit(1)
                }
            }
            Text(group.messageCount == 1 ? group.latestSubject
                                          : "\(group.messageCount) messages, including \u{201C}\(group.latestSubject)\u{201D}")
                .font(.subheadline).foregroundStyle(CorresPalette.ink).lineLimit(2)
            HStack(spacing: 10) {
                Button {
                    decideOne(group, .approved)
                } label: {
                    Text("Allow").frame(maxWidth: .infinity)
                }
                .buttonStyle(CorresMetalCapsuleStyle(minHeight: 44))
                .accessibilityLabel("Allow \(group.sender)")
                Button {
                    decideOne(group, .blocked)
                } label: {
                    Text("Block").frame(maxWidth: .infinity)
                }
                .buttonStyle(CorresPillStyle(minHeight: 44))
                .accessibilityLabel("Block \(group.sender)")
                if group.isCompany, let domain = group.domain {
                    Menu {
                        Button("Allow Everyone from \(domain)", systemImage: "checkmark.circle") {
                            decideDomain(domain, .approved)
                        }
                        Button("Block Everyone from \(domain)", systemImage: "nosign", role: .destructive) {
                            decideDomain(domain, .blocked)
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(CorresPalette.ink)
                            .frame(width: 44, height: 44)
                            .background(CorresPalette.surfaceRaised, in: Circle())
                            .overlay(Circle().strokeBorder(CorresPalette.line, lineWidth: 0.5))
                    }
                    .fixedSize()
                    .accessibilityLabel("More for \(domain)")
                }
            }
        }
        .padding(16)
        .corresSurface()
        .modifier(SwipeToDecide { decision in decideOne(group, decision) })
        .accessibilityAction(named: "Allow") { decideOne(group, .approved) }
        .accessibilityAction(named: "Block") { decideOne(group, .blocked) }
    }

    /// Company rules in force, each removable: new senders from there are
    /// screened again; decisions already made stay.
    private var rulesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Company Rules").font(.footnote.weight(.semibold)).foregroundStyle(CorresPalette.secondary)
                .textCase(.uppercase).padding(.horizontal, 4).padding(.top, 16)
            VStack(spacing: 0) {
                ForEach(rules.keys.sorted(), id: \.self) { domain in
                    HStack {
                        Image(systemName: rules[domain] == .blocked ? "nosign" : "checkmark.circle")
                            .foregroundStyle(CorresPalette.secondary)
                        Text((rules[domain] == .blocked ? "Block " : "Allow ") + "everyone from \(domain)")
                            .font(.subheadline)
                        Spacer()
                        Button("Remove") {
                            Task {
                                await store.setDomainRule(domain, nil)
                                rules = CorresSettings.domainRules
                            }
                        }
                        .font(.subheadline)
                    }
                    .padding(.vertical, 10).padding(.horizontal, 16)
                }
            }
            .corresSurface()
        }
    }

    @ViewBuilder private var undoBar: some View {
        if let undo {
            HStack {
                Text(undo.message).font(.subheadline.weight(.medium)).lineLimit(2)
                Spacer()
                Button("Undo") { take(undo) }.font(.subheadline.weight(.semibold))
            }
            .padding(.horizontal, 18).padding(.vertical, 14)
            .corresGlass(in: Capsule())
            .padding(.horizontal, CorresSpace.page).padding(.bottom, 12)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .task(id: undo.message) {
                try? await Task.sleep(for: .seconds(8))
                if self.undo == undo { self.undo = nil }
            }
        }
    }

    private func decideOne(_ group: SenderGroup, _ decision: SenderDecision) {
        let sender = Sender(email: group.senderEmail, account: group.account)
        Task {
            await store.setSenderDecision(decision, senders: [(sender.email, sender.account)])
            undo = Undo(message: "\(decision == .approved ? "Allowed" : "Blocked") \(group.sender)", senders: [sender], domain: nil)
        }
    }

    private func decideAll(_ shown: [SenderGroup], _ decision: SenderDecision) {
        let senders = shown.map { Sender(email: $0.senderEmail, account: $0.account) }
        Task {
            await store.setSenderDecision(decision, senders: senders.map { ($0.email, $0.account) })
            undo = Undo(message: "\(decision == .approved ? "Allowed" : "Blocked") \(senders.count) senders",
                        senders: senders, domain: nil)
        }
    }

    private func decideDomain(_ domain: String, _ decision: SenderDecision) {
        Task {
            let decided = await store.setDomainRule(domain, decision)
            rules = CorresSettings.domainRules
            undo = Undo(message: "\(decision == .approved ? "Allowing" : "Blocking") everyone from \(domain)",
                        senders: decided.map { Sender(email: $0.email, account: $0.account) }, domain: domain)
        }
    }

    private func take(_ undo: Undo) {
        self.undo = nil
        Task {
            if let domain = undo.domain {
                await store.setDomainRule(domain, nil)
                rules = CorresSettings.domainRules
            }
            await store.setSenderDecision(.pending, senders: undo.senders.map { ($0.email, $0.account) })
        }
    }

    private func initials(for sender: String) -> String {
        sender.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined()
    }
}

/// A Screener card you can swipe: right to allow, left to block, the way
/// Spark's Gatekeeper and Tinder-style triage work. The card follows the
/// finger over a tinted backdrop that names the action, and lets go past a
/// third of its width to decide; anything shorter springs back.
private struct SwipeToDecide: ViewModifier {
    let decide: (SenderDecision) -> Void
    @State private var offset: CGFloat = 0
    @State private var width: CGFloat = 340
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var threshold: CGFloat { width / 3 }

    func body(content: Content) -> some View {
        content
            .offset(x: offset)
            .rotationEffect(.degrees(reduceMotion ? 0 : Double(offset / 40)), anchor: .bottom)
            .background(alignment: offset >= 0 ? .leading : .trailing) {
                if offset != 0 {
                    let allowing = offset > 0
                    RoundedRectangle(cornerRadius: CorresSpace.radius, style: .continuous)
                        .fill(allowing ? CorresPalette.swipeHandled : CorresPalette.swipeTrash)
                        .overlay(alignment: allowing ? .leading : .trailing) {
                            Label(allowing ? "Allow" : "Block", systemImage: allowing ? "checkmark" : "nosign")
                                .font(.headline).foregroundStyle(.white)
                                .padding(.horizontal, 24)
                                .opacity(min(1, abs(offset) / threshold))
                        }
                }
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
            .sensoryFeedback(.selection, trigger: abs(offset) > threshold)
            .simultaneousGesture(
                DragGesture(minimumDistance: 20)
                    .onChanged { value in
                        // Horizontal only, so the list still scrolls.
                        guard abs(value.translation.width) > abs(value.translation.height) else { return }
                        offset = value.translation.width
                    }
                    .onEnded { value in
                        let distance = value.translation.width
                        if abs(distance) > threshold {
                            withAnimation(.easeOut(duration: 0.2)) { offset = distance > 0 ? width * 1.5 : -width * 1.5 }
                            decide(distance > 0 ? .approved : .blocked)
                        } else {
                            withAnimation(.spring(duration: 0.3)) { offset = 0 }
                        }
                    }
            )
    }
}
