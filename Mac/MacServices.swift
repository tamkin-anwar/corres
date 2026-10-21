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

    private var checkLoop: Task<Void, Never>?
    private var launched = false
    /// While Corres runs: what you do in Gmail, Outlook or Mail shows here
    /// within this, and new mail on services without push for us sooner.
    private static let checkInterval: Duration = .seconds(20)

    init() {
        let (container, inMemory) = Self.makeModelContainer()
        let repository = Self.makeRepository(container)
        CorresSettings.applyToCore()
        let store = MailStore(repository: repository)
        store.contentReader = MessageContentReader(modelContainer: container)
        store.seedsSampleMail = { !GoogleAuthService.hasSavedAccounts }
        let auth = GoogleAuthService()
        self.store = store
        if inMemory {
            store.errorMessage = "Corres couldn't open its usual storage and is running in memory only. Nothing will be saved once you quit. Restart Corres, and check your Mac has free space."
        }
        sync = GmailSyncService(repository: repository)
        self.auth = auth
        outbox = OutboxService(store: store, auth: auth, repository: repository)
        threadActions = ThreadActionService(store: store, auth: auth)
        Organizer.shared.attach(store: store, actions: threadActions)
        // Handled from a desktop widget, applied when Corres comes forward.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in Organizer.shared.applyWidgetHandoffs() }
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
    }

    /// The buttons on a new-mail notification, as on the iPhone.
    private func notificationAction(_ action: String, id: ThreadID, typed: String?) async {
        if store.state != .loaded { await store.load() }
        guard let thread = store.thread(id) else { return }
        switch action {
        case PushNotificationService.archiveAction:
            await threadActions.archive(thread)
            await threadActions.commitPendingRemoval()
        case PushNotificationService.markReadAction:
            await threadActions.setUnread(false, for: thread)
        case PushNotificationService.replyAction:
            let text = (typed ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
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

    /// Once per launch: open the mailbox, restore accounts, first sync.
    func launch() async {
        guard !launched else { return }
        launched = true
        HangReporter.shared.start()
        CloudSync.shared.start(store: store)
        PushNotificationService.registerNotificationActions()
        MacAppDelegate.handleAction = { [weak self] action, id, typed in await self?.notificationAction(action, id: id, typed: typed) }
        MacAppDelegate.didRegister = { [weak self] token in
            guard let self else { return }
            Task { await self.pushService.didRegister(deviceToken: token, accounts: self.auth.accounts.map(\.email)) }
        }
        MacAppDelegate.didWake = { [weak self] in Task { await self?.checkForMail() } }
        async let loaded: Void = store.load()
        await auth.restoreConnectedAccounts()
        await loaded
        HangReporter.finish("launch")
        // Web views ready before the first email is opened, as on iPhone.
        Task {
            try? await Task.sleep(for: .seconds(1))
            await WKWebViewPool.shared.prewarm()
        }
        await store.migrateAttentionRulesIfNeeded()
        let accounts = auth.accounts.map(\.email)
        if await sync.syncAll(accounts: accounts) {
            await store.load()
            await semanticTriage.triageIfNeeded(store: store)
        }
        await labelDirectory.refreshIfConnected(accounts: accounts)
        if !accounts.isEmpty { await store.deleteSampleDataIfPresent() }
        await outbox.resumeAfterRelaunch()
        watchIMAP()
        startChecking()
        await startNotifications()
    }

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

    /// Get New Mail (⇧⌘N), and the once-a-minute check.
    func checkForMail() async {
        let accounts = auth.accounts.map(\.email)
        guard !accounts.isEmpty else { return }
        let before = Dictionary(store.threads.map { ($0.id, $0.isUnread) }, uniquingKeysWith: { first, _ in first })
        guard await sync.syncAll(accounts: accounts) else { return }
        await store.load()
        await ScheduledSends.shared.sendDue(store: store, outbox: outbox)
        let arrived = store.threads.filter { $0.isUnread && before[$0.id] != true && !$0.isScreenedOut }
        await semanticTriage.triageIfNeeded(store: store, only: Set(arrived.map(\.id)))
        // Only while Corres isn't the app in front: when you're looking
        // at the list, the new row is the notice.
        guard !NSApplication.shared.isActive else { return }
        let fresh = store.threads.filter { $0.isUnread && before[$0.id] != true && !$0.isScreenedOut }
        let toNotify = fresh.filter { AccountPreferences.level(for: $0.id.account)?.includes($0) == true }
        pushService.notifyAboutNewMail(toNotify)
    }

    /// What follows every sync, wherever it came from (the minute check,
    /// IDLE, a newly added account): the same as on the iPhone.
    func afterSync() {
        Task { await FollowUps.shared.check(store: store) }
        Task { await CloudSync.shared.apply() }
        Task {
            let accounts = auth.accounts.map(\.email)
            people.update(from: store.threads, accounts: accounts)
            await people.backfillIfNeeded(accounts: accounts)
        }
        Task {
            await store.refresh()
            await semanticTriage.triageIfNeeded(store: store)
        }
        Task {
            await sync.backfillContent()
            await store.refresh()
            if await sync.indexOlderMail(accounts: auth.accounts.map(\.email)) { await store.refresh() }
            await sync.verifyInboxes(accounts: auth.accounts.map(\.email))
            await store.refresh()
            if entitlements.isPro && CorresSettings.summaries {
                await intelligence.prewarm(store.threads, includeRead: false)
            }
        }
    }

    func accountsChanged() {
        watchIMAP()
        Task { await checkForMail() }
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
        IMAPWatcher.shared.start(accounts: auth.accounts.map(\.email)) { [sync, store] account in
            Task { if await sync.syncIfConnected(account: account) { await store.load() } }
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
        do {
            let container = try ModelContainer(for: schema, migrationPlan: CorresMigrationPlan.self,
                                               configurations: [ModelConfiguration(schema: schema)])
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
