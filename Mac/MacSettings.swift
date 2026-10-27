import SwiftUI

/// Settings (⌘,): accounts, reading, and Corres Pro, in the Mac's own
/// tabbed Settings window.
struct MacSettingsView: View {
    let services: MacServices
    @State private var tab = Self.firstTab

    var body: some View {
        TabView(selection: $tab) {
            MacAccountsSettings(services: services)
                .tabItem { Label("Accounts", systemImage: "at") }.tag(0)
            MacGeneralSettings(store: services.store)
                .tabItem { Label("General", systemImage: "gearshape") }.tag(1)
            MacReadingSettings(intelligence: services.intelligence)
                .tabItem { Label("Reading", systemImage: "text.book.closed") }.tag(2)
            MacComposingSettings(auth: services.auth)
                .tabItem { Label("Composing", systemImage: "square.and.pencil") }.tag(3)
            MacSignaturesSettings(accounts: services.auth.accounts.map(\.email))
                .tabItem { Label("Signatures", systemImage: "signature") }.tag(4)
            NavigationStack { TemplatesView() }
                .tabItem { Label("Templates", systemImage: "text.badge.plus") }.tag(5)
            NavigationStack { SendersView(store: services.store, unsubscriber: services.unsubscribeService) }
                .tabItem { Label("Senders", systemImage: "person.2") }.tag(6)
            NavigationStack { RulesView() }
                .tabItem { Label("Rules", systemImage: "line.3.horizontal.decrease") }.tag(7)
            MacPlanSettings(services: services)
                .tabItem { Label("Corres Pro", systemImage: "sparkle") }.tag(8)
        }
        .frame(width: 680, height: 520)
    }

    /// Debug builds: -SettingsTab N opens on that tab, for screenshots.
    private static var firstTab: Int {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let index = args.firstIndex(of: "-SettingsTab"), args.indices.contains(index + 1) { return Int(args[index + 1]) ?? 0 }
        #endif
        return 0
    }
}

private struct MacAccountsSettings: View {
    let services: MacServices
    @State private var addingIMAP: IMAPKind?
    @State private var removing: String?
    @State private var showingOutOfOffice = false

    enum IMAPKind: String, Identifiable { case icloud, other; var id: String { rawValue } }

    private var auth: GoogleAuthService { services.auth }

