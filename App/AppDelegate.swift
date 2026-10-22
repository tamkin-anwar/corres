import BackgroundTasks
import SwiftData
import UIKit
import UserNotifications

/// Owns every core service Corres needs, not `CorresApp`. This is a
/// correction, not the original design: a SwiftUI `View`'s `.task`
/// modifier only reliably runs once the app's UI actually appears, which
/// is not guaranteed for a background-only launch (a silent push, or the
/// `BGAppRefreshTask` this file adds, both firing after iOS may have fully
/// terminated the app between launches). Both need real, live service
/// instances and an already-restored signed-in account the moment this
/// delegate is constructed, not whenever SwiftUI's view hierarchy happens
/// to run its own launch task. `CorresApp` now just reads these back out
/// and does only genuinely foreground-only setup (pre-warming the
/// WKWebView pool) in its own `.task`.
final class AppDelegate: NSObject, UIApplicationDelegate {
    let store: MailStore
    let sync: GmailSyncService
    let auth: GoogleAuthService
    let outbox: OutboxService
    let threadActions: ThreadActionService
    let labelDirectory: LabelDirectory
    let pushService: PushNotificationService
    let unsubscribeService: UnsubscribeService
    let semanticTriageService: SemanticTriageService
    let mailIntelligence: MailIntelligence
    let router: AppRouter
    let askService: AskService
    let entitlements: EntitlementStore
    let people: PeopleDirectory

    /// Must match the identifier declared in `Info.plist`'s
    /// `BGTaskSchedulerPermittedIdentifiers`; iOS silently refuses to run
    /// (or even accept registration for) an identifier missing from there.
    private static let backgroundRefreshIdentifier = "studio.anwarcreative.corres.renewWatch"

    /// Made on a background thread, not here on the main thread: SwiftData
    /// sets up a context created on the main thread as a main-queue
    /// context, and the repository's whole point is keeping its work off
    /// the main thread (see SwiftDataMailRepository). `async` plus a wait,
    /// because `sync` onto a global queue runs the block right here on the
    /// calling thread.
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

