import SwiftUI

/// Adds an iCloud Mail account. Apple doesn't let other apps sign in to
/// iCloud Mail with your Apple Account; it asks for an app-specific
/// password instead, made once at account.apple.com. This screen says how,
/// links there, and checks the password with iCloud before saving it.
struct ICloudSignInView: View {
    let auth: GoogleAuthService
    /// Called after the account is added, with the account count before it.
    let onConnected: (Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var email = ""
    @State private var password = ""
    @State private var error: String?
    @FocusState private var focused: Field?

    private enum Field { case email, password }
    private static let passwordsPage = URL(string: "https://account.apple.com/account/manage/section/security")!

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 10) {
                        Image(systemName: "icloud").font(.system(size: 30)).foregroundStyle(CorresPalette.accent)
                        Text("Connect iCloud Mail").font(.title3.weight(.semibold))
                        Text("Apple asks other mail apps to use an app-specific password, not your Apple Account password. You make one once, and can turn it off at any time.")
                            .font(.subheadline).foregroundStyle(CorresPalette.secondary)
                    }
                    .padding(.vertical, 6)
                }

                Section {
                    step(1, "Open account.apple.com and sign in.")
                    step(2, "Choose Sign-In and Security, then App-Specific Passwords.")
                    step(3, "Make one called Corres, and copy it.")
                    Button {
                        openURL(Self.passwordsPage)
                    } label: {
                        Label("Open account.apple.com", systemImage: "arrow.up.right.square")
                    }
                } header: {
                    Text("Make an app-specific password")
                }

                Section {
                    TextField("you@icloud.com", text: $email)
                        .keyboardType(.emailAddress)
                        // No .username: paired with the password field below,
                        // it makes iOS offer to save a password Corres
                        // already keeps in its own Keychain.
                        .textContentType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focused, equals: .email)
                        .submitLabel(.next)
                        .onSubmit { focused = .password }
                    SecureField("xxxx-xxxx-xxxx-xxxx", text: $password)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focused, equals: .password)
                        .submitLabel(.go)
                        .onSubmit(connect)
                } header: {
                    Text("Your iCloud address and the password")
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
            .onAppear { focused = .email }
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
