import Foundation

/// Turns what a person types into a snooze field ("in 3 days at 9am",
/// "tomorrow evening", "next friday", "tonight") into a concrete future
/// date. The common relative phrasings are parsed here directly, because
/// `NSDataDetector` doesn't understand "in 3 days" or "this weekend";
/// anything else falls through to `NSDataDetector` ("Oct 2 at 6:40").
/// Returns nil unless the result is in the future.
public enum TimePhrase {
    /// Default hour when a day is named without a time: early enough to be
    /// the first thing seen, the same default Gmail and Apple Mail use.
    public nonisolated(unsafe) static var morningHour = 8
    /// "Later today": three hours from now, or this evening at six.
    public nonisolated(unsafe) static var laterTodayIsEvening = false

    public static func parse(_ input: String, now: Date = .now, calendar: Calendar = .current) -> Date? {
        let text = input.lowercased()
            .replacingOccurrences(of: ",", with: " ")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !text.isEmpty else { return nil }
        let result = parseRelative(text, now: now, calendar: calendar) ?? detect(text, now: now)
        guard let result, result > now else { return nil }
        return result
    }

    // MARK: - Relative phrases

    private static let units: [(names: [String], component: Calendar.Component)] = [
        (["minute", "minutes", "min", "mins"], .minute),
        (["hour", "hours", "hr", "hrs", "h"], .hour),
        (["day", "days", "d"], .day),
        (["week", "weeks", "wk", "wks", "w"], .weekOfYear),
        (["month", "months"], .month),
    ]
    private static let numberWords = ["a": 1, "an": 1, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5,
                                      "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10, "couple": 2, "few": 3]
    private static let weekdays = ["sunday": 1, "sun": 1, "monday": 2, "mon": 2, "tuesday": 3, "tue": 3, "tues": 3,
                                   "wednesday": 4, "wed": 4, "thursday": 5, "thu": 5, "thurs": 5,
                                   "friday": 6, "fri": 6, "saturday": 7, "sat": 7]

    private static func parseRelative(_ text: String, now: Date, calendar: Calendar) -> Date? {
        var words = text.split(separator: " ").map(String.init)
        if words.first == "in" { words.removeFirst() }
        let (dayWords, time) = splitTime(words)

        // "in 3 days", "2 hours", "a couple of weeks"
        var amountWords = dayWords
        if amountWords.count > 1, ["a", "an"].contains(amountWords[0]), ["couple", "few"].contains(amountWords[1]) {
            amountWords.removeFirst()
        }
        if let first = amountWords.first {
            let amount = Int(first) ?? numberWords[first]
            var rest = Array(amountWords.dropFirst())
            if rest.first == "of" { rest.removeFirst() }
            if let amount, let unitWord = rest.first, rest.count == 1,
               let unit = units.first(where: { $0.names.contains(unitWord) })?.component,
               let shifted = calendar.date(byAdding: unit, value: amount, to: now) {
                if let time { return at(time, on: shifted, calendar: calendar) }
                // Whole days land at the morning hour; shorter spans stay exact.
                return unit == .minute || unit == .hour ? shifted : at((morningHour, 0), on: shifted, calendar: calendar)
            }
        }

        let phrase = dayWords.joined(separator: " ")
        let today = calendar.startOfDay(for: now)
        switch phrase {
        case "", "today":
            guard let time else { return nil }
            let candidate = at(time, on: today, calendar: calendar)
            // "9am" typed at 10am means tomorrow's 9am.
            return candidate.flatMap { $0 > now ? $0 : calendar.date(byAdding: .day, value: 1, to: $0) }
        case "tonight":
            return at(time ?? (20, 0), on: today, calendar: calendar)
        case "later", "later today":
            if laterTodayIsEvening, let evening = at((18, 0), on: today, calendar: calendar), evening > now.addingTimeInterval(1_800) {
                return evening
            }
            return calendar.date(byAdding: .hour, value: 3, to: now)
        case "tomorrow", "tmrw", "tmr":
            return at(time ?? (morningHour, 0), on: calendar.date(byAdding: .day, value: 1, to: today)!, calendar: calendar)
        case "this weekend", "weekend", "the weekend":
            return at(time ?? (morningHour + 1, 0), on: next(weekday: 7, after: today, calendar: calendar, allowToday: true), calendar: calendar)
        case "next week":
            // On a Sunday the coming Monday is tomorrow, which "Tomorrow"
            // already covers; next week then means the Monday after.
            var monday = next(weekday: 2, after: today, calendar: calendar, allowToday: false)
            if calendar.dateComponents([.day], from: today, to: monday).day ?? 7 <= 1 {
                monday = calendar.date(byAdding: .day, value: 7, to: monday) ?? monday
            }
            return at(time ?? (morningHour, 0), on: monday, calendar: calendar)
        case "next month":
            guard let date = calendar.date(byAdding: .month, value: 1, to: today),
                  let first = calendar.date(from: calendar.dateComponents([.year, .month], from: date)) else { return nil }
            return at(time ?? (morningHour, 0), on: first, calendar: calendar)
        default:
            break
        }

        // "friday", "next friday", "on friday", "this friday"
        var dayPhrase = dayWords
        if ["on", "this", "next"].contains(dayPhrase.first) { dayPhrase.removeFirst() }
        if dayPhrase.count == 1, let weekday = weekdays[dayPhrase[0]] {
            let day = next(weekday: weekday, after: today, calendar: calendar, allowToday: false)
            return at(time ?? (morningHour, 0), on: day, calendar: calendar)
        }
        return nil
    }

    /// Pulls a trailing time off the words: "at 9", "9am", "9:30 pm",
    /// "17:00", "noon", "morning", "evening".
    private static func splitTime(_ words: [String]) -> ([String], (Int, Int)?) {
        var words = words
        var time: (Int, Int)?
        let named: [String: (Int, Int)] = ["morning": (morningHour, 0), "noon": (12, 0), "midday": (12, 0),
                                           "afternoon": (14, 0), "evening": (18, 0), "night": (20, 0)]
        if let last = words.last, let value = named[last] {
            words.removeLast()
            if words.last == "the" { words.removeLast() }
            if words.last == "in" || words.last == "at" { words.removeLast() }
            return (words, value)
        }
        var meridiem: String?
        if let last = words.last, last == "am" || last == "pm" {
            meridiem = last
            words.removeLast()
        }
        if let last = words.last, let parsed = clock(last, meridiem: meridiem) {
            // A bare number is only a time when "at" precedes it or it
            // carries am/pm or a colon; "in 3" is an amount, not 3 o'clock.
            let hasMarker = meridiem != nil || last.contains(":") || last.hasSuffix("am") || last.hasSuffix("pm")
            if hasMarker || words.dropLast().last == "at" {
                words.removeLast()
                if words.last == "at" { words.removeLast() }
                time = parsed
            }
        } else if let meridiem {
            words.append(meridiem)
        }
        return (words, time)
    }

    private static func clock(_ token: String, meridiem: String?) -> (Int, Int)? {
        var token = token
        var meridiem = meridiem
        for suffix in ["am", "pm", "a", "p"] where token.hasSuffix(suffix) && token.count > suffix.count {
            let prefix = token.dropLast(suffix.count)
            if prefix.last?.isNumber == true {
                meridiem = suffix.hasPrefix("a") ? "am" : "pm"
                token = String(prefix)
                break
            }
        }
        let parts = token.split(separator: ":")
        guard (1...2).contains(parts.count), var hour = Int(parts[0]) else { return nil }
        let minute = parts.count == 2 ? Int(parts[1]) : 0
        guard let minute, (0..<60).contains(minute) else { return nil }
        switch meridiem {
        case "am": guard (1...12).contains(hour) else { return nil }; if hour == 12 { hour = 0 }
        case "pm": guard (1...12).contains(hour) else { return nil }; if hour != 12 { hour += 12 }
        default: guard (0...23).contains(hour) else { return nil }
        }
        return (hour, minute)
    }

    private static func at(_ time: (Int, Int), on day: Date, calendar: Calendar) -> Date? {
        calendar.date(bySettingHour: time.0, minute: time.1, second: 0, of: day)
    }

    private static func next(weekday: Int, after day: Date, calendar: Calendar, allowToday: Bool) -> Date {
        let current = calendar.component(.weekday, from: day)
        var delta = (weekday - current + 7) % 7
        if delta == 0 && !allowToday { delta = 7 }
        return calendar.date(byAdding: .day, value: delta, to: day) ?? day
    }

    // MARK: - Fallback

    private static func detect(_ text: String, now: Date) -> Date? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        return detector.firstMatch(in: text, options: [], range: range)?.date
    }
}