    override init() {
        HangReporter.step("setup began")
        let (container, usedInMemoryFallback) = Self.makeModelContainer()
        HangReporter.step("storage opened")
        let repository = Self.makeRepository(container)
        CorresSettings.applyToCore()
        let mailStore = MailStore(repository: repository)
        mailStore.contentReader = MessageContentReader(modelContainer: container)
        mailStore.seedsSampleMail = { !GoogleAuthService.hasSavedAccounts }
        let authService = GoogleAuthService()
        HangReporter.step("accounts ready")
        store = mailStore
        // A real, silent-until-now failure mode, found in a review sweep:
        // this used to fall back to an in-memory store with nothing telling
        // the person their mail had stopped actually being saved. Reusing
        // `MailStore.errorMessage` (the same alert `CorresShell` already
        // shows for every other save failure) rather than inventing a
        // second, separate banner mechanism just for this one case.
        if usedInMemoryFallback {
            mailStore.errorMessage = "Corres couldn't open its usual local storage and is running in memory only right now. Nothing will be saved once you close the app. Restart Corres. If this keeps happening, your device may be low on storage."
        }
        sync = GmailSyncService(repository: repository)
        auth = authService
        outbox = OutboxService(store: mailStore, auth: authService, repository: repository)
        threadActions = ThreadActionService(store: mailStore, auth: authService)
        Organizer.shared.attach(store: mailStore, actions: threadActions, outbox: outbox)
        labelDirectory = LabelDirectory()
        pushService = PushNotificationService()
        unsubscribeService = UnsubscribeService()
        semanticTriageService = SemanticTriageService()
        mailIntelligence = MailIntelligence()
        mailIntelligence.storedThread = { [weak mailStore] in await mailStore?.storedThread($0) ?? $0 }
        router = AppRouter.shared
        askService = AskService(store: mailStore, sync: sync, auth: authService)
        HangReporter.step("services ready")
        entitlements = EntitlementStore()
        people = PeopleDirectory()
        super.init()
    }

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        CorresTips.start()
        HangReporter.shared.start()
        HangReporter.step("app started")
        CloudSync.shared.start(store: store)
        // Registration must happen before this method returns, for every
        // launch, background or foreground alike: registering even one
        // async tick late is a documented source of silent failures where
        // iOS never runs the task at all.
        // On the main queue: this delegate runs on the main actor, and with
        // `nil` iOS ran the handler on its own background queue, which
        // Swift stops with a crash (every TestFlight crash so far: the app
        // woken in the background, phone locked, to refresh).
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.backgroundRefreshIdentifier, using: .main) { [weak self] task in
            guard let self, let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            self.handleBackgroundRefresh(refreshTask)
        }
        UNUserNotificationCenter.current().delegate = self
        PushNotificationService.registerNotificationActions()
        Task { await self.performLaunchWork() }
        return true
    }

    /// Everything a launch needs regardless of whether the app is actually
    /// visible: restoring the signed-in accounts, loading local threads, an
    /// initial sync, and renewing the push watch subscription. Runs on
    /// every launch (this method fires for a background-only launch too),
    /// not gated behind the UI ever appearing.
    ///
    /// Structured for real parallelism, not just readability (Batch 29's
    /// full-sweep pass): `store.load()` (reading local SwiftData) and
    /// `auth.restoreConnectedAccounts()` (Keychain + UserDefaults, no
    /// dependency on local thread data) don't depend on each other and used
    /// to run one after another for no reason. Once the connected accounts
    /// are known, `sync.syncAll` (each account's own Gmail round trip),
    /// `labelDirectory.refreshIfConnected`, and `pushService.renewWatch`
    /// are three more independent network operations that don't need to
    /// wait on each other either, each of which is itself now internally
    /// concurrent across accounts (see their own doc comments); only
    /// `store.load()`'s second call (to pick up whatever `sync` just wrote)
    /// and everything that reads that fresh state (`deleteSampleDataIfPresent`,
    /// `outbox.resumeAfterRelaunch`, which needs `store.threads` to resolve
    /// a resumed reply's source thread) still have to wait for `sync` to
    /// actually finish.
    private func performLaunchWork() async {
        async let storeLoaded: Void = store.load()
        await auth.restoreConnectedAccounts()
        await storeLoaded
        await store.migrateAttentionRulesIfNeeded()
        let accountEmails = auth.accounts.map(\.email)
        PushNotificationService.publishPolicy(accounts: accountEmails, threads: store.threads)

        async let didSync = sync.syncAll(accounts: accountEmails)
        async let labelsRefreshed: Void = labelDirectory.refreshIfConnected(accounts: accountEmails)
        async let watchRenewed: Void = pushService.renewWatch(accounts: accountEmails)

        if await didSync {
            await store.load()
            // Runs after the fresh sync is actually in `store.threads`, not
            // concurrently with it: triage needs real, current
            // `latestMessageID`/`attention` values to know what's actually
            // new, and silently assessing stale pre-sync data would just
            // mean redoing the same work again moments later anyway.
            await semanticTriageService.triageIfNeeded(store: store)
        }
        _ = await (labelsRefreshed, watchRenewed)

        // Covers relaunching already connected (the connect button in
        // Preferences handles the first-connection case itself): sample
        // threads from before that connection existed have no reason to
        // still be mixed into real mail.
        if !accountEmails.isEmpty {
            await store.deleteSampleDataIfPresent()
        }
        await outbox.resumeAfterRelaunch()
        Self.scheduleBackgroundRefresh()
    }

    /// iOS decides the actual timing (usage patterns, battery, thermal
    /// state); `earliestBeginDate` is only a hint of the earliest
    /// reasonable moment, never a guarantee it runs then or at all. Called
    /// after every launch and after every background run, since a
    /// submitted request is consumed the moment it executes; forgetting to
    /// resubmit here would make this run exactly once per install rather
    /// than recur.
    static func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: Self.backgroundRefreshIdentifier)
        // Sooner when an email is scheduled to go: iOS treats this as the
        // earliest moment, so the send isn't held up by a 4-hour wait.
        // With iCloud connected, as often as iOS allows: it's how iCloud
        // mail is noticed while Corres is closed. Gmail and Outlook push.
        let hasICloud = (UserDefaults.standard.stringArray(forKey: "corres.connectedAccounts") ?? [])
            .contains { MailAccounts.provider(for: $0).usesIMAP }
        let usual = Date(timeIntervalSinceNow: hasICloud ? 15 * 60 : 4 * 60 * 60)
        request.earliestBeginDate = ScheduledSends.shared.nextSendAt.map { min(max($0, .now), usual) } ?? usual
        try? BGTaskScheduler.shared.submit(request)
    }

    private func handleBackgroundRefresh(_ task: BGAppRefreshTask) {
        Self.scheduleBackgroundRefresh()
        let work = Task {
            if store.state != .loaded { await store.load() }
            // iCloud has no push for apps: this is when its new mail is
            // found and notified while Corres is closed.
            let icloud = auth.accounts.map(\.email).filter { MailAccounts.provider(for: $0).usesIMAP }
            if !icloud.isEmpty { _ = await syncAndNotify(accounts: icloud) }
            await ScheduledSends.shared.sendDue(store: store, outbox: outbox)
            await FollowUps.shared.check(store: store)
            await pushService.renewWatch(accounts: auth.accounts.map(\.email))
            task.setTaskCompleted(success: true)
        }
        // Ignoring the expiration handler damages this task's standing
        // with iOS's own scheduling model; an ungracefully-killed task
        // gets future requests deprioritized. Made outside the main actor:
        // iOS calls it on a queue of its own.
        task.expirationHandler = Self.expirationHandler(cancelling: work, task: task)
    }

    nonisolated private static func expirationHandler(cancelling work: Task<Void, Never>,
                                                      task: BGAppRefreshTask) -> @Sendable () -> Void {
        nonisolated(unsafe) let task = task
        return {
            work.cancel()
            task.setTaskCompleted(success: false)
        }
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        Task { await pushService.didRegister(deviceToken: deviceToken, accounts: auth.accounts.map(\.email)) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // Best-effort feature: a failed APNs registration (no network, a
        // simulator with no push entitlement, etc.) should not surface as
        // an error anywhere a person would see it unprompted.
    }

    /// The push itself carries no content, only a "something changed"
    /// signal (see `PushNotificationService`'s doc comment); this is what
    /// actually fetches and shows the real mail, on-device, exactly like
    /// any other sync. Fires reliably even from a cold background launch,
    /// since `store`/`sync`/`auth` are real instances owned by this
    /// delegate, not closures that depend on SwiftUI's view ever running.
    func application(_ application: UIApplication,
                     didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        // A "before" snapshot, not just "is it unread now": a thread
        // already unread before this sync (the person just hasn't gotten
        // to it yet) must not re-trigger a notification every time
        // something else in the account also changes.
        guard await syncAndNotify(accounts: auth.accounts.map(\.email)) else { return .noData }
        return .newData
    }

    /// Syncs `accounts` and notifies about what's newly arrived, by each
    /// account's notification choice. A push for Gmail or Outlook runs it
    /// for every account; background refresh runs it for iCloud, which has
    /// no push for apps.
    private func syncAndNotify(accounts: [String]) async -> Bool {
        // The snapshot needs the saved mail: taken from an empty store on a
        // cold launch, every unread email looked new.
        if store.state != .loaded { await store.load() }
        let previousUnread = Dictionary(store.threads.map { ($0.id, $0.isUnread) }, uniquingKeysWith: { first, _ in first })
        guard await sync.syncAll(accounts: accounts) else { return false }
        await store.load()
        // A push is also a chance to send what's scheduled, and to see
        // whether a follow-up reminder is due or answered.
        await ScheduledSends.shared.sendDue(store: store, outbox: outbox)
        await FollowUps.shared.check(store: store)
        await pushService.renewOutlookSubscriptions(accounts: auth.accounts.map(\.email))
        func newlyUnreadThreads() -> [Correspondence] {
            store.threads.filter { thread in
                thread.isUnread && previousUnread[thread.id] != true && !thread.isScreenedOut
            }
        }
        // First emails from senders still in New senders, filtered by
        // Settings → Notifications → New senders.
        let newSenders = store.threads.filter { thread in
            thread.isUnread && previousUnread[thread.id] != true
                && PushNotificationService.NewSenderAlerts.includes(thread)
        }
        // Triage only what just arrived, before deciding what to notify
        // about, so "Only notify for what needs me" acts on a refined
        // judgment. Scoped deliberately: iOS allows roughly 30 seconds of
        // background execution per push, and assessing the whole untriaged
        // backlog first could delay this notification past that window, or
        // get the app killed before it's posted at all. The backlog is
        // picked up by the next foreground sync instead.
        await semanticTriageService.triageIfNeeded(store: store, only: Set(newlyUnreadThreads().map(\.id)))
        let newlyUnread = newlyUnreadThreads()
        // Settings → Notifications (see PushNotificationService.Level), or
        // the account's own choice in Settings → the account.
        let toNotify = (newlyUnread.filter { AccountPreferences.level(for: $0.id.account)?.includes($0) == true }
                        + newSenders.filter { AccountPreferences.level(for: $0.id.account) != nil })
            // During a Focus limited to one account, only that account notifies.
            .filter { thread in CorresFocusFilter.activeAccount.map { $0 == thread.id.account } ?? true }
        pushService.notifyAboutNewMail(toNotify)
        WidgetBridge.update(from: store.threads)
        return true
    }

    /// The `Bool` is whether this had to fall back to the in-memory
    /// configuration — found in a review sweep to matter a lot more than
    /// the original comment here assumed: "at the cost of that device's
    /// local history this session" undersold it. The in-memory fallback
    /// doesn't just lose history that already existed; it silently stops
    /// persisting anything new for the rest of this launch, with nothing
    /// telling the person their mail isn't actually being saved until they
    /// relaunch and it's gone. `init` surfaces this via the same
    /// `MailStore.errorMessage` alert every other save failure already
    /// uses, rather than failing quietly the way this did before.
    private static func makeModelContainer() -> (container: ModelContainer, usedInMemoryFallback: Bool) {
        let schema = Schema(CorresSchemaV1.models)
        do {
            let container = try ModelContainer(for: schema, migrationPlan: CorresMigrationPlan.self,
                                               configurations: [ModelConfiguration(schema: schema)])
            return (container, false)
        } catch {
            // A corrupt/incompatible on-disk store should not brick the app on
            // launch; fall back to a fresh in-memory container so it still
            // opens, at the cost of that device's local history this session.
            let fallbackConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            guard let fallback = try? ModelContainer(for: schema, configurations: [fallbackConfiguration]) else {
                fatalError("Couldn't create any Corres local store, including an in-memory fallback: \(error)")
            }
            return (fallback, true)
        }
    }
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    /// Archive / Mark as Read from a notification. Runs in the background
    /// window iOS grants the action, so an archive is sent right away
    /// rather than waiting out the in-app Undo window nobody can see.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        // "Ready to send": opening Corres sends what's due.
        if info["destination"] as? String == "scheduled" {
            await MainActor.run { AppRouter.shared.pending = .destination(.mail) }
            await sendScheduledDue()
            return
        }
        if info["destination"] as? String == "brief" {
            await MainActor.run { AppRouter.shared.pending = .destination(.needsYou) }
            return
        }
        guard let account = info["account"] as? String, let providerID = info["thread"] as? String else {
            // A summary of several emails opens Needs You.
            if response.actionIdentifier == UNNotificationDefaultActionIdentifier {
                await MainActor.run { AppRouter.shared.pending = .destination(.needsYou) }
            }
            return
        }
        let typed = (response as? UNTextInputNotificationResponse)?.userText
        await handleNotificationAction(response.actionIdentifier, account: account, providerID: providerID, typed: typed)
    }

    private func sendScheduledDue() async {
        if store.state != .loaded { await store.load() }
        await ScheduledSends.shared.sendDue(store: store, outbox: outbox)
    }

    /// Awaited to completion so iOS keeps the app alive until Gmail has it.
    private func handleNotificationAction(_ action: String, account: String, providerID: String, typed: String? = nil) async {
        if store.state != .loaded { await store.load() }
        guard let thread = store.threads.first(where: { $0.id == ThreadID(account: account, providerID: providerID) }) else { return }
        switch action {
        case PushNotificationService.archiveAction:
            await threadActions.archive(thread)
            await threadActions.commitPendingRemoval()
        case PushNotificationService.markReadAction:
            await threadActions.setUnread(false, for: thread)
        case PushNotificationService.replyAction:
            let text = (typed ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            // As a reply written in Compose: your words, your signature,
            // then the email quoted; from the address it was sent to.
            var draft = thread.draft(kind: .reply)
            draft.body = ComposeView.adding(signature: CorresSettings.signature(for: account, reply: true), to: text + draft.body)
            if let address = SendAsDirectory.shared.address(for: account, answering: thread), !address.isPrimary {
                draft.fromAddress = address.email
                draft.fromName = address.name.isEmpty ? nil : address.name
            }
            await outbox.sendNow(draft, replyingTo: thread)
            await threadActions.setUnread(false, for: thread)
        case UNNotificationDefaultActionIdentifier:
            // Tapping the notification opens that conversation.
            router.pending = .thread(thread.id)
        default:
            break
        }
    }
}
