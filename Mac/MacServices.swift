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
    private static let checkInterval: Duration = .seconds(60)

    init() {
        let (container, inMemory) = Self.makeModelContainer()
        let repository = Self.makeRepository(container)
        CorresSettings.applyToCore()
        let store = MailStore(repository: repository)
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
        labelDirectory = LabelDirectory()
        pushService = PushNotificationService()
        unsubscribeService = UnsubscribeService()
        semanticTriage = SemanticTriageService()
        intelligence = MailIntelligence()
        router = AppRouter.shared
        ask = AskService(store: store, sync: sync, auth: auth)
        entitlements = EntitlementStore()
        people = PeopleDirectory()
    }

    /// Once per launch: open the mailbox, restore accounts, first sync.
    func launch() async {
        guard !launched else { return }
        launched = true
        HangReporter.shared.start()
        CloudSync.shared.start(store: store)
        PushNotificationService.registerNotificationActions()
        async let loaded: Void = store.load()
        await auth.restoreConnectedAccounts()
        await loaded
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
