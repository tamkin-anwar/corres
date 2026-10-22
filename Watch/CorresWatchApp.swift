import SwiftUI

/// Corres on Apple Watch: what needs you, read on your wrist, and answered
/// there: Handled, Archive, or a reply you say or write.
@main
struct CorresWatchApp: App {
    init() { WatchMailStore.shared.start() }

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                MailListView(store: WatchMailStore.shared)
            }
            .tint(WatchPalette.accent)
        }
    }
}

enum WatchPalette {
    static let accent = Color(red: 0x8F / 255, green: 0xB4 / 255, blue: 0xE8 / 255)
}
