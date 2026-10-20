import Foundation

/// The four snooze times offered everywhere, worked out from now.
enum SnoozeOption: CaseIterable {
    case laterToday, tomorrow, thisWeekend, nextWeek

    var title: String {
        switch self {
        case .laterToday: String(localized: "Later Today")
        case .tomorrow: String(localized: "Tomorrow")
        case .thisWeekend: String(localized: "This Weekend")
        case .nextWeek: String(localized: "Next Week")
        }
    }

    func date(from now: Date = .now) -> Date {
        let phrase = switch self {
        case .laterToday: "later today"
        case .tomorrow: "tomorrow"
        case .thisWeekend: "this weekend"
        case .nextWeek: "next week"
        }
        return TimePhrase.parse(phrase, now: now) ?? now.addingTimeInterval(86_400)
    }
}
