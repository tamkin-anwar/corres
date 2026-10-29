import AppKit
import SwiftData
import SwiftUI
import UserNotifications

/// Everything Corres runs on the Mac, made once at launch: the same store,
/// sync, Postwright engine, sorting, iCloud state and on-device
/// intelligence as the iPhone app (see the iPhone's `AppDelegate`).
///
/// A Mac stays awake and Corres stays open, so mail is checked every
/// minute while it runs, iCloud and other IMAP accounts hold IDLE for
/// instant arrival, and new mail notifies as it lands.
@MainActor @Observable
final class MacServices {
    /// One for the app: the app delegate starts it at launch, before (or
    /// without) any window.
    static let shared = MacServices()

    let store: MailStore
    let sync: GmailSyncService
    let auth: GoogleAuthService
    let outbox: OutboxService
    let threadActions: ThreadActionService
    let labelDirectory: LabelDirectory
    let pushService: PushNotificationService
    let unsubscribeService: UnsubscribeService
    let semanticTriage: SemanticTriageService
    let intelligence: MailIntelligence
    let router: AppRouter
    let ask: AskService
    let entitlements: EntitlementStore
    let people: PeopleDirectory
    let remote = MacRemoteMailboxes()

    /// Pro screens lock only for real accounts once StoreKit has answered;
    /// sample mail stays fully open so people can try everything first.
    /// The same rule as the iPhone's (`CorresShell.requiresPro`): before
    /// StoreKit answers, the last known answer stands in, and mail already
    /// here counts as connected, so a Pro list never flashes open and locks.
    var requiresPro: Bool {
        let connected = !auth.accounts.isEmpty || store.threads.contains { $0.id.account != "sample" }
        return connected && !entitlements.isProForDisplay
    }

    /// Whether the Corres Pro window is open, so its own alert shows an
    /// error rather than Settings' too.
    var paywallOpen = false

    private var checkLoop: Task<Void, Never>?
    private var launched = false
    /// What `observe` keeps running.
    @ObservationIgnored private var observers: [AnyObject] = []
    /// While Corres runs: what you do in Gmail, Outlook or Mail shows here
    /// within this, and new mail on services without push for us sooner.
    private static let checkInterval: Duration = .seconds(20)

