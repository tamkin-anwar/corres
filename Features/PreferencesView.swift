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
    /// For unsubscribing from Settings → Senders.
    var unsubscriber: UnsubscribeService? = nil
    @Environment(\.dismiss) private var dismiss
    @Environment(MailIntelligence.self) private var intelligence
    @AppStorage("corres.appearance") private var appearance = Appearance.system.rawValue
    @AppStorage(AccountPreferences.colorCodingKey) private var colorCoding = true
    /// Redraws the account rows when one is renamed or recoloured.
    @AppStorage(AccountPreferences.revisionKey) private var accountsRevision = 0
    @Environment(EntitlementStore.self) private var entitlements
    @State private var showingPaywall = false
    @State private var managingSubscription = false
    @State private var addingICloud = false
    @State private var addingOther = false

    #if DEBUG
    @State private var corpusStatus: String?

    /// Development builds only: saves recent Inbox mail as JSON in the
    /// app's Documents/corpus folder, for running Corres's reading over
    /// real mail on this Mac (`CORRES_CORPUS=… swift test --filter Corpus`).
    /// Never committed, never in TestFlight or the App Store.
    private var developerSection: some View {
        Section {
            Button("Export Test Corpus (500 per account)") {
                Task {
                    guard corpusStatus != "Exporting…" else { return }
                    corpusStatus = "Exporting…"
                    let folder = URL.documentsDirectory.appending(path: "corpus")
                    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    var total = 0, missing = 0
                    for account in auth.accounts.map(\.email) {
                        do {
                            let (items, failed) = try await MailClient().exportCorpus(account: account, limit: 500)
                            missing += failed
                            let data = try JSONEncoder().encode(items)
                            try data.write(to: folder.appending(path: "\(account).json"))
                            total += items.count
                        } catch {
                            corpusStatus = "Failed for \(account): \(String(describing: error))"
                            return
                        }
                    }
                    corpusStatus = "Saved \(total) emails" + (missing > 0 ? " (\(missing) Gmail didn't send)" : "") + " to \(folder.path())"
                    print("[Corpus] \(folder.path())")
                }
            }
            .disabled(auth.accounts.isEmpty || corpusStatus == "Exporting…")
            Button("Audit Summaries on Test Corpus") {
                Task {
                    guard !(corpusStatus ?? "").hasPrefix("Auditing") else { return }
                    let folder = URL.documentsDirectory.appending(path: "corpus")
                    let files = ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
                        .filter { $0.pathExtension == "json" }
                    let emails = files.flatMap { (try? JSONDecoder().decode([Correspondence].self, from: Data(contentsOf: $0))) ?? [] }
                    guard !emails.isEmpty else {
                        corpusStatus = "Export a test corpus first."
                        return
                    }
                    let file = folder.appending(path: "summaries.tsv")
                    let report = await intelligence.auditSummaries(emails, to: file) { done, total in
                        corpusStatus = "Auditing \(done) of \(total)…"
                    }
                    try? report.write(to: file, atomically: true, encoding: .utf8)
                    corpusStatus = (report.split(separator: "\n").last.map(String.init) ?? "") + " → \(file.path())"
                    print("[Audit] \(file.path())")
                }
            }
            .disabled(!intelligence.isAvailable || (corpusStatus ?? "").hasPrefix("Auditing"))
        } header: {
            Text("Developer")
        } footer: {
            if let corpusStatus { Text(corpusStatus).textSelection(.enabled) }
        }
    }
    #endif

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
                        OutOfOfficeView(auth: auth)
                    } label: {
                        settingLabel("Out of Office", "airplane")
                    }
                    NavigationLink {
                        SendersView(store: store, unsubscriber: unsubscriber)
                    } label: {
                        settingLabel("Senders", "person.2")
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
                        ReadingBarSettingsView()
                    } label: {
                        settingLabel("Email Toolbar", "ellipsis.rectangle")
                    }
                    NavigationLink {
                        SnippetSettingsView()
                    } label: {
                        settingLabel("Snippets", "text.badge.plus")
                    }
                    NavigationLink {
                        NotificationSettingsView(auth: auth, pushService: pushService, store: store)
                    } label: {
                        LabeledContent {
                            Text(auth.accounts.isEmpty ? "Needs an Account" : (pushService.isEnabled ? "On" : "Off"))
                        } label: {
                            settingLabel("Notifications", "bell.badge")
                        }
                    }
                    .disabled(auth.accounts.isEmpty)
                }
                Section {
                    LabeledContent {
                        Text(intelligence.isAvailable ? "On this \(Device.name)" : "Not available")
                    } label: {
                        settingLabel("Apple Intelligence", "sparkle")
                    }
                } header: {
                    Text("Intelligence")
                } footer: {
                    Text(intelligence.isAvailable
                         ? "Sorting, summaries, suggested replies and rewrites happen on this \(Device.name) with Apple Intelligence. Nothing goes to a server."
                         : "Turn on Apple Intelligence in the Settings app for summaries, suggested replies and rewrites. Needs You still sorts your mail without it.")
                }
                Section {
                    NavigationLink {
                        PrivacyView()
                    } label: {
                        LabeledContent {
                            Text("Read on this \(Device.name)")
                        } label: {
                            settingLabel("Private by Design", "lock.shield")
                        }
                    }
                }
                #if DEBUG
                developerSection
                #endif
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
            .sheet(isPresented: $addingOther) {
                OtherEmailSignInView(auth: auth) { previousCount in
                    Task { await finishConnecting(after: previousCount) }
                } onUseSignIn: { provider in
                    // After this sheet has gone, so the two don't collide.
                    Task { try? await Task.sleep(for: .milliseconds(500)); connect(provider) }
                }
            }
            .sheet(isPresented: $addingICloud) {
                ICloudSignInView(auth: auth) { previousCount in
                    Task { await finishConnecting(after: previousCount) }
                }
            }
            .manageSubscriptionsSheet(isPresented: $managingSubscription)
            .alert("Corres Pro", isPresented: Binding(
                get: { entitlements.errorMessage != nil && !showingPaywall },
                set: { if !$0 { entitlements.errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { entitlements.errorMessage = nil }
            } message: { Text(entitlements.errorMessage ?? "") }
            .alert("Couldn't Connect", isPresented: Binding(
                get: { auth.errorMessage != nil },
                set: { if !$0 { auth.errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { auth.errorMessage = nil }
            } message: { Text(auth.errorMessage ?? "Try again.") }

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
                    Text(entitlements.plan != .none ? entitlements.plan.title
                         : entitlements.isPro ? "Corres Pro · Beta" : "Corres Pro").font(.body.weight(.semibold))
                    Text(planStatus).font(.footnote).foregroundStyle(CorresPalette.secondary)
                }
            }
            .padding(.vertical, 2)
            switch entitlements.plan {
            case .none:
                Button("Try Corres Pro Free") { showingPaywall = true }
            case .monthly, .annual:
                Button("Manage Subscription") { managingSubscription = true }
            case .lifetime:
                EmptyView()
            }
            Button("Restore Purchases") { Task { await entitlements.restore() } }
            Button("Redeem Code") {
                    // Close this sheet first so Apple's sheet isn't stacked on it.
                    dismiss()
                    Task {
                        try? await Task.sleep(for: .milliseconds(450))
                        await entitlements.presentRedeemSheet()
                    }
                }
            if EntitlementStore.isBetaBuild && entitlements.hasBetaAccess {
                Toggle("Preview as Free User", isOn: Bindable(entitlements).previewAsFree)
            }
        } header: {
            Text("Plan").accessibilityIdentifier(EntitlementStore.buildKind)
        } footer: {
            if entitlements.isPro && entitlements.plan == .none {
                Text("Pro is included while you test the beta. Preview as Free User shows the app as it is without Pro.")
            } else if !entitlements.isPro {
                Text("Without Pro, Mail keeps working: read, reply, archive and search. Brief, Needs You, Waiting, Ask and the on-device intelligence need Pro.")
            }
        }
    }

    private var planStatus: String {
        switch entitlements.plan {
        case .none where entitlements.isPro:
            return "Included for beta testers"
        case .none:
            if let monthly = entitlements.product(EntitlementStore.ProductID.monthly),
               let annual = entitlements.product(EntitlementStore.ProductID.annual) {
                return "Try it free, then \(monthly.displayPrice) a month or \(annual.displayPrice) a year."
            }
            return "Try it free for 14 days."
        case .monthly(let renews, let inTrial), .annual(let renews, let inTrial):
            let date = renews.map { $0.formatted(date: .abbreviated, time: .omitted) } ?? "soon"
            return inTrial ? "Free trial · first charge \(date)" : "Renews \(date)"
        case .lifetime(let purchased, let familyShared):
            // What you have, as Apple's own purchase screens say it.
            return familyShared ? "Shared by your family"
                : "Yours for good · bought \(purchased.formatted(date: .abbreviated, time: .omitted))"
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
                            Text("Connect Your Email").font(.headline)
                            Text("You're looking at sample mail.").font(.subheadline).foregroundStyle(CorresPalette.secondary)
                        }
                    }
                    Button { connect(.google) } label: {
                        if auth.isSigningIn || sync.isSyncing { ProgressView() } else { Text("Continue with Google") }
                    }
                    .buttonStyle(CorresButtonStyle())
                    .disabled(auth.isSigningIn || sync.isSyncing)
                    Button { connect(.microsoft) } label: {
                        Text("Continue with Microsoft")
                    }
                    .buttonStyle(CorresButtonStyle())
                    .disabled(auth.isSigningIn || sync.isSyncing)
                    Button { connect(.icloud) } label: {
                        Text("Continue with iCloud Mail")
                    }
                    .buttonStyle(CorresButtonStyle())
                    .disabled(auth.isSigningIn || sync.isSyncing)
                    Button("Other Email Account") { connect(.imap) }
                        .font(.subheadline.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .disabled(auth.isSigningIn || sync.isSyncing)
                    Text("Gmail, Outlook, iCloud Mail, Yahoo, AOL, Fastmail and almost any other email. Your mail is sorted and read on this \(Device.name).")
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
                // Which service, as Mail asks.
                Menu {
                    Button("Gmail") { connect(.google) }
                    Button("Outlook") { connect(.microsoft) }
                    Button("iCloud Mail") { connect(.icloud) }
                    Button("Other Email") { connect(.imap) }
                } label: {
                    if auth.isSigningIn || sync.isSyncing {
                        ProgressView()
                    } else {
                        settingLabel("Add Account", "plus")
                    }
                }
                .disabled(auth.isSigningIn || sync.isSyncing)
                if auth.accounts.count > 1 {
                    Toggle(isOn: $colorCoding) { settingLabel("Color-Code Accounts", "paintpalette") }
                        .onChange(of: colorCoding) { AccountPreferences.changed() }
                }
            } header: {
                Text("Accounts")
            } footer: {
                Text(auth.accounts.count > 1
                     ? "Every account shares All Inboxes, newest first, each marked with its color. Switch to one account by tapping your photo."
                     : "Every account shares one inbox, newest first. Switch to one account from the top of any screen.")
            }
        }
    }

    /// Its name in Corres over its address, as Spark lists accounts, with
    /// its colour once there's more than one.
    private func accountRow(_ account: GmailAccount) -> some View {
        let profile = auth.profile(for: account.email)
        let color = AccountPreferences.color(for: account.email, among: auth.accounts.map(\.email))
        return HStack(spacing: 12) {
            AccountAvatar(email: account.email, name: profile?.name, photoURL: profile?.photoURL, size: 40)
            VStack(alignment: .leading, spacing: 1) {
                Text(AccountPreferences.nickname(for: account.email)).font(.body.weight(.medium)).lineLimit(1)
                Text(account.email).font(.footnote).foregroundStyle(CorresPalette.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if let color {
                Circle().fill(color).frame(width: 10, height: 10).accessibilityHidden(true)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private func connect(_ provider: MailProvider) {
        if provider == .icloud { addingICloud = true; return }
        if provider == .imap { addingOther = true; return }
        Task {
            let previousCount = auth.accounts.count
            if provider == .microsoft { await auth.signInOutlook() } else { await auth.signIn() }
            await finishConnecting(after: previousCount)
        }
    }

    /// The new account's first sync, in place of the sample mail.
    private func finishConnecting(after previousCount: Int) async {
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

/// One account, set the way Spark sets one, in Corres's words: what Corres
/// calls it and its colour, the name your email is from, whether it's in
/// All Inboxes, its own notifications and signatures. Removing it takes
/// its mail off this iPhone; nothing is deleted from the account.
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
    /// Only a sync you asked for here reports failing: background syncs
    /// retry on their own, and an old failure shouldn't greet you later.
    @State private var syncFailed = false
    @AppStorage private var icloudInstant: Bool
    @State private var changingInstant = false
    @State private var instantError: String?
    @State private var updatingICloudPassword = false
    @State private var updatingOtherPassword = false
    @AppStorage private var nickname: String
    @AppStorage private var senderName: String
    @AppStorage private var showsInAllInboxes: Bool
    @AppStorage private var notify: String
    @AppStorage(AccountPreferences.colorCodingKey) private var colorCoding = true
    @AppStorage(AccountPreferences.revisionKey) private var accountsRevision = 0

    init(account: GmailAccount, store: MailStore, auth: GoogleAuthService, sync: GmailSyncService, pushService: PushNotificationService) {
        self.account = account
        self.store = store
        self.auth = auth
        self.sync = sync
        self.pushService = pushService
        let email = account.email
        _nickname = AppStorage(wrappedValue: "", AccountPreferences.nicknameKey(for: email))
        _senderName = AppStorage(wrappedValue: "", AccountPreferences.senderNameKey(for: email))
        _showsInAllInboxes = AppStorage(wrappedValue: true, AccountPreferences.allInboxesKey(for: email))
        _notify = AppStorage(wrappedValue: AccountPreferences.notify(for: email).rawValue, AccountPreferences.notifyKey(for: email))
        _icloudInstant = AppStorage(wrappedValue: false, AccountPreferences.icloudInstantKey(for: email))
    }

    private var provider: MailProvider { MailAccounts.provider(for: account.email) }
    private var emails: [String] { auth.accounts.map(\.email) }
    private var tone: AccountPreferences.Tone { AccountPreferences.tone(for: account.email, among: emails) }

    var body: some View {
        let profile = auth.profile(for: account.email)
        Form {
            Section {
                VStack(spacing: 10) {
                    AccountAvatar(email: account.email, name: profile?.name, photoURL: profile?.photoURL, size: 76)
                        .padding(4)
                        .overlay(Circle().strokeBorder(colorCoding && emails.count > 1 ? tone.color : .clear, lineWidth: 2.5))
                    Text(AccountPreferences.nickname(for: account.email)).font(.title3.weight(.semibold))
                    Text(account.email).font(.subheadline).foregroundStyle(CorresPalette.secondary)
                    if AccountPreferences.nickname(for: account.email) != provider.title {
                        Label(provider.title, systemImage: "envelope").font(.caption).foregroundStyle(CorresPalette.tertiary)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .listRowBackground(Color.clear)
            }
            Section {
                LabeledContent("Name") {
                    TextField(MailAccounts.serviceName(for: account.email), text: $nickname)
                        .multilineTextAlignment(.trailing)
                        .submitLabel(.done)
                }
                LabeledContent("Your Name") {
                    // What it sends under when left blank: its own name, or
                    // the one you use on your other accounts.
                    TextField(profile?.name
                              ?? auth.accounts.lazy.compactMap { AccountPreferences.senderName(for: $0.email) ?? auth.profile(for: $0.email)?.name }.first
                              ?? "Name", text: $senderName)
                        .multilineTextAlignment(.trailing)
                        .textContentType(.name)
                        .submitLabel(.done)
                }
            } footer: {
                Text("Name is what Corres calls this account, like Work or Personal. Your Name is who your email is from.")
            }
            if emails.count > 1 {
                Section {
                    if colorCoding {
                        TonePicker(selection: Binding(
                            get: { tone.id },
                            set: { UserDefaults.standard.set($0, forKey: AccountPreferences.toneKey(for: account.email)); AccountPreferences.changed() }
                        ))
                    }
                    Toggle("Show in All Inboxes", isOn: $showsInAllInboxes)
                } header: {
                    Text(colorCoding ? "Color" : "All Inboxes")
                } footer: {
                    Text(showsInAllInboxes
                         ? "Its mail is marked with this color in All Inboxes, so you can tell your accounts apart at a glance."
                         : "Kept out of All Inboxes, Needs You, Waiting and the Brief. It still syncs; switch to it by tapping your photo.")
                }
            }
            if pushService.isEnabled {
                Section {
                    Picker("Notifications", selection: $notify) {
                        ForEach(AccountPreferences.Notify.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } header: {
                    Text("Notifications")
                } footer: {
                    Text(notifyFooter)
                }
                if provider.usesIMAP {
                    Section {
                        Toggle("Instant Notifications", isOn: Binding(
                            get: { icloudInstant },
                            set: { on in setInstant(on) }
                        ))
                        .disabled(changingInstant)
                    } footer: {
                        Text(instantError ?? (icloudInstant
                             ? "New mail notifies the moment it arrives. Corres's server keeps this account's app-specific password, sealed so only its mail watcher can open it, and never reads or stores your email. Turn this off to delete it."
                             : provider == .icloud
                             ? "iCloud tells only Apple Mail the moment mail arrives. Without this, Corres checks when iOS lets it, usually within the hour, and instantly while it's open. Turn it on and Corres's server watches your Inbox for you; it never reads or stores your email."
                             : "Without this, Corres checks when iOS lets it, usually within the hour, and instantly while it's open. Turn it on and Corres's server watches your Inbox for you; it never reads or stores your email."))
                            .foregroundStyle(instantError == nil ? CorresPalette.secondary : CorresPalette.alert)
                    }
                }
            }
            Section {
                SignatureDefaultPicker(account: account.email, reply: false)
                SignatureDefaultPicker(account: account.email, reply: true)
                NavigationLink("Edit Signatures") { SignaturesView(auth: auth) }
            } header: {
                Text("Signatures")
            } footer: {
                Text("Pick another for one email from Signature, below what you're writing.")
            }
            let aliases = SendAsDirectory.shared.addresses(for: account.email).filter { !$0.isPrimary }
            if !aliases.isEmpty {
                Section {
                    ForEach(aliases, id: \.email) { alias in
                        LabeledContent(alias.email) { if !alias.name.isEmpty { Text(alias.name) } }
                    }
                } header: {
                    Text("Also Sends As")
                } footer: {
                    Text("Choose one from From when you write. Add or remove them in \(MailAccounts.serviceTitle(for: account.email))'s settings.")
                }
            }
            Section {
                Button {
                    Task {
                        syncing = true
                        if await sync.syncNow(account: account.email) { await store.refresh() } else { syncFailed = true }
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
                        Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                .disabled(syncing || sync.isSyncing)
                .alert("Couldn't Sync", isPresented: $syncFailed) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(provider == .icloud
                         ? "\(MailAccounts.serviceTitle(for: account.email)) didn't answer. Check your connection, or update the app-specific password if it keeps happening."
                         : "\(MailAccounts.serviceTitle(for: account.email)) didn't answer. Check your connection, or reconnect if it keeps happening.")
                }
                Button {
                    if provider == .icloud { updatingICloudPassword = true }
                    else if provider == .imap { updatingOtherPassword = true }
                    else { Task { await auth.reconnect(account.email) } }
                } label: {
                    Label(provider == .microsoft ? "Reconnect with Microsoft"
                          : provider == .icloud ? "Update App-Specific Password"
                          : provider == .imap ? "Update Password" : "Reconnect with Google", systemImage: "key")
                }
                .sheet(isPresented: $updatingOtherPassword) {
                    OtherEmailSignInView(auth: auth, reconnecting: account.email) { _ in
                        Task { _ = await sync.syncIfConnected(account: account.email) }
                    } onUseSignIn: { _ in }
                }
                .sheet(isPresented: $updatingICloudPassword) {
                    ICloudSignInView(auth: auth, reconnecting: account.email) { _ in
                        Task {
                            _ = await sync.syncIfConnected(account: account.email)
                            // The watcher gets the new password too.
                            if icloudInstant { try? await pushService.setICloudInstant(true, account: account.email) }
                        }
                    }
                }
            } footer: {
                Text(provider == .icloud
                     ? "If iCloud stops syncing, make a new app-specific password at account.apple.com and update it here."
                     : provider == .imap
                     ? "If this account stops syncing, its password may have changed. Update it here."
                     : "If marking as read, archiving or flagging stops working, reconnect and keep every permission checked.")
            }
            Section {
                Button("Remove Account", role: .destructive) { confirmingRemoval = true }
            } footer: {
                Text("Removes this account and its mail from Corres on this \(Device.name). Nothing is deleted from \(MailAccounts.serviceTitle(for: account.email)).")
            }
        }
        .scrollContentBackground(.hidden)
        .background(CorresPalette.canvas)
        .navigationTitle(AccountPreferences.nickname(for: account.email))
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: nickname) { AccountPreferences.changed() }
        // Off stops the instant alerts at the relay too; back on starts them.
        .onChange(of: notify) {
            PushNotificationService.publishPolicy(accounts: auth.accounts.map(\.email), threads: store.threads)
            Task { await pushService.renewWatch(accounts: [account.email]) }
        }
        .onChange(of: showsInAllInboxes) { AccountPreferences.changed() }
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
            Text("Its mail is removed from this \(Device.name). It stays in \(MailAccounts.serviceTitle(for: account.email)).")
        }
    }

    private func setInstant(_ on: Bool) {
        changingInstant = true
        instantError = nil
        Task {
            do {
                try await pushService.setICloudInstant(on, account: account.email)
                icloudInstant = on
            } catch PushNotificationService.ICloudInstantError.notificationsOff {
                instantError = "Turn on notifications for Corres first, in Settings > Notifications."
            } catch {
                instantError = "Couldn't reach Corres's server. Try again in a moment."
            }
            changingInstant = false
        }
    }

    private var notifyFooter: String {
        let choice = AccountPreferences.Notify(rawValue: notify) ?? .standard
        switch choice {
        case .standard: return "Follows Settings → Notifications: \(PushNotificationService.Level.current.title)."
        case .off: return "This account stays quiet. Its mail still syncs and sorts."
        case .everything: return PushNotificationService.Level.everything.detail
        case .people: return PushNotificationService.Level.people.detail
        case .needsYou: return PushNotificationService.Level.needsYou.detail
        }
    }
}

/// The eight account colours as swatches, the chosen one ringed.
private struct TonePicker: View {
    @Binding var selection: Int

    var body: some View {
        HStack(spacing: 0) {
            ForEach(AccountPreferences.tones) { tone in
                Button {
                    withAnimation(.snappy(duration: 0.2)) { selection = tone.id }
                } label: {
                    Circle().fill(tone.color)
                        .frame(width: 26, height: 26)
                        .padding(4)
                        .overlay(Circle().strokeBorder(selection == tone.id ? tone.color : .clear, lineWidth: 2))
                        .overlay {
                            if selection == tone.id {
                                Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(.white)
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tone.name)
                .accessibilityAddTraits(selection == tone.id ? .isSelected : [])
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Signatures

/// Which signature an account adds to new mail, or to replies and forwards.
private struct SignatureDefaultPicker: View {
    let account: String
    let reply: Bool
    @AppStorage private var selection: String
    @AppStorage(Signatures.key) private var library = Data()

    init(account: String, reply: Bool) {
        self.account = account
        self.reply = reply
        _selection = AppStorage(wrappedValue: Signatures.defaultID(for: account, reply: reply), Signatures.defaultKey(for: account, reply: reply))
    }

    var body: some View {
        Picker(reply ? "Replies & Forwards" : "New Emails", selection: $selection) {
            Text("None").tag("")
            ForEach(Signatures.all) { Text($0.name).tag($0.id) }
        }
    }
}

/// Every signature: add, edit, delete, and each account's two defaults,
/// as Gmail's signature settings, on one screen.
private struct SignaturesView: View {
    var auth: GoogleAuthService
    @State private var signatures = Signatures.all
    @State private var editing: Signature?

    private var accounts: [String] { auth.accounts.isEmpty ? ["sample"] : auth.accounts.map(\.email) }

    var body: some View {
        Form {
            Section {
                ForEach(signatures) { signature in
                    Button { editing = signature } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(signature.name).font(.body.weight(.medium)).foregroundStyle(CorresPalette.ink)
                            Text(signature.text).font(.footnote).foregroundStyle(CorresPalette.secondary).lineLimit(2)
                        }
                        .padding(.vertical, 2)
                    }
                }
                .onDelete { offsets in
                    for index in offsets { Signatures.delete(signatures[index].id) }
                    signatures = Signatures.all
                }
                Button {
                    editing = Signature(name: "", text: "")
                } label: {
                    Label("Add Signature", systemImage: "plus")
                }
            } footer: {
                Text("Added below what you write, above the email you're replying to.")
            }
            if !signatures.isEmpty {
                ForEach(accounts, id: \.self) { account in
                    Section {
                        SignatureDefaultPicker(account: account, reply: false)
                        SignatureDefaultPicker(account: account, reply: true)
                    } header: {
                        Text(account == "sample" ? "Defaults" : AccountPreferences.nickname(for: account) + " · " + account)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(CorresPalette.canvas)
        .navigationTitle("Signatures")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editing) { signature in
            SignatureEditor(signature: signature, accounts: accounts) { edited in
                var saved = edited
                // Unnamed: "Signature", then "Signature 2", as Gmail numbers them.
                if saved.name.isEmpty { saved.name = signatures.isEmpty ? "Signature" : "Signature \(signatures.count + 1)" }
                var all = Signatures.all
                if let index = all.firstIndex(where: { $0.id == saved.id }) { all[index] = saved } else { all.append(saved) }
                let isFirst = Signatures.all.isEmpty
                Signatures.all = all
                // The first signature becomes every account's default, as
                // the single signature did before.
                if isFirst {
                    for account in accounts {
                        Signatures.setDefault(saved.id, for: account, reply: false)
                        Signatures.setDefault(saved.id, for: account, reply: true)
                    }
                }
                signatures = Signatures.all
            }
        }
    }
}

private struct SignatureEditor: View {
    @State var signature: Signature
    let accounts: [String]
    let onSave: (Signature) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Best regards,\nYour name\nTitle · Company", text: $signature.text, axis: .vertical)
                        .lineLimit(4...14)
                }
                Section {
                    TextField("Name, like Full or Short", text: $signature.name)
                } footer: {
                    Text("Only you see the name, when choosing a signature.")
                }
            }
            .scrollContentBackground(.hidden)
            .background(CorresPalette.canvas)
            .navigationTitle(signature.name.isEmpty ? "New Signature" : signature.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", role: .cancel) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        signature.name = signature.name.trimmingCharacters(in: .whitespaces)
                        onSave(signature)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                    .disabled(signature.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
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
    @AppStorage(CorresSettings.suggestContactsKey) private var suggestContacts = true
    @Environment(PeopleDirectory.self) private var people: PeopleDirectory?

    var body: some View {
        Form {
            Section {
                Toggle("Suggest from Contacts", isOn: $suggestContacts)
                    .onChange(of: suggestContacts) { Task { await people?.contactsSettingChanged() } }
            } header: {
                Text("Addressing")
            } footer: {
                Text("As you type a name in To, Cc or search, Corres suggests people you email, the ones you write to most first, and people in your Contacts once you allow it. All on this \(Device.name). Press and hold a suggestion to stop seeing it.")
            }
            Section {
                NavigationLink {
                    SignaturesView(auth: auth)
                } label: {
                    LabeledContent("Signatures") {
                        let count = Signatures.all.count
                        Text(count == 0 ? "None" : "\(count)")
                    }
                }
            } footer: {
                Text("Keep several, like a full one for new email and a short one for replies, and choose each account's.")
            }
            Section {
                Picker("Undo Send", selection: $undoSeconds) {
                    ForEach(CorresSettings.undoSendChoices, id: \.self) { seconds in
                        Text(seconds == 0 ? "Off" : "\(seconds) seconds").tag(seconds)
                    }
                }
                Picker("Default Reply", selection: $defaultReply) {
                    ForEach(CorresSettings.DefaultReply.allCases) { Text($0.title).tag($0.rawValue) }
                }
                if auth.accounts.count > 1 {
                    Picker("Send New Mail From", selection: $defaultFrom) {
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

// MARK: - Reading

private struct ReadingSettingsView: View {
    @AppStorage(CorresSettings.remoteImagesKey) private var remoteImages = CorresSettings.RemoteImages.ask.rawValue
    @AppStorage(CorresSettings.markReadOnOpenKey) private var markReadOnOpen = true
    @AppStorage(CorresSettings.confirmTrashKey) private var confirmTrash = false
    @AppStorage(CorresSettings.openLinksKey) private var openLinks = CorresSettings.OpenLinks.inCorres.rawValue
    @AppStorage(AfterRemoval.key) private var afterRemoval = AfterRemoval.nextConversation.rawValue
    @AppStorage(CorresSettings.summariesKey) private var summaries = true
    @AppStorage(CorresSettings.keyDetailsKey) private var keyDetails = true
    @Environment(MailIntelligence.self) private var intelligence

    var body: some View {
        Form {
            Section {
                Toggle("Key Details", isOn: $keyDetails)
                Toggle("Summarize Emails", isOn: $summaries)
            } header: {
                Text("At the Top of Each Email")
            } footer: {
                Text("Key Details: a receipt's or bill's status and amounts, a delivery's date, and what a long email asks of you, read straight from the email. "
                     + (intelligence.isAvailable
                        ? "Summaries are written on this \(Device.name) and checked against the email: every name, number and date has to be in it. Summaries are part of Corres Pro."
                        : "Summaries need Apple Intelligence, and are part of Corres Pro."))
            }
            Section {
                Picker("Remote Images", selection: $remoteImages) {
                    ForEach(CorresSettings.RemoteImages.allCases) { Text($0.title).tag($0.rawValue) }
                }
            } footer: {
                Text(remoteImages == CorresSettings.RemoteImages.ask.rawValue
                     ? "Images from the web stay off until you tap Show Images, so senders can't tell when you opened their email. Trusting a sender loads theirs from then on."
                     : "Images load as soon as you open an email. Senders using tracking images can see when you opened it.")
            }
            Section {
                Toggle("Mark as Read When Opened", isOn: $markReadOnOpen)
                Toggle("Ask Before Moving to Trash", isOn: $confirmTrash)
                Picker("After Archiving", selection: $afterRemoval) {
                    Text("Next Conversation").tag(AfterRemoval.nextConversation.rawValue)
                    Text("Back to List").tag(AfterRemoval.list.rawValue)
                }
                Picker("Open Links", selection: $openLinks) {
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

/// Every lesson Corres has learned from your corrections, with a way to
/// forget each one: learning you can see and undo, not a black box.
private struct LessonsView: View {
    @State private var lessons = SenderLessons.all.sorted { $0.learnedAt > $1.learnedAt }
    @AppStorage(SenderLessons.enabledKey) private var isEnabled = true

    var body: some View {
        Form {
            Section {
                Toggle("Learn from My Changes", isOn: $isEnabled)
            } footer: {
                Text("When you say an email Apple Intelligence flagged needs no action, Corres stops flagging that kind of email from that sender; their other mail is untouched. When you move a sender's automated email into Needs You, it keeps that kind there. Corres also notices habits, like lists you never open or people you always read at once, and suggests a change, at most once a day. Everything stays on this \(Device.name).")
            }
            Section {
                if lessons.isEmpty {
                    Text("Nothing yet. Corres learns as you correct it.").foregroundStyle(CorresPalette.secondary)
                } else {
                    ForEach(lessons) { lesson in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(lesson.name).font(.body)
                            Text("\(lesson.summary) · \(lesson.learnedAt.formatted(.relative(presentation: .named)))")
                                .font(.footnote).foregroundStyle(CorresPalette.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                    .onDelete { offsets in
                        for index in offsets { SenderLessons.forget(lessons[index].id) }
                        lessons.remove(atOffsets: offsets)
                    }
                }
            } header: {
                Text("Lessons")
            } footer: {
                if !lessons.isEmpty { Text("Swipe a lesson to forget it.") }
            }
            Section {
                    Button("Forget Everything", role: .destructive) {
                        SenderLessons.forgetAll()
                        HabitWatcher.shared.forgetAll()
                        UserDefaults.standard.removeObject(forKey: "corres.snoozeHabits")
                        lessons = []
                    }
            } footer: {
                Text("Also forgets the habits Corres has noticed: which lists you open, who you read first, and your usual snoozes.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(CorresPalette.canvas)
        .navigationTitle("What Corres Has Learned")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct SortingSettingsView: View {
    let store: MailStore
    @State private var vipsStorage: [String] = CorresSettings.vips.sorted()
    @AppStorage(CorresSettings.sensitivityKey) private var sensitivity = InboxClassifier.Sensitivity.balanced.rawValue
    @AppStorage(CorresSettings.followUpDaysKey) private var followUpDays = 3
    @AppStorage(CorresSettings.morningHourKey) private var morningHour = 8
    @AppStorage(CorresSettings.laterTodayEveningKey) private var laterTodayEvening = false
    @AppStorage(CorresSettings.screenNewSendersKey) private var screenNewSenders = false
    @State private var showingScreener = false

    var body: some View {
        Form {
            Section {
                Toggle("Screen New Senders", isOn: $screenNewSenders)
                    .onChange(of: screenNewSenders) {
                        CorresSettings.applyToCore()
                        store.listsShouldRebuild()
                    }
                // Also reached from the Brief; here so it's there without Pro.
                let waiting = Set(store.pendingSenderThreads.compactMap(\.senderEmail)).count
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
            }
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
                NavigationLink {
                    LessonsView()
                } label: {
                    Label("What Corres Has Learned", systemImage: "brain")
                }
            } footer: {
                Text("Corres learns from your corrections, on this \(Device.name). Every lesson is listed here, and you can make it forget any of them.")
            }
            Section {
                Picker("Needs You", selection: $sensitivity) {
                    Text("Focused").tag(InboxClassifier.Sensitivity.focused.rawValue)
                    Text("Balanced").tag(InboxClassifier.Sensitivity.balanced.rawValue)
                    Text("Everything from People").tag(InboxClassifier.Sensitivity.inclusive.rawValue)
                }
                Picker("Follow Up After", selection: $followUpDays) {
                    ForEach(CorresSettings.followUpChoices, id: \.self) { Text($0 == 1 ? "1 day" : "\($0) days").tag($0) }
                }
            } footer: {
                Text(sensitivityDetail + " Waiting turns into Follow up once someone hasn't replied in that long.")
            }
            Section {
                Picker("Start of Day", selection: $morningHour) {
                    ForEach(6...10, id: \.self) { hour in
                        Text(Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: .now)!
                                .formatted(date: .omitted, time: .shortened)).tag(hour)
                    }
                }
                Picker("Later Today", selection: $laterTodayEvening) {
                    Text("In 3 Hours").tag(false)
                    Text("This Evening, 6 PM").tag(true)
                }
            } header: {
                Text("Snooze")
            } footer: {
                Text("Tomorrow and Next Week come back at the start of your day; This Weekend an hour later, on Saturday.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(CorresPalette.canvas)
        .sheet(isPresented: $showingScreener) { ScreenerView(store: store) }
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

    var body: some View {
        Form {
            Section {
                Picker("Preview", selection: $previewLines) {
                    Text("None").tag(0)
                    Text("1 Line").tag(1)
                    Text("2 Lines").tag(2)
                    Text("3 Lines").tag(3)
                }
                Toggle("Show Pictures", isOn: $showAvatars)
                Toggle("Summaries as Preview", isOn: $summaryInList)
            } footer: {
                Text("How much of each email shows in Mail. Needs You and Waiting keep one line, so the reason fits. With summaries as preview, an email Corres has summarized shows its summary instead of its opening words. Part of Corres Pro.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(CorresPalette.canvas)
        .navigationTitle("Lists")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Swipes

/// Settings → Tab Bar: which screens get a tab, and their order, the way
/// Spark and Music let you arrange theirs. Drag to reorder; remove a tab
/// and it moves to More, still reachable from links (the Brief's "All",
/// widgets, Siri). Mail always stays.

/// Settings → Email Toolbar: which actions sit on the bar under an email,
/// in order, like Tab Bar. Everything else is one tap away in its ⋯ menu.
private struct ReadingBarSettingsView: View {
    @AppStorage(CorresSettings.readingBarKey) private var raw = ""
    private typealias Action = CorresSettings.ReadingAction
    private var actions: [Action] { CorresSettings.readingBar(from: raw) }
    private var others: [Action] { Action.allCases.filter { !actions.contains($0) } }
    private var isFull: Bool { actions.count >= CorresSettings.readingBarLimit }
    private var groups: [String] {
        var seen = Set<String>()
        return others.map(\.group).filter { seen.insert($0).inserted }
    }

    private func save(_ actions: [Action]) { raw = CorresSettings.raw(for: actions) }

    var body: some View {
        List {
            Section {
                ForEach(actions) { action in
                    Label(action.rawValue, systemImage: action.systemImage)
                }
                .onMove { from, to in
                    var updated = actions
                    updated.move(fromOffsets: from, toOffset: to)
                    save(updated)
                }
                .onDelete { offsets in
                    var updated = actions
                    updated.remove(atOffsets: offsets)
                    save(updated)
                }
            } header: {
                Text("On the Bar")
            } footer: {
                Text("Drag to reorder, up to \(CorresSettings.readingBarLimit). Reply always stays beside the bar.")
            }
            ForEach(groups, id: \.self) { group in
                Section {
                    ForEach(others.filter { $0.group == group }) { action in
                        Button {
                            save(actions + [action])
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "plus.circle.fill").foregroundStyle(isFull ? CorresPalette.tertiary : .green)
                                Label(action.rawValue, systemImage: action.systemImage).foregroundStyle(CorresPalette.ink)
                            }
                        }
                        .disabled(isFull)
                        .accessibilityLabel("Add \(action.rawValue)")
                    }
                } header: {
                    Text(group == groups.first ? "In the ⋯ menu · \(group)" : group)
                } footer: {
                    if group == groups.last {
                        Text(isFull ? "The bar is full. Remove one to add another." : "Still a tap away under ⋯ on the bar. An action that doesn't apply to an email (Unsubscribe without a list, Add to Calendar without an event) is dimmed on the bar.")
                    }
                }
            }
            Section {
                Button("Reset to Default") { raw = "" }
                    .disabled(actions == CorresSettings.defaultReadingBar)
            }
        }
        .environment(\.editMode, .constant(.active))
        .id(raw)
        .scrollContentBackground(.hidden)
        .background(CorresPalette.canvas)
        .navigationTitle("Email Toolbar")
        .navigationBarTitleDisplayMode(.inline)
        .sensoryFeedback(.selection, trigger: raw)
    }
}

private struct SwipeSettingsView: View {
    @AppStorage("corres.trailingShortSwipeAction") private var trailingShortRaw = PrimarySwipeAction.archive.rawValue
    @AppStorage("corres.trailingLongSwipeAction") private var trailingLongRaw = PrimarySwipeAction.trash.rawValue
    @AppStorage("corres.leadingShortSwipeAction") private var leadingShortRaw = LeadingSwipeAction.pin.rawValue
    @AppStorage("corres.leadingLongSwipeAction") private var leadingLongRaw = LeadingSwipeAction.unread.rawValue

    var body: some View {
        Form {
            Section {
                Picker("Short Swipe", selection: $trailingShortRaw) {
                    ForEach(PrimarySwipeAction.allCases) { Text($0.title).tag($0.rawValue) }
                }
                Picker("Long Swipe", selection: $trailingLongRaw) {
                    ForEach(PrimarySwipeAction.allCases) { Text($0.title).tag($0.rawValue) }
                }
            } header: {
                Label("Swipe left", systemImage: "arrow.left")
            }
            Section {
                Picker("Short Swipe", selection: $leadingShortRaw) {
                    ForEach(LeadingSwipeAction.allCases) { Text($0.settingsTitle).tag($0.rawValue) }
                }
                Picker("Long Swipe", selection: $leadingLongRaw) {
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
                Text("Insert a snippet from the bar above the keyboard in any message. Write \(SnippetStore.firstNameToken) and Corres fills in the recipient's first name. Snippets stay on this \(Device.name).")
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
    /// The New senders alerts only apply while new senders are held back;
    /// otherwise their mail notifies like anyone else's.
    @AppStorage(CorresSettings.screenNewSendersKey) private var screenNewSenders = false
    @AppStorage(PushNotificationService.NewSenderAlerts.peopleKey) private var newPeople = true
    @AppStorage(PushNotificationService.NewSenderAlerts.otherKey) private var newOther = false
    @AppStorage(BriefNotifier.enabledKey) private var briefEnabled = false
    @AppStorage(BriefNotifier.hourKey) private var briefHour = 8
    @AppStorage(BriefNotifier.minuteKey) private var briefMinute = 0
    @AppStorage(CorresSettings.badgeKey) private var badge = CorresSettings.Badge.needsYou.rawValue
    var store: MailStore?

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
                Toggle("New Mail", isOn: Binding(
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
                    Picker("Notify Me About", selection: $level) {
                        ForEach(PushNotificationService.Level.allCases) { option in
                            Text(option.title).tag(option.rawValue)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } header: {
                    Text("Notify Me About")
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
                if screenNewSenders {
                Section {
                    Toggle("Time-sensitive", isOn: $newTimeSensitive)
                    Toggle("From a Person", isOn: $newPeople)
                    Toggle("Everything Else", isOn: $newOther)
                } header: {
                    Text("New Senders")
                } footer: {
                    Text("Someone's first email waits in New Senders until you allow them. These still notify, marked \u{201C}New sender\u{201D}, and you can allow or block them right from the email. Blocked senders never notify.")
                }
                }
            }
            Section {
                Picker("App Icon Badge", selection: $badge) {
                    ForEach(CorresSettings.Badge.allCases) { Text($0.title).tag($0.rawValue) }
                }
            } footer: {
                Text((CorresSettings.Badge(rawValue: badge) ?? .needsYou).detail
                     + " Accounts left out of All Inboxes aren't counted.")
            }
            .onChange(of: badge) { if let store { WidgetBridge.update(from: store.threads) } }
        }
        .scrollContentBackground(.hidden)
        .background(CorresPalette.canvas)
        .navigationTitle("Notifications")
        .onChange(of: briefEnabled) { BriefNotifier.reschedule() }
        .onChange(of: briefHour) { BriefNotifier.reschedule() }
        .onChange(of: briefMinute) { BriefNotifier.reschedule() }
        .navigationBarTitleDisplayMode(.inline)
        .alert("Couldn't Turn On Notifications", isPresented: Binding(
            get: { pushService.errorMessage != nil },
            set: { if !$0 { pushService.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { pushService.errorMessage = nil }
        } message: { Text(pushService.errorMessage ?? "Try again.") }
    }
}

// MARK: - Privacy

private struct PrivacyView: View {
    var body: some View {
        Form {
            Section {
                row("Corres never sees your account password", "key",
                    "Gmail and Outlook sign in on Google's and Microsoft's own pages, and Corres gets a permission you can take back anytime. iCloud uses an app-specific password you can turn off at account.apple.com. Both stay in this \(Device.name)'s Keychain.")
                row("Your mail is read on this \(Device.name)", Device.name == "iPad" ? "ipad" : "iphone",
                    "Sorting, summaries, suggested replies and rewrites happen on this \(Device.name) with Apple Intelligence. Your mail never goes to Corres's servers or to an AI company.")
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
        .navigationTitle("Private by Design")
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
