import SwiftUI

/// Settings (⌘,): accounts, reading, and Corres Pro, in the Mac's own
/// tabbed Settings window.
struct MacSettingsView: View {
    let services: MacServices

    var body: some View {
        TabView {
            MacAccountsSettings(services: services)
                .tabItem { Label("Accounts", systemImage: "at") }
            MacGeneralSettings(store: services.store)
                .tabItem { Label("General", systemImage: "gearshape") }
            MacSignaturesSettings(accounts: services.auth.accounts.map(\.email))
                .tabItem { Label("Signatures", systemImage: "signature") }
            NavigationStack { TemplatesView() }
                .tabItem { Label("Templates", systemImage: "text.badge.plus") }
            NavigationStack { RulesView() }
                .tabItem { Label("Rules", systemImage: "line.3.horizontal.decrease") }
            MacPlanSettings(entitlements: services.entitlements)
                .tabItem { Label("Corres Pro", systemImage: "sparkle") }
        }
        .frame(width: 600, height: 460)
    }
}

private struct MacAccountsSettings: View {
    let services: MacServices
    @State private var addingIMAP: IMAPKind?
    @State private var removing: String?

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
        }
        .formStyle(.grouped)
        .sheet(item: $addingIMAP) { kind in
            MacIMAPSignIn(kind: kind, services: services)
        }
        .confirmationDialog("Remove \(removing ?? "")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Remove", role: .destructive) {
                guard let email = removing else { return }
                Task {
                    await auth.signOut(email)
                    await services.store.removeAccountData(email)
                    services.accountsChanged()
                }
            }
        } message: {
            Text("It's removed from Corres on all your devices. Nothing is deleted from the account itself.")
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
                    error = "This address signs in with its own button: use Gmail, Outlook or iCloud."
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
    @AppStorage(CorresSettings.summariesKey) private var summaries = true
    @AppStorage(CorresSettings.markReadOnOpenKey) private var markRead = true
    @AppStorage(CorresSettings.remoteImagesKey) private var remoteImages = CorresSettings.RemoteImages.ask.rawValue
    @AppStorage(SpotlightIndex.enabledKey) private var inSpotlight = true
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
            Toggle("Mark as read when opened", isOn: $markRead)
            Picker("Images in email", selection: $remoteImages) {
                ForEach(CorresSettings.RemoteImages.allCases) { Text($0.title).tag($0.rawValue) }
            }
            Toggle("Summaries (Apple Intelligence, on this Mac)", isOn: $summaries)
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
        }
        .formStyle(.grouped)
    }
}

private struct MacPlanSettings: View {
    let entitlements: EntitlementStore

    var body: some View {
        Form {
            Section {
                LabeledContent("Plan", value: entitlements.isPro ? "Corres Pro" : "Free")
                Text("Corres Pro adds Needs You, Waiting, answers in Search, summaries and suggested replies. One purchase covers your iPhone, iPad and Mac.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section {
                Button("Restore Purchases") { Task { await entitlements.restore() } }
                Button("Redeem Code") { Task { await entitlements.presentRedeemSheet() } }
            }
        }
        .formStyle(.grouped)
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
        let signature = Signature(name: "Signature \(signatures.count + 1)", text: "")
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
