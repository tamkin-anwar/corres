import SwiftUI

/// Settings (⌘,): accounts, reading, and Corres Pro, in the Mac's own
/// tabbed Settings window.
struct MacSettingsView: View {
    let services: MacServices

    var body: some View {
        TabView {
            MacAccountsSettings(services: services)
                .tabItem { Label("Accounts", systemImage: "at") }
            MacGeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            MacPlanSettings(entitlements: services.entitlements)
                .tabItem { Label("Corres Pro", systemImage: "sparkle") }
        }
        .frame(width: 560, height: 420)
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
                            Text(MailAccounts.serviceName(for: email)).font(.caption).foregroundStyle(.secondary)
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

    var body: some View {
        Form {
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
