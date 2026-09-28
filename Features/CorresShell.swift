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
    @Environment(\.scenePhase) private var scenePhase

    @Environment(\.horizontalSizeClass) private var sizeClass
    /// The conversation open in the split layout's detail column.
    @State private var splitRoute: ConversationRoute?
    @State private var paths: [Destination: NavigationPath] = [:]
    @Environment(AppRouter.self) private var router

    private func path(for destination: Destination) -> Binding<NavigationPath> {
        Binding(get: { paths[destination] ?? NavigationPath() }, set: { paths[destination] = $0 })
    }

    /// Acts on a widget tap, Siri/Shortcuts action or `corres://` link.
    private func handle(_ target: AppRouter.Target?) {
        guard let target else { return }
        router.pending = nil
        switch target {
        case .destination(let destination):
            selection = destination
            paths[destination] = NavigationPath()
        case .compose:
            composeDraft = Draft(kind: .new, to: "", subject: "")
        case .thread(let id):
            guard store.threads.contains(where: { $0.id == id }) else {
                selection = .needsYou
                return
            }
            let thread = store.threads.first { $0.id == id }
            let destination: Destination = thread?.attention == .waiting ? .waiting : (thread?.attention == .needsYou ? .needsYou : .mail)
            selection = destination
            let route = ConversationRoute(id: id, orderedIDs: [id])
            if sizeClass == .regular {
                splitRoute = route
            } else {
                var fresh = NavigationPath()
                fresh.append(route)
                paths[destination] = fresh
            }
        }
    }

    var body: some View {
        withAlerts(withSheets(withFeedback(layout)))
    }

    @ViewBuilder
    private var layout: some View {
        if sizeClass == .regular {
            splitLayout
        } else {
            tabLayout
        }
    }

    private func withFeedback(_ content: some View) -> some View {
        content
        .foregroundStyle(CorresPalette.ink)
        .overlay(alignment: .bottom) { outboxBanner }
        // Reduce Motion, respected: the banner still needs to appear and
        // disappear (it carries a real, actionable state change: Undo,
        // Retry, Discard), just without the animated slide a person asked
        // iOS to minimize.
        .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: outbox.pending?.id)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: outbox.failed?.id)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: threadActions.pendingRemoval?.id)
        // Premium apps confirm what just happened in the hand, not only on screen.
        .sensoryFeedback(.success, trigger: outbox.pending?.id) { _, new in new != nil }
        .sensoryFeedback(.impact(weight: .medium), trigger: threadActions.pendingRemoval?.id) { _, new in new != nil }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { Task { await threadActions.commitPendingRemoval() } }
        }
        .onChange(of: router.pending) { _, target in handle(target) }
        .task {
            if !hasExplored { showingWelcome = true }
            if store.state == .idle { await store.load() }
            handle(router.pending)
        }
    }

    private func withSheets(_ content: some View) -> some View {
        content
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
    }

    private func withAlerts(_ content: some View) -> some View {
        content
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
        if outbox.pending == nil, outbox.failed == nil, let removal = threadActions.pendingRemoval {
            HStack(spacing: 12) {
                Image(systemName: removal.kind == .archive ? "archivebox" : "trash")
                    .foregroundStyle(CorresPalette.secondary)
                Text(removal.title).font(.subheadline.weight(.medium))
                Text(removal.thread.subject).font(.subheadline).foregroundStyle(CorresPalette.secondary).lineLimit(1)
                Spacer(minLength: 8)
                Button("Undo") { threadActions.undoRemoval() }.font(.subheadline.weight(.semibold))
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
            .corresGlass(in: Capsule())
            .padding(.horizontal, CorresSpace.page).padding(.bottom, 90)
            .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
        } else if let pending = outbox.pending {
            HStack(spacing: 12) {
                // The subject truncates; the countdown never does.
                Text("Sending \u{201C}\(pending.subjectPreview)\u{201D}")
                    .font(.subheadline).lineLimit(1)
                Text("\(pending.secondsRemaining)s")
                    .font(.subheadline).monospacedDigit()
                    .foregroundStyle(CorresPalette.secondary)
                    .fixedSize()
                    .contentTransition(.numericText(countsDown: true))
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

    /// iPhone: one tab per destination, conversations pushed on top.
    private var tabLayout: some View {
        TabView(selection: $selection) {
            ForEach(Destination.allCases) { destination in
                NavigationStack(path: path(for: destination)) {
                    destinationContent(for: destination)
                        .background(CorresPalette.canvas)
                        .navigationTitle(title(for: destination))
                        // Brief sets its own greeting as the headline; the
                        // lists use the system large title, set in New York
                        // (see CorresApp.init), which collapses on scroll.
                        .navigationBarTitleDisplayMode(destination == .brief ? .inline : .large)
                        .modifier(AccountTitleMenu(isEnabled: auth.accounts.count > 1) { accountMenu })
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
    }

    /// iPad and wide windows: Apple Mail's three columns. Sidebar picks the
    /// destination, the middle column lists it, the conversation stays open
    /// beside the list instead of covering it.
    private var splitLayout: some View {
        NavigationSplitView {
            List(selection: Binding(get: { Optional(selection) }, set: { if let new = $0 { selection = new } })) {
                Section {
                    ForEach(Destination.allCases) { destination in
                        NavigationLink(value: destination) {
                            LabeledContent {
                                if let count = sidebarCount(for: destination), count > 0 {
                                    Text(count, format: .number).monospacedDigit()
                                }
                            } label: {
                                Label(destination.rawValue, systemImage: destination.systemImage)
                            }
                        }
                    }
                } header: {
                    HStack(spacing: 8) {
                        CorrespondenceMark().frame(width: 22, height: 22)
                        Text("corres").font(.system(.title3, design: .serif)).foregroundStyle(CorresPalette.ink)
                    }
                    .textCase(nil)
                    .padding(.bottom, 6)
                }
                if auth.accounts.count > 1 {
                    Section("Accounts") { accountMenu }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 240)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { accountButton }
            }
        } content: {
            NavigationStack {
                destinationContent(for: selection)
                    .background(CorresPalette.canvas)
                    .navigationTitle(title(for: selection))
                    .navigationBarTitleDisplayMode(selection == .brief ? .inline : .large)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Button { composeDraft = Draft(kind: .new, to: "", subject: "") } label: {
                                Image(systemName: "square.and.pencil")
                            }
                            .keyboardShortcut("n", modifiers: .command)
                            .accessibilityLabel("New message")
                        }
                    }
            }
            .navigationSplitViewColumnWidth(min: 320, ideal: 380, max: 460)
        } detail: {
            NavigationStack {
                if let splitRoute {
                    ConversationView(store: store, outbox: outbox, threadActions: threadActions,
                                    labelDirectory: labelDirectory, unsubscribeService: unsubscribeService,
                                    route: splitRoute)
                        .id(splitRoute)
                } else {
                    ContentUnavailableView {
                        Label("No conversation selected", systemImage: "envelope.open")
                    } description: {
                        Text("Choose one from the list.")
                    }
                    .background(CorresPalette.canvas)
                }
            }
        }
        .environment(\.conversationSelection, $splitRoute)
        .onChange(of: selection) { splitRoute = nil }
        .tint(CorresPalette.accent)
    }

    private func sidebarCount(for destination: Destination) -> Int? {
        let scoped = accountFilter.map { filter in store.threads.filter { $0.id.account == filter } } ?? store.threads
        switch destination {
        case .needsYou: return MailQuery.filter(scoped, attention: .needsYou).count
        case .waiting: return MailQuery.filter(scoped, attention: .waiting).count
        case .mail: return MailQuery.filter(scoped).filter(\.isUnread).count
        case .brief: return nil
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

    /// Whose face the account button shows: the account being viewed, or
    /// the first connected one in the merged view.
    private var displayedAccount: String? { accountFilter ?? auth.accounts.first?.email }

    private var accountButton: some View {
        Button { showingSettings = true } label: {
            AccountAvatar(email: displayedAccount,
                          name: displayedAccount.flatMap { auth.profile(for: $0)?.name },
                          photoURL: displayedAccount.flatMap { auth.profile(for: $0)?.photoURL })
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Account and settings")
        .accessibilityValue(displayedAccount ?? "Sample mail")
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // Tapping the title also switches (on the lists), but the Brief has
        // no title, so a visible control is the one path that always works.
        if auth.accounts.count > 1 {
            ToolbarItem(placement: .topBarLeading) {
                Menu { accountMenu } label: {
                    Image(systemName: accountFilter == nil ? "tray.2" : "person.crop.circle")
                        .frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel(accountFilter == nil ? "All Inboxes" : accountFilter ?? "")
                .accessibilityHint("Switch between all inboxes and one account")
            }
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button { composeDraft = Draft(kind: .new, to: "", subject: "") } label: {
                Image(systemName: "square.and.pencil")
                    .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel("New message")
        }
        // Its own circle, outside the glass group the system gives other
        // toolbar items on iOS 26, the way Apple's apps show an account.
        if #available(iOS 26.0, *) {
            ToolbarItem(placement: .topBarTrailing) { accountButton }
                .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .topBarTrailing) { accountButton }
        }
    }
}

/// The title-tap account switcher, attached only when there's a choice to
/// make: an empty title menu still draws a disclosure arrow.
private struct AccountTitleMenu<Menu: View>: ViewModifier {
    let isEnabled: Bool
    @ViewBuilder let menu: () -> Menu

    func body(content: Content) -> some View {
        if isEnabled {
            content.toolbarTitleMenu { menu() }
        } else {
            content
        }
    }
}
