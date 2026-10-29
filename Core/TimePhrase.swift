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
    public static var morningHour: Int {
        get { morningHourStore.value }
        set { morningHourStore.set(newValue) }
    }
    /// "Later today": three hours from now, or this evening at six.
    public static var laterTodayIsEvening: Bool {
        get { laterTodayStore.value }
        set { laterTodayStore.set(newValue) }
    }
    // Set on the main thread, read wherever a time is worked out.
    private static let morningHourStore = LockedValue(8)
    private static let laterTodayStore = LockedValue(false)

    /// `languages`: the reader's, most preferred first. A lone "9h" is
    /// nine o'clock to a French reader, as French writes the time, and
    /// nine hours to anyone else ("2h" in Superhuman and Spark).
    public static func parse(_ input: String, now: Date = .now, calendar: Calendar = .current,
                             languages: [String] = Locale.preferredLanguages) -> Date? {
        let french = languages.first.map { Locale(identifier: $0).language.languageCode == .french } ?? false
        let text = Words.english(input, frenchReader: french)
        guard !text.isEmpty else { return nil }
        let result = parseRelative(text, now: now, calendar: calendar) ?? detect(text, now: now)
        guard let result, result > now else { return nil }
        return result
    }

    // MARK: - Relative phrases

    private static let units: [(names: [String], component: Calendar.Component)] = [
        (["minute", "minutes", "min", "mins", "m"], .minute),
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
        // "2h", "30m", "3d": the amount and its unit written together.
        if amountWords.count == 1, let word = amountWords.first, word.first?.isNumber == true,
           let letter = word.firstIndex(where: { !$0.isNumber }) {
            amountWords = [String(word[..<letter]), String(word[letter...])]
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
        // "This evening", "this afternoon": today, at that time.
        case "", "today", "this":
            guard let time else { return nil }
            let candidate = at(time, on: today, calendar: calendar)
            // "This evening" said after it's begun is not tomorrow's.
            if phrase == "this" { return candidate }
            // "9am" typed at 10am means tomorrow's 9am.
            return candidate.flatMap { $0 > now ? $0 : calendar.date(byAdding: .day, value: 1, to: $0) }
        case "tonight":
            // "Tonight at 9" is nine in the evening; "tonight at 12" is
            // midnight.
            let evening = time.map { $0.0 < 12 ? ($0.0 + 12, $0.1) : $0.0 == 12 ? (24, $0.1) : $0 }
            return at(evening ?? (20, 0), on: today, calendar: calendar)
        case "later", "later today":
            if laterTodayIsEvening, let evening = at((18, 0), on: today, calendar: calendar), evening > now.addingTimeInterval(1_800) {
                return evening
            }
            return calendar.date(byAdding: .hour, value: 3, to: now)
        case "tomorrow", "tmrw", "tmr":
            return at(time ?? (morningHour, 0), on: calendar.date(byAdding: .day, value: 1, to: today)!, calendar: calendar)
        case "this weekend", "weekend", "the weekend":
            return at(time ?? (morningHour + 1, 0), on: weekendStart(onOrAfter: today, calendar: calendar), calendar: calendar)
        case "next week":
            return at(time ?? (morningHour, 0), on: nextWorkWeekStart(after: today, calendar: calendar), calendar: calendar)
        case "next month":
            guard let date = calendar.date(byAdding: .month, value: 1, to: today),
                  let first = calendar.date(from: calendar.dateComponents([.year, .month], from: date)) else { return nil }
            return at(time ?? (morningHour, 0), on: first, calendar: calendar)
        default:
            break
        }

        // "金曜" in "来週の金曜", "下周五", "다음 주 금요일": that day in
        // the week after this one, not the coming one.
        if dayWords.count == 2, dayWords[0] == "nextweek", let weekday = weekdays[dayWords[1]],
           let following = calendar.dateInterval(of: .weekOfYear, for: today)?.end {
            let start = calendar.startOfDay(for: following)
            return at(time ?? (morningHour, 0), on: next(weekday: weekday, after: start, calendar: calendar, allowToday: true), calendar: calendar)
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
    /// "17:00", "noon", "morning", "evening". Midnight is hour 24, the end
    /// of the day it's said with.
    private static func splitTime(_ words: [String]) -> ([String], (Int, Int)?) {
        var words = words
        var time: (Int, Int)?
        let named: [String: (Int, Int)] = ["morning": (morningHour, 0), "noon": (12, 0), "midday": (12, 0),
                                           "afternoon": (14, 0), "evening": (18, 0), "night": (20, 0), "midnight": (24, 0)]
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
            // A bare number is only a time when "at" or a day ("tomorrow
            // 9") precedes it or it carries am/pm or a colon; "in 3" is an
            // amount, not 3 o'clock.
            let hasMarker = meridiem != nil || last.contains(":") || last.hasSuffix("am") || last.hasSuffix("pm")
            let before = words.dropLast().last ?? ""
            if hasMarker || before == "at" || dayNames.contains(before) || weekdays[before] != nil {
                words.removeLast()
                if words.last == "at" { words.removeLast() }
                time = parsed
            }
        } else if let meridiem {
            words.append(meridiem)
        }
        return (words, time)
    }

    /// Days a bare hour can follow without "at": "tomorrow 9", "friday 2".
    private static let dayNames: Set<String> = ["today", "tomorrow", "tmrw", "tmr", "tonight"]

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
        // "午前0時" says am and a 24-hour time, as Japanese writes midnight.
        case "am": guard (0...12).contains(hour) else { return nil }; if hour == 12 { hour = 0 }
        // "午後21時" says pm and a 24-hour time; both mean the same.
        case "pm": guard (1...23).contains(hour) else { return nil }; if hour < 12 { hour += 12 }
        default:
            guard (0...24).contains(hour) else { return nil }
            // A bare hour reads as calendars read it (Google Calendar,
            // Fantastical, Apple Reminders): 1 to 6 is the afternoon, 7 to
            // 11 the morning, 12 noon. A leading zero ("05:00") is a
            // 24-hour time and stays as written.
            if (1...6).contains(hour), !token.hasPrefix("0") { hour += 12 }
        }
        return (hour, minute)
    }

    private static func at(_ time: (Int, Int), on day: Date, calendar: Calendar) -> Date? {
        // "Tomorrow at midnight" is when tomorrow ends.
        if time.0 == 24, let next = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: day)) {
            return calendar.date(bySettingHour: 0, minute: time.1, second: 0, of: next)
        }
        return calendar.date(bySettingHour: time.0, minute: time.1, second: 0, of: day)
    }

    // MARK: - Weekends

    /// The first day of the weekend: today when the weekend starts today,
    /// otherwise the next one. Weekends follow the region's calendar:
    /// Saturday and Sunday in most places, Friday and Saturday in
    /// Bangladesh and much of the Middle East, Sunday alone in India.
    public static func weekendStart(onOrAfter day: Date, calendar: Calendar = .current) -> Date {
        let today = calendar.startOfDay(for: day)
        if calendar.isDateInWeekend(today), let current = calendar.dateIntervalOfWeekend(containing: today),
           calendar.isDate(current.start, inSameDayAs: today) {
            return today
        }
        if let coming = calendar.nextWeekend(startingAfter: today) { return calendar.startOfDay(for: coming.start) }
        return next(weekday: 7, after: today, calendar: calendar, allowToday: true)
    }

    /// The first working day after the weekend (Monday in most places,
    /// Sunday in Bangladesh), never today or tomorrow: on the weekend's
    /// last day the coming working day is tomorrow, which "Tomorrow"
    /// already covers, so next week means the one after.
    public static func nextWorkWeekStart(after day: Date, calendar: Calendar = .current) -> Date {
        let today = calendar.startOfDay(for: day)
        func end(_ weekend: DateInterval?) -> Date? { weekend.map { calendar.startOfDay(for: $0.end) } }
        let weekend = calendar.isDateInWeekend(today) ? calendar.dateIntervalOfWeekend(containing: today)
            : calendar.nextWeekend(startingAfter: today)
        if var start = end(weekend) {
            if calendar.dateComponents([.day], from: today, to: start).day ?? 7 <= 1,
               let later = end(calendar.nextWeekend(startingAfter: start)) {
                start = later
            }
            return start
        }
        var monday = next(weekday: 2, after: today, calendar: calendar, allowToday: false)
        if calendar.dateComponents([.day], from: today, to: monday).day ?? 7 <= 1 {
            monday = calendar.date(byAdding: .day, value: 7, to: monday) ?? monday
        }
        return monday
    }

    /// For Send Later: the first working day after the weekend, offered
    /// from the last working day before it (Friday in most places,
    /// Thursday in Bangladesh) until the weekend is over. Nil on other
    /// days, and when that day is tomorrow.
    public static func workWeekStartForSendLater(now: Date, calendar: Calendar = .current) -> Date? {
        let today = calendar.startOfDay(for: now)
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) else { return nil }
        let inWeekend = calendar.isDateInWeekend(today)
        guard inWeekend || calendar.isDateInWeekend(tomorrow),
              let weekend = calendar.dateIntervalOfWeekend(containing: inWeekend ? today : tomorrow) else { return nil }
        let start = calendar.startOfDay(for: weekend.end)
        return start > tomorrow ? start : nil
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