    private init() {
        HangReporter.step("setup began")
        let (container, inMemory) = Self.makeModelContainer()
        HangReporter.step("storage opened")
        let repository = Self.makeRepository(container)
        CorresSettings.applyToCore()
        let store = MailStore(repository: repository)
        store.contentReader = MessageContentReader(modelContainer: container)
        store.seedsSampleMail = {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-MeasureLaunch") { return false }
            #endif
            return !GoogleAuthService.hasSavedAccounts
        }
        let auth = GoogleAuthService()
        self.store = store
        if inMemory {
            store.errorMessage = String(localized: "Corres couldn't open its usual local storage and is running in memory only right now. Nothing will be saved once you close the app. Restart Corres. If this keeps happening, your device may be low on storage.")
        }
        sync = GmailSyncService(repository: repository)
        self.auth = auth
        outbox = OutboxService(store: store, auth: auth, repository: repository)
        threadActions = ThreadActionService(store: store, auth: auth)
        Organizer.shared.attach(store: store, actions: threadActions, outbox: outbox)
        ServerRules.shared.attach(auth: auth)
        // Handled from a desktop widget, applied when Corres comes forward.
        // The Dock's New Since Last Opened (chosen on the iPhone, it comes
        // here through iCloud) counts from when you last left Corres, as on
        // the iPhone. Never noted here, it counted nothing.
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in
                OutboxService.isAway = true
                UserDefaults.standard.set(Date.now, forKey: CorresSettings.lastLeftKey)
            }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [store] _ in
            Task { @MainActor in
                if CorresSettings.badge == .new {
                    UserDefaults.standard.set(Date.now, forKey: CorresSettings.lastLeftKey)
                    WidgetBridge.update(from: store.threads)
                }
                OutboxService.isAway = false
                // A subscription that ended while Corres sat in the
                // background sends no update: it kept Pro until relaunch.
                Task { await MacServices.shared.entitlements.refresh() }
                Organizer.shared.applyWidgetHandoffs()
                ServerRules.shared.retryIfFailed()
                await Organizer.shared.outbox?.retryFailedQuietly()
            }
        }
        labelDirectory = LabelDirectory()
        pushService = PushNotificationService()
        unsubscribeService = UnsubscribeService()
        semanticTriage = SemanticTriageService()
        intelligence = MailIntelligence()
        intelligence.storedThread = { [weak store] in await store?.storedThread($0) ?? $0 }
        router = AppRouter.shared
        ask = AskService(store: store, sync: sync, auth: auth)
        entitlements = EntitlementStore()
        people = PeopleDirectory()
        HangReporter.step("services ready")
        // Reading your mail starts now, in the background, not once the
        // window is up.
        store.readEarly()
    }

    /// The buttons on a new-mail notification, as on the iPhone
    /// (`AppDelegate.handleNotificationAction`).
    private func notificationAction(_ action: String, id: ThreadID, typed: String?) async {
        if store.state != .loaded { await store.load() }
        // Archive and reply need the account back, or they're turned away:
        // a notification clicked as Corres launches came before it was.
        await auth.waitUntilRestored()
        // Notified before Corres had stored it: fetched now, for a few
        // seconds at most, or a reply typed into it would be lost.
        if store.thread(id) == nil {
            _ = await Self.waitBriefly(for: Task { [sync] in _ = await sync.syncAll(accounts: [id.account]) }, upTo: .seconds(10))
            await store.load()
        }
        guard var thread = store.thread(id) else {
            // Still not here (deleted, or moved elsewhere): your words are
            // kept as a draft to finish in Corres, rather than vanishing.
            if action == PushNotificationService.replyAction, let typed, !typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                outbox.shelve(Draft(kind: .new, fromAccount: id.account, to: "", subject: "", body: typed), replyingTo: nil)
            }
            return
        }
        switch action {
        case PushNotificationService.archiveAction:
            await threadActions.archive(thread)
            await threadActions.commitPendingRemoval()
        case PushNotificationService.markReadAction:
            await threadActions.setUnread(false, for: thread)
        case PushNotificationService.replyAction:
            let text = (typed ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            // The email it quotes, often not read here yet: without it the
            // reply went out quoting nothing. Bounded, so a slow connection
            // doesn't hold the reply back.
            if !thread.isBodyLoaded {
                _ = await Self.waitBriefly(for: Task { [threadActions] in await threadActions.loadContent(for: thread) }, upTo: .seconds(8))
                thread = store.thread(thread.id) ?? thread
            }
            var draft = thread.draft(kind: .reply)
            draft.body = Draft.adding(signature: CorresSettings.signature(for: id.account, reply: true), to: text + draft.body)
            if let address = SendAsDirectory.shared.address(for: id.account, answering: thread), !address.isPrimary {
                draft.fromAddress = address.email
                draft.fromName = address.name.isEmpty ? nil : address.name
            }
            await outbox.sendNow(draft, replyingTo: thread)
            await threadActions.setUnread(false, for: thread)
        default:
            break
        }
    }

    /// Waits for `task` up to `limit`: what it returned, or nil if it's
    /// still going (it carries on). The iPhone's `waitBriefly`.
    private static func waitBriefly<T: Sendable>(for task: Task<T, Never>, upTo limit: Duration) async -> T? {
        let timer = Task<T?, Never> {
            try? await Task.sleep(for: limit)
            return nil
        }
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            let once = OnceBox()
            Task { let value = await task.value; if once.claim() { continuation.resume(returning: value) } }
            Task { let value = await timer.value; if once.claim() { continuation.resume(returning: value) } }
        }
        timer.cancel()
        return result
    }

    /// True the first time it's claimed.
    private final class OnceBox: @unchecked Sendable {
        private let lock = NSLock()
        private var claimed = false
        func claim() -> Bool { lock.withLock { defer { claimed = true }; return !claimed } }
    }

    /// Once per launch: open the mailbox, restore accounts, first sync.
    func launch() async {
        guard !launched else { return }
        launched = true
        startObserving()
        HangReporter.shared.start()
        HangReporter.step("window up")
        CrashCollector.shared.start()
        CloudSync.shared.start(store: store)
        HangReporter.step("iCloud settings ready")
        PushNotificationService.registerNotificationActions()
        MacAppDelegate.handleAction = { [weak self] action, id, typed in await self?.notificationAction(action, id: id, typed: typed) }
        MacAppDelegate.didRegister = { [weak self] token in
            guard let self else { return }
            Task { await self.pushService.didRegister(deviceToken: token, accounts: self.auth.accounts.map(\.email)) }
        }
        // Waking from sleep or back online: the old connections are gone,
        // so open new ones and check now.
        MacAppDelegate.didWake = { [weak self] in self?.reconnect() }
        // A push only says mail changed: check now, without reconnecting
        // every iCloud account's live connection.
        MacAppDelegate.didReceivePush = { [weak self] in Task { await self?.checkForMail() } }
        NetworkWatch.shared.cameBack = { [weak self] in self?.reconnect() }
        NetworkWatch.shared.start()
        // The mail first, then the accounts: the list doesn't wait on the
        // keychain.
        let loading = Task { await store.load() }
        // Removed from all your devices on another one: its mail here goes.
        auth.onRemovedElsewhere = { [unowned self] email in
            await pushService.disable(account: email)
            await AccountRemoval.forgetHere(email, sync: sync, store: store, intelligence: intelligence, people: people)
        }
        await auth.restoreConnectedAccounts()
        HangReporter.step("accounts restored")
        // Asked for as soon as the accounts are known, not after the
        // first sync: a slow or stuck sync used to mean it was never
        // asked at all, so no alerts and no pushes on the Mac.
        Task { await startNotifications() }
        await loading.value
        HangReporter.finish("launch")
        #if DEBUG
        await stressSyncIfAsked()
        #endif
        // Web views ready before the first email is opened, as on iPhone.
        Task {
            try? await Task.sleep(for: .seconds(1))
            await WKWebViewPool.shared.prewarm()
        }
        await store.migrateAttentionRulesIfNeeded()
        let accounts = auth.accounts.map(\.email)
        // What's already here isn't news: only what arrives from now on.
        noticeBaseline()
        if await sync.syncAll(accounts: accounts) {
            await store.load()
            await notifyArrivals()
            await semanticTriage.triageIfNeeded(store: store)
        }
        await labelDirectory.refreshIfConnected(accounts: accounts)
        if !accounts.isEmpty { await store.deleteSampleDataIfPresent() }
        await outbox.resumeAfterRelaunch()
        watchIMAP()
        startChecking()
    }

    #if DEBUG
    /// Measuring the first minute after launch with no server:
    /// `-stressSync N` saves N batches of 50 changed conversations (2 of
    /// them with new mail) the way a first sync does, a quarter second
    /// apart, each reloaded as `syncProgress` reloads, then runs what a
    /// sync that brought mail runs after (`launch`, `afterSync`,
    /// `afterChange`). Use with -SampleMailOnly -stressThreads N
    /// -stressAccount, which keeps it all in memory.
    private func stressSyncIfAsked() async {
        let args = ProcessInfo.processInfo.arguments
        guard args.contains("-SampleMailOnly"), let flag = args.firstIndex(of: "-stressSync"), flag + 1 < args.count,
              let batches = Int(args[flag + 1]) else { return }
        try? await Task.sleep(for: .seconds(2))
        FileHandle.standardError.write(Data("stress sync start \(ProcessInfo.processInfo.systemUptime)\n".utf8))
        HangReporter.note("stress sync \(batches) batches")
        for _ in 0..<batches {
            await store.stressSyncBatch(50, arriving: 2)
            SyncBatchRefresh.schedule(store)
            try? await Task.sleep(for: .milliseconds(250))
        }
        await store.load()
        await semanticTriage.triageIfNeeded(store: store)
        afterSync()
        afterChange()
        FileHandle.standardError.write(Data("stress sync end \(ProcessInfo.processInfo.systemUptime)\n".utf8))
    }
    #endif

    /// New-mail notifications, and the pushes that wake Corres the moment
    /// mail changes: asked for once accounts are here, as Mail does on
    /// first launch, then kept registered every launch.
    private func startNotifications() async {
        let accounts = auth.accounts.map(\.email)
        guard !accounts.isEmpty else { return }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined:
            await pushService.enableAll(accounts: accounts)
        case .authorized, .provisional:
            if !pushService.isEnabled { await pushService.enableAll(accounts: accounts) }
            NSApplication.shared.registerForRemoteNotifications()
            await pushService.renewWatchIfDue(accounts: accounts)
        default:
            break
        }
    }

    /// Get New Mail (⇧⌘N, the toolbar or the sidebar's footer): a fresh
    /// connection to iCloud's live updates too, in case it went quiet.
    /// While a Get New Mail you asked for runs. The quiet check every 20
    /// seconds doesn't count: shown, it kept "Checking for mail…" up and
    /// the button gone most of the time.
    private(set) var isGettingNewMail = false

    func getNewMail() {
        guard NetworkWatch.shared.isOnline, !isGettingNewMail else { return }
        isGettingNewMail = true
        reconnect { self.isGettingNewMail = false }
    }

    private func reconnect(then done: (@MainActor () -> Void)? = nil) {
        guard NetworkWatch.shared.isOnline else { done?(); return }
        IMAPWatcher.shared.stopAll()
        watchIMAP()
        Task {
            await checkForMail()
            done?()
            // Labels and folders too: fetched only at launch, a Mac opened
            // offline had none in its sidebar until Corres was quit.
            await labelDirectory.refreshIfConnected(accounts: auth.accounts.map(\.email))
        }
    }

    /// The regular check (every 20 seconds while open).
    func checkForMail() async {
        let accounts = auth.accounts.map(\.email)
        guard !accounts.isEmpty, NetworkWatch.shared.isOnline else { return }
        let changeBefore = sync.lastChange
        // Handled from a desktop widget while Corres runs in the background:
        // applied here, or the next snapshot brought the email back.
        Organizer.shared.applyWidgetHandoffs()
        guard await sync.syncAll(accounts: accounts) else { return }
        await ScheduledSends.shared.sendDue(store: store, outbox: outbox)
        // Push kept alive while Corres stays open for days (cheap when not due).
        await pushService.renewWatchIfDue(accounts: accounts)
        // Nothing new: the mailbox isn't read again.
        guard sync.lastChange != changeBefore else { return }
        await store.load()
        await notifyArrivals()
    }

    /// The newest message of each conversation already considered, so a
    /// new reply in an unread conversation is news, and nothing is
    /// announced twice however many checks find it.
    private var noticed: [ThreadID: String] = [:]

    private func noticeBaseline() {
        for thread in store.threads { if let latest = thread.latestMessageID { noticed[thread.id] = latest } }
    }

    /// Whatever arrived since last time, wherever the sync came from (the
    /// 20-second check, iCloud's live connection, a push): one place.
    private func notifyArrivals() async {
        let fresh = store.threads.filter { thread in
            guard let latest = thread.latestMessageID, noticed[thread.id] != latest else { return false }
            return thread.isUnread && !thread.isFromAccountOwner
        }
        noticeBaseline()
        guard !fresh.isEmpty else { return }
        let ids = Set(fresh.filter { !$0.isScreenedOut }.map(\.id))
        await semanticTriage.triageIfNeeded(store: store, only: ids)
        // Only while Corres isn't the app in front: when you're looking
        // at the list, the new row is the notice.
        guard !NSApplication.shared.isActive else { return }
        // During a Focus limited to one account, only that account notifies.
        let focus = Self.focusAccount(among: auth.accounts.map(\.email))
        let toNotify = fresh.compactMap { store.thread($0.id) }.filter { thread in
            guard focus.map({ $0 == thread.id.account }) ?? true else { return false }
            return thread.isScreenedOut
                ? PushNotificationService.NewSenderAlerts.includes(thread) && AccountPreferences.level(for: thread.id.account) != nil
                : AccountPreferences.level(for: thread.id.account)?.includes(thread) == true
        }
        pushService.notifyAboutNewMail(toNotify)
    }

    /// The account a Focus's Show One Account limits Corres to, while it's
    /// one still connected here (removed since, it limits nothing).
    static func focusAccount(among accounts: [String]) -> String? {
        CorresFocusFilter.activeAccount.flatMap { accounts.contains($0) ? $0 : nil }
    }

    /// What follows a sync that brought or changed something: each goes
    /// over the whole mailbox, so not after every check that found nothing.
    func afterChange() {
        Task { await CloudSync.shared.apply() }
        Task {
            let accounts = auth.accounts.map(\.email)
            await people.updateInBackground(from: store.threads, accounts: accounts)
            await people.backfillIfNeeded(accounts: accounts)
        }
        Task {
            await store.refresh()
            await semanticTriage.triageIfNeeded(store: store)
        }
    }

    /// What follows every sync, wherever it came from (the minute check,
    /// IDLE, a newly added account): the same as on the iPhone.
    func afterSync() {
        Task { await FollowUps.shared.check(store: store) }
        // Almost every check finds nothing, so each step reloads the lists
        // only when it saved something; the last reload costs next to
        // nothing when nothing changed.
        Task {
            if await sync.backfillContent() { await store.refresh() }
            if await sync.indexOlderMail(accounts: auth.accounts.map(\.email)) { await store.refresh() }
            await sync.verifyInboxes(accounts: auth.accounts.map(\.email))
            await store.refresh()
            if !requiresPro && CorresSettings.summaries {
                await intelligence.prewarm(store.threads, includeRead: false, revision: store.contentRevision)
            }
        }
    }

    /// What follows a sync, and what the widgets, Spotlight and the Dock
    /// show: watched here rather than by the main window, so it all goes
    /// on with no window open (Corres runs on in the menu bar).
    private func startObserving() {
        observe({ [unowned self] in sync.lastCompletedSync }) { [unowned self] _ in afterSync() }
        observe({ [unowned self] in sync.lastChange }) { [unowned self] _ in afterChange() }
        observe({ [unowned self] in store.revision }, initial: true) { [unowned self] _ in
            SpotlightIndex.shared.scheduleUpdate { [store] in store.searchableThreads }
            // The desktop widgets and the Dock show what's on this Mac.
            WidgetBridge.scheduleUpdate { [store] in store.threads }
        }
        observe({ [unowned self] in WidgetBridge.locks(connected: !auth.accounts.isEmpty, entitlements: entitlements) },
                initial: true) { [unowned self] locked in
            WidgetBridge.isLocked = locked
            Task { await WidgetBridge.updateInBackground(from: store.threads) }
        }
        // At most one reload each half second: a first sync saves a hundred
        // batches, and each reload redraws the lists.
        observe({ [unowned self] in sync.syncProgress }) { [unowned self] _ in SyncBatchRefresh.schedule(store) }
        // Siri, Shortcuts or a person's card in a conversation window asking
        // for a place (open this email, this draft, search) while the main
        // window is closed: only it takes those, so it opens and takes the
        // request as it appears, rather than nothing happening.
        observe({ [unowned self] in router.pending }) { pending in
            if pending != nil, !MacWindows.mainIsOpen { MacWindows.showMain() }
        }
    }

    /// SwiftUI's onChange, for the app rather than a view: `changed` runs
    /// each time what `read` returns changes, and once at the start when
    /// `initial`.
    private func observe<Value: Equatable>(_ read: @escaping @MainActor () -> Value, initial: Bool = false,
                                           _ changed: @escaping @MainActor (Value) -> Void) {
        let observer = Observer(read: read, changed: changed)
        observers.append(observer)
        observer.start(initial: initial)
    }

    func accountsChanged() {
        watchIMAP()
        ServerRules.shared.schedule()
        Task {
            // The first account added in Settings: the sample mail goes
            // before its mail arrives, as on the iPhone. It stayed in
            // among the real mail until Corres was opened again.
            if !auth.accounts.isEmpty { await store.deleteSampleDataIfPresent() }
            await checkForMail()
            // A new account's labels or folders, in the sidebar now.
            await labelDirectory.refreshIfConnected(accounts: auth.accounts.map(\.email))
            // The first account added in Settings asks for alerts now,
            // not at the next launch; a later one registers its pushes.
            await startNotifications()
        }
    }

    private func startChecking() {
        checkLoop?.cancel()
        checkLoop = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.checkInterval)
                guard let self, !Task.isCancelled else { return }
                await self.checkForMail()
            }
        }
    }

    /// iCloud and other IMAP accounts have no push for other apps: IDLE
    /// keeps a connection open so new mail lands within seconds.
    private func watchIMAP() {
        IMAPWatcher.shared.start(accounts: auth.accounts.map(\.email)) { [weak self] account in
            Task { @MainActor in
                guard let self, await self.sync.syncIfConnected(account: account) else { return }
                await self.store.load()
                // iCloud's new mail notifies too, not only the 20-second check's.
                await self.notifyArrivals()
            }
        }
    }

    /// Made on a background queue, so the repository's model actor runs
    /// there and not on the main thread (as on the iPhone).
    private static func makeRepository(_ container: ModelContainer) -> SwiftDataMailRepository {
        final class Box: @unchecked Sendable { var repository: SwiftDataMailRepository? }
        let box = Box()
        let made = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            box.repository = SwiftDataMailRepository(modelContainer: container)
            made.signal()
        }
        made.wait()
        return box.repository!
    }

    private static func makeModelContainer() -> (container: ModelContainer, inMemory: Bool) {
        let schema = Schema(CorresSchemaV1.models)
        #if DEBUG
        // Screenshots: sample mail in memory, never the store a real
        // Corres on this Mac is using.
        if ProcessInfo.processInfo.arguments.contains("-SampleMailOnly"),
           let sample = try? ModelContainer(for: schema, configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]) {
            return (sample, false)
        }
        #endif
        #if DEBUG
        // A test build keeps its own mailbox, so it can never move the one
        // the TestFlight Corres on this Mac uses to a newer layout.
        let directory = URL.applicationSupportDirectory.appending(path: "Corres Debug", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let configuration = ModelConfiguration(schema: schema, url: directory.appending(path: "default.store"), cloudKitDatabase: .none)
        #else
        let configuration = ModelConfiguration(schema: schema, cloudKitDatabase: .none)
        #endif
        do {
            let container = try ModelContainer(for: schema, migrationPlan: CorresMigrationPlan.self,
                                               configurations: [configuration])
            return (container, false)
        } catch {
            let memory = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            guard let fallback = try? ModelContainer(for: schema, configurations: [memory]) else {
                fatalError("Couldn't create any Corres store, including in memory: \(error)")
            }
            return (fallback, true)
        }
    }
}

