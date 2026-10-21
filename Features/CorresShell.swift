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
    /// One screen on iPhone: Mail, opening on its Needs You split. The
    /// iPad sidebar still picks Needs You, Mail or Waiting.
    @State private var selection: Destination = .mail
    private var tabs: [Destination] { [.mail] }
    @AppStorage("corres.mailFilter") private var mailFilter = MailFilter.needsYou

    /// Goes to a screen. On iPhone, Needs You (and the Brief it replaced)
    /// is Mail's first split, and Waiting opens on top of Mail; a widget,
    /// Siri, a notification and a link all land there.
    private func show(_ destination: Destination) {
        if sizeClass == .regular {
            selection = switch destination { case .brief: .needsYou; case .ask: .mail; default: destination }
            return
        }
        var path = NavigationPath()
        switch destination {
        case .needsYou, .brief: mailFilter = .needsYou
        case .waiting: path.append(Destination.waiting)
        case .mail, .ask: break
        }
        paths[.mail] = path
    }

    private var selectionBinding: Binding<Destination> {
        Binding(get: { selection }, set: { show($0) })
    }
    @State private var showingSettings = false
    @State private var settingsAfterAccounts = false
    @State private var foregroundSync: Task<Void, Never>?
    @State private var showingAccounts = false
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
    /// Redraws when an account is renamed, recoloured or hidden from All Inboxes.
    @AppStorage(AccountPreferences.revisionKey) private var accountsRevision = 0
    @AppStorage("corres.hasExplored") private var hasExplored = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    @Environment(\.horizontalSizeClass) private var sizeClass
    /// The conversation open in the split layout's detail column.
    @State private var splitRoute: ConversationRoute?
    @State private var paths: [Destination: NavigationPath] = [:]
    @Environment(AppRouter.self) private var router
    @Environment(AskService.self) private var ask
    @Environment(EntitlementStore.self) private var entitlements
    @Environment(PeopleDirectory.self) private var people: PeopleDirectory?
    @State private var showingPaywall = false
    @AppStorage("corres.paywallOffered") private var paywallOffered = false

    /// Pro screens lock only for real accounts once StoreKit has answered;
    /// sample mail stays fully open so people can try everything first.
    ///
    /// At launch, before StoreKit and the Keychain have answered, the last
    /// known answer stands in (see `isProForDisplay`), and mail already on
    /// screen counts as connected, so a Pro screen never flashes open and
    /// then locks.
    private var requiresPro: Bool {
        let connected = !auth.accounts.isEmpty || store.threads.contains { $0.id.account != "sample" }
        return connected && !entitlements.isProForDisplay
    }

    @State private var focusSetFilter = false

    private func applyFocusFilter() {
        if let account = CorresFocusFilter.activeAccount, auth.accounts.contains(where: { $0.email == account }) {
            accountFilter = account
            focusSetFilter = true
        } else if focusSetFilter {
            accountFilter = nil
            focusSetFilter = false
        }
    }

    private func path(for destination: Destination) -> Binding<NavigationPath> {
        Binding(get: { paths[destination] ?? NavigationPath() }, set: { paths[destination] = $0 })
    }

    /// A conversation opened from a list pushed onto the current screen
    /// (Purchases, Attachments, a person): on top of it, so Back returns
    /// there.
    func openPushed(_ id: ThreadID) {
        let route = ConversationRoute(id: id, orderedIDs: [id])
        if sizeClass == .regular {
            splitRoute = route
        } else {
            var path = paths[selection] ?? NavigationPath()
            path.append(route)
            paths[selection] = path
        }
    }

    /// A new email to someone (from their person card).
    func write(to address: String) {
        composeDraft = Draft(kind: .new, to: address, subject: "")
    }

    /// Acts on a widget tap, Siri/Shortcuts action or `corres://` link.
    private func handle(_ target: AppRouter.Target?) {
        guard let target else { return }
        // Opened cold (from Search or a notification): the mail isn't
        // loaded yet, so the conversation waits until it is.
        if case .thread = target, store.state == .idle || store.state == .loading { return }
        router.pending = nil
        switch target {
        case .destination(let destination):
            show(destination)
        case .compose:
            composeDraft = Draft(kind: .new, to: "", subject: "")
        case .composeTo(let to, let subject, let body):
            composeDraft = Draft(kind: .new, to: to, subject: subject, body: body)
        case .draft(let draft):
            composeDraft = draft
        case .thread(let id):
            // Archived mail too: Search finds it, so it opens.
            guard let thread = store.thread(id) else {
                show(.needsYou)
                return
            }
            let preferred: Destination = thread.attention == .waiting ? .waiting : (thread.attention == .needsYou ? .needsYou : .mail)
            let destination = tabs.contains(preferred) || sizeClass == .regular ? preferred : .mail
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
        // The banner animates on its own; attached to the whole app, these
        // used to animate every list underneath each time it came and went.
        // Reduce Motion keeps the fade and drops the slide.
        // Its own view, so only the pill redraws when it changes. Read here,
        // the Undo pill and the send countdown redrew the whole app (every
        // tab, every toolbar) on each swipe, inside the row's animation,
        // and every second while a send waited.
        .overlay(alignment: .bottom) { FeedbackPills(shell: self) }
        // A Focus filter (Settings → Focus) limits Corres to one account
        // while it's on; turning the Focus off brings every account back.
        .onReceive(NotificationCenter.default.publisher(for: CorresFocusFilter.didChange)) { _ in applyFocusFilter() }
        .onAppear { applyFocusFilter(); watchICloud() }
        .onChange(of: auth.accounts) { watchICloud() }
        .onChange(of: scenePhase) { _, phase in
            // Back from a Control Center button or a widget's Handled.
            if phase == .active { Organizer.shared.applyWidgetHandoffs() }
            // Leaving Corres. Not on a glance at Notification Center or
            // Control Center (`.inactive`), which used to end Undo early.
            if phase == .background {
                // iOS gives a few seconds to finish: a swipe to Trash still
                // reaches the server rather than coming back next launch.
                let work = BackgroundWork.begin("Leaving Corres")
                Task {
                    await threadActions.commitPendingRemoval()
                    // After the snapshot iOS takes on the way out, so it
                    // isn't kept waiting on this.
                    try? await Task.sleep(for: .milliseconds(400))
                    // The Share sheet gets who you've written to since.
                    await ShareBridge.update(auth: auth, people: people, threads: store.threads)
                    // And the notification extension, the settings it judges mail by.
                    PushNotificationService.publishPolicy(accounts: auth.accounts.map(\.email), threads: store.threads)
                    work.end()
                }
            }
            // Back in Corres: anything scheduled that's now due goes.
            if phase == .active {
                Task {
                    // Push for Gmail lapses after 7 days unless renewed; an
                    // app kept open in memory all week never relaunched.
                    await pushService.renewWatchIfDue(accounts: auth.accounts.map(\.email))
                    await ScheduledSends.shared.sendDue(store: store, outbox: outbox)
                    await FollowUps.shared.check(store: store)
                }
                watchICloud()
                keepCurrent()
                // Changes made while offline go now if they can.
                Task { await ActionQueue.shared.drain() }
                // New Since Last Opened: opening Corres clears it.
                if CorresSettings.badge == .new { UserDefaults.standard.set(Date.now, forKey: CorresSettings.lastLeftKey); WidgetBridge.update(from: store.threads) }
            } else if phase == .background {
                IMAPWatcher.shared.stopAll()
                foregroundSync?.cancel()
                UserDefaults.standard.set(Date.now, forKey: CorresSettings.lastLeftKey)
            }
        }
        .task {
            let scheduled = ScheduledSends.shared
            scheduled.announce = { [threadActions] item in
                threadActions.offerUndo(String(localized: "Sends \(ScheduledSends.describe(item.sendAt))"), systemImage: "clock.arrow.circlepath") {
                    if let draft = scheduled.remove(item.id) { composeDraft = draft }
                }
            }
            await scheduled.sendDue(store: store, outbox: outbox)
            await ShareBridge.update(auth: auth, people: people, threads: store.threads)
        }
        .onChange(of: router.pending) { _, target in handle(target) }
        // Without Pro, Corres opens on Primary: Needs You stays one tap
        // along to look at, never a lock in your face each time you open it.
        .onChange(of: requiresPro, initial: true) { _, locked in
            if locked, mailFilter == .needsYou { mailFilter = .primary }
        }
        .environment(\.proUnlocked, !requiresPro)
        // Right after someone connects their first Gmail account, offer the
        // trial once; after that it's only ever one tap away.
        .onChange(of: requiresPro) { _, locked in
            guard locked else { return }
            if selection != .mail { selection = .mail }
            if !paywallOffered {
                paywallOffered = true
                showingPaywall = true
            }
        }
        .task {
            if !hasExplored { showingWelcome = true }
            HangReporter.step("first frame")
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
            Task { await ShareBridge.update(auth: auth, people: people, threads: store.threads) }
            if let accountFilter, !accounts.contains(where: { $0.email == accountFilter }) {
                self.accountFilter = nil
            }
        }
        .sheet(isPresented: $showingAccounts, onDismiss: {
            // Only once the switcher has fully gone: presenting Settings
            // while it's still closing is silently dropped.
            if settingsAfterAccounts {
                settingsAfterAccounts = false
                showingSettings = true
            }
        }) {
            AccountSwitcher(store: store, auth: auth, selection: $accountFilter) {
                settingsAfterAccounts = true
            }
        }
        .sheet(item: Binding(
            get: { showingSettings ? nil : auth.icloudNeedsPassword.map(ICloudReconnect.init) },
            set: { if $0 == nil { auth.icloudNeedsPassword = nil } }
        )) { item in
            if MailAccounts.provider(for: item.id) == .imap {
                OtherEmailSignInView(auth: auth, reconnecting: item.id) { _ in
                    Task { if await sync.syncIfConnected(account: item.id) { await store.load() } }
                } onUseSignIn: { _ in }
            } else {
            ICloudSignInView(auth: auth, reconnecting: item.id, rejected: true) { _ in
                Task {
                    // The watcher needs the new password too.
                    if AccountPreferences.icloudInstant(for: item.id) { try? await pushService.setICloudInstant(true, account: item.id) }
                    if await sync.syncIfConnected(account: item.id) { await store.load() }
                }
            }
            }
        }
        .sheet(isPresented: $showingSettings) { PreferencesView(store: store, auth: auth, sync: sync, pushService: pushService, unsubscriber: unsubscribeService) }
        .sheet(isPresented: $showingScreener) { ScreenerView(store: store) }
        .sheet(isPresented: $showingPaywall) { PaywallView() }
        .sheet(item: $composeDraft) { draft in ComposeView(store: store, outbox: outbox, auth: auth, draft: draft,
                                                                     sourceThread: draft.threadID.flatMap { store.thread($0) })
            .environment(\.proUnlocked, !requiresPro) }
        .fullScreenCover(isPresented: $showingWelcome) {
            WelcomeView {
                hasExplored = true
                showingWelcome = false
            }
        }
    }

    /// Back in Corres, and every 20 seconds while it stays open: ask every
    /// account what changed. Pushes are a hint iOS may delay or drop; mail
    /// read or deleted on gmail.com, Outlook.com or another phone has to
    /// show here without a pull to refresh. Each check asks only for
    /// changes, so it's a few small requests.
    private func keepCurrent() {
        foregroundSync?.cancel()
        foregroundSync = Task { [sync, store, auth] in
            while !Task.isCancelled {
                // iCloud too: its live connection watches only the Inbox,
                // and a connection that quietly dropped would miss changes.
                let accounts = auth.accounts.map(\.email)
                if !accounts.isEmpty, await sync.syncAll(accounts: accounts) { await store.refresh() }
                // Each check asks only what changed (a few small requests),
                // so reading, archiving or deleting in Gmail, Outlook or
                // Mail shows here within seconds, not a minute.
                try? await Task.sleep(for: .seconds(20))
            }
        }
    }

    /// iCloud has no push for other apps: catch up on coming back, then
    /// hold IDLE so new mail lands while Corres is open.
    private func watchICloud() {
        let accounts = auth.accounts.map(\.email)
        for account in accounts where MailAccounts.provider(for: account).usesIMAP {
            Task { if await sync.syncIfConnected(account: account) { await store.load() } }
        }
        IMAPWatcher.shared.start(accounts: accounts) { [sync, store] account in
            Task {
                // A sync already running joins with one more pass after it,
                // so mail that arrived mid-pass isn't dropped.
                if await sync.syncIfConnected(account: account) { await store.load() }
            }
        }
    }

    private func withAlerts(_ content: some View) -> some View {
        content
        .alert("Couldn't Save", isPresented: Binding(
            get: { store.errorMessage != nil },
            set: { if !$0 { store.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "Try again.") }
        .alert("Couldn't Finish That", isPresented: Binding(
            get: { threadActions.errorMessage != nil },
            set: { if !$0 { threadActions.errorMessage = nil } }
        )) {
            if let account = threadActions.reconnectAccount {
                Button("Reconnect") {
                    threadActions.errorMessage = nil
                    threadActions.reconnectAccount = nil
                    Task { await auth.reconnect(account) }
                }
                Button("Not Now", role: .cancel) {
                    threadActions.errorMessage = nil
                    threadActions.reconnectAccount = nil
                }
            } else {
                Button("OK", role: .cancel) { threadActions.errorMessage = nil }
            }
        } message: { Text(threadActions.errorMessage ?? "Try again.") }
        // Reconnect can start from the action-failure alert above, outside
        // Preferences, so its outcome has to be visible here too.
        .alert("Account Connection", isPresented: Binding(
            get: { auth.errorMessage != nil && !showingSettings },
            set: { if !$0 { auth.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { auth.errorMessage = nil }
        } message: { Text(auth.errorMessage ?? "Try again.") }
        .alert("Couldn't Turn On Notifications", isPresented: Binding(
            get: { pushService.errorMessage != nil },
            set: { if !$0 { pushService.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { pushService.errorMessage = nil }
        } message: { Text(pushService.errorMessage ?? "Try again.") }
    }

    @State private var bannerDrag: CGFloat = 0

    @ViewBuilder
    fileprivate var outboxBanner: some View {
        if outbox.pending == nil, outbox.failed == nil, let removal = threadActions.pendingRemoval {
            // A small pill, not a full-width bar: working through a stack of
            // email, the rows beside it stay swipeable, the list makes room
            // below (see CorrespondenceList), and a flick down sends it now.
            HStack(spacing: 10) {
                Image(systemName: removal.kind.systemImage)
                    .foregroundStyle(CorresPalette.secondary)
                Text(removal.title).font(.subheadline.weight(.medium))
                Button("Undo") { threadActions.undoRemoval() }
                    .font(.subheadline.weight(.semibold))
                    .padding(.leading, 4)
            }
            .padding(.horizontal, 18).frame(minHeight: 44)
            .corresGlass(in: Capsule())
            .fixedSize()
            // Follows the finger vertically; a flick up or down puts it away
            // (the archive or delete goes through, as if the time ran out).
            .offset(y: bannerDrag)
            .opacity(1 - min(abs(bannerDrag) / 120, 0.6))
            .gesture(DragGesture(minimumDistance: 8)
                .onChanged { bannerDrag = $0.translation.height }
                .onEnded { value in
                    let moved = value.translation.height
                    let flung = value.predictedEndTranslation.height
                    if abs(moved) > 24 || abs(flung) > 60 {
                        Task { await threadActions.commitPendingRemoval() }
                    }
                    withAnimation(.spring(duration: 0.25)) { bannerDrag = 0 }
                })
            .accessibilityElement(children: .contain)
            .accessibilityLabel(removal.threads.count == 1 ? "\(removal.title): \(removal.thread.subject)" : removal.title)
            .padding(.bottom, 92)
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
        } else if let change = threadActions.lastChange {
            // Handled, read, flag, pin, Move to: the same pill as Archive,
            // so a mis-swipe is one tap from undone. A flick puts it away.
            HStack(spacing: 10) {
                Image(systemName: change.systemImage)
                    .foregroundStyle(CorresPalette.secondary)
                // Long ones ("Mail from Teddy Baldassarre goes to
                // Promotions") wrap inside the screen instead of running
                // off it.
                Text(change.title).font(.subheadline.weight(.medium))
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                Button("Undo") { threadActions.undoLastChange() }
                    .font(.subheadline.weight(.semibold))
                    .padding(.leading, 4)
                    .fixedSize()
            }
            .padding(.horizontal, 18).padding(.vertical, 6).frame(minHeight: 44)
            .corresGlass(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .frame(maxWidth: 380)
            .padding(.horizontal, CorresSpace.page)
            .offset(y: bannerDrag)
            .opacity(1 - min(abs(bannerDrag) / 120, 0.6))
            .gesture(DragGesture(minimumDistance: 8)
                .onChanged { bannerDrag = $0.translation.height }
                .onEnded { value in
                    if abs(value.translation.height) > 24 || abs(value.predictedEndTranslation.height) > 60 {
                        threadActions.dismissLastChange()
                    }
                    withAnimation(.spring(duration: 0.25)) { bannerDrag = 0 }
                })
            .accessibilityElement(children: .contain)
            .padding(.bottom, 92)
            .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
        } else if let shelved = outbox.shelved, composeDraft == nil {
            // The email you stepped away from, a tap from where you left
            // it, like Mail's tucked-away compose.
            HStack(spacing: 10) {
                Image(systemName: "square.and.pencil").foregroundStyle(CorresPalette.secondary)
                VStack(alignment: .leading, spacing: 0) {
                    Text(shelved.draft.subject.isEmpty ? String(localized: "Draft") : shelved.draft.subject)
                        .font(.subheadline.weight(.medium)).lineLimit(1)
                    Text(shelved.isSavedToGmail ? "Saved to Drafts" : shelved.couldNotSave ? "Kept on this \(Device.name)" : "Saving to Drafts\u{2026}")
                        .font(.caption).foregroundStyle(CorresPalette.secondary)
                }
                .frame(maxWidth: 200, alignment: .leading)
                Button("Open") { composeDraft = outbox.takeShelved() }
                    .font(.subheadline.weight(.semibold))
                Button { outbox.clearShelf() } label: {
                    Image(systemName: "xmark").font(.caption.weight(.semibold)).foregroundStyle(CorresPalette.secondary)
                        .frame(width: 28, height: 28)
                }
                .accessibilityLabel("Put away. It stays in Drafts.")
            }
            .padding(.leading, 16).padding(.trailing, 8).frame(minHeight: 48)
            .corresGlass(in: Capsule())
            .fixedSize()
            .onTapGesture { composeDraft = outbox.takeShelved() }
            .accessibilityElement(children: .contain)
            .padding(.bottom, 92)
            .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
        }
    }

    @ViewBuilder
    /// `pushedOnto`: shown on top of that tab rather than as a tab itself.
    /// It's on screen whenever that tab is; it used to count as never on
    /// screen, so its rows never updated (a swiped row sprang back).
    private func destinationContent(for destination: Destination, pushedOnto host: Destination? = nil) -> some View {
        let isActive = selection == (host ?? destination)
        switch store.displayState {
        case .idle, .loading:
            // The launch screen's own mark, at the same size and centered
            // on the whole screen, so launch hands off without the mark
            // fading under a spinner.
            Image("LaunchMark")
                .overlay(alignment: .bottom) {
                    ProgressView().controlSize(.small).offset(y: 44)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()
                .accessibilityElement()
                .accessibilityLabel("Preparing your space")
        case .failed:
            ContentUnavailableView {
                Label("One moment", systemImage: "arrow.clockwise")
            } description: {
                Text("Your sample conversations couldn't be opened.")
            } actions: {
                Button("Try Again") { Task { await store.load() } }
            }
        case .loaded:
            if requiresPro && destination != .mail {
                ProLockView(destination: destination,
                            onUnlock: { showingPaywall = true },
                            onOpenMail: { show(.mail) })
            } else {
                CorrespondenceList(store: store, sync: sync, auth: auth, threadActions: threadActions,
                                   destination: destination, accountFilter: accountFilter,
                                   isActive: isActive, needsYouLocked: requiresPro,
                                   onUnlockPro: { showingPaywall = true }, showingScreener: $showingScreener,
                                   onOpenWaiting: { show(.waiting) })
            }
        }
    }

    private func title(for destination: Destination) -> String {
        switch destination {
        case .brief: ""
        case .mail:
            if let accountFilter { AccountPreferences.nickname(for: accountFilter) }
            else { auth.accounts.count > 1 ? String(localized: "All Inboxes") : String(localized: "Mail") }
        default: destination.title
        }
    }

    /// iPhone: Mail alone, no tab bar. Its splits (Needs You first) are
    /// the views of your mail; conversations and Waiting push on top.
    private var tabLayout: some View {
        NavigationStack(path: path(for: .mail)) {
            destinationContent(for: .mail)
                .background(CorresPalette.canvas)
                .navigationTitle(title(for: .mail))
                // The system large title, set in New York (see
                // CorresApp.init), which collapses on scroll.
                .navigationBarTitleDisplayMode(.large)
                .toolbar { toolbarContent }
                .navigationDestination(for: ConversationRoute.self) { route in
                    let _ = HangReporter.startOpening("\(route.id.account)|\(route.id.providerID)")
                    ConversationView(store: store, outbox: outbox, threadActions: threadActions,
                                    labelDirectory: labelDirectory, unsubscribeService: unsubscribeService,
                                    route: route)
                }
                .modifier(MailboxDestinations(shell: self))
                // Waiting, opened from the row above Needs You or a link.
                .navigationDestination(for: Destination.self) { pushed in
                    destinationContent(for: pushed, pushedOnto: .mail)
                        .background(CorresPalette.canvas)
                        .navigationTitle(title(for: pushed))
                        .navigationBarTitleDisplayMode(.large)
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
                    ForEach([Destination.needsYou, .mail, .waiting]) { destination in
                        NavigationLink(value: destination) {
                            LabeledContent {
                                if let count = sidebarCount(for: destination), count > 0 {
                                    Text(count, format: .number).monospacedDigit()
                                }
                            } label: {
                                Label(destination.title, systemImage: destination.systemImage)
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
                    .modifier(MailboxDestinations(shell: self))
                    .toolbar {
                        if selection == .mail {
                            ToolbarItem(placement: .topBarLeading) { mailboxesLink }
                        }
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
        let overview = store.overview(account: accountFilter, all: auth.accounts.map(\.email))
        switch destination {
        case .needsYou: return overview.needsYou.count
        case .waiting: return overview.waitingCount
        case .mail: return overview.unreadCount
        case .brief, .ask: return nil
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
                // Its name in Corres ("Work", "Gmail"), the address beneath.
                if accountFilter == account.email {
                    Label(AccountPreferences.nickname(for: account.email), systemImage: "checkmark")
                } else {
                    Text(AccountPreferences.nickname(for: account.email))
                }
                Text(account.email)
            }
        }
    }

    /// Whose face the account button shows: the account being viewed, or
    /// the first connected one in the merged view.
    private var displayedAccount: String? { accountFilter ?? auth.accounts.first?.email }

    /// With one account, Settings. With several, Gmail's account switcher
    /// (`AccountSwitcher`): All Inboxes, each account, then Settings.
    @ViewBuilder
    private var accountButton: some View {
        let avatar = AccountAvatar(email: displayedAccount,
                                   name: displayedAccount.flatMap { auth.profile(for: $0)?.name },
                                   photoURL: displayedAccount.flatMap { auth.profile(for: $0)?.photoURL })
            // Viewing one account: a ring in its colour says which.
            .padding(accountFilter == nil ? 0 : 3)
            .overlay {
                if let accountFilter, let color = AccountPreferences.color(for: accountFilter, among: auth.accounts.map(\.email)) {
                    Circle().strokeBorder(color, lineWidth: 2)
                }
            }
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Circle())
        if auth.accounts.count > 1 {
            Button { showingAccounts = true } label: { avatar }
                .buttonStyle(.plain)
                .accessibilityLabel("Accounts and settings")
                .accessibilityValue(accountFilter.map(AccountPreferences.nickname(for:)) ?? "All Inboxes")
        } else {
            Button { showingSettings = true } label: { avatar }
                .buttonStyle(.plain)
                .accessibilityLabel("Account and settings")
                .accessibilityValue(displayedAccount ?? "Sample mail")
        }
    }

    /// The accounts Mailboxes shows: the one in view, or all of them.
    fileprivate var mailboxAccounts: [String] { accountFilter.map { [$0] } ?? AccountPreferences.allInboxesAccounts(auth.accounts.map(\.email)) }

    private var mailboxesLink: some View {
        NavigationLink(value: MailboxesRoute()) {
            // The menu mark Gmail and Spark use for "everything else": a
            // folder read as "files", not mailboxes.
            Image(systemName: "line.3.horizontal").frame(minWidth: 44, minHeight: 44)
        }
        .accessibilityLabel("Mailboxes")
        .accessibilityHint("Drafts, Sent, All Mail, Spam, Trash and labels")
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
      // While selecting, the list's own Select All / count / Done take the
      // bar, as in Mail.
      if !router.isSelecting {
        // Drafts, Sent, All Mail, Spam, Trash and labels: the rest of the
        // mailbox, one tap from Mail (see `MailboxesView`).
        if selection == .mail {
            ToolbarItem(placement: .topBarLeading) { mailboxesLink }
            // Its own button, not merged into one capsule with Select.
            if #available(iOS 26.0, macOS 26.0, *) {
                ToolbarSpacer(.fixed, placement: .topBarLeading)
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
        if #available(iOS 26.0, macOS 26.0, *) {
            ToolbarItem(placement: .topBarTrailing) { accountButton }
                .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .topBarTrailing) { accountButton }
        }
      }
    }
}

/// Mailboxes and each mailbox in it, registered at the root of a stack so
/// they open from anywhere on it (see `MailboxesRoute`).
private struct MailboxDestinations: ViewModifier {
    let shell: CorresShell

    func body(content: Content) -> some View {
        content
            .navigationDestination(for: MailboxesRoute.self) { _ in
                MailboxesView(store: shell.store, threadActions: shell.threadActions, labelDirectory: shell.labelDirectory,
                              outbox: shell.outbox, auth: shell.auth, accounts: shell.mailboxAccounts,
                              open: { shell.openPushed($0) })
            }
            .navigationDestination(for: Mailbox.self) { mailbox in
                if mailbox == .drafts {
                    DraftsView(store: shell.store, outbox: shell.outbox, auth: shell.auth, accounts: shell.mailboxAccounts)
                } else {
                    MailboxView(mailbox: mailbox, store: shell.store, threadActions: shell.threadActions,
                                accounts: shell.mailboxAccounts)
                }
            }
    }
}

/// The iCloud account asking for a new password, as a sheet item.
private struct ICloudReconnect: Identifiable { let id: String }

/// The Undo, sending and draft pills along the bottom (see `withFeedback`).
private struct FeedbackPills: View {
    let shell: CorresShell
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let outbox = shell.outbox, threadActions = shell.threadActions
        let animation: Animation? = reduceMotion ? nil : .easeOut(duration: 0.22)
        ZStack { shell.outboxBanner }
            .animation(animation, value: outbox.pending?.id)
            .animation(animation, value: outbox.failed?.id)
            .animation(animation, value: threadActions.pendingRemoval?.id)
            .animation(animation, value: threadActions.lastChange?.id)
            .animation(animation, value: outbox.shelved?.id)
            // Premium apps confirm what just happened in the hand, not only on screen.
            .sensoryFeedback(.success, trigger: outbox.pending?.id) { _, new in new != nil }
            .sensoryFeedback(.impact(weight: .medium), trigger: threadActions.pendingRemoval?.id) { _, new in new != nil }
            // Snoozed, Handled, moved: a lighter tap than a removal.
            .sensoryFeedback(.impact(weight: .light), trigger: threadActions.lastChange?.id) { _, new in new != nil }
            // Undo, felt as undone.
            .sensoryFeedback(.impact(flexibility: .soft, intensity: 0.7), trigger: threadActions.undoCount)
    }
}
