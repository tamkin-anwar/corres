import GoogleSignIn
import SwiftUI

@main
struct CorresApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage("corres.appearance") private var appearance = Appearance.system.rawValue

    var body: some Scene {
        WindowGroup {
            CorresShell(store: appDelegate.store, auth: appDelegate.auth, sync: appDelegate.sync,
                       outbox: appDelegate.outbox, threadActions: appDelegate.threadActions,
                       labelDirectory: appDelegate.labelDirectory, pushService: appDelegate.pushService,
                       unsubscribeService: appDelegate.unsubscribeService)
                .preferredColorScheme(Appearance(rawValue: appearance)?.colorScheme)
                .tint(CorresPalette.accent)
                .task {
                    // Everything account/data-dependent already happened in
                    // AppDelegate's own launch task, which runs on every
                    // launch regardless of whether this view ever appears
                    // (see AppDelegate's doc comment). All that's left here
                    // is genuinely foreground-only: pre-creating the pool of
                    // reusable WKWebView instances off the interaction path,
                    // instead of paying to create one on the first real tap
                    // into a message (see WKWebViewPool).
                    WKWebViewPool.shared.prewarm()
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
                    Task { await appDelegate.sync.backfillContent() }
                }
                // Each batch of 50 a sync saves shows up as it lands, so the
                // first screenful appears within a round trip, not after the
                // whole first sync finishes.
                .onChange(of: appDelegate.sync.syncProgress) {
                    Task { await appDelegate.store.refresh() }
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
