import CoreSpotlight
import GoogleSignIn
import SwiftUI
import UIKit

@main
struct CorresApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage("corres.appearance") private var appearance = Appearance.system.rawValue

    init() {
        // Large navigation titles in New York, the same serif as the rest
        // of Corres's display type; inline titles stay SF for legibility.
        let largeTitle = UIFont.preferredFont(forTextStyle: .largeTitle)
        if let serif = largeTitle.fontDescriptor.withDesign(.serif) {
            let font = UIFont(descriptor: serif, size: 0)
            UINavigationBar.appearance().largeTitleTextAttributes = [.font: font]
        }
    }

    var body: some Scene {
        WindowGroup {
            CorresShell(store: appDelegate.store, auth: appDelegate.auth, sync: appDelegate.sync,
                       outbox: appDelegate.outbox, threadActions: appDelegate.threadActions,
                       labelDirectory: appDelegate.labelDirectory, pushService: appDelegate.pushService,
                       unsubscribeService: appDelegate.unsubscribeService)
                .environment(appDelegate.mailIntelligence)
                .environment(appDelegate.router)
                .environment(appDelegate.askService)
                .environment(appDelegate.entitlements)
                .environment(appDelegate.people)
                .preferredColorScheme(Appearance(rawValue: appearance)?.colorScheme)
                // Set on the window itself, so everything already open (the
                // Settings sheet you're changing it from, Compose, Welcome)
                // switches in the same instant instead of after it closes.
                .onAppear { Appearance.apply(appearance) }
                .onChange(of: appearance) { _, value in Appearance.apply(value) }
                .tint(CorresPalette.accent)
                .task {
                    // Everything account/data-dependent already happened in
                    // AppDelegate's own launch task, which runs on every
                    // launch regardless of whether this view ever appears
                    // (see AppDelegate's doc comment). All that's left here
                    // is genuinely foreground-only: pre-creating the pool of
                    // reusable WKWebView instances off the interaction path,
                    // instead of paying to create one on the first real tap
                    // into a message (see WKWebViewPool). Deferred past
                    // launch: creating a web view blocks the main thread,
                    // and doing it as the first screen appeared swallowed
                    // the first tap.
                    try? await Task.sleep(for: .seconds(1.5))
                    await WKWebViewPool.shared.prewarm()
                    // People to suggest, ready before the first Compose.
                    let accounts = appDelegate.auth.accounts.map(\.email)
                    await appDelegate.people.updateInBackground(from: appDelegate.store.threads, accounts: accounts)
                    await appDelegate.people.backfillIfNeeded(accounts: accounts)
                }
                // One place covers every foreground sync path (pull-to-refresh
                // on Brief or a list, connecting an account in Preferences),
                // instead of each view needing its own triage call. Unawaited
                // by the refresh itself, so the pull-to-refresh spinner ends
                // when mail arrives, not when the on-device model finishes.
                // Only when a sync brought or changed something: each of these
                // goes over the whole mailbox, and the 20-second check
                // usually finds nothing.
                .onChange(of: appDelegate.sync.lastChange) {
                    // Mail that just arrived may have a move or snooze
                    // waiting for it from your other devices.
                    Task { await CloudSync.shared.apply() }
                    // Who to suggest in To, Cc and search: synced mail now,
                    // and each account's Sent history once.
                    Task {
                        let accounts = appDelegate.auth.accounts.map(\.email)
                        await appDelegate.people.updateInBackground(from: appDelegate.store.threads, accounts: accounts)
                        await appDelegate.people.backfillIfNeeded(accounts: accounts)
                    }
                    Task {
                        await appDelegate.store.refresh()
                        await appDelegate.semanticTriageService.triageIfNeeded(store: appDelegate.store)
                    }
                }
                .onChange(of: appDelegate.sync.lastCompletedSync) {
                    Task { await FollowUps.shared.check(store: appDelegate.store) }
                    // Network-bound, independent of the on-device model, so
                    // it runs alongside triage rather than after it.
                    // Then ready summaries for what's likely to be opened
                    // next, once their bodies are here (Corres Pro).
                    Task {
                        await appDelegate.sync.backfillContent()
                        await appDelegate.store.refresh()
                        // Then the rest of the mailbox, for Search.
                        let accounts = appDelegate.auth.accounts.map(\.email)
                        if await appDelegate.sync.indexOlderMail(accounts: accounts) { await appDelegate.store.refresh() }
                        await appDelegate.sync.verifyInboxes(accounts: accounts)
                        await appDelegate.store.refresh()
                        if appDelegate.entitlements.isPro && CorresSettings.summaries {
                            await appDelegate.mailIntelligence.prewarm(appDelegate.store.threads, includeRead: false)
                        }
                    }
                }
                // Each batch of 50 a sync saves shows up as it lands, so the
                // first screenful appears within a round trip, not after the
                // whole first sync finishes.
                // At most one reload each half second, though: a first sync
                // saves a hundred batches, and each reload redraws the lists.
                .onChange(of: appDelegate.sync.syncProgress) {
                    SyncBatchRefresh.schedule(appDelegate.store)
                }
                .onOpenURL { url in
                    if !appDelegate.router.open(url) { GIDSignIn.sharedInstance.handle(url) }
                }
                // Handed off from your Mac or another iPhone or iPad.
                .onContinueUserActivity(Handoff.conversation) { activity in
                    if let id = Handoff.threadID(activity) { appDelegate.router.pending = .thread(id) }
                }
                // A conversation picked in Search on the Home Screen.
                .onContinueUserActivity(CSSearchableItemActionType) { activity in
                    if let id = SpotlightIndex.threadID(from: activity) { appDelegate.router.pending = .thread(id) }
                }
                // Widgets show what's on the phone; refresh their snapshot
                // whenever the mail it summarizes changes.
                // Keyed on the store's revision, not its threads: comparing
                // the whole mailbox on every redraw of the root was itself
                // work on each swipe.
                .onChange(of: appDelegate.store.revision) {
                    SpotlightIndex.shared.scheduleUpdate { [store = appDelegate.store] in store.searchableThreads }
                    WidgetBridge.scheduleUpdate { [store = appDelegate.store] in store.threads }
                    LiveActivities.scheduleDeliveries { [store = appDelegate.store] in store.threads }
                    WatchBridge.shared.scheduleUpdate { [store = appDelegate.store] in store.threads }
                }
                // Live Activities can only start while Corres is open.
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                    LiveActivities.syncSendLater(ScheduledSends.shared.items)
                    LiveActivities.syncDeliveries(appDelegate.store.threads)
                    #if DEBUG
                    LiveActivities.demo()
                    #endif
                }
                // Removing the last account forgets who you correspond with.
                .onChange(of: appDelegate.auth.accounts.isEmpty) { _, isEmpty in
                    if isEmpty { appDelegate.people.reset() }
                }
                // Set from launch, not only on a change: a free or lapsed
                // user's widgets, Siri and Brief otherwise never locked. The
                // same rule as the app's own lock (CorresShell.requiresPro).
                .onChange(of: WidgetBridge.locks(connected: !appDelegate.auth.accounts.isEmpty,
                                                 entitlements: appDelegate.entitlements), initial: true) { _, locked in
                    WidgetBridge.isLocked = locked
                    WidgetBridge.update(from: appDelegate.store.threads)
                    WatchBridge.shared.scheduleUpdate { [store = appDelegate.store] in store.threads }
                }
        }
        // iPad: a conversation in a window of its own, beside your mail
        // (press and hold a conversation, then Open in New Window).
        WindowGroup("Conversation", id: ConversationWindow.id, for: ThreadID.self) { $id in
            if let id {
                ConversationWindow(id: id, appDelegate: appDelegate)
                    .preferredColorScheme(Appearance(rawValue: appearance)?.colorScheme)
                    .tint(CorresPalette.accent)
            }
        }
        // iPad's menu bar and ⌘ shortcuts list: where to go. A
        // conversation's own commands (Reply, Archive, Next) come from it.
        .commands {
            CommandMenu("Go") {
                Button("Needs You") { appDelegate.router.pending = .destination(.needsYou) }
                    .keyboardShortcut("1", modifiers: .command)
                Button("Waiting") { appDelegate.router.pending = .destination(.waiting) }
                    .keyboardShortcut("2", modifiers: .command)
                Button("Mail") { appDelegate.router.pending = .destination(.mail) }
                    .keyboardShortcut("3", modifiers: .command)
            }
        }
    }
}

