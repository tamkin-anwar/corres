import SwiftUI
import TipKit

/// A few things in Corres you'd only find by looking: shown once each, a
/// while after you've started using it, never on the first launch.
struct UnreadOnlyTip: Tip {
    /// Conversations opened; the tip waits until you've read a few.
    static let opened = Tips.Event(id: "conversationOpened")

    var title: Text { Text("Just What's Unread") }
    var message: Text? { Text("Tap here to see only unread mail in this list. Tap again to see it all.") }
    var image: Image? { Image(systemName: "line.3.horizontal.decrease.circle") }
    var rules: [Rule] { #Rule(Self.opened) { $0.donations.count >= 5 } }
}

enum CorresTips {
    /// At launch. Screenshots and sample-mail runs never show tips.
    static func start() {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-CorresScreenshots") || arguments.contains("-SampleMailOnly") {
            Tips.hideAllTipsForTesting()
        }
        try? Tips.configure([.displayFrequency(.daily)])
    }
}
