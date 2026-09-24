import SwiftUI

struct PreferencesView: View {
    let store: MailStore
    var auth: GoogleAuthService
    var sync: GmailSyncService
    @Bindable var pushService: PushNotificationService
    @Environment(\.dismiss) private var dismiss
    @AppStorage("corres.appearance") private var appearance = Appearance.system.rawValue
    @AppStorage("corres.primarySwipeAction") private var primarySwipeActionRaw = PrimarySwipeAction.archive.rawValue
    @AppStorage("corres.primaryLeadingSwipeAction") private var primaryLeadingSwipeActionRaw = LeadingSwipeAction.pin.rawValue
    @AppStorage("corres.notifyOnlyNeedsYou") private var notifyOnlyNeedsYou = false
    @State private var showingResetConfirmation = false
    @State private var accountPendingDisconnect: GmailAccount?

    var body: some View {
        NavigationStack {
            Form {
                Section("Make yourself comfortable") {
                    Picker("Appearance", selection: $appearance) {
                        ForEach(Appearance.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                }
                Section {
                    Picker("Full swipe right", selection: $primarySwipeActionRaw) {
                        ForEach(PrimarySwipeAction.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    Picker("Full swipe left", selection: $primaryLeadingSwipeActionRaw) {
                        ForEach(LeadingSwipeAction.allCases) { Text($0.settingsTitle).tag($0.rawValue) }
                    }
                } header: {
                    Text("Swipe Actions")
                } footer: {
                    Text("What a full swipe does on a Mail row, without needing to tap a specific button first. Every other swipe action stays reachable with a partial swipe.")
                }
                Section("Your Gmail accounts") {
                    ForEach(auth.accounts) { account in
                        Label(account.email, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(CorresPalette.accent)
                            .swipeActions(edge: .trailing) {
                                Button("Disconnect", role: .destructive) { accountPendingDisconnect = account }
                            }
                    }
                    Button {
                        Task {
                            let previousCount = auth.accounts.count
                            await auth.signIn()
                            // Only the newly-added account needs a fresh
                            // sync; the others, if any, are already current.
                            if auth.accounts.count > previousCount, let newAccount = auth.accounts.last {
                                if await sync.syncIfConnected(account: newAccount.email) {
                                    await store.load()
                                }
                            }
                            await store.deleteSampleDataIfPresent()
                        }
                    } label: {
                        if auth.isSigningIn || sync.isSyncing {
                            ProgressView()
                        } else {
                            Label(auth.accounts.isEmpty ? "Connect Gmail" : "Connect another account", systemImage: "envelope.badge")
                        }
                    }
                    .disabled(auth.isSigningIn || sync.isSyncing)
                    Text("Every connected account syncs into Mail at once. Switch between a single merged inbox and one account at a time from the toolbar. Sender, subject, and content are real, but Needs You/Waiting are only based on Gmail's own read/unread state at first, not real judgment. Replying, replying all, forwarding, starting a new message, archiving, moving to Trash, marking read/unread, and applying your own Gmail labels all act for real.")
                        .font(.footnote).foregroundStyle(CorresPalette.secondary)
                    if !auth.accounts.isEmpty {
                        Toggle("Notify me about new mail", isOn: Binding(
                            get: { pushService.isEnabled },
                            set: { newValue in
                                Task {
                                    if newValue { await pushService.enableAll(accounts: auth.accounts.map(\.email)) }
                                    else { await pushService.disableAll(accounts: auth.accounts.map(\.email)) }
                                }
                            }
                        ))
                        Text("A background service tells Corres when new mail arrives on any connected account so it can check for real, on this device. It never sees your mail's subject, sender, or content, only that something changed.")
                            .font(.footnote).foregroundStyle(CorresPalette.secondary)
                        // Only worth offering once notifications are
                        // actually on; "less noise, more perspective" is
                        // Corres's own stated thesis (see BriefView), so
                        // this is a direct extension of it, not a bolted-on
                        // setting: every new message ringing your phone is
                        // exactly the noise Brief/Needs You/Waiting already
                        // exist to cut through.
                        if pushService.isEnabled {
                            Toggle("Only notify for what needs me", isOn: $notifyOnlyNeedsYou)
                            Text("Skips a notification for mail Corres would file under Waiting or quiet reading, the same distinction Needs You already makes. You'll still see everything the moment you open Corres.")
                                .font(.footnote).foregroundStyle(CorresPalette.secondary)
                        }
                    }
                }
                .confirmationDialog("Disconnect this account?", isPresented: Binding(
                    get: { accountPendingDisconnect != nil },
                    set: { if !$0 { accountPendingDisconnect = nil } }
                ), titleVisibility: .visible) {
                    Button("Disconnect", role: .destructive) {
                        guard let account = accountPendingDisconnect else { return }
                        accountPendingDisconnect = nil
                        sync.clearCursor(for: account.email)
                        // A stale watch subscription/device registration
                        // after disconnecting would keep the relay pinging
                        // for an account nothing local is listening for.
                        Task {
                            await pushService.disable(account: account.email)
                            await auth.signOut(account.email)
                        }
                    }
                    Button("Cancel", role: .cancel) { accountPendingDisconnect = nil }
                } message: { Text(accountPendingDisconnect?.email ?? "") }
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
                            let accounts = auth.accounts.map(\.email)
                            for account in accounts { sync.clearCursor(for: account) }
                            await store.resetSampleData()
                            if await sync.syncAll(accounts: accounts) {
                                await store.load()
                            }
                        }
                    }
                    Button("Cancel", role: .cancel) {}
                }
                Section("The next chapter") {
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
