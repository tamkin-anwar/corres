import SwiftUI

/// Settings, ordered the way Mail, Gmail, Superhuman and Spark all order
/// theirs: who you are (accounts) first, then how the app behaves, then
/// what it does with your data, then a quiet version footer. Everything
/// here is something a person using Corres every day would change; there
/// are no developer or demo controls.
struct PreferencesView: View {
    let store: MailStore
    var auth: GoogleAuthService
    var sync: GmailSyncService
    @Bindable var pushService: PushNotificationService
    @Environment(\.dismiss) private var dismiss
    @Environment(MailIntelligence.self) private var intelligence
    @AppStorage("corres.appearance") private var appearance = Appearance.system.rawValue
    @Environment(EntitlementStore.self) private var entitlements
    @State private var showingPaywall = false
    @State private var managingSubscription = false

    var body: some View {
        NavigationStack {
            Form {
                accountsSection
                planSection
                Section("Mail") {
                    Picker(selection: $appearance) {
                        ForEach(Appearance.allCases) { Text($0.title).tag($0.rawValue) }
                    } label: {
                        settingLabel("Appearance", "circle.lefthalf.filled")
                    }
                    NavigationLink {
                        SortingSettingsView(store: store)
                    } label: {
                        settingLabel("Sorting", "line.3.horizontal.decrease")
                    }
                    NavigationLink {
                        ListSettingsView(store: store)
                    } label: {
                        settingLabel("Lists", "list.bullet")
                    }
                    NavigationLink {
                        ReadingSettingsView()
                    } label: {
                        settingLabel("Reading", "text.book.closed")
                    }
                    NavigationLink {
                        ComposingSettingsView(auth: auth)
                    } label: {
                        settingLabel("Composing", "square.and.pencil")
                    }
                    NavigationLink {
                        SwipeSettingsView()
                    } label: {
                        settingLabel("Swipes", "hand.draw")
                    }
                    NavigationLink {
                        SnippetSettingsView()
                    } label: {
                        settingLabel("Snippets", "text.badge.plus")
                    }
                    NavigationLink {
                        NotificationSettingsView(auth: auth, pushService: pushService)
                    } label: {
                        LabeledContent {
                            Text(auth.accounts.isEmpty ? "Needs Gmail" : (pushService.isEnabled ? "On" : "Off"))
                        } label: {
                            settingLabel("Notifications", "bell.badge")
                        }
                    }
                    .disabled(auth.accounts.isEmpty)
                }
                Section {
                    LabeledContent {
                        Text(intelligence.isAvailable ? "On this iPhone" : "Not available")
                    } label: {
                        settingLabel("Apple Intelligence", "sparkle")
                    }
                } header: {
                    Text("Intelligence")
                } footer: {
                    Text(intelligence.isAvailable
                         ? "Sorting, summaries, suggested replies and rewrites run on Apple's on-device model, not on a server."
                         : "Turn on Apple Intelligence in the Settings app for summaries, suggested replies and rewrites. Needs You still sorts your mail without it.")
                }
                Section {
                    NavigationLink {
                        PrivacyView()
                    } label: {
                        LabeledContent {
                            Text("Read on this iPhone")
                        } label: {
                            settingLabel("Private by design", "lock.shield")
                        }
                    }
                }
                aboutFooter
            }
            .scrollContentBackground(.hidden)
            .background(CorresPalette.canvas)
            .navigationTitle("Settings")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            // Presented from the whole screen, never from inside a Section:
            // modifiers on a Section apply to every row in it, and five
            // copies of one sheet cancelled each other, closing Settings.
            .sheet(isPresented: $showingPaywall) { PaywallView() }
            .manageSubscriptionsSheet(isPresented: $managingSubscription)
            .alert("Corres Pro", isPresented: Binding(
                get: { entitlements.errorMessage != nil && !showingPaywall },
                set: { if !$0 { entitlements.errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { entitlements.errorMessage = nil }
            } message: { Text(entitlements.errorMessage ?? "") }
            .alert("Could not connect", isPresented: Binding(
                get: { auth.errorMessage != nil },
                set: { if !$0 { auth.errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { auth.errorMessage = nil }
            } message: { Text(auth.errorMessage ?? "Please try again.") }
            .alert("Could not sync", isPresented: Binding(
                get: { sync.errorMessage != nil },
                set: { if !$0 { sync.errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { sync.errorMessage = nil }
            } message: { Text(sync.errorMessage ?? "Please try again.") }
        }
        // Self-sufficient: a distant .preferredColorScheme does not reliably
        // re-trait an already-presented sheet when the value changes.
        .preferredColorScheme(Appearance(rawValue: appearance)?.colorScheme)
    }

    // MARK: - Plan

    private var planSection: some View {
        Section {
            HStack(spacing: 12) {
                CorrespondenceMark().frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entitlements.isPro ? entitlements.plan.title : "Corres Pro").font(.body.weight(.semibold))
                    Text(planStatus).font(.footnote).foregroundStyle(CorresPalette.secondary)
                }
            }
            .padding(.vertical, 2)
            switch entitlements.plan {
            case .none:
                Button("Try Corres Pro free") { showingPaywall = true }
            case .monthly, .annual:
                Button("Manage subscription") { managingSubscription = true }
            case .lifetime:
                EmptyView()
            }
            Button("Restore purchases") { Task { await entitlements.restore() } }
            Button("Redeem code") {
                    // Close this sheet first so Apple's sheet isn't stacked on it.
                    dismiss()
                    Task {
                        try? await Task.sleep(for: .milliseconds(450))
                        await entitlements.presentRedeemSheet()
                    }
                }
        } header: {
            Text("Plan")
        } footer: {
            if !entitlements.isPro {
                Text("Without Pro, Mail keeps working: read, reply, archive and search. Brief, Needs You, Waiting, Ask and the on-device intelligence need Pro.")
            }
        }
    }

    private var planStatus: String {
        switch entitlements.plan {
        case .none:
            if let monthly = entitlements.product(EntitlementStore.ProductID.monthly),
               let annual = entitlements.product(EntitlementStore.ProductID.annual) {
                return "Try it free, then \(monthly.displayPrice) a month or \(annual.displayPrice) a year."
            }
            return "Try it free for 14 days."
        case .monthly(let renews, let inTrial), .annual(let renews, let inTrial):
            let date = renews.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "soon"
            return inTrial ? "Free trial · first charge \(date)" : "Renews \(date)"
        case .lifetime(let familyShared):
            return familyShared ? "Lifetime · shared by your family" : "Lifetime · yours for good"
        }
    }

    // MARK: - Accounts

    @ViewBuilder
    private var accountsSection: some View {
        if auth.accounts.isEmpty {
            Section {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 12) {
                        CorrespondenceMark().frame(width: 40, height: 40)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Connect your Gmail").font(.headline)
                            Text("You're looking at sample mail.").font(.subheadline).foregroundStyle(CorresPalette.secondary)
                        }
                    }
                    Button(action: connect) {
                        if auth.isSigningIn || sync.isSyncing { ProgressView() } else { Text("Continue with Google") }
                    }
                    .buttonStyle(CorresButtonStyle())
                    .disabled(auth.isSigningIn || sync.isSyncing)
                    Text("Corres never sees your Google password. Your mail is sorted and read on this iPhone.")
                        .font(.footnote).foregroundStyle(CorresPalette.tertiary)
                }
                .padding(.vertical, 8)
            }
        } else {
            Section {
                ForEach(auth.accounts) { account in
                    NavigationLink {
                        AccountDetailView(account: account, store: store, auth: auth, sync: sync, pushService: pushService)
                    } label: {
                        accountRow(account)
                    }
                }
                Button(action: connect) {
                    if auth.isSigningIn || sync.isSyncing {
                        ProgressView()
                    } else {
                        settingLabel("Add account", "plus")
                    }
                }
                .disabled(auth.isSigningIn || sync.isSyncing)
            } header: {
                Text("Accounts")
            } footer: {
                Text("Every account shares one inbox, newest first. Switch to one account from the top of any screen.")
            }
        }
    }

    private func accountRow(_ account: GmailAccount) -> some View {
        let profile = auth.profile(for: account.email)
        return HStack(spacing: 12) {
            AccountAvatar(email: account.email, name: profile?.name, photoURL: profile?.photoURL, size: 40)
            VStack(alignment: .leading, spacing: 1) {
                Text(profile?.name ?? account.email).font(.body.weight(.medium)).lineLimit(1)
                if profile?.name != nil {
                    Text(account.email).font(.footnote).foregroundStyle(CorresPalette.secondary).lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private func connect() {
        Task {
            let previousCount = auth.accounts.count
            await auth.signIn()
            // Only the newly added account needs a fresh sync; the others,
            // if any, are already current.
            // Cancelled sign-in: keep the sample mail, there's nothing to
            // replace it with.
            guard auth.accounts.count > previousCount, let newAccount = auth.accounts.last else { return }
            // Sample mail goes before real mail arrives, so the two are
            // never shown together, not even for a moment.
            await store.deleteSampleDataIfPresent()
            if await sync.syncIfConnected(account: newAccount.email) {
                await store.load()
            }
        }
    }

    // MARK: - About

    private var aboutFooter: some View {
        Section {
        } footer: {
            VStack(spacing: 6) {
                CorrespondenceMark().frame(width: 30, height: 30)
                Text("corres").font(.system(.title3, design: .serif))
                    .foregroundStyle(CorresPalette.ink)
                Text("Email, considered.").font(.system(.footnote, design: .serif).italic())
                Text("Version \(Self.version) · Anwar Creative Studio")
                    .font(.caption2).monospacedDigit()
                    .foregroundStyle(CorresPalette.tertiary)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 12)
            .accessibilityElement(children: .combine)
        }
    }

    private static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String
        return build.map { "\(short) (\($0))" } ?? short
    }

    private func settingLabel(_ title: String, _ icon: String) -> some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: icon).foregroundStyle(CorresPalette.accent)
        }
    }
}

// MARK: - Account detail

/// One account: who it is, when it last synced, and the two things a
/// person might need to do to it. Removing it takes its mail off this
/// iPhone; nothing is deleted from Gmail.
private struct AccountDetailView: View {
    @Environment(MailIntelligence.self) private var intelligence
    let account: GmailAccount
    let store: MailStore
    var auth: GoogleAuthService
    var sync: GmailSyncService
    var pushService: PushNotificationService
    @Environment(\.dismiss) private var dismiss
    @State private var confirmingRemoval = false
    @State private var syncing = false

    var body: some View {
        let profile = auth.profile(for: account.email)
        Form {
            Section {
                VStack(spacing: 10) {
                    AccountAvatar(email: account.email, name: profile?.name, photoURL: profile?.photoURL, size: 76)
                    if let name = profile?.name { Text(name).font(.title3.weight(.semibold)) }
                    Text(account.email).font(.subheadline).foregroundStyle(CorresPalette.secondary)
                    Label("Gmail", systemImage: "envelope").font(.caption).foregroundStyle(CorresPalette.tertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .listRowBackground(Color.clear)
            }
            Section {
                Button {
                    Task {
                        syncing = true
                        if await sync.syncIfConnected(account: account.email) { await store.refresh() }
                        syncing = false
                    }
                } label: {
                    LabeledContent {
                        if syncing || sync.isSyncing {
                            ProgressView()
                        } else if let last = sync.lastCompletedSync {
                            Text(last, format: .relative(presentation: .named))
                        }
                    } label: {
                        Label("Sync now", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                .disabled(syncing || sync.isSyncing)
                Button {
                    Task { await auth.signIn(hint: account.email) }
                } label: {
                    Label("Reconnect with Google", systemImage: "key")
                }
            } footer: {
                Text("If marking as read, archiving or flagging stops working, reconnect and keep every permission checked.")
            }
            if pushService.isEnabled {
                Section {
                    AccountNotificationToggle(email: account.email)
                } footer: {
                    Text("Turn off to keep this account quiet while its mail still syncs and sorts.")
                }
            }
            Section {
                Button("Remove Account", role: .destructive) { confirmingRemoval = true }
            } footer: {
                Text("Removes this account and its mail from Corres on this iPhone. Nothing is deleted from Gmail.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(CorresPalette.canvas)
        .navigationTitle("Account")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Remove \(account.email)?", isPresented: $confirmingRemoval, titleVisibility: .visible) {
            Button("Remove Account", role: .destructive) {
                let email = account.email
                sync.clearCursor(for: email)
                Task {
                    // A stale watch subscription would keep the relay
                    // pinging for an account nothing here listens for.
                    await pushService.disable(account: email)
                    await auth.signOut(email)
                    await store.removeAccountData(email)
                    intelligence.forget(account: email)
                }
                dismiss()
            }
        } message: {
            Text("Its mail is removed from this iPhone. It stays in Gmail.")
        }
    }
}

// MARK: - Composing

/// Signatures, Undo Send, the default reply and which account new mail
/// comes from: the composing settings Mail, Gmail and Spark all offer.
private struct ComposingSettingsView: View {
    var auth: GoogleAuthService
    @AppStorage(CorresSettings.undoSendKey) private var undoSeconds = 5
    @AppStorage(CorresSettings.defaultReplyKey) private var defaultReply = CorresSettings.DefaultReply.reply.rawValue
    @AppStorage(CorresSettings.defaultFromKey) private var defaultFrom = ""

    var body: some View {
        Form {
            if auth.accounts.isEmpty {
                Section {
                    SignatureEditor(account: "sample")
                } header: {
                    Text("Signature")
                } footer: {
                    Text("Added below what you write, above the email you're replying to.")
                }
            } else {
                ForEach(auth.accounts) { account in
                    Section {
                        SignatureEditor(account: account.email)
                    } header: {
                        Text(auth.accounts.count > 1 ? "Signature · \(account.email)" : "Signature")
                    } footer: {
                        if account.email == auth.accounts.last?.email {
                            Text("Added below what you write, above the email you're replying to. Each account keeps its own.")
                        }
                    }
                }
            }
            Section {
                Picker("Undo Send", selection: $undoSeconds) {
                    ForEach(CorresSettings.undoSendChoices, id: \.self) { seconds in
                        Text(seconds == 0 ? "Off" : "\(seconds) seconds").tag(seconds)
                    }
                }
                Picker("Default reply", selection: $defaultReply) {
                    ForEach(CorresSettings.DefaultReply.allCases) { Text($0.title).tag($0.rawValue) }
                }
                if auth.accounts.count > 1 {
                    Picker("Send new mail from", selection: $defaultFrom) {
                        ForEach(auth.accounts) { Text($0.email).tag($0.email) }
                    }
                }
            } footer: {
                Text("Undo Send holds a message for a moment so you can take it back. Reply All is used only when others were on the email; press and hold Reply for the other choice.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(CorresPalette.canvas)
        .navigationTitle("Composing")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if defaultFrom.isEmpty, let first = auth.accounts.first { defaultFrom = first.email }
        }
    }
}

private struct SignatureEditor: View {
    let account: String
    @State private var text = ""

    var body: some View {
        TextField("None", text: $text, axis: .vertical)
            .lineLimit(2...8)
            .onAppear { text = UserDefaults.standard.string(forKey: CorresSettings.signatureKey(for: account)) ?? "" }
            .onChange(of: text) { _, value in
                UserDefaults.standard.set(value, forKey: CorresSettings.signatureKey(for: account))
            }
    }
}

/// Observed through @AppStorage, so the switch redraws when flipped.
private struct AccountNotificationToggle: View {
    @AppStorage private var isOn: Bool

    init(email: String) {
        _isOn = AppStorage(wrappedValue: true, CorresSettings.accountNotificationsKey(for: email))
    }

    var body: some View {
        Toggle(isOn: $isOn) { Label("Notifications", systemImage: "bell") }
    }
}

// MARK: - Reading

private struct ReadingSettingsView: View {
    @AppStorage(CorresSettings.remoteImagesKey) private var remoteImages = CorresSettings.RemoteImages.ask.rawValue
    @AppStorage(CorresSettings.markReadOnOpenKey) private var markReadOnOpen = true
    @AppStorage(CorresSettings.confirmTrashKey) private var confirmTrash = false
    @AppStorage(CorresSettings.openLinksKey) private var openLinks = CorresSettings.OpenLinks.inCorres.rawValue
    @AppStorage(AfterRemoval.key) private var afterRemoval = AfterRemoval.nextConversation.rawValue
    @AppStorage(CorresSettings.summariesKey) private var summaries = true
    @Environment(MailIntelligence.self) private var intelligence

    var body: some View {
        Form {
            Section {
                Toggle("Summarize emails", isOn: $summaries)
            } header: {
                Text("Summaries")
            } footer: {
                Text(intelligence.isAvailable
                     ? "A short summary at the top of each email and conversation, written on this iPhone and checked against the email: every name, number and date in it has to be in the email. Part of Corres Pro."
                     : "Without Apple Intelligence, summaries are the email's own key sentence, taken word for word. Part of Corres Pro.")
            }
            Section {
                Picker("Remote images", selection: $remoteImages) {
                    ForEach(CorresSettings.RemoteImages.allCases) { Text($0.title).tag($0.rawValue) }
                }
            } footer: {
                Text(remoteImages == CorresSettings.RemoteImages.ask.rawValue
                     ? "Images from the web stay off until you tap Show Images, so senders can't tell when you opened their email. Trusting a sender loads theirs from then on."
                     : "Images load as soon as you open an email. Senders using tracking images can see when you opened it.")
            }
            Section {
                Toggle("Mark as read when opened", isOn: $markReadOnOpen)
                Toggle("Ask before moving to Trash", isOn: $confirmTrash)
                Picker("After archiving", selection: $afterRemoval) {
                    Text("Next conversation").tag(AfterRemoval.nextConversation.rawValue)
                    Text("Back to list").tag(AfterRemoval.list.rawValue)
                }
                Picker("Open links", selection: $openLinks) {
                    ForEach(CorresSettings.OpenLinks.allCases) { Text($0.title).tag($0.rawValue) }
                }
            } footer: {
                Text("With marking as read off, a conversation stays unread until you swipe or choose Mark as Read. Links open in Corres with Safari's Reader and content blockers, or in your default browser.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(CorresPalette.canvas)
        .navigationTitle("Reading")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Sorting

private struct SortingSettingsView: View {
    let store: MailStore
    @State private var vipsStorage: [String] = CorresSettings.vips.sorted()
    @AppStorage(CorresSettings.sensitivityKey) private var sensitivity = InboxClassifier.Sensitivity.balanced.rawValue
    @AppStorage(CorresSettings.followUpDaysKey) private var followUpDays = 3
    @AppStorage(CorresSettings.morningHourKey) private var morningHour = 8
    @AppStorage(CorresSettings.laterTodayEveningKey) private var laterTodayEvening = false

    var body: some View {
        Form {
            Section {
                if vipsStorage.isEmpty {
                    Text("No VIPs yet").foregroundStyle(CorresPalette.secondary)
                } else {
                    ForEach(vipsStorage, id: \.self) { email in
                        Label(name(for: email), systemImage: "star.fill")
                    }
                    .onDelete { offsets in
                        let removed = offsets.map { vipsStorage[$0] }
                        vipsStorage.remove(atOffsets: offsets)
                        Task {
                            for email in removed {
                                let account = store.threads.first { $0.senderEmail?.lowercased() == email }?.id.account ?? ""
                                await store.setVIP(email, account: account, isVIP: false)
                            }
                        }
                    }
                }
            } header: {
                Text("VIPs")
            } footer: {
                Text("A VIP's email always lands in Needs You and always notifies, even when you're only copied. Add someone from the ⋯ menu in their email, or by pressing and holding it in a list. Swipe to remove.")
            }
            Section {
                Picker("Needs You", selection: $sensitivity) {
                    Text("Focused").tag(InboxClassifier.Sensitivity.focused.rawValue)
                    Text("Balanced").tag(InboxClassifier.Sensitivity.balanced.rawValue)
                    Text("Everything from people").tag(InboxClassifier.Sensitivity.inclusive.rawValue)
                }
                Picker("Follow up after", selection: $followUpDays) {
                    ForEach(CorresSettings.followUpChoices, id: \.self) { Text($0 == 1 ? "1 day" : "\($0) days").tag($0) }
                }
            } footer: {
                Text(sensitivityDetail + " Waiting turns into Follow up once someone hasn't replied in that long.")
            }
            Section {
                Picker("Start of day", selection: $morningHour) {
                    ForEach(6...10, id: \.self) { hour in
                        Text(Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: .now)!
                                .formatted(date: .omitted, time: .shortened)).tag(hour)
                    }
                }
                Picker("Later today", selection: $laterTodayEvening) {
                    Text("In 3 hours").tag(false)
                    Text("This evening, 6 PM").tag(true)
                }
            } header: {
                Text("Snooze")
            } footer: {
                Text("Tomorrow and Next week come back at the start of your day; This weekend an hour later, on Saturday.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(CorresPalette.canvas)
        .navigationTitle("Sorting")
        .onAppear { vipsStorage = CorresSettings.vips.sorted() }
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: sensitivity) { CorresSettings.applyToCore(); Task { await store.reapplyRules() } }
        .onChange(of: morningHour) { CorresSettings.applyToCore() }
        .onChange(of: laterTodayEvening) { CorresSettings.applyToCore() }
    }

    private var sensitivityDetail: String {
        switch InboxClassifier.Sensitivity(rawValue: sensitivity) ?? .balanced {
        case .focused: "Focused: only email that asks something of you, has a deadline, or is from a VIP or someone you write to."
        case .balanced: "Balanced: email written to you by a person; mail you're only copied on stays in Mail."
        case .inclusive: "Everything from people: every email from a person, including ones you're copied on."
        }
    }

    private func name(for email: String) -> String {
        store.threads.first { $0.senderEmail?.lowercased() == email }.map { "\($0.sender) · \(email)" } ?? email
    }
}

// MARK: - Lists

private struct ListSettingsView: View {
    let store: MailStore
    @AppStorage(CorresSettings.previewLinesKey) private var previewLines = 2
    @AppStorage(CorresSettings.showAvatarsKey) private var showAvatars = true
    @AppStorage(CorresSettings.summaryInListKey) private var summaryInList = false
    @AppStorage(CorresSettings.badgeKey) private var badge = CorresSettings.Badge.needsYou.rawValue

    var body: some View {
        Form {
            Section {
                Picker("Preview", selection: $previewLines) {
                    Text("None").tag(0)
                    Text("1 line").tag(1)
                    Text("2 lines").tag(2)
                    Text("3 lines").tag(3)
                }
                Toggle("Show pictures", isOn: $showAvatars)
                Toggle("Summaries as preview", isOn: $summaryInList)
            } footer: {
                Text("How much of each email shows in Mail. Needs You and Waiting keep one line, so the reason fits. With summaries as preview, an email Corres has summarized shows its summary instead of its opening words. Part of Corres Pro.")
            }
            Section {
                Picker("App icon badge", selection: $badge) {
                    ForEach(CorresSettings.Badge.allCases) { Text($0.title).tag($0.rawValue) }
                }
            } footer: {
                Text("Needs You counts only what asks something of you, so the number means something. Badges need notifications to be allowed for Corres.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(CorresPalette.canvas)
        .navigationTitle("Lists")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: badge) { WidgetBridge.update(from: store.threads) }
    }
}

// MARK: - Swipes

private struct SwipeSettingsView: View {
    @AppStorage("corres.trailingShortSwipeAction") private var trailingShortRaw = PrimarySwipeAction.archive.rawValue
    @AppStorage("corres.trailingLongSwipeAction") private var trailingLongRaw = PrimarySwipeAction.trash.rawValue
    @AppStorage("corres.leadingShortSwipeAction") private var leadingShortRaw = LeadingSwipeAction.pin.rawValue
    @AppStorage("corres.leadingLongSwipeAction") private var leadingLongRaw = LeadingSwipeAction.unread.rawValue

    var body: some View {
        Form {
            Section {
                Picker("Short swipe", selection: $trailingShortRaw) {
                    ForEach(PrimarySwipeAction.allCases) { Text($0.title).tag($0.rawValue) }
                }
                Picker("Long swipe", selection: $trailingLongRaw) {
                    ForEach(PrimarySwipeAction.allCases) { Text($0.title).tag($0.rawValue) }
                }
            } header: {
                Label("Swipe left", systemImage: "arrow.left")
            }
            Section {
                Picker("Short swipe", selection: $leadingShortRaw) {
                    ForEach(LeadingSwipeAction.allCases) { Text($0.settingsTitle).tag($0.rawValue) }
                }
                Picker("Long swipe", selection: $leadingLongRaw) {
                    ForEach(LeadingSwipeAction.allCases) { Text($0.settingsTitle).tag($0.rawValue) }
                }
            } header: {
                Label("Swipe right", systemImage: "arrow.right")
            } footer: {
                Text("A short swipe acts right away; swiping further does the second action. Snooze and Move to are one tap away in a conversation, or by pressing and holding a row.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(CorresPalette.canvas)
        .navigationTitle("Swipes")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Snippets

private struct SnippetSettingsView: View {
    @Environment(SnippetStore.self) private var store
    @State private var editing: SnippetStore.Snippet?

    var body: some View {
        Form {
            Section {
                ForEach(store.snippets) { snippet in
                    Button { editing = snippet } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(snippet.title).foregroundStyle(CorresPalette.ink)
                            Text(snippet.body).font(.footnote).foregroundStyle(CorresPalette.secondary).lineLimit(2)
                        }
                    }
                }
                .onDelete { store.delete(at: $0) }
                .onMove { store.move(from: $0, to: $1) }
                Button {
                    editing = SnippetStore.Snippet(title: "", body: "")
                } label: {
                    Label("New snippet", systemImage: "plus")
                }
            } footer: {
                Text("Insert a snippet from the bar above the keyboard in any message. Write \(SnippetStore.firstNameToken) and Corres fills in the recipient's first name. Snippets stay on this iPhone.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(CorresPalette.canvas)
        .navigationTitle("Snippets")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { EditButton() }
        .sheet(item: $editing) { snippet in
            SnippetEditor(snippet: snippet) { store.save($0) }
        }
    }
}

private struct SnippetEditor: View {
    @State var snippet: SnippetStore.Snippet
    let onSave: (SnippetStore.Snippet) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                TextField("Title", text: $snippet.title)
                Section {
                    TextEditor(text: $snippet.body).frame(minHeight: 160)
                } footer: {
                    Button("Insert \(SnippetStore.firstNameToken)") { snippet.body += SnippetStore.firstNameToken }
                        .font(.footnote.weight(.semibold))
                }
            }
            .navigationTitle(snippet.title.isEmpty ? "New Snippet" : "Edit Snippet")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(snippet)
                        dismiss()
                    }
                    .disabled(snippet.title.trimmingCharacters(in: .whitespaces).isEmpty
                              || snippet.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Notifications

private struct NotificationSettingsView: View {
    var auth: GoogleAuthService
    @Bindable var pushService: PushNotificationService
    @AppStorage(PushNotificationService.Level.key) private var level = PushNotificationService.Level.current.rawValue
    @AppStorage(PushNotificationService.NewSenderAlerts.timeSensitiveKey) private var newTimeSensitive = true
    @AppStorage(PushNotificationService.NewSenderAlerts.peopleKey) private var newPeople = true
    @AppStorage(PushNotificationService.NewSenderAlerts.otherKey) private var newOther = false
    @AppStorage(BriefNotifier.enabledKey) private var briefEnabled = false
    @AppStorage(BriefNotifier.hourKey) private var briefHour = 8
    @AppStorage(BriefNotifier.minuteKey) private var briefMinute = 0

    private var briefTime: Binding<Date> {
        Binding(
            get: { Calendar.current.date(bySettingHour: briefHour, minute: briefMinute, second: 0, of: .now) ?? .now },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                briefHour = parts.hour ?? 8
                briefMinute = parts.minute ?? 0
            }
        )
    }

    var body: some View {
        Form {
            Section {
                Toggle("New mail", isOn: Binding(
                    get: { pushService.isEnabled },
                    set: { newValue in
                        Task {
                            if newValue { await pushService.enableAll(accounts: auth.accounts.map(\.email)) }
                            else { await pushService.disableAll(accounts: auth.accounts.map(\.email)) }
                        }
                    }
                ))
            } footer: {
                Text("A small relay tells Corres that something changed in your mailbox. It never sees a subject, sender or message.")
            }
            if pushService.isEnabled {
                Section {
                    Picker("Notify me about", selection: $level) {
                        ForEach(PushNotificationService.Level.allCases) { option in
                            Text(option.title).tag(option.rawValue)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } header: {
                    Text("Notify me about")
                } footer: {
                    Text((PushNotificationService.Level(rawValue: level) ?? .people).detail
                         + " Everything is always in Corres when you open it.")
                }
                Section {
                    Toggle("Morning Brief", isOn: $briefEnabled)
                    if briefEnabled {
                        DatePicker("Time", selection: briefTime, displayedComponents: .hourAndMinute)
                    }
                } footer: {
                    Text("One quiet notification a day with what needs you and who you're waiting on. Tap it to open Brief.")
                }
                Section {
                    Toggle("Time-sensitive", isOn: $newTimeSensitive)
                    Toggle("From a person", isOn: $newPeople)
                    Toggle("Everything else", isOn: $newOther)
                } header: {
                    Text("New senders")
                } footer: {
                    Text("Someone's first email waits in New senders until you allow them. These still notify, marked \u{201C}New sender\u{201D}, and you can allow or block them right from the email. Blocked senders never notify.")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(CorresPalette.canvas)
        .navigationTitle("Notifications")
        .onChange(of: briefEnabled) { BriefNotifier.reschedule() }
        .onChange(of: briefHour) { BriefNotifier.reschedule() }
        .onChange(of: briefMinute) { BriefNotifier.reschedule() }
        .navigationBarTitleDisplayMode(.inline)
        .alert("Could not turn on notifications", isPresented: Binding(
            get: { pushService.errorMessage != nil },
            set: { if !$0 { pushService.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { pushService.errorMessage = nil }
        } message: { Text(pushService.errorMessage ?? "Please try again.") }
    }
}

// MARK: - Privacy

private struct PrivacyView: View {
    var body: some View {
        Form {
            Section {
                row("Corres never sees your Google password", "key",
                    "You sign in with Google directly. Corres receives a permission you can revoke anytime, kept in this iPhone's Keychain.")
                row("Your mail is read on this iPhone", "iphone",
                    "Sorting, summaries, suggested replies and rewrites run on Apple's on-device model. Your mail isn't sent to a server Corres runs, or to any AI company, to do it.")
                row("Trackers blocked", "shield.lefthalf.filled",
                    "Remote images, and the tracking pixels hidden in them, stay off until you choose to show them.")
                row("No read receipts, ever", "eye.slash",
                    "Corres never tells anyone you opened their email. Waiting is tracked from the conversation itself.")
                row("No ads, no analytics", "hand.raised",
                    "No advertising or analytics code is built into Corres.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(CorresPalette.canvas)
        .navigationTitle("Private by design")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ title: String, _ icon: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon).font(.title3).foregroundStyle(CorresPalette.accent).frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.body.weight(.medium))
                Text(detail).font(.subheadline).foregroundStyle(CorresPalette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }
}
