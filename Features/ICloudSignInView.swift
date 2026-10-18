import SafariServices
import SwiftUI

/// Adds an iCloud Mail account, or gives one a new password. Apple doesn't
/// let other apps sign in to iCloud Mail with your Apple Account password;
/// it asks for an app-specific password, made once at account.apple.com.
///
/// Built to take about thirty seconds: your address first, Apple's page
/// opened inside Corres (Face ID and saved passwords work there), then one
/// tap on Paste. A pasted app-specific password connects by itself.
struct ICloudSignInView: View {
    let auth: GoogleAuthService
    /// Set when the account exists and needs a new password: its address
    /// is filled in and fixed.
    var reconnecting: String?
    /// iCloud turned the saved password away (as opposed to you choosing
    /// to update it).
    var rejected = false
    /// Called after the account is added, with the account count before it.
    let onConnected: (Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var password = ""
    @State private var error: String?
    @State private var showingApple = false
    @FocusState private var focused: Field?

    private enum Field { case email, password }
    static let passwordsPage = URL(string: "https://account.apple.com/account/manage/section/security")!

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Image(systemName: "icloud").font(.system(size: 30)).foregroundStyle(CorresPalette.accent)
                        Text(reconnecting == nil ? "Connect iCloud Mail" : rejected ? "iCloud needs a new password" : "Update App-Specific Password")
                            .font(.title3.weight(.semibold))
                        Text(reconnecting == nil
                             ? "Apple asks other mail apps for an app-specific password instead of your Apple Account password. It takes about a minute, once."
                             : rejected
                             ? "iCloud stopped accepting the password Corres had, usually because your Apple Account password changed. Make a new one and Corres picks up where it left off."
                             : "Make a new app-specific password and paste it here. Corres keeps your mail and settings as they are.")
                            .font(.subheadline).foregroundStyle(CorresPalette.secondary)
                    }
                    .padding(.vertical, 6)
                }

                Section {
                    TextField("you@icloud.com", text: $email)
                        .keyboardType(.emailAddress)
                        // Not .username: paired with the password below, it
                        // makes iOS offer to save a password Corres already
                        // keeps in its own Keychain.
                        .textContentType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focused, equals: .email)
                        .submitLabel(.next)
                        .onSubmit { focused = nil }
                        .disabled(reconnecting != nil)
                } header: {
                    Text("Your iCloud address")
                }

                Section {
                    step(1, "Open Apple Account below and sign in.")
                    step(2, "Choose Sign-In and Security, then App-Specific Passwords.")
                    step(3, "Make one called Corres, then tap Copy and Done.")
                    Button {
                        focused = nil
                        showingApple = true
                    } label: {
                        Label("Open Apple Account", systemImage: "person.badge.key")
                    }
                } header: {
                    Text("Make an app-specific password")
                }

                Section {
                    PasteButton(payloadType: String.self) { strings in
                        guard let pasted = strings.first else { return }
                        Task { @MainActor in
                            password = pasted
                            if ICloudSignIn.looksLikeAppPassword(pasted), ICloudSignIn.address(from: email) != nil { connect() }
                        }
                    }
                    .labelStyle(.titleAndIcon)
                    .buttonBorderShape(.capsule)
                    .tint(CorresPalette.accent)
                    SecureField("Or type it: xxxx-xxxx-xxxx-xxxx", text: $password)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focused, equals: .password)
                        .submitLabel(.go)
                        .onSubmit(connect)
                } header: {
                    Text("The password")
                } footer: {
                    if let error {
                        Text(error).foregroundStyle(CorresPalette.alert)
                    } else {
                        Text("The password stays in this \(Device.name)'s Keychain. Your mail goes from iCloud straight to this \(Device.name); Corres's servers never see either.")
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(CorresPalette.canvas)
            .navigationTitle("iCloud Mail")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if auth.isSigningIn {
                        ProgressView()
                    } else {
                        Button("Connect", action: connect).disabled(email.isEmpty || password.isEmpty)
                    }
                }
            }
            .sheet(isPresented: $showingApple) {
                SafariView(url: Self.passwordsPage).ignoresSafeArea()
            }
            .onAppear {
                if let reconnecting { email = reconnecting } else if email.isEmpty { focused = .email }
            }
        }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("\(number)").font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(CorresPalette.accent).frame(width: 18)
            Text(text).font(.subheadline)
        }
    }

    private func connect() {
        guard !auth.isSigningIn else { return }
        error = nil
        let before = auth.accounts.count
        Task {
            if let message = await auth.signInICloud(email: email, password: password) {
                error = message
            } else {
                dismiss()
                onConnected(before)
            }
        }
    }
}

/// What an iCloud sign-in accepts, kept apart from the view so it can be
/// tested.
enum ICloudSignIn {
    /// Apple's app-specific passwords: four groups of four lowercase
    /// letters, with or without the dashes.
    static func looksLikeAppPassword(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .wholeMatch(of: /[a-z]{4}-?[a-z]{4}-?[a-z]{4}-?[a-z]{4}/) != nil
    }

    /// The address to sign in with: trimmed and lowercased, with
    /// "@icloud.com" added to a bare name. Nil when it can't be an address.
    static func address(from raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty, !text.contains(" ") else { return nil }
        if !text.contains("@") { return text + "@icloud.com" }
        let parts = text.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, parts[1].contains(".") else { return nil }
        return text
    }

    /// Apple's own domains. Anything else is a custom domain on iCloud+.
    static func isAppleDomain(_ address: String) -> Bool {
        ["icloud.com", "me.com", "mac.com"].contains(address.split(separator: "@").last.map(String.init) ?? "")
    }
}

/// Apple's sign-in page inside Corres, so you never leave the app; Safari's
/// saved passwords and Face ID work in it.
struct SafariView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController {
        let controller = SFSafariViewController(url: url)
        controller.dismissButtonStyle = .done
        controller.preferredControlTintColor = UIColor(CorresPalette.accent)
        return controller
    }
    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}
