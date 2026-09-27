import SwiftUI

struct CorresShell: View {
    @Bindable var store: MailStore
    var auth: GoogleAuthService
    var sync: GmailSyncService
    @Bindable var outbox: OutboxService
    @Bindable var threadActions: ThreadActionService
    var labelDirectory: LabelDirectory
    @Bindable var pushService: PushNotificationService
    @Bindable var unsubscribeService: UnsubscribeService
    @State private var selection = Destination.brief
    @State private var showingSettings = false
    @State private var showingScreener = false
    @State private var showingWelcome = false
    @State private var composeDraft: Draft?
    /// nil is the unified view (every connected account merged, chronological,
    /// matching Apple Mail's "All Inboxes"/Spark's Smart Inbox); a specific
    /// email switches to that one account only, matching Superhuman's
    /// per-account view. Both are real view modes over the same underlying
    /// `store.threads`, not separate data: Core's `ThreadID.account` already
    /// scopes every thread, so this needed no Core changes at all.
    @State private var accountFilter: String?
    @AppStorage("corres.hasExplored") private var hasExplored = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TabView(selection: $selection) {
            ForEach(Destination.allCases) { destination in
                NavigationStack {
                    destinationContent(for: destination)
                        .background(CorresPalette.canvas)
                        .navigationTitle(title(for: destination))
                        // Brief sets its own greeting as the headline; the
                        // lists use the system large title, set in New York
                        // (see CorresApp.init), which collapses on scroll.
                        .navigationBarTitleDisplayMode(destination == .brief ? .inline : .large)
                        .toolbarTitleMenu { if auth.accounts.count > 1 { accountMenu } }
                        .toolbar { toolbarContent }
                        .navigationDestination(for: ConversationRoute.self) { route in
                            ConversationView(store: store, outbox: outbox, threadActions: threadActions,
                                            labelDirectory: labelDirectory, unsubscribeService: unsubscribeService,
                                            route: route)
                        }
                }
                .tabItem { Label(destination.rawValue, systemImage: destination.systemImage) }
                .tag(destination)
            }
        }
        .foregroundStyle(CorresPalette.ink)
        .overlay(alignment: .bottom) { outboxBanner }
        // Reduce Motion, respected: the banner still needs to appear and
        // disappear (it carries a real, actionable state change: Undo,
        // Retry, Discard), just without the animated slide a person asked
        // iOS to minimize.
        .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: outbox.pending?.id)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: outbox.failed?.id)
        .task {
            if !hasExplored { showingWelcome = true }
            if store.state == .idle { await store.load() }
        }
        // A filtered-to-one-account view whose account was just disconnected
        // would otherwise keep silently showing nothing, with no visible
        // explanation; falling back to "All Inboxes" is the same recovery
        // Preferences' own disconnect flow already expects.
        .onChange(of: auth.accounts) { _, accounts in
            if let accountFilter, !accounts.contains(where: { $0.email == accountFilter }) {
                self.accountFilter = nil
            }
        }
        .sheet(isPresented: $showingSettings) { PreferencesView(store: store, auth: auth, sync: sync, pushService: pushService) }
        .sheet(isPresented: $showingScreener) { ScreenerView(store: store) }
        .sheet(item: $composeDraft) { draft in ComposeView(store: store, outbox: outbox, auth: auth, draft: draft, sourceThread: nil) }
        .fullScreenCover(isPresented: $showingWelcome) {
            WelcomeView {
                hasExplored = true
                showingWelcome = false
            }
        }
        .alert("Could not save", isPresented: Binding(
            get: { store.errorMessage != nil },
            set: { if !$0 { store.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "Please try again.") }
        .alert("Could not complete this action", isPresented: Binding(
            get: { threadActions.errorMessage != nil },
            set: { if !$0 { threadActions.errorMessage = nil } }
        )) {
            if let account = threadActions.reconnectAccount {
                Button("Reconnect") {
                    threadActions.errorMessage = nil
                    threadActions.reconnectAccount = nil
                    Task { await auth.signIn(hint: account) }
                }
                Button("Not Now", role: .cancel) {
                    threadActions.errorMessage = nil
                    threadActions.reconnectAccount = nil
                }
            } else {
                Button("OK", role: .cancel) { threadActions.errorMessage = nil }
            }
        } message: { Text(threadActions.errorMessage ?? "Please try again.") }
        // Reconnect can start from the action-failure alert above, outside
        // Preferences, so its outcome has to be visible here too.
        .alert("Gmail connection", isPresented: Binding(
            get: { auth.errorMessage != nil && !showingSettings },
            set: { if !$0 { auth.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { auth.errorMessage = nil }
        } message: { Text(auth.errorMessage ?? "Please try again.") }
        .alert("Could not turn on notifications", isPresented: Binding(
            get: { pushService.errorMessage != nil },
            set: { if !$0 { pushService.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { pushService.errorMessage = nil }
        } message: { Text(pushService.errorMessage ?? "Please try again.") }
    }

    @ViewBuilder
    private var outboxBanner: some View {
        if let pending = outbox.pending {
            HStack(spacing: 12) {
                Text("Sending \u{201C}\(pending.subjectPreview)\u{201D} in \(pending.secondsRemaining)\u{2026}")
                    .font(.subheadline).lineLimit(1)
                Spacer(minLength: 8)
                Button("Undo") { outbox.undo() }.font(.subheadline.weight(.semibold))
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
            .corresGlass(in: Capsule())
            .padding(.horizontal, CorresSpace.page).padding(.bottom, 90)
            // Reduce Motion drops the slide specifically (large-scale
            // positional movement, what the setting actually targets), not
            // the whole transition: a plain fade still shows the banner
            // appearing/disappearing rather than an abrupt, disorienting
            // instant swap.
            .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
        } else if let failed = outbox.failed {
            HStack(spacing: 12) {
                Text("Couldn't send \u{201C}\(failed.draft.subject)\u{201D}").font(.subheadline).lineLimit(1)
                Spacer(minLength: 8)
                Button("Discard") { outbox.discardFailed() }.font(.subheadline)
                Button("Retry") { outbox.retryFailed() }.font(.subheadline.weight(.semibold))
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
            .corresGlass(in: Capsule())
            .padding(.horizontal, CorresSpace.page).padding(.bottom, 90)
            .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
        }
    }

    @ViewBuilder
    private func destinationContent(for destination: Destination) -> some View {
        switch store.state {
        case .idle, .loading:
            ProgressView("Preparing your space")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed:
            ContentUnavailableView {
                Label("A moment, please", systemImage: "arrow.clockwise")
            } description: {
                Text("Your sample conversations could not be opened.")
            } actions: {
                Button("Try again") { Task { await store.load() } }
            }
        case .loaded:
            if destination == .brief {
                BriefView(store: store, sync: sync, auth: auth, selection: $selection, showingScreener: $showingScreener,
                          accountFilter: accountFilter)
            } else {
                CorrespondenceList(store: store, sync: sync, auth: auth, threadActions: threadActions,
                                   destination: destination, accountFilter: accountFilter)
            }
        }
    }

    private func title(for destination: Destination) -> String {
        switch destination {
        case .brief: ""
        case .mail:
            if let accountFilter { accountFilter.components(separatedBy: "@").first ?? accountFilter }
            else { auth.accounts.count > 1 ? "All Inboxes" : "Mail" }
        default: destination.rawValue
        }
    }

    /// "All Inboxes" (every connected account merged, newest first; the
    /// default) plus one row per account. Reached by tapping the screen's
    /// title, the system's own place for switching what a screen shows.
    @ViewBuilder
    private var accountMenu: some View {
        Button {
            accountFilter = nil
        } label: {
            if accountFilter == nil { Label("All Inboxes", systemImage: "checkmark") }
            else { Label("All Inboxes", systemImage: "tray.2") }
        }
        ForEach(auth.accounts) { account in
            Button {
                accountFilter = account.email
            } label: {
                if accountFilter == account.email { Label(account.email, systemImage: "checkmark") }
                else { Text(account.email) }
            }
        }
    }

    private var profileInitial: String {
        (accountFilter ?? auth.primaryAccount?.email ?? auth.accounts.first?.email)?.first.map { String($0).uppercased() } ?? "C"
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button { composeDraft = Draft(kind: .new, to: "", subject: "") } label: {
                Image(systemName: "square.and.pencil")
                    .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel("New message")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button { showingSettings = true } label: {
                Text(profileInitial)
                    .font(.subheadline.weight(.semibold))
                    .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel("Accounts and settings")
        }
    }
}