/// One value `MacServices.observe` watches, through Observation.
@MainActor
private final class Observer<Value: Equatable> {
    private let read: @MainActor () -> Value
    private let changed: @MainActor (Value) -> Void
    private var last: Value?

    init(read: @escaping @MainActor () -> Value, changed: @escaping @MainActor (Value) -> Void) {
        self.read = read
        self.changed = changed
    }

    func start(initial: Bool) {
        let value = track()
        last = value
        if initial { changed(value) }
    }

    /// Reads it, and asks to hear about the next change.
    private func track() -> Value {
        withObservationTracking { read() } onChange: { [weak self] in
            Task { @MainActor in self?.fire() }
        }
    }

    private func fire() {
        let value = track()
        guard value != last else { return }
        last = value
        changed(value)
    }
}

/// Shows each batch a sync saves: the first batch at once, the last one
/// always, the ones between folded together. At most one reload each half
/// second while the first screenful fills in, then each two seconds: a
/// first sync saves a hundred batches, and each reload rebuilds the lists
/// on the main thread, which made scrolling stall through it.
@MainActor
private enum SyncBatchRefresh {
    private static var running: Task<Void, Never>?
    private static var again = false

    static func schedule(_ store: MailStore) {
        guard running == nil else { again = true; return }
        running = Task {
            var reloads = 0
            repeat {
                again = false
                await store.refresh()
                reloads += 1
                try? await Task.sleep(for: .milliseconds(reloads < 3 ? 500 : 2_000))
            } while again
            running = nil
        }
    }
}
