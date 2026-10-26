import SwiftUI

/// Adds any other email account (Yahoo, AOL, Fastmail, Zoho, a work or
/// school server) with just the address and a password: Corres finds the
/// servers itself (`MailServerDiscovery`) and proves them by signing in.
/// Server settings only appear if nothing could be found.
struct OtherEmailSignInView: View {
    let auth: GoogleAuthService
    /// Set when the account exists and needs a new password.
    var reconnecting: String?
    /// Called after the account is added, with the account count before it.
    let onConnected: (Int) -> Void
    /// The address belongs with one of Corres's own sign-ins.
    let onUseSignIn: (MailProvider) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var password = ""
    @State private var finding: MailServerDiscovery.Finding?
    @State private var searching = false
    @State private var error: String?
    @State private var showingHelp = false
    @State private var manual = false
    @State private var imapHost = ""
    @State private var imapPort = "993"
    @State private var smtpHost = ""
    @State private var smtpPort = "587"
    @FocusState private var focused: Field?

    private enum Field { case email, password }

    private var service: MailServerDiscovery.Service? {
        if case .candidates(_, let service) = finding { return service }
        return nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Image(systemName: "envelope").font(.system(size: 28)).foregroundStyle(CorresPalette.accent)
                        if reconnecting != nil {
                            Text("Sign In Again").font(.title3.weight(.semibold))
                            Text(service?.appPassword == true
                                 ? "Your mail server stopped accepting the password Corres has. Enter it again, or make a new app password."
                                 : "Your mail server stopped accepting the password Corres has. Enter it again.")
                                .font(.subheadline).foregroundStyle(CorresPalette.secondary)
                        } else {
                            Text(service.map { String(localized: "Connect \($0.name)") } ?? String(localized: "Add an Email Account")).font(.title3.weight(.semibold))
                            Text("Enter your address and Corres finds your mail server for you.")
                                .font(.subheadline).foregroundStyle(CorresPalette.secondary)
                        }
                    }
                    .padding(.vertical, 6)
                }

                Section {
                    TextField("you@example.com", text: $email)
                        .keyboardType(.emailAddress)
                        .textContentType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focused, equals: .email)
                        .submitLabel(.next)
                        .onSubmit(find)
                        .onChange(of: email) { if reconnecting == nil { finding = nil; error = nil; manual = false } }
                        .disabled(reconnecting != nil)
                } header: {
                    Text("Your email address")
                } footer: {
                    if searching { Text("Finding your mail server\u{2026}") }
                }

                switch finding {
                case .useSignIn(let provider)?:
                    Section {
                        Button("Continue with \(provider == .google ? "Google" : provider == .microsoft ? "Microsoft" : "iCloud Mail")") {
                            dismiss()
                            onUseSignIn(provider)
                        }
                    } footer: {
                        Text("This address uses \(provider.title). Corres signs in to \(provider.title) directly, which is quicker and safer than a password.")
                    }
                case .unsupported(let note)?:
                    Section {} footer: { Text(note) }
                case .candidates?:
                    if let service, service.appPassword {
                        Section {
                            ForEach(Array(service.steps.enumerated()), id: \.offset) { index, text in
                                HStack(alignment: .firstTextBaseline, spacing: 12) {
                                    Text("\(index + 1)").font(.subheadline.weight(.semibold).monospacedDigit())
                                        .foregroundStyle(CorresPalette.accent).frame(width: 18)
                                    Text(text).font(.subheadline)
                                }
                            }
                            if service.appPasswordURL != nil {
                                Button { showingHelp = true } label: {
                                    Label("Open \(service.name.replacingOccurrences(of: " Mail", with: "")) Account Security", systemImage: "person.badge.key")
                                }
                            }
                        } header: {
                            Text("Make an app password")
                        } footer: {
                            Text("\(service.name) asks other mail apps for an app password instead of your usual one.")
                        }
                    } else if let service, !service.steps.isEmpty {
                        Section {} footer: { Text(service.steps.joined(separator: " ")) }
                    }
                    passwordSection
                    if manual { serverSection }
                case nil:
                    EmptyView()
                }
            }
            .scrollContentBackground(.hidden)
            .background(CorresPalette.canvas)
            .navigationTitle("Email Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if auth.isSigningIn || searching {
                        ProgressView()
                    } else if finding == nil {
                        Button("Next", action: find).disabled(!email.contains("@"))
                    } else if case .candidates = finding {
                        Button("Connect", action: connect).disabled(password.isEmpty)
                    }
                }
            }
            .sheet(isPresented: $showingHelp) {
                if let url = service?.appPasswordURL { SafariView(url: url).ignoresSafeArea() }
            }
            .onAppear {
                if let reconnecting {
                    email = reconnecting
                    // Its servers are already known.
                    finding = .candidates([IMAPServer.for(reconnecting)], service: MailServerDiscovery.known[reconnecting.split(separator: "@").last.map(String.init) ?? ""])
                    focused = .password
                } else {
                    focused = .email
                }
            }
        }
    }

    private var passwordSection: some View {
        Section {
            PasteButton(payloadType: String.self) { strings in
                guard let pasted = strings.first else { return }
                Task { @MainActor in password = pasted.trimmingCharacters(in: .whitespacesAndNewlines) }
            }
            .labelStyle(.titleAndIcon)
            .buttonBorderShape(.capsule)
            .tint(CorresPalette.accent)
            SecureField(service?.appPassword == true ? "App password" : "Password", text: $password)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focused, equals: .password)
                .submitLabel(.go)
                .onSubmit(connect)
        } header: {
            Text(service?.appPassword == true ? "The app password" : "Your password")
        } footer: {
            if let error {
                VStack(alignment: .leading, spacing: 8) {
                    Text(error).foregroundStyle(CorresPalette.alert)
                    if !manual {
                        Button("Enter Server Settings") { startManual() }.font(.footnote.weight(.semibold))
                    }
                }
            } else {
                Text("Your password stays in this \(Device.name)'s Keychain. Your mail goes from your provider straight to this \(Device.name).")
            }
        }
    }

    private var serverSection: some View {
        Section {
            LabeledContent("Incoming (IMAP)") {
                TextField("imap.example.com", text: $imapHost).multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
            }
            LabeledContent("Port") { TextField("993", text: $imapPort).multilineTextAlignment(.trailing).keyboardType(.numberPad) }
            LabeledContent("Outgoing (SMTP)") {
                TextField("smtp.example.com", text: $smtpHost).multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
            }
            LabeledContent("Port") { TextField("587", text: $smtpPort).multilineTextAlignment(.trailing).keyboardType(.numberPad) }
        } header: {
            Text("Server Settings")
        } footer: {
            Text("Your email provider's help pages list these. Corres connects securely: SSL for incoming mail, and SSL (465) or STARTTLS (587) for outgoing.")
        }
    }

    private func find() {
        guard email.contains("@"), !searching else { return }
        error = nil
        searching = true
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        Task {
            let found = await MailServerDiscovery.find(for: address)
            searching = false
            finding = found
            if case .candidates = found { focused = .password }
        }
    }

    private func startManual() {
        let domain = email.split(separator: "@").last.map(String.init) ?? ""
        if case .candidates(let servers, _) = finding, let first = servers.first {
            imapHost = first.imapHost; imapPort = String(first.imapPort)
            smtpHost = first.smtpHost; smtpPort = String(first.smtpPort)
        } else {
            imapHost = "imap.\(domain)"; smtpHost = "smtp.\(domain)"
        }
        manual = true
        error = nil
    }

    private func connect() {
        guard !auth.isSigningIn, case .candidates(let found, let service) = finding else { return }
        error = nil
        let candidates: [IMAPServer]
        if manual, !imapHost.isEmpty, !smtpHost.isEmpty {
            let outPort = Int(smtpPort) ?? 587
            let host = imapHost.trimmingCharacters(in: .whitespaces).lowercased()
            // The sign-in name the server's settings gave, when it's the
            // same server (some want just the part before the @).
            let username = found.first { $0.imapHost == host }?.username
            candidates = [IMAPServer(imapHost: host, imapPort: Int(imapPort) ?? 993,
                                     smtpHost: smtpHost.trimmingCharacters(in: .whitespaces).lowercased(),
                                     smtpPort: outPort, smtpSecurity: outPort == 465 ? .tls : .startTLS, username: username)]
        } else {
            candidates = found
        }
        let before = auth.accounts.count
        Task {
            if let message = await auth.signInIMAP(email: email, password: password, candidates: candidates,
                                                   appPassword: service?.appPassword ?? false) {
                error = message
            } else {
                dismiss()
                onConnected(before)
            }
        }
    }
}
