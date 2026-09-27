import SwiftUI

struct PreferencesView: View {
    let store: MailStore
    var auth: GoogleAuthService
    var sync: GmailSyncService
    @Bindable var pushService: PushNotificationService
    @Environment(\.dismiss) private var dismiss
    @AppStorage("corres.appearance") private var appearance = Appearance.system.rawValue
    @AppStorage("corres.trailingShortSwipeAction") private var trailingShortRaw = PrimarySwipeAction.archive.rawValue
    @AppStorage("corres.trailingLongSwipeAction") private var trailingLongRaw = PrimarySwipeAction.trash.rawValue
    @AppStorage("corres.leadingShortSwipeAction") private var leadingShortRaw = LeadingSwipeAction.pin.rawValue
    @AppStorage("corres.leadingLongSwipeAction") private var leadingLongRaw = LeadingSwipeAction.unread.rawValue
    @AppStorage("corres.notifyOnlyNeedsYou") private var notifyOnlyNeedsYou = false
    @State private var showingResetConfirmation = false
    @State private var accountPendingDisconnect: GmailAccount?

    var body: some View {
        NavigationStack {
            Form {
                Section("Appearance") {
                    Picker("Appearance", selection: $appearance) {
                        ForEach(Appearance.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                }
                Section {
                    Picker("Short swipe left", selection: $trailingShortRaw) {
                        ForEach(PrimarySwipeAction.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    Picker("Long swipe left", selection: $trailingLongRaw) {
                        ForEach(PrimarySwipeAction.allCases) { Text($0.title).tag($0.rawValue) }
                    }
                    Picker("Short swipe right", selection: $leadingShortRaw) {
                        ForEach(LeadingSwipeAction.allCases) { Text($0.settingsTitle).tag($0.rawValue) }
                    }
                    Picker("Long swipe right", selection: $leadingLongRaw) {
                        ForEach(LeadingSwipeAction.allCases) { Text($0.settingsTitle).tag($0.rawValue) }
                    }
                } header: {
                    Text("Swipes")
                } footer: {
                    Text("A short swipe fires one action right away; swiping further fires a second one. Snooze and Move to are always one tap away in a conversation, or by pressing and holding a row.")
                }
                Section("Accounts") {
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
                    Text("Every account syncs into one inbox, newest first; switch to a single account from the top of the screen. Needs You holds what asks something of you; promotions, newsletters and notifications stay in Mail, never hidden. Everything you do here, from replying to archiving and labels, happens in Gmail too.")
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
                Section {
                    privacyRow("Corres never sees your Google password", "key")
                    privacyRow("Sorting, summaries and drafts run on this iPhone", "iphone")
                    privacyRow("Remote images and tracking pixels blocked", "shield.lefthalf.filled")
                    privacyRow("No read receipts or tracking, ever", "eye.slash")
                    privacyRow("No advertising or analytics SDKs", "hand.raised")
                } header: {
                    Text("Private by design")
                } footer: {
                    Text("Sign-in happens with Google directly; Corres only receives a revocable permission, kept in this iPhone's Keychain. Apple Intelligence runs on-device, so your mail is never sent to a server Corres runs, or to any AI provider.")
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
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 10) {
                            CorrespondenceMark().frame(width: 34, height: 34)
                            Text("corres").font(CorresType.heading)
                        }
                        Text("Email, considered.").font(.system(.body, design: .serif).italic())
                        Text("A flagship by Anwar Creative Studio, alongside Artha.")
                            .font(.footnote).foregroundStyle(CorresPalette.secondary)
                        Text("Foundation preview · 0.1.0").font(.caption)
                    }.padding(.vertical, 8)
                }
            }
            .scrollContentBackground(.hidden)
            .background(CorresPalette.canvas)
            .navigationTitle("Settings")
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

    private func privacyRow(_ title: String, _ icon: String) -> some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: icon).foregroundStyle(CorresPalette.accent)
        }
    }
}
