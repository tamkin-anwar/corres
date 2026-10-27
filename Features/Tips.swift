import SwiftUI
import TipKit

/// A few things in Corres you'd only find by looking: shown once each, a
/// while after you've started using it, never on the first launch.
struct UnreadOnlyTip: Tip {
    /// Conversations opened; the tip waits until you've read a few.
    static let opened = Tips.Event(id: "conversationOpened")

    var title: Text { Text("Unread Only") }
    var message: Text? { Text("Tap here to see only unread mail in this list. Tap again to see it all.") }
    var image: Image? { Image(systemName: "line.3.horizontal.decrease.circle") }
    var rules: [Rule] { #Rule(Self.opened) { $0.donations.count >= 5 } }
}

/// The Daily Brief is off until turned on, and almost nobody changes a
/// default: on Needs You, once you've used Corres on three different days,
/// one offer to show it. Shown once; Not Now puts it away for good.
struct DailyBriefTip: Tip {
    /// Donated at most once a calendar day (`noteDayOpened`).
    static let dayOpened = Tips.Event(id: "dayOpened")
    static let showAction = "showBrief"
    static let notNowAction = "notNow"
    private static let lastDayKey = "corres.tips.lastDayOpened"

    var title: Text { Text("Daily Brief") }
    var message: Text? {
        Text("See what's due, today's meetings and deliveries at the top of Needs You. You can change this in Settings.")
    }
    var image: Image? { Image(systemName: "sun.max") }
    var rules: [Rule] { #Rule(Self.dayOpened) { $0.donations.count >= 3 } }
    var options: [any TipOption] { [MaxDisplayCount(1)] }
    var actions: [Action] {
        [Action(id: Self.showAction, title: String(localized: "Show Daily Brief")),
         Action(id: Self.notNowAction, title: String(localized: "Not Now"))]
    }

    /// Counts the day Corres is opened, once per day in this time zone.
    @MainActor static func noteDayOpened() async {
        let today = CorresSettings.briefDay()
        guard UserDefaults.standard.string(forKey: lastDayKey) != today else { return }
        UserDefaults.standard.set(today, forKey: lastDayKey)
        await dayOpened.donate()
    }
}

enum CorresTips {
    /// At launch. Screenshots and sample-mail runs never show tips.
    static func start() {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-CorresScreenshots") || arguments.contains("-SampleMailOnly") {
            Tips.hideAllTipsForTesting()
        }
        try? Tips.configure([.displayFrequency(.daily)])
        Task { await DailyBriefTip.noteDayOpened() }
    }
}