// MARK: - Other languages

extension TimePhrase {
    /// What people type in Japanese, Korean, Chinese, Bengali, German,
    /// French, Spanish and Portuguese, rewritten into the English phrases
    /// above: "明日の夜" is "tomorrow night", "3일 후 오전 9시" is "in 3 days
    /// at 9:00 am", "en 3 días a las 9" is "in 3 days at 9". Every table
    /// is tried on every phrase, so it works whatever language the phone
    /// is set to, and English passes through untouched. Digits in any
    /// script count ("৩", "３"), and small Chinese numbers do too ("三天后").
    enum Words {
        /// `frenchReader`: a lone "9h" (or "9 h") is nine o'clock, as French
        /// writes the time; "dans 2h" and "pendant 2h" stay spans.
        static func english(_ input: String, frenchReader: Bool = false) -> String {
            var text = asciiDigits(input.precomposedStringWithCanonicalMapping.lowercased())
                .replacingOccurrences(of: "\u{2019}", with: "'")
            for separator in ["、", "，", "。", "；", ",", ";"] {
                text = text.replacingOccurrences(of: separator, with: " ")
            }
            if frenchReader { text = text.replacingPattern(#"^\s*(\d{1,2}) ?h\s*$"#, with: "at $1:00") }
            for (index, rule) in rules.enumerated() {
                if index == hanNumberStep { text = hanNumbers(text) }
                let range = NSRange(text.startIndex..., in: text)
                text = rule.regex.stringByReplacingMatches(in: text, range: range, withTemplate: rule.template)
            }
            return text.split(whereSeparator: \.isWhitespace).map(String.init)
                .filter { !particles.contains($0) }
                .joined(separator: " ")
        }

        /// Little words left between the translated ones ("明日の夜").
        private static let particles: Set<String> = ["の", "に", "で", "は", "頃", "ごろ", "まで", "くらい", "ぐらい",
                                                     "에", "쯤", "까지", "的", "在", "到", "el", "la", "le", "der", "die", "den"]

        private static func asciiDigits(_ text: String) -> String {
            var result = String.UnicodeScalarView()
            for scalar in text.unicodeScalars {
                if !scalar.isASCII, scalar.properties.numericType == .decimal,
                   let value = scalar.properties.numericValue, let digit = Unicode.Scalar(48 + UInt32(value)) {
                    result.append(digit)
                } else {
                    result.append(scalar)
                }
            }
            return String(result)
        }

        /// "三" in "三天后", "十二" in "十二点": one to ninety-nine, only
        /// right before a unit of time, so "星期一" (Monday) stays a day.
        private static func hanNumbers(_ text: String) -> String {
            let digits: [Character: Int] = ["一": 1, "二": 2, "两": 2, "兩": 2, "三": 3, "四": 4, "五": 5,
                                            "六": 6, "七": 7, "八": 8, "九": 9]
            var result = text
            for match in hanNumber.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
                guard let range = Range(match.range, in: result) else { continue }
                let word = Array(result[range])
                var value = 0
                if let ten = word.firstIndex(of: "十") {
                    let tens = ten == 0 ? 1 : digits[word[0]] ?? 0
                    let ones = ten + 1 < word.count ? digits[word[ten + 1]] ?? 0 : 0
                    value = tens * 10 + ones
                } else if word.count == 1 {
                    value = digits[word[0]] ?? 0
                }
                if value > 0 { result.replaceSubrange(range, with: String(value)) }
            }
            return result
        }

        private static let hanNumber = try! NSRegularExpression(
            pattern: #"(?<![期拜周週])([一二两兩三四五六七八九十]{1,3})(?=\s*[天日个個小时時分周週星礼禮月点點钟鐘])"#)

        private struct Rule {
            let regex: NSRegularExpression
            let template: String
        }

        private static func rule(_ pattern: String, _ template: String) -> Rule {
            Rule(regex: try! NSRegularExpression(pattern: pattern.precomposedStringWithCanonicalMapping, options: [.caseInsensitive]),
                 template: " " + template + " ")
        }

        private static let english = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]

        /// Each weekday's names, Sunday first, as a pattern per language.
        private static func weekdayRules(_ names: [String], next: [String] = [], nextWeek: [String] = [],
                                         this: [String] = [], before: String = "", after: String = "") -> [Rule] {
            var rules: [Rule] = []
            for (index, name) in names.enumerated() {
                for prefix in nextWeek { rules.append(rule(prefix + "(?:" + name + ")" + after, "nextweek \(english[index])")) }
                for form in next {
                    rules.append(rule(form.replacingOccurrences(of: "DAY", with: "(?:" + name + ")" + after), "next \(english[index])"))
                }
                for prefix in this { rules.append(rule(prefix + "(?:" + name + ")" + after, "this \(english[index])")) }
                rules.append(rule(before + "(?:" + name + ")" + after, english[index]))
            }
            return rules
        }

        /// Where small Chinese numbers become digits: after the weekdays
        /// ("星期一") are read, before the amounts ("三天后").
        private static var hanNumberStep: Int { weekdayStep }
        private static let weekdayStep = weekdays.count

        // Japanese and Chinese weekdays, read before anything else.
        private static let weekdays: [Rule] =
            weekdayRules(["日", "月", "火", "水", "木", "金", "土"], nextWeek: [#"来週の?\s*"#], this: [#"今週の?\s*"#], after: #"曜日?"#)
            + weekdayRules(["日|天", "一", "二", "三", "四", "五", "六"],
                           nextWeek: [#"下\s*(?:个|個)?\s*(?:周|週|星期|礼拜|禮拜)"#],
                           this: [#"(?:这|這|本)\s*(?:个|個)?\s*(?:周|週|星期|礼拜|禮拜)"#], before: #"(?:周|週|星期|礼拜|禮拜)"#)

        private static let rules: [Rule] = weekdays + japanese + korean + chinese + bengali + german + french + spanish + portuguese + clocks

        private static let japanese: [Rule] = [
            rule(#"(\d+)\s*分後"#, "in $1 minutes"), rule(#"(\d+)\s*時間後"#, "in $1 hours"),
            rule(#"(\d+)\s*日後"#, "in $1 days"), rule(#"(\d+)\s*週間後"#, "in $1 weeks"),
            rule(#"(\d+)\s*(?:か|ヶ|カ|ケ|箇)月後"#, "in $1 months"),
            rule(#"(?:午後|(?<!今)夜|夕方|(?<!今)晩)\s*(\d{1,2})\s*時半"#, "at $1:30 pm"),
            rule(#"(?:午後|(?<!今)夜|夕方|(?<!今)晩)\s*(\d{1,2})\s*時\s*(\d{1,2})\s*分"#, "at $1:$2 pm"),
            rule(#"(?:午後|(?<!今)夜|夕方|(?<!今)晩)\s*(\d{1,2})\s*時"#, "at $1:00 pm"),
            rule(#"(?:午前|朝)\s*(\d{1,2})\s*時半"#, "at $1:30 am"),
            rule(#"(?:午前|朝)\s*(\d{1,2})\s*時\s*(\d{1,2})\s*分"#, "at $1:$2 am"),
            rule(#"(?:午前|朝)\s*(\d{1,2})\s*時"#, "at $1:00 am"),
            rule(#"(\d{1,2})\s*時半"#, "at $1:30"), rule(#"(\d{1,2})\s*時\s*(\d{1,2})\s*分"#, "at $1:$2"),
            rule(#"(\d{1,2})\s*時"#, "at $1:00"),
            rule("明後日|あさって", "in 2 days"), rule("明日|あした|あす", "tomorrow"), rule("今日|きょう", "today"),
            rule("今夜|今晩", "tonight"), rule("来週", "next week"), rule("今週末|週末", "this weekend"),
            rule("来月", "next month"), rule("あとで|後で", "later"), rule("正午|昼", "noon"), rule("午後", "afternoon"),
            rule("夕方", "evening"), rule("朝", "morning"), rule("夜|晩", "night"),
        ]

        private static let korean: [Rule] = [
            rule(#"(\d+)\s*분\s*(?:후|뒤)"#, "in $1 minutes"), rule(#"(\d+)\s*시간\s*(?:후|뒤)"#, "in $1 hours"),
            rule(#"(\d+)\s*일\s*(?:후|뒤)"#, "in $1 days"), rule(#"(\d+)\s*주\s*(?:후|뒤)"#, "in $1 weeks"),
            rule(#"(\d+)\s*(?:개월|달)\s*(?:후|뒤)"#, "in $1 months"),
        ] + weekdayRules(["일", "월", "화", "수", "목", "금", "토"], nextWeek: [#"다음\s*주\s*"#], this: [#"이번\s*주\s*"#], after: "요일") + [
            // 12 at night is midnight ("밤 12시", "자정"); 12 by day stays
            // noon ("낮 12시", "오후 12시", "정오").
            rule(#"밤\s*12\s*시\s*반"#, "at 24:30"), rule(#"밤\s*12\s*시\s*(\d{1,2})\s*분"#, "at 24:$1"),
            rule(#"밤\s*12\s*시(?!간)"#, "midnight"), rule("자정", "midnight"),
            rule(#"낮\s*(12|[1-6])\s*시(?!간)"#, "at $1:00 pm"),
            rule(#"(?:오후|저녁|밤)\s*(\d{1,2})\s*시\s*반"#, "at $1:30 pm"),
            rule(#"(?:오후|저녁|밤)\s*(\d{1,2})\s*시\s*(\d{1,2})\s*분"#, "at $1:$2 pm"),
            rule(#"(?:오후|저녁|밤)\s*(\d{1,2})\s*시(?!간)"#, "at $1:00 pm"),
            rule(#"(?:오전|아침|새벽)\s*(\d{1,2})\s*시\s*반"#, "at $1:30 am"),
            rule(#"(?:오전|아침|새벽)\s*(\d{1,2})\s*시\s*(\d{1,2})\s*분"#, "at $1:$2 am"),
            rule(#"(?:오전|아침|새벽)\s*(\d{1,2})\s*시(?!간)"#, "at $1:00 am"),
            rule(#"(\d{1,2})\s*시\s*반"#, "at $1:30"), rule(#"(\d{1,2})\s*시\s*(\d{1,2})\s*분"#, "at $1:$2"),
            rule(#"(\d{1,2})\s*시(?!간)"#, "at $1:00"),
            rule("모레", "in 2 days"), rule("내일", "tomorrow"), rule(#"오늘\s*밤"#, "tonight"), rule("오늘", "today"),
            rule(#"다음\s*주"#, "next week"), rule(#"(?:이번\s*)?주말"#, "this weekend"), rule(#"다음\s*달"#, "next month"),
            rule("나중에", "later"), rule("아침", "morning"), rule("정오|점심", "noon"), rule("오후", "afternoon"),
            rule("저녁", "evening"), rule("밤", "night"),
        ]

        private static let after = "(?:以后|之后|以後|之後|后|後)"
        private static let chinese: [Rule] = [
            rule(#"(\d+)\s*分(?:钟|鐘)?\s*"# + after, "in $1 minutes"),
            rule(#"(\d+)\s*(?:个|個)?\s*(?:小时|小時|钟头|鐘頭)\s*"# + after, "in $1 hours"),
            rule(#"(\d+)\s*天\s*"# + after, "in $1 days"),
            rule(#"(\d+)\s*(?:个|個)?\s*(?:星期|礼拜|禮拜|周|週)\s*"# + after, "in $1 weeks"),
            rule(#"(\d+)\s*(?:个|個)\s*月\s*"# + after, "in $1 months"),
            rule(#"晚上\s*12\s*[点點]\s*半"#, "at 24:30"), rule(#"晚上\s*12\s*[点點](?:钟|鐘)?"#, "midnight"),
            rule(#"(?:下午|晚上|傍晚)\s*(\d{1,2})\s*[点點]\s*半"#, "at $1:30 pm"),
            rule(#"(?:下午|晚上|傍晚)\s*(\d{1,2})\s*[点點]\s*(\d{1,2})\s*分?"#, "at $1:$2 pm"),
            rule(#"(?:下午|晚上|傍晚)\s*(\d{1,2})\s*[点點](?:钟|鐘)?"#, "at $1:00 pm"),
            rule(#"(?:上午|早上|早晨|凌晨)\s*(\d{1,2})\s*[点點]\s*半"#, "at $1:30 am"),
            rule(#"(?:上午|早上|早晨|凌晨)\s*(\d{1,2})\s*[点點]\s*(\d{1,2})\s*分?"#, "at $1:$2 am"),
            rule(#"(?:上午|早上|早晨|凌晨)\s*(\d{1,2})\s*[点點](?:钟|鐘)?"#, "at $1:00 am"),
            rule(#"(\d{1,2})\s*[点點]\s*半"#, "at $1:30"), rule(#"(\d{1,2})\s*[点點]\s*(\d{1,2})\s*分?"#, "at $1:$2"),
            rule(#"(\d{1,2})\s*[点點](?:钟|鐘)?"#, "at $1:00"),
            rule("大后天|大後天", "in 3 days"), rule("后天|後天", "in 2 days"), rule("明天", "tomorrow"),
            rule("今天晚上|今晚", "tonight"), rule("今天", "today"),
            rule(#"下\s*(?:个|個)?\s*(?:周|週|星期|礼拜|禮拜)"#, "next week"),
            rule(#"(?:这个|這個|本)?\s*周末"#, "this weekend"), rule(#"下\s*(?:个|個)\s*月"#, "next month"),
            rule("稍后|稍後|晚些时候|待会儿|等会儿", "later"), rule("早上|上午|早晨", "morning"), rule("中午", "noon"),
            rule("下午", "afternoon"), rule("傍晚", "evening"), rule("晚上", "night"),
        ]

        /// Bengali words start after a space or at the start ("কাল" is
        /// also the end of "সকাল"), and take endings ("সন্ধ্যায়").
        private static let word = #"(?<!\S)"#
        private static let bengali: [Rule] = [
            rule(#"(\d+)\s*মিনিট\s*পরে?"#, "in $1 minutes"), rule(#"(\d+)\s*ঘ(?:ণ্|ন্)টা\s*পরে?"#, "in $1 hours"),
            rule(#"(\d+)\s*দিন\s*পরে?"#, "in $1 days"), rule(#"(\d+)\s*সপ্তাহ\s*পরে?"#, "in $1 weeks"),
            rule(#"(\d+)\s*মাস\s*পরে?"#, "in $1 months"),
            // 12 at night is midnight ("রাত ১২টা", "মধ্যরাত"); 12 by day
            // stays noon ("দুপুর ১২টা").
            rule(word + #"রাত\S*\s*সাড়ে\s*12\s*টা\S*"#, "at 24:30"), rule(word + #"রাত\S*\s*12:(\d{2})\s*(?:টা\S*)?"#, "at 24:$1"),
            rule(word + #"রাত\S*\s*12\s*টা\S*"#, "midnight"), rule(word + #"(?:মধ্যরাত|মাঝরাত)\S*"#, "midnight"),
            rule(word + #"(?:বিকাল|বিকেল|সন্ধ্যা|সন্ধ্যে|রাত|দুপুর)\S*\s*সাড়ে\s*(\d{1,2})\s*টা\S*"#, "at $1:30 pm"),
            rule(word + #"(?:বিকাল|বিকেল|সন্ধ্যা|সন্ধ্যে|রাত|দুপুর)\S*\s*(\d{1,2}):(\d{2})\s*(?:টা\S*)?"#, "at $1:$2 pm"),
            rule(word + #"(?:বিকাল|বিকেল|সন্ধ্যা|সন্ধ্যে|রাত|দুপুর)\S*\s*(\d{1,2})\s*টা\S*"#, "at $1:00 pm"),
            rule(word + #"(?:সকাল|ভোর)\S*\s*সাড়ে\s*(\d{1,2})\s*টা\S*"#, "at $1:30 am"),
            rule(word + #"(?:সকাল|ভোর)\S*\s*(\d{1,2}):(\d{2})\s*(?:টা\S*)?"#, "at $1:$2 am"),
            rule(word + #"(?:সকাল|ভোর)\S*\s*(\d{1,2})\s*টা\S*"#, "at $1:00 am"),
            rule(#"সাড়ে\s*(\d{1,2})\s*টা\S*"#, "at $1:30"), rule(#"(\d{1,2}):(\d{2})\s*টা\S*"#, "at $1:$2"),
            rule(#"(\d{1,2})\s*টা\S*"#, "at $1:00"),
        ] + weekdayRules(["রবিবার", "সোমবার", "মঙ্গলবার", "বুধবার", "বৃহস্পতিবার", "শুক্রবার", "শনিবার"],
                         next: [word + #"(?:আগামী|পরের|সামনের)\s*DAY"#], before: word, after: #"\S*"#) + [
            rule(word + #"আগামীকাল\S*"#, "tomorrow"), rule(word + #"কাল(?:কে)?(?!\S)"#, "tomorrow"),
            rule(word + #"পরশু\S*"#, "in 2 days"), rule(word + #"আজ\S*\s*রাত\S*"#, "tonight"), rule(word + #"আজ\S*"#, "today"),
            rule(word + #"(?:আগামী|পরের|সামনের)\s*সপ্তাহ\S*"#, "next week"),
            rule(word + #"(?:এই\s*)?(?:সপ্তাহান্ত|উইকেন্ড)\S*"#, "this weekend"),
            rule(word + #"(?:আগামী|পরের|সামনের)\s*মাস\S*"#, "next month"), rule(word + #"পরে(?!\S)"#, "later"),
            rule(word + #"(?:সকাল|ভোর)\S*"#, "morning"), rule(word + #"দুপুর\S*"#, "noon"),
            rule(word + #"(?:বিকাল|বিকেল)\S*"#, "afternoon"), rule(word + #"(?:সন্ধ্যা|সন্ধ্যে)\S*"#, "evening"),
            rule(word + #"রাত\S*"#, "night"),
        ]

        // Midnight, the end of the day it's said with, in every language:
        // unread, "demain à minuit" fell to the date detector, at noon.
        private static let german: [Rule] = [
            rule(#"\b(?:um )?mitternacht\b"#, "midnight"),
            rule(#"\bübermorgen\b"#, "in 2 days"),
            rule(#"\bin ein(?:er|em|en|e)?\b"#, "in 1"), rule(#"\bin zwei\b"#, "in 2"), rule(#"\bin drei\b"#, "in 3"),
            rule(#"\bin (\d+) minuten?\b"#, "in $1 minutes"), rule(#"\bin (\d+) stunden?\b"#, "in $1 hours"),
            rule(#"\bin (\d+) tag(?:en)?\b"#, "in $1 days"), rule(#"\bin (\d+) wochen?\b"#, "in $1 weeks"),
            rule(#"\bin (\d+) monat(?:en)?\b"#, "in $1 months"),
            rule(#"(?:\bum )?\b(\d{1,2})[:.](\d{2}) uhr (?:abends|nachmittags)\b"#, "at $1:$2 pm"),
            rule(#"(?:\bum )?\b(\d{1,2}) uhr (?:abends|nachmittags)\b"#, "at $1:00 pm"),
            rule(#"(?:\bum )?\b(\d{1,2})[:.](\d{2}) uhr\b"#, "at $1:$2"), rule(#"(?:\bum )?\b(\d{1,2}) uhr\b"#, "at $1:00"),
            rule(#"\bum (\d{1,2}):(\d{2})\b"#, "at $1:$2"), rule(#"\bum (\d{1,2})\b"#, "at $1"),
        ] + weekdayRules(["sonntag", "montag", "dienstag", "mittwoch", "donnerstag", "freitag", "samstag"],
                         next: [#"\b(?:nächsten|nächster|nächste|kommenden|kommender) DAY"#], before: #"\b(?:am )?"#, after: #"\b"#) + [
            rule(#"\bheute (?:abend|nacht)\b"#, "tonight"), rule(#"\bheute\b"#, "today"),
            rule(#"\bmorgen früh\b"#, "tomorrow morning"), rule(#"\bmorgen\b"#, "tomorrow"),
            rule(#"\b(?:nächste|kommende) woche\b"#, "next week"), rule(#"\b(?:dieses |am )?wochenende\b"#, "this weekend"),
            rule(#"\b(?:nächsten|kommenden) monat\b"#, "next month"), rule(#"\bspäter\b"#, "later"),
            rule(#"\b(?:morgens|früh|vormittags?)\b"#, "morning"), rule(#"\bmittags?\b"#, "noon"),
            rule(#"\bnachmittags?\b"#, "afternoon"), rule(#"\babends?\b"#, "evening"), rule(#"\bnachts?\b"#, "night"),
        ]

        private static let french: [Rule] = [
            rule(#"(?:\bà )?\bminuit\b"#, "midnight"),
            rule(#"\baprès[- ]demain\b|\bapres[- ]demain\b"#, "in 2 days"),
            rule(#"\bdans une?\b"#, "dans 1"), rule(#"\bdans deux\b"#, "dans 2"), rule(#"\bdans trois\b"#, "dans 3"),
            rule(#"\bdans (\d+) ?min(?:ute)?s?\b"#, "in $1 minutes"), rule(#"\bdans (\d+) ?(?:heures?|h)\b"#, "in $1 hours"),
            rule(#"\bpendant (\d+) ?min(?:ute)?s?\b"#, "in $1 minutes"), rule(#"\bpendant (\d+) ?(?:heures?|h)\b"#, "in $1 hours"),
            rule(#"\bdans (\d+) jours?\b"#, "in $1 days"), rule(#"\bdans (\d+) semaines?\b"#, "in $1 weeks"),
            rule(#"\bdans (\d+) mois\b"#, "in $1 months"),
            rule(#"(?:\bà )?\b(\d{1,2}) ?h ?(\d{2}) (?:du soir|de l'après-midi|de l'apres-midi)"#, "at $1:$2 pm"),
            rule(#"(?:\bà )?\b(\d{1,2}) ?(?:h|heures?) (?:du soir|de l'après-midi|de l'apres-midi)"#, "at $1:00 pm"),
            rule(#"(?<!às )(?<!as )(?:\bà )?\b(\d{1,2}) ?h ?(\d{2})\b"#, "at $1:$2"),
            rule(#"\bà (\d{1,2}) ?(?:h|heures?)?\b"#, "at $1"),
            rule(#"\b(\d{1,2}) heures?\b"#, "at $1:00"),
        ] + weekdayRules(["dimanche", "lundi", "mardi", "mercredi", "jeudi", "vendredi", "samedi"],
                         next: [#"\bDAY prochain\b"#], this: [#"\bce "#], before: #"\b"#, after: #"\b"#) + [
            rule(#"\bce soir\b"#, "tonight"), rule(#"\bcet (?:après|apres)-midi\b"#, "this afternoon"),
            rule(#"\bce matin\b"#, "this morning"),
            rule(#"\baujourd'hui\b"#, "today"), rule(#"\bdemain\b"#, "tomorrow"),
            rule(#"\b(?:la )?semaine prochaine\b"#, "next week"), rule(#"\b(?:ce|le) week-?end\b"#, "this weekend"),
            rule(#"\bweek-end\b"#, "weekend"),
            rule(#"\b(?:le )?mois prochain\b"#, "next month"), rule(#"\bplus tard\b"#, "later"),
            rule(#"\b(?:après|apres)-midi\b"#, "afternoon"), rule(#"\bmatin(?:ée)?\b"#, "morning"), rule(#"\bmidi\b"#, "noon"),
            rule(#"\bsoir(?:ée)?\b"#, "evening"), rule(#"\bnuit\b"#, "night"),
        ]

        private static let spanish: [Rule] = [
            // "Las 12 de la noche" is midnight too.
            rule(#"\b(?:a (?:la )?)?medianoche\b|\ba las 12 de la noche\b"#, "midnight"),
            rule(#"\bpasado ma[ñn]ana\b"#, "in 2 days"),
            rule(#"\b(?:en|dentro de) un[ao]?\b"#, "en 1"), rule(#"\b(?:en|dentro de) dos\b"#, "en 2"),
            rule(#"\b(?:en|dentro de) tres\b"#, "en 3"),
            rule(#"\b(?:en|dentro de) (\d+) minutos?\b"#, "in $1 minutes"), rule(#"\b(?:en|dentro de) (\d+) horas?\b"#, "in $1 hours"),
            rule(#"\b(?:en|dentro de) (\d+) d[ií]as?\b"#, "in $1 days"), rule(#"\b(?:en|dentro de) (\d+) semanas?\b"#, "in $1 weeks"),
            rule(#"\b(?:en|dentro de) (\d+) mes(?:es)?\b"#, "in $1 months"),
            rule(#"\ba la una\b"#, "a las 1"),
            rule(#"\ba las (\d{1,2}):(\d{2}) de la (?:tarde|noche)\b"#, "at $1:$2 pm"),
            rule(#"\ba las (\d{1,2}) de la (?:tarde|noche)\b"#, "at $1:00 pm"),
            rule(#"\ba las (\d{1,2}):(\d{2}) de la (?:ma[ñn]ana|madrugada)\b"#, "at $1:$2 am"),
            rule(#"\ba las (\d{1,2}) de la (?:ma[ñn]ana|madrugada)\b"#, "at $1:00 am"),
            rule(#"\ba las (\d{1,2}):(\d{2})\b"#, "at $1:$2"), rule(#"\ba las (\d{1,2})\b"#, "at $1"),
        ] + weekdayRules(["domingo", "lunes", "martes", "mi[ée]rcoles", "jueves", "viernes", "s[áa]bado"],
                         next: [#"\b(?:el )?pr[óo]ximo DAY"#, #"\b(?:el )?DAY (?:que viene|pr[óo]ximo)\b"#],
                         before: #"\b(?:el )?"#, after: #"\b"#) + [
            rule(#"\b(?:por|en) la ma[ñn]ana\b"#, "morning"), rule(#"\besta noche\b"#, "tonight"),
            rule(#"\besta tarde\b"#, "this afternoon"),
            rule(#"\bma[ñn]ana\b"#, "tomorrow"), rule(#"\bhoy\b"#, "today"),
            rule(#"\b(?:la )?(?:pr[óo]xima semana|semana que viene|semana pr[óo]xima)\b"#, "next week"),
            rule(#"\b(?:este |el )?fin de semana\b"#, "this weekend"),
            rule(#"\b(?:el )?(?:pr[óo]ximo mes|mes que viene)\b"#, "next month"), rule(#"\bm[áa]s tarde\b|\bluego\b"#, "later"),
            rule(#"\bmediod[ií]a\b"#, "noon"), rule(#"\b(?:por la )?tarde\b"#, "afternoon"), rule(#"\b(?:por la )?noche\b"#, "night"),
        ]

        private static let portuguese: [Rule] = [
            rule(#"(?:\bà |\ba )?\bmeia-noite\b|(?:\bàs |\bas )12 ?h? da noite\b"#, "midnight"),
            rule(#"\bdepois de amanh[ãa]\b"#, "in 2 days"),
            rule(#"\b(?:em|daqui a) uma?\b"#, "em 1"), rule(#"\b(?:em|daqui a) (?:dois|duas)\b"#, "em 2"),
            rule(#"\b(?:em|daqui a) tr[êe]s\b"#, "em 3"),
            rule(#"\b(?:em|daqui a) (\d+) minutos?\b"#, "in $1 minutes"), rule(#"\b(?:em|daqui a) (\d+) horas?\b"#, "in $1 hours"),
            rule(#"\b(?:em|daqui a) (\d+) dias?\b"#, "in $1 days"), rule(#"\b(?:em|daqui a) (\d+) semanas?\b"#, "in $1 weeks"),
            rule(#"\b(?:em|daqui a) (\d+) m[eê]s(?:es)?\b"#, "in $1 months"),
            rule(#"(?:\bàs |\bas )(\d{1,2})[:h](\d{2}) da (?:tarde|noite)\b"#, "at $1:$2 pm"),
            rule(#"(?:\bàs |\bas )(\d{1,2}) ?h? da (?:tarde|noite)\b"#, "at $1:00 pm"),
            rule(#"(?:\bàs |\bas )(\d{1,2})[:h](\d{2})\b"#, "at $1:$2"), rule(#"(?:\bàs |\bas )(\d{1,2}) ?h?\b"#, "at $1"),
        ] + weekdayRules(["domingo", "segunda(?:-feira)?", "ter[çc]a(?:-feira)?", "quarta(?:-feira)?", "quinta(?:-feira)?",
                          "sexta(?:-feira)?", "s[áa]bado"],
                         next: [#"\bpr[óo]xim[ao] DAY"#, #"\bDAY que vem\b"#], before: #"\b(?:n[ao] )?"#, after: #"\b"#) + [
            rule(#"\bhoje (?:à|a) noite\b|\besta noite\b"#, "tonight"), rule(#"\besta tarde\b"#, "this afternoon"),
            rule(#"\bhoje\b"#, "today"),
            rule(#"\bamanh[ãa]\b"#, "tomorrow"),
            rule(#"\b(?:semana que vem|pr[óo]xima semana)\b"#, "next week"),
            rule(#"\b(?:neste |este |no )?fim de semana\b"#, "this weekend"),
            rule(#"\b(?:m[êe]s que vem|pr[óo]ximo m[êe]s)\b"#, "next month"), rule(#"\bmais tarde\b"#, "later"),
            rule(#"\bde manh[ãa]\b"#, "morning"), rule(#"\bmeio-dia\b"#, "noon"),
            rule(#"(?:\bà |\ba )?\btarde\b"#, "afternoon"), rule(#"(?:\bà |\ba )?\bnoite\b"#, "night"),
        ]

        /// "in 2h" and a lone "2h" are two hours; "9h" after a day is nine
        /// o'clock, as in French ("demain 9h"), read last so Portuguese
        /// "às 9h" is first.
        private static let clocks: [Rule] = [rule(#"\bin (\d+) ?h\b"#, "in $1 hours"),
                                             rule(#"(?<=\S)(?<!\bin)\s+(\d{1,2})h\b"#, "at $1:00")]
    }
}
