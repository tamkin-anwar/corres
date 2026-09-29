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
                .environment(appDelegate.snippetStore)
                .environment(appDelegate.router)
                .environment(appDelegate.askService)
                .environment(appDelegate.entitlements)
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
                }
                // One place covers every foreground sync path (pull-to-refresh
                // on Brief or a list, connecting an account in Preferences),
                // instead of each view needing its own triage call. Unawaited
                // by the refresh itself, so the pull-to-refresh spinner ends
                // when mail arrives, not when the on-device model finishes.
                .onChange(of: appDelegate.sync.lastCompletedSync) {
                    Task {
                        await appDelegate.store.refresh()
                        await appDelegate.semanticTriageService.triageIfNeeded(store: appDelegate.store)
                    }
                    // Network-bound, independent of the on-device model, so
                    // it runs alongside triage rather than after it.
                    // Then ready summaries for what's likely to be opened
                    // next, once their bodies are here (Corres Pro).
                    Task {
                        await appDelegate.sync.backfillContent()
                        await appDelegate.store.refresh()
                        if appDelegate.entitlements.isPro && CorresSettings.summaries {
                            await appDelegate.mailIntelligence.prewarm(appDelegate.store.threads,
                                                                       includeRead: CorresSettings.summaryInList)
                        }
                    }
                }
                // Each batch of 50 a sync saves shows up as it lands, so the
                // first screenful appears within a round trip, not after the
                // whole first sync finishes.
                .onChange(of: appDelegate.sync.syncProgress) {
                    Task { await appDelegate.store.refresh() }
                }
                .onOpenURL { url in
                    if !appDelegate.router.open(url) { GIDSignIn.sharedInstance.handle(url) }
                }
                // Widgets show what's on the phone; refresh their snapshot
                // whenever the mail it summarizes changes.
                .onChange(of: appDelegate.store.threads) { _, threads in
                    WidgetBridge.update(from: threads)
                }
                .onChange(of: appDelegate.entitlements.isPro) { _, isPro in
                    WidgetBridge.isLocked = !isPro
                    WidgetBridge.update(from: appDelegate.store.threads)
                }
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
    var title: String { rawValue.capitalized }
    var colorScheme: ColorScheme? {
        switch self { case .system: nil; case .light: .light; case .dark: .dark }
    }
}
