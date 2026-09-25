import BackgroundTasks
import SwiftData
import UIKit

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

    /// Must match the identifier declared in `Info.plist`'s
    /// `BGTaskSchedulerPermittedIdentifiers`; iOS silently refuses to run
    /// (or even accept registration for) an identifier missing from there.
    private static let backgroundRefreshIdentifier = "studio.anwarcreative.corres.renewWatch"

    override init() {
        let (container, usedInMemoryFallback) = Self.makeModelContainer()
        let repository = SwiftDataMailRepository(modelContainer: container)
        let mailStore = MailStore(repository: repository)
        let authService = GoogleAuthService()
        store = mailStore
        // A real, silent-until-now failure mode, found in a review sweep:
        // this used to fall back to an in-memory store with nothing telling
        // the person their mail had stopped actually being saved. Reusing
        // `MailStore.errorMessage` (the same alert `CorresShell` already
        // shows for every other save failure) rather than inventing a
        // second, separate banner mechanism just for this one case.
        if usedInMemoryFallback {
            mailStore.errorMessage = "Corres couldn't open its usual local storage and is running in memory only right now. Nothing will be saved once you close the app — please restart Corres. If this keeps happening, your device may be low on storage."
        }
        sync = GmailSyncService(repository: repository)
        auth = authService
        outbox = OutboxService(store: mailStore, auth: authService, repository: repository)
        threadActions = ThreadActionService(store: mailStore, auth: authService)
        labelDirectory = LabelDirectory()
        pushService = PushNotificationService()
        unsubscribeService = UnsubscribeService()
        semanticTriageService = SemanticTriageService()
        super.init()
    }

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Registration must happen before this method returns, for every
        // launch, background or foreground alike: registering even one
        // async tick late is a documented source of silent failures where
        // iOS never runs the task at all.
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.backgroundRefreshIdentifier, using: nil) { [weak self] task in
            guard let self, let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            self.handleBackgroundRefresh(refreshTask)
        }
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
        scheduleBackgroundRefresh()
    }

    /// iOS decides the actual timing (usage patterns, battery, thermal
    /// state); `earliestBeginDate` is only a hint of the earliest
    /// reasonable moment, never a guarantee it runs then or at all. Called
    /// after every launch and after every background run, since a
    /// submitted request is consumed the moment it executes; forgetting to
    /// resubmit here would make this run exactly once per install rather
    /// than recur.
    private func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: Self.backgroundRefreshIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 4 * 60 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    private func handleBackgroundRefresh(_ task: BGAppRefreshTask) {
        scheduleBackgroundRefresh()
        let work = Task {
            await pushService.renewWatch(accounts: auth.accounts.map(\.email))
            task.setTaskCompleted(success: true)
        }
        // Ignoring the expiration handler damages this task's standing
        // with iOS's own scheduling model; an ungracefully-killed task
        // gets future requests deprioritized.
        task.expirationHandler = {
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
        let previousUnread = Dictionary(uniqueKeysWithValues: store.threads.map { ($0.id, $0.isUnread) })
        guard await sync.syncAll(accounts: auth.accounts.map(\.email)) else { return .noData }
        await store.load()
        func newlyUnreadThreads() -> [Correspondence] {
            store.threads.filter { thread in
                thread.isUnread && previousUnread[thread.id] != true
                    // Matches the Screener's own rule for ordinary browsing:
                    // a pending/blocked sender's first message doesn't
                    // belong in a notification either.
                    && thread.senderDecision == .approved
            }
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
        // Preferences → "Only notify for what needs me": a direct extension
        // of Corres's own stated thesis ("less noise, more perspective"),
        // not a bolted-on setting. Read straight from UserDefaults, not
        // @AppStorage: AppDelegate is not a View, and the key is the same
        // one PreferencesView's own @AppStorage toggle writes to.
        let notifyOnlyNeedsYou = UserDefaults.standard.bool(forKey: "corres.notifyOnlyNeedsYou")
        let toNotify = notifyOnlyNeedsYou ? newlyUnread.filter { $0.attention == .needsYou } : newlyUnread
        pushService.notifyAboutNewMail(toNotify)
        return .newData
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
                fatalError("Could not create any Corres local store, including an in-memory fallback: \(error)")
            }
            return (fallback, true)
        }
    }
}
