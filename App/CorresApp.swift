import GoogleSignIn
import SwiftData
import SwiftUI

@main
struct CorresApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store: MailStore
    @State private var sync: GmailSyncService
    @State private var auth: GoogleAuthService
    @State private var outbox: OutboxService
    @State private var threadActions: ThreadActionService
    @State private var labelDirectory = LabelDirectory()
    @State private var pushService = PushNotificationService()
    @AppStorage("corres.appearance") private var appearance = Appearance.system.rawValue

    init() {
        let container = Self.makeModelContainer()
        let repository = SwiftDataMailRepository(modelContainer: container)
        let mailStore = MailStore(repository: repository)
        let authService = GoogleAuthService()
        _store = State(initialValue: mailStore)
        _sync = State(initialValue: GmailSyncService(repository: repository))
        _auth = State(initialValue: authService)
        _outbox = State(initialValue: OutboxService(store: mailStore, auth: authService, repository: repository))
        _threadActions = State(initialValue: ThreadActionService(store: mailStore, auth: authService))
    }

    private static func makeModelContainer() -> ModelContainer {
        let schema = Schema(CorresSchemaV1.models)
        do {
            return try ModelContainer(for: schema, migrationPlan: CorresMigrationPlan.self,
                                      configurations: [ModelConfiguration(schema: schema)])
        } catch {
            // A corrupt/incompatible on-disk store should not brick the app on
            // launch; fall back to a fresh in-memory container so it still
            // opens, at the cost of that device's local history this session.
            let fallbackConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
            guard let fallback = try? ModelContainer(for: schema, configurations: [fallbackConfiguration]) else {
                fatalError("Could not create any Corres local store, including an in-memory fallback: \(error)")
            }
            return fallback
        }
    }

    var body: some Scene {
        WindowGroup {
            CorresShell(store: store, auth: auth, sync: sync, outbox: outbox, threadActions: threadActions,
                       labelDirectory: labelDirectory, pushService: pushService)
                .preferredColorScheme(Appearance(rawValue: appearance)?.colorScheme)
                .tint(CorresPalette.accent)
                .task {
                    // Wired here, not at AppDelegate construction time: the
                    // delegate exists before this App's own store/sync/auth/
                    // pushService do (UIApplicationDelegateAdaptor
                    // constructs it first), so it starts with nil closures
                    // and this is the first point those can be filled in.
                    appDelegate.onDeviceToken = { deviceToken in
                        Task { await pushService.didRegister(deviceToken: deviceToken, account: auth.account?.email) }
                    }
                    appDelegate.onRemoteNotification = {
                        // The push itself carries no content, only a
                        // "something changed" signal (see
                        // PushNotificationService's doc comment); this is
                        // what actually fetches and shows the real mail,
                        // on-device, exactly like any other sync.
                        if await sync.syncIfConnected(account: auth.account?.email) {
                            await store.load()
                        }
                    }
                    // Fired first, before any await: pre-creates the whole
                    // pool of reusable WKWebView instances here, off the
                    // interaction path, instead of paying to create one on
                    // the first real tap into a message (see WKWebViewPool).
                    WKWebViewPool.shared.prewarm()
                    // Loaded first and unconditionally (store.load() is a
                    // no-op if CorresShell's own load-if-idle task already
                    // beat it to it): resumeAfterRelaunch below needs
                    // store.threads populated to re-link a resumed reply
                    // draft back to its source thread.
                    await store.load()
                    await auth.restorePreviousSignIn()
                    if await sync.syncIfConnected(account: auth.account?.email) {
                        await store.load()
                    }
                    // Covers relaunching already connected (the connect
                    // button in Preferences handles the first-connection
                    // case itself): sample threads from before that
                    // connection existed have no reason to still be mixed
                    // into real mail.
                    if auth.account != nil {
                        await store.deleteSampleDataIfPresent()
                    }
                    await outbox.resumeAfterRelaunch()
                    await labelDirectory.refreshIfConnected(account: auth.account?.email)
                    if let account = auth.account?.email {
                        await pushService.renewWatch(account: account)
                    }
                }
                .onOpenURL { GIDSignIn.sharedInstance.handle($0) }
        }
    }
}

enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var colorScheme: ColorScheme? {
        switch self { case .system: nil; case .light: .light; case .dark: .dark }
    }
}