/// Shows each batch a sync saves, at most one reload each half second: the
/// first batch at once, the last one always, the ones between folded
/// together.
@MainActor
private enum SyncBatchRefresh {
    private static var running: Task<Void, Never>?
    private static var again = false

    static func schedule(_ store: MailStore) {
        guard running == nil else { again = true; return }
        running = Task {
            repeat {
                again = false
                await store.refresh()
                try? await Task.sleep(for: .milliseconds(500))
            } while again
            running = nil
        }
    }
}

enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark

    @MainActor static func apply(_ raw: String) {
        let style: UIUserInterfaceStyle = switch Appearance(rawValue: raw) ?? .system {
        case .system: .unspecified
        case .light: .light
        case .dark: .dark
        }
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            for window in scene.windows { window.overrideUserInterfaceStyle = style }
        }
    }
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: String(localized: "System")
        case .light: String(localized: "Light")
        case .dark: String(localized: "Dark")
        }
    }
    var colorScheme: ColorScheme? {
        switch self { case .system: nil; case .light: .light; case .dark: .dark }
    }
}

/// One conversation in its own iPad window, with everything the main
/// window gives a conversation.
struct ConversationWindow: View {
    static let id = "conversation"
    let id: ThreadID
    let appDelegate: AppDelegate

    var body: some View {
        let delegate = appDelegate
        let connected = !delegate.auth.accounts.isEmpty || delegate.store.threads.contains { $0.id.account != "sample" }
        NavigationStack {
            ConversationView(store: delegate.store, outbox: delegate.outbox, threadActions: delegate.threadActions,
                             labelDirectory: delegate.labelDirectory, unsubscribeService: delegate.unsubscribeService,
                             auth: delegate.auth, route: ConversationRoute(id: id, orderedIDs: [id]))
        }
        .environment(delegate.mailIntelligence)
        .environment(delegate.router)
        .environment(delegate.askService)
        .environment(delegate.entitlements)
        .environment(delegate.people)
        .environment(\.proUnlocked, !connected || delegate.entitlements.isProForDisplay)
    }
}
