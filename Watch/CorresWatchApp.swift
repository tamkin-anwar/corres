import SwiftUI

/// Corres on Apple Watch: what needs you, read on your wrist, and answered
/// there: Handled, Archive, or a reply you say or write.
@main
struct CorresWatchApp: App {
    init() { WatchMailStore.shared.start() }

    #if DEBUG
    /// Screenshots: `-WatchScreen` opens the first email straight away.
    @State private var path: [WatchLink.Mail] = WatchMailStore.screenshotScreen == nil
        ? [] : Array(WatchMailStore.shared.needsYou.prefix(1))
    #endif

    var body: some Scene {
        WindowGroup {
            #if DEBUG
            NavigationStack(path: $path) {
                MailListView(store: WatchMailStore.shared)
            }
            .tint(WatchPalette.accent)
            #else
            NavigationStack {
                MailListView(store: WatchMailStore.shared)
            }
            .tint(WatchPalette.accent)
            #endif
        }
    }
}

enum WatchPalette {
    static let accent = Color(red: 0x8F / 255, green: 0xB4 / 255, blue: 0xE8 / 255)
}