    var body: some View {
        Form {
            Section {
                if auth.accounts.isEmpty {
                    Text("No accounts yet. Corres is showing sample mail.").foregroundStyle(.secondary)
                }
                ForEach(auth.accounts.map(\.email), id: \.self) { email in
                    HStack {
                        Circle().fill(AccountPreferences.color(for: email, among: auth.accounts.map(\.email)) ?? CorresPalette.accent)
                            .frame(width: 10, height: 10)
                        VStack(alignment: .leading) {
                            Text(email)
                            if let problem = services.sync.health[email]?.problem {
                                Text(problem).font(.caption).foregroundStyle(.red)
                            } else if let last = services.sync.health[email]?.lastSuccess {
                                Text("\(MailAccounts.serviceName(for: email)) · up to date \(last.formatted(.relative(presentation: .named)))")
                                    .font(.caption).foregroundStyle(.secondary)
                            } else {
                                Text(MailAccounts.serviceName(for: email)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button("Remove…") { removing = email }
                    }
                }
            } header: {
                Text("Accounts")
            } footer: {
                Text("Accounts you add on your iPhone or iPad appear here on their own, through iCloud Keychain. Corres reads your mail straight from your provider on this Mac; our servers never receive it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Add an Account") {
                HStack(spacing: 10) {
                    Button("Gmail") { Task { await auth.signIn(); services.accountsChanged() } }
                    Button("Outlook") { Task { await auth.signInOutlook(); services.accountsChanged() } }
                    Button("iCloud") { addingIMAP = .icloud }
                    Button("Other Email") { addingIMAP = .other }
                }
            }
            if !auth.accounts.isEmpty {
                Section {
                    LabeledContent {
                        Button("Set Up…") { showingOutOfOffice = true }
                    } label: {
                        Text("Out of Office")
                        Text("An automatic reply while you're away, sent by your email provider even with this Mac off.")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .sheet(item: $addingIMAP) { kind in
            MacIMAPSignIn(kind: kind, services: services)
        }
        .sheet(isPresented: $showingOutOfOffice) {
            NavigationStack {
                OutOfOfficeView(auth: auth)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Done") { showingOutOfOffice = false } }
                    }
            }
            .frame(width: 520, height: 520)
        }
        .confirmationDialog("Remove \(removing ?? "")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Remove from This Mac", role: .destructive) { remove(everywhere: false) }
            Button("Remove from All Devices", role: .destructive) { remove(everywhere: true) }
        } message: {
            Text(AccountRemoval.explanation(for: removing ?? ""))
        }
    }

    private func remove(everywhere: Bool) {
        guard let email = removing else { return }
        Task {
            await AccountRemoval.remove(email, everywhere: everywhere, auth: auth, sync: services.sync, store: services.store,
                                        push: services.pushService, intelligence: services.intelligence, people: services.people)
            services.accountsChanged()
        }
    }
}

/// iCloud (an app-specific password) or any other IMAP account (address
/// and password, servers found automatically).
private struct MacIMAPSignIn: View {
    let kind: MacAccountsSettings.IMAPKind
    let services: MacServices
    @State private var email = ""
    @State private var password = ""
    @State private var working = false
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(kind == .icloud ? "Add iCloud Mail" : "Add an Email Account")
                .font(.system(size: 20, weight: .regular, design: .serif))
            Text(kind == .icloud
                 ? "Use an app-specific password from account.apple.com → Sign-In and Security → App-Specific Passwords. You can turn it off there any time."
                 : "Yahoo, AOL, Fastmail, Zoho or a work server. Corres finds the server settings for you.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if kind == .icloud {
                Link("Open account.apple.com", destination: URL(string: "https://account.apple.com")!).font(.callout)
            }
            Form {
                TextField("Email", text: $email).textContentType(.username)
                SecureField(kind == .icloud ? "App-specific password" : "Password", text: $password).textContentType(.password)
            }
            .formStyle(.columns)
            if let error { Text(error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(working ? "Signing In…" : "Sign In") { signIn() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(working || email.isEmpty || password.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 440)
    }

    private func signIn() {
        working = true
        error = nil
        Task {
            defer { working = false }
            if kind == .icloud {
                if let problem = await services.auth.signInICloud(email: email, password: password) {
                    error = problem
                    return
                }
            } else {
                switch await MailServerDiscovery.find(for: email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()) {
                case .useSignIn:
                    error = String(localized: "This address signs in with its own button: use Gmail, Outlook or iCloud.")
                    return
                case .unsupported(let message):
                    error = message
                    return
                case .candidates(let servers, let service):
                    if let problem = await services.auth.signInIMAP(email: email, password: password, candidates: servers,
                                                                   appPassword: service?.appPassword ?? false) {
                        error = problem
                        return
                    }
                }
            }
            services.accountsChanged()
            dismiss()
        }
    }
}

private struct MacGeneralSettings: View {
    @AppStorage("corres.appearance") private var appearance = "system"
    @AppStorage(SpotlightIndex.enabledKey) private var inSpotlight = true
    @AppStorage(CorresSettings.sensitivityKey) private var sensitivity = InboxClassifier.Sensitivity.balanced.rawValue
    @AppStorage(CorresSettings.followUpDaysKey) private var followUpDays = 3
    @AppStorage(CorresSettings.morningHourKey) private var morningHour = 8
    @AppStorage(CorresSettings.laterTodayEveningKey) private var laterTodayEvening = false
    @AppStorage(MacMenuBarSetting.key) private var inMenuBar = true
    @AppStorage(BrandLogos.enabledKey) private var companyLogos = true
    let store: MailStore

    @State private var isDefaultMailApp = MacDefaultMail.isCorres

    var body: some View {
        Form {
            LabeledContent {
                if isDefaultMailApp {
                    Label("Corres", systemImage: "checkmark.circle.fill").foregroundStyle(CorresPalette.secondary)
                } else {
                    Button("Make Corres the Default") {
                        Task { isDefaultMailApp = await MacDefaultMail.makeCorres() }
                    }
                }
            } label: {
                Text("Default email app")
                Text("Email links in other apps open in Corres.")
            }
            Picker("Appearance", selection: $appearance) {
                Text("Automatic").tag("system")
                Text("Light").tag("light")
                Text("Dark").tag("dark")
            }
            Toggle(isOn: $inMenuBar) {
                Text("Show in menu bar")
                Text("How many emails need you, and the first few, from the menu bar.")
            }
            Toggle(isOn: $companyLogos) {
                Text("Company logos")
                Text("Beside companies' mail, the logo they publish for email, checked by its certificate. Corres's server fetches it, so the company never sees you, and is sent only the company's web address.")
            }
            .onChange(of: companyLogos) { _, on in if !on { BrandLogos.shared.forgetAll() } }
            Toggle(isOn: $inSpotlight) {
                Text("Show in Spotlight")
                Text("Find conversations from Spotlight by sender, subject or what they say. The index stays on this Mac.")
            }
            .onChange(of: inSpotlight) { _, on in
                Task {
                    if on { await SpotlightIndex.shared.update(store.searchableThreads) }
                    else { await SpotlightIndex.shared.removeAll() }
                }
            }
            Section("Sorting") {
                Picker(selection: $sensitivity) {
                    Text("Focused").tag(InboxClassifier.Sensitivity.focused.rawValue)
                    Text("Balanced").tag(InboxClassifier.Sensitivity.balanced.rawValue)
                    Text("Everything from People").tag(InboxClassifier.Sensitivity.inclusive.rawValue)
                } label: {
                    Text("Needs You")
                    Text(sensitivityDetail)
                }
                Picker(selection: $followUpDays) {
                    ForEach(CorresSettings.followUpChoices, id: \.self) { Text($0 == 1 ? "1 day" : "\($0) days").tag($0) }
                } label: {
                    Text("Follow up after")
                    Text("Waiting turns into Follow up once someone hasn't replied in that long.")
                }
            }
            Section("Snooze") {
                Picker(selection: $morningHour) {
                    ForEach(6...10, id: \.self) { hour in
                        Text(Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: .now)!
                                .formatted(date: .omitted, time: .shortened)).tag(hour)
                    }
                } label: {
                    Text("Start of day")
                    Text("Tomorrow and Next Week come back then; This Weekend an hour later, on Saturday.")
                }
                Picker("Later today", selection: $laterTodayEvening) {
                    Text("In 3 Hours").tag(false)
                    Text("This Evening, 6 PM").tag(true)
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: sensitivity) { CorresSettings.applyToCore(); Task { await store.reapplyRules() } }
        .onChange(of: morningHour) { CorresSettings.applyToCore() }
        .onChange(of: laterTodayEvening) { CorresSettings.applyToCore() }
    }

    private var sensitivityDetail: String {
        switch InboxClassifier.Sensitivity(rawValue: sensitivity) ?? .balanced {
        case .focused: String(localized: "Focused: only email that asks something of you, has a deadline, or is from a VIP or someone you write to.")
        case .balanced: String(localized: "Balanced: email written to you by a person; mail you're only copied on stays in Mail.")
        case .inclusive: String(localized: "Everything from people: every email from a person, including ones you're copied on.")
        }
    }
}

private struct MacReadingSettings: View {
    let intelligence: MailIntelligence
    @AppStorage(CorresSettings.keyDetailsKey) private var keyDetails = true
    @AppStorage(CorresSettings.summariesKey) private var summaries = true
    @AppStorage(CorresSettings.markReadOnOpenKey) private var markRead = true
    @AppStorage(CorresSettings.remoteImagesKey) private var remoteImages = CorresSettings.RemoteImages.ask.rawValue

    var body: some View {
        Form {
            Section("At the top of each email") {
                Toggle(isOn: $keyDetails) {
                    Text("Key Details")
                    Text("A receipt's or bill's status and amounts, a delivery's date, and what a long email asks of you, read straight from the email.")
                }
                Toggle(isOn: $summaries) {
                    Text("Summaries and suggested replies")
                    Text(intelligence.isAvailable
                         ? "Written by Apple Intelligence on this Mac and checked against the email: every name, number and date has to be in it. Part of Corres Pro."
                         : "Need Apple Intelligence, and are part of Corres Pro.")
                }
            }
            Section {
                Picker(selection: $remoteImages) {
                    ForEach(CorresSettings.RemoteImages.allCases) { Text($0.title).tag($0.rawValue) }
                } label: {
                    Text("Images in email")
                    Text(remoteImages == CorresSettings.RemoteImages.ask.rawValue
                         ? "Images from the web stay off until you click Show Images, so senders can't tell when you opened their email."
                         : "Images load as soon as you open an email. Senders using tracking images can see when you opened it.")
                }
                Toggle("Mark as read when opened", isOn: $markRead)
            }
        }
        .formStyle(.grouped)
    }
}

private struct MacComposingSettings: View {
    let auth: GoogleAuthService
    @AppStorage(CorresSettings.undoSendKey) private var undoSeconds = 5
    @AppStorage(CorresSettings.defaultFromKey) private var defaultFrom = ""

    var body: some View {
        Form {
            Section {
                Picker(selection: $undoSeconds) {
                    ForEach(CorresSettings.undoSendChoices, id: \.self) { seconds in
                        Text(seconds == 0 ? "Off" : "\(seconds) seconds").tag(seconds)
                    }
                } label: {
                    Text("Undo Send")
                    Text("Holds a message for a moment so you can take it back.")
                }
                if auth.accounts.count > 1 {
                    Picker("Send new mail from", selection: $defaultFrom) {
                        ForEach(auth.accounts) { Text($0.email).tag($0.email) }
                    }
                }
            }
            Section {
                WritingStyleRows()
            } footer: {
                Text("Suggested replies use the greeting, sign-off and length you use in email you've sent, for each person you write to often. Learned on this Mac from your sent mail, and never sent anywhere.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            if defaultFrom.isEmpty, let first = auth.accounts.first { defaultFrom = first.email }
        }
    }
}

/// Settings › Corres Pro: the plan you're on and what it does next, the
/// way into the free trial, and Restore and Redeem, as on the iPhone.
private struct MacPlanSettings: View {
    let services: MacServices
    @Environment(\.openWindow) private var openWindow

    private var entitlements: EntitlementStore { services.entitlements }
    /// The App Store's own subscriptions page, where a Mac subscription
    /// is changed or cancelled.
    private static let manageURL = URL(string: "https://apps.apple.com/account/subscriptions")!

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    CorrespondenceMark().frame(width: 34, height: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entitlements.planName).font(.body.weight(.semibold))
                        Text(entitlements.planStatus).font(.callout).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 2)
                switch entitlements.plan {
                case .none:
                    // Someone who's had the trial can't have it again.
                    if !entitlements.isPro {
                        Button(MacPro.unlockTitle(entitlements)) { MacPro.open(openWindow) }
                    }
                case .monthly, .annual:
                    Button("Manage Subscription") { NSWorkspace.shared.open(Self.manageURL) }
                case .lifetime:
                    EmptyView()
                }
                if EntitlementStore.isBetaBuild && entitlements.hasBetaAccess {
                    Toggle("Preview as Free User", isOn: Bindable(entitlements).previewAsFree)
                }
            } header: {
                Text("Plan").accessibilityIdentifier(EntitlementStore.buildKind)
            } footer: {
                if entitlements.isPro && entitlements.plan == .none {
                    Text("Pro is included while you test the beta. Preview as Free User shows the app as it is without Pro.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if !entitlements.isPro {
                    Text("Without Pro, Mail keeps working: read, reply, archive and search. Needs You, Waiting, answers in Search, summaries and suggested replies need Pro.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                Text("Corres Pro adds Needs You, Waiting, answers in Search, summaries and suggested replies. One purchase covers your iPhone, iPad and Mac.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Button("Restore Purchases") { Task { await entitlements.restore() } }
                Button("Redeem Code") { Task { await entitlements.presentRedeemSheet() } }
            }
        }
        .formStyle(.grouped)
        .task { await entitlements.loadProducts() }
        // The Corres Pro window shows its own.
        .alert("Corres Pro", isPresented: Binding(
            get: { entitlements.errorMessage != nil && !services.paywallOpen },
            set: { if !$0 { entitlements.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { entitlements.errorMessage = nil }
        } message: { Text(entitlements.errorMessage ?? "") }
    }
}

/// The Mac's default email app: what opens mailto: links everywhere.
@MainActor
enum MacDefaultMail {
    static var isCorres: Bool {
        guard let mailto = URL(string: "mailto:"),
              let current = NSWorkspace.shared.urlForApplication(toOpen: mailto) else { return false }
        return Bundle(url: current)?.bundleIdentifier == Bundle.main.bundleIdentifier
    }

    /// macOS asks you to confirm.
    static func makeCorres() async -> Bool {
        do {
            try await NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpenURLsWithScheme: "mailto")
        } catch {
            return isCorres
        }
        return isCorres
    }
}

/// Signatures on the Mac: the same named signatures as the iPhone's, and
/// which one each account adds to new mail and to replies.
private struct MacSignaturesSettings: View {
    let accounts: [String]
    @State private var signatures = Signatures.all
    @State private var selection: String?
    @State private var revision = 0

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(signatures, selection: $selection) { signature in
                    Text(signature.name.isEmpty ? String(localized: "Untitled") : signature.name).tag(signature.id)
                }
                .listStyle(.bordered)
                HStack(spacing: 0) {
                    Button { add() } label: { Image(systemName: "plus").frame(width: 24, height: 20) }
                        .accessibilityLabel("Add Signature").help("Add a signature")
                    Button { remove() } label: { Image(systemName: "minus").frame(width: 24, height: 20) }
                        .accessibilityLabel("Delete Signature").help("Delete this signature")
                        .disabled(selection == nil)
                    Spacer()
                }
                .buttonStyle(.borderless)
                .padding(4)
            }
            .frame(width: 180)
            Divider()
            if let index = signatures.firstIndex(where: { $0.id == selection }) {
                Form {
                    TextField("Name", text: $signatures[index].name)
                    TextEditor(text: $signatures[index].text)
                        .font(.body)
                        .frame(minHeight: 120)
                    if !accounts.isEmpty {
                        Section("Use for") {
                            ForEach(accounts, id: \.self) { account in
                                defaults(for: account, signature: signatures[index].id)
                            }
                        }
                    }
                }
                .formStyle(.grouped)
                .id(revision)
            } else {
                ContentUnavailableView {
                    EmptyTitle("No signature selected", systemImage: "signature")
                } description: {
                    Text("Add one with +, like a full one for new mail and a short one for replies.")
                }
                    .frame(maxWidth: .infinity)
            }
        }
        .onChange(of: signatures) { _, value in Signatures.all = value }
        .onAppear { if selection == nil { selection = signatures.first?.id } }
    }

    private func defaults(for account: String, signature id: String) -> some View {
        HStack {
            Text(AccountPreferences.nickname(for: account)).lineLimit(1)
            Spacer()
            Toggle("New mail", isOn: binding(account, id, reply: false))
            Toggle("Replies", isOn: binding(account, id, reply: true))
        }
        .toggleStyle(.checkbox)
    }

    private func binding(_ account: String, _ id: String, reply: Bool) -> Binding<Bool> {
        Binding(get: { _ = revision; return Signatures.defaultID(for: account, reply: reply) == id },
                set: { on in
                    Signatures.setDefault(on ? id : "", for: account, reply: reply)
                    revision += 1
                })
    }

    private func add() {
        let signature = Signature(name: String(localized: "Signature \(signatures.count + 1)"), text: "")
        signatures.append(signature)
        selection = signature.id
    }

    private func remove() {
        guard let selection else { return }
        Signatures.delete(selection)
        signatures = Signatures.all
        self.selection = signatures.first?.id
    }
}
