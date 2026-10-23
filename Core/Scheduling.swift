import Foundation

/// "When are you free?": an email asking to find a time, and the times
/// your calendar has open, offered in a reply you can change before
/// sending. Superhuman's and Gmail's "share availability", done on this
/// device from your own calendar.
public enum Scheduling {
    /// Whether the email asks you for a time to meet or talk.
    public static func asksForTime(_ text: String) -> Bool {
        // The opening is where an ask is, not the quoted history below; and
        // this is checked each time a reading view is drawn.
        String(text.prefix(4_000)).patternRange(askPattern, caseInsensitive: true) != nil
    }

    /// One pattern, compiled once (`PatternCache`).
    private static let askPattern: String = {
        let patterns = [
            #"when (are|would) you (be )?(free|available)"#,
            #"(what|which) (time|day|times|days)s? (would |might )?(work|suit|suits|works) (for|best for) you"#,
            #"when (works|would work|suits) (for )?you"#,
            #"are you (free|available) (on|this|next|for|to|at|tomorrow)"#,
            #"(find|grab|set up|schedule|book) (a )?(time|call|meeting|chat|slot)"#,
            #"your availability"#,
            #"(free|available) (to|for) (a )?(chat|call|meet|talk|catch up|coffee)"#,
            #"let me know (when|what time) (you're|you are) (free|available)"#,
        ]
        return patterns.map { "(?:\($0))" }.joined(separator: "|")
    }()

    public struct Slot: Equatable, Sendable {
        public let start: Date
        public let end: Date
    }

    /// Up to `count` open times of `length`, one per weekday, from the next
    /// working hour on: between `dayStart` and `dayEnd`, never on a
    /// weekend, never overlapping anything busy, and at least an hour
    /// from now.
    public static func freeSlots(busy: [(start: Date, end: Date)], from now: Date, days: Int = 7,
                                 dayStart: Int = 9, dayEnd: Int = 17, length: TimeInterval = 30 * 60,
                                 count: Int = 3, calendar: Calendar = .current) -> [Slot] {
        var result: [Slot] = []
        let earliest = roundedUpToHalfHour(now.addingTimeInterval(3600), calendar: calendar)
        for offset in 0..<days where result.count < count {
            guard let day = calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: now)),
                  !calendar.isDateInWeekend(day),
                  let open = calendar.date(bySettingHour: dayStart, minute: 0, second: 0, of: day),
                  let close = calendar.date(bySettingHour: dayEnd, minute: 0, second: 0, of: day) else { continue }
            var start = max(open, earliest)
            while start.addingTimeInterval(length) <= close {
                let end = start.addingTimeInterval(length)
                if !busy.contains(where: { $0.start < end && $0.end > start }) {
                    result.append(Slot(start: start, end: end))
                    break
                }
                start = start.addingTimeInterval(30 * 60)
            }
        }
        return result
    }

    /// 10:05 becomes 10:30; 10:30 stays.
    static func roundedUpToHalfHour(_ date: Date, calendar: Calendar) -> Date {
        let parts = calendar.dateComponents([.minute, .second], from: date)
        let minute = parts.minute ?? 0, second = parts.second ?? 0
        if second == 0 && (minute == 0 || minute == 30) { return date }
        let toNext = (minute < 30 ? 30 - minute : 60 - minute) * 60 - second
        return date.addingTimeInterval(TimeInterval(toNext))
    }
}
