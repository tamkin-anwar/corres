import SwiftUI

/// Settings → Senders: everything about who emails you, in one place.
/// Suggestions from your habits, new senders, VIPs and what Corres has
/// learned on top; then everyone who has emailed you, where an allow, a
/// block or a subscription can be changed any time. HEY's Screener History
/// shows only who you screened out, Gmail's blocked list is web-only, and
/// iOS keeps blocked contacts under Privacy & Security; here it's every
/// sender, searchable, with what you decided about each.
struct SendersView: View {
    let store: MailStore
    var unsubscriber: UnsubscribeService?
    @State private var filter = SenderDirectory.Filter.all
    @State private var order = SenderDirectory.Order.recent
    @State private var search = ""
    @State private var confirmingUnsubscribe: SenderSummary?
    @State private var note: String?
    @AppStorage(CorresSettings.screenNewSendersKey) private var screenNewSenders = false
    @State private var vips: [String] = CorresSettings.vips.sorted()
    @State private var showingScreener = false
    @State private var suggestions: [SenderHabits.Suggestion] = []
    @State private var cache = Directory()

    /// Everyone's summary, the count for each Show option and VIPs' names,
    /// worked out once per change to the mail; and the rows shown, once
    /// per change to those or to the search, filter or order. Each redraw
    /// and keystroke used to go through the whole mailbox again.
    private final class Directory {
        var revision: Int?
        var senders: [SenderSummary] = []
        var counts: [SenderDirectory.Filter: Int] = [:]
        /// The name on each sender's mail, by lowercased address.
        var names: [String: String] = [:]
        /// New senders waiting to be screened.
        var waiting = 0
        var shownKey: String?
        var shown: [SenderSummary] = []
    }

    private var directory: Directory {
        let cache = cache
        if cache.revision != store.revision {
            let threads = store.threads
            cache.senders = SenderDirectory.summaries(threads)
            cache.counts = Dictionary(uniqueKeysWithValues: SenderDirectory.Filter.allCases.map {
                ($0, SenderDirectory.filtered(cache.senders, $0).count)
            })
            var names: [String: String] = [:]
            for thread in threads {
                guard let email = thread.senderEmail?.lowercased(), names[email] == nil else { continue }
                names[email] = thread.sender
            }
            cache.names = names
            cache.waiting = Set(store.pendingSenderThreads.compactMap(\.senderEmail)).count
            cache.revision = store.revision
            cache.shownKey = nil
        }
        let key = "\(filter.rawValue)|\(order.rawValue)|\(search)"
        if cache.shownKey != key {
            cache.shown = SenderDirectory.filtered(cache.senders, filter, search: search, order: order)
            cache.shownKey = key
        }
        return cache
    }

