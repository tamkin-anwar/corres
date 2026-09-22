import SwiftUI

struct PreferencesView: View {
    let store: MailStore
    var auth: GoogleAuthService
    var sync: GmailSyncService
    @Environment(\.dismiss) private var dismiss
    @AppStorage("corres.appearance") private var appearance = Appearance.system.rawValue
    @State private var showingResetConfirmation = false
    @State private var showingDisconnectConfirmation = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Make yourself comfortable") {
                    Picker("Appearance", selection: $appearance) {
                        ForEach(Appearance.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                }
                Section("Your Gmail account") {
                    if let account = auth.account {
                        Label(account.email, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(CorresPalette.accent)
                        Button("Disconnect", role: .destructive) { showingDisconnectConfirmation = true }
                    } else {
                        Button {
                            Task {
                                await auth.signIn()
                                if await sync.syncIfConnected(account: auth.account?.email) {
                                    await store.load()
                                }
                                await store.deleteSampleDataIfPresent()
                            }
                        } label: {
                            if auth.isSigningIn || sync.isSyncing {
                                ProgressView()
                            } else {
                                Label("Connect Gmail", systemImage: "envelope.badge")
                            }
                        }
                        .disabled(auth.isSigningIn || sync.isSyncing)
                    }
                    Text("Your inbox syncs into Mail, and new messages keep arriving automatically; sender, subject, and content are real, but Needs You/Waiting are only based on Gmail's own read/unread state for now, not real judgment. Replying, replying all, forwarding, and starting a new message all send for real. Corres still cannot delete, label, or otherwise modify anything else in your real mailbox.")
                        .font(.footnote).foregroundStyle(CorresPalette.secondary)
                }
                .confirmationDialog("Disconnect Gmail?", isPresented: $showingDisconnectConfirmation, titleVisibility: .visible) {
                    Button("Disconnect", role: .destructive) {
                        sync.clearCursor(for: auth.account?.email)
                        auth.signOut()
                    }
                    Button("Cancel", role: .cancel) {}
                }
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
                Section("Your privacy, clearly") {
                    Label("No advertising or analytics SDKs", systemImage: "hand.raised")
                    Label("No AI processing in this build", systemImage: "lock.shield")
                    Text("Sample conversations are stored only on this device and never leave it. Attention, pins, and snoozes now persist between launches.")
                        .font(.footnote).foregroundStyle(CorresPalette.secondary)
                }
                Section {
                    Button("Reset Sample Data", role: .destructive) { showingResetConfirmation = true }
                } footer: {
                    Text("Returns every sample conversation to its original state. Any attention, pin, or snooze changes you've made are lost.")
                }
                .confirmationDialog("Reset all sample data?", isPresented: $showingResetConfirmation, titleVisibility: .visible) {
                    Button("Reset", role: .destructive) {
                        Task {
                            // Reset deletes every persisted thread, real synced
                            // mail included. Without also forgetting the history
                            // cursor, the next sync would be incremental and
                            // would not re-fetch anything already "seen" before
                            // the reset, leaving Mail empty until new mail
                            // arrives. Clear it and resync immediately instead.
                            sync.clearCursor(for: auth.account?.email)
                            await store.resetSampleData()
                            if await sync.syncIfConnected(account: auth.account?.email) {
                                await store.load()
                            }
                        }
                    }
                    Button("Cancel", role: .cancel) {}
                }
                Section("The next chapter") {
                    Text("Attachments, and a fully durable outbox with retries, are not built yet. This foundation is being verified first.")
                    Text("Future cloud intelligence will require a clear processing choice, always disclosed and reviewed by you before anything sends. Corres will never silently forward your correspondence to an AI service.")
                }
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("corres").font(CorresType.heading)
                        Text("Email, considered.")
                        Text("A flagship by Anwar Creative Studio, alongside Artha.")
                            .font(.footnote).foregroundStyle(CorresPalette.secondary)
                        Text("Foundation preview · 0.1.0").font(.caption)
                    }.padding(.vertical, 8)
                }
            }
            .navigationTitle("Preferences")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        // .preferredColorScheme() set on a distant ancestor (here, the app's
        // WindowGroup root) does not reliably re-trait a .sheet() that is
        // already presented when the underlying value changes mid-presentation,
        // a separate SwiftUI quirk from the adaptive-color fix in Tokens.swift.
        // Applying it directly on this sheet's own content, driven by the same
        // @AppStorage value it already reads, makes it self-sufficient.
        .preferredColorScheme(Appearance(rawValue: appearance)?.colorScheme)
    }
}
