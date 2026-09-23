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
                       labelDirectory: appDelegate.labelDirectory, pushService: appDelegate.pushService)
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