    var body: some View {
        let directory = directory
        let shown = directory.shown
        container {
            #if os(macOS)
            // A settings window has no toolbar search, so it's a field here.
            Section {
                TextField("Search", text: $search, prompt: Text("Name or address"))
            }
            #endif
            if search.isEmpty {
                suggestionSection
                newSendersSection
                vipSection
                Section {
                    NavigationLink {
                        LessonsView()
                    } label: {
                        Label("What Corres Has Learned", systemImage: "brain")
                    }
                } footer: {
                    Text("Corres learns from your corrections, on this \(Device.name). Every lesson is listed there, and you can make it forget any of them.")
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Section {
                Picker("Show", selection: $filter) {
                    ForEach(SenderDirectory.Filter.allCases, id: \.self) { item in
                        Text(title(item, count: directory.counts[item] ?? 0)).tag(item)
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
                Text(footer).fixedSize(horizontal: false, vertical: true)
            }
            Section {
                if shown.isEmpty {
                    Text(search.isEmpty ? emptyText : String(localized: "No senders match \u{201C}\(search)\u{201D}."))
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
        #if os(iOS)
        .scrollContentBackground(.hidden)
        .background(CorresPalette.canvas)
        .searchable(text: $search, prompt: "Name or address")
        #endif
        .navigationTitle("Senders")
        .inlineTitle()
        .sheet(isPresented: $showingScreener) {
            ScreenerView(store: store)
                #if os(macOS)
                .frame(minWidth: 480, idealWidth: 520, minHeight: 560, idealHeight: 640)
                #endif
        }
        .onAppear { suggestions = HabitWatcher.shared.suggestions(in: store.threads) }
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

    /// A list on iPhone and iPad; the Mac's grouped settings form.
    @ViewBuilder
    private func container<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        #if os(macOS)
        Form { content() }.formStyle(.grouped)
        #else
        List { content() }
        #endif
    }

    // MARK: Suggestions, new senders, VIPs

    /// What your habits suggest, waiting here instead of interrupting you.
    @ViewBuilder
    private var suggestionSection: some View {
        if !suggestions.isEmpty {
            Section {
                ForEach(suggestions, id: \.email) { suggestion in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(HabitWatcher.title(for: suggestion)).font(.subheadline)
                        HStack(spacing: 18) {
                            Button(HabitWatcher.actionTitle(for: suggestion)) {
                                suggestions.removeAll { $0 == suggestion }
                                Task { await HabitWatcher.shared.accept(suggestion, store: store, unsubscriber: unsubscriber) }
                            }
                            .font(.subheadline.weight(.semibold))
                            Button("Not Now") {
                                suggestions.removeAll { $0 == suggestion }
                                HabitWatcher.shared.decline(suggestion, forever: false)
                            }
                            .font(.subheadline).foregroundStyle(CorresPalette.secondary)
                            Spacer(minLength: 0)
                            Menu {
                                Button("Never for This Sender") {
                                    suggestions.removeAll { $0 == suggestion }
                                    HabitWatcher.shared.decline(suggestion, forever: true)
                                }
                            } label: {
                                Image(systemName: "ellipsis").font(.subheadline).foregroundStyle(CorresPalette.secondary)
                                    .frame(minWidth: 32, minHeight: 32)
                            }
                            .accessibilityLabel("More")
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(.vertical, 4)
                }
            } header: {
                Text("Suggestions")
            } footer: {
                Text("From how you treat each sender's mail, counted on this \(Device.name).")
            }
        }
    }

    private var newSendersSection: some View {
        Section {
            Toggle("Screen New Senders", isOn: $screenNewSenders)
                .onChange(of: screenNewSenders) {
                    CorresSettings.applyToCore()
                    store.listsShouldRebuild()
                }
            let waiting = directory.waiting
            Button {
                showingScreener = true
            } label: {
                LabeledContent("Review New Senders", value: waiting == 0 ? "None" : "\(waiting)")
            }
            .foregroundStyle(CorresPalette.ink)
        } header: {
            Text("New Senders")
        } footer: {
            Text(screenNewSenders
                 ? "Someone's first email waits in New Senders until you allow them, so you only see mail from people you've let in. Blocked senders stay hidden."
                 : "Someone's first email shows like anyone else's, marked New, and you can allow or block them right from the email. Blocked senders stay hidden.")
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var vipSection: some View {
        Section {
            if vips.isEmpty {
                Text("No VIPs yet").foregroundStyle(CorresPalette.secondary)
            } else {
                ForEach(vips, id: \.self) { email in
                    Label(vipName(for: email), systemImage: "star.fill")
                        .contextMenu {
                            Button { removeVIPs([email]) } label: { Label("Remove from VIPs", systemImage: "star.slash") }
                        }
                }
                .onDelete { offsets in removeVIPs(offsets.map { vips[$0] }) }
            }
        } header: {
            Text("VIPs")
        } footer: {
            #if os(macOS)
            Text("A VIP's email always lands in Needs You and always notifies, even when you're only copied. Add someone by right-clicking their email in a list. Right-click a VIP here to remove them.")
                .fixedSize(horizontal: false, vertical: true)
            #else
            Text("A VIP's email always lands in Needs You and always notifies, even when you're only copied. Add someone from the ⋯ menu in their email, or by pressing and holding it in a list. Swipe to remove.")
            #endif
        }
    }

    private func removeVIPs(_ removed: [String]) {
        vips.removeAll { removed.contains($0) }
        Task {
            for email in removed {
                let account = store.threads.first { $0.senderEmail?.lowercased() == email }?.id.account ?? ""
                await store.setVIP(email, account: account, isVIP: false)
            }
        }
    }

    private func vipName(for email: String) -> String {
        directory.names[email] ?? email
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
            Button { Platform.copy(sender.email) } label: { Label("Copy Address", systemImage: "doc.on.doc") }
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
        case .all: String(localized: "All")
        case .allowed: String(localized: "Allowed")
        case .blocked: String(localized: "Blocked")
        case .new: String(localized: "New")
        case .subscriptions: String(localized: "Subscriptions")
        }
        return "\(name) (\(count))"
    }

    private var footer: String {
        #if os(macOS)
        switch filter {
        case .subscriptions: return String(localized: "Newsletters, stores and services: anyone who sends with an unsubscribe link. Right-click one to unsubscribe.")
        case .blocked: return String(localized: "Blocked senders' mail stays out of every list on this Mac, and they're never told. Right-click one to allow them again.")
        case .new: return String(localized: "First emails from people you haven't allowed or blocked yet.")
        default: return String(localized: "Everyone who has emailed you, from mail on this Mac. Right-click a sender to block, allow, unsubscribe or make them a VIP.")
        }
        #else
        switch filter {
        case .subscriptions: String(localized: "Newsletters, stores and services: anyone who sends with an unsubscribe link. Swipe right to unsubscribe.")
        case .blocked: String(localized: "Blocked senders' mail stays out of every list on this \(Device.name), and they're never told. Swipe to allow one again.")
        case .new: String(localized: "First emails from people you haven't allowed or blocked yet.")
        default: String(localized: "Everyone who has emailed you, from mail on this \(Device.name). Swipe left to block or allow, right to unsubscribe, or press and hold for more.")
        }
        #endif
    }

    private var emptyText: String {
        switch filter {
        case .blocked: String(localized: "Nobody blocked.")
        case .new: String(localized: "No new senders waiting.")
        case .subscriptions: String(localized: "No subscriptions yet.")
        default: String(localized: "No senders yet.")
        }
    }

    private func detail(_ sender: SenderSummary) -> String {
        let count = sender.count == 1 ? String(localized: "1 email") : String(localized: "\(sender.count) emails")
        let unread = sender.unread > 0 ? String(localized: " · \(sender.unread) unread") : ""
        return String(localized: "\(count)\(unread) · last \(sender.lastReceived.formatted(.relative(presentation: .named)))")
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
