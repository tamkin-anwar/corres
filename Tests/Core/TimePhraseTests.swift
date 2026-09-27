import Foundation
import Testing
@testable import CorresCore

struct TimePhraseTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }()
    /// Thursday, September 24, 2026, 9:14 PM in New York.
    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: 24, hour: 21, minute: 14))!
    }

    private func parts(_ phrase: String) -> DateComponents? {
        TimePhrase.parse(phrase, now: now, calendar: calendar)
            .map { calendar.dateComponents([.month, .day, .hour, .minute, .weekday], from: $0) }
    }

    @Test func relativeAmountsWithAndWithoutATime() {
        #expect(parts("in 3 days at 9am").map { [$0.day, $0.hour, $0.minute] } == [27, 9, 0])
        #expect(parts("3 days").map { [$0.day, $0.hour] } == [27, TimePhrase.morningHour])
        #expect(parts("in 2 hours").map { [$0.day, $0.hour, $0.minute] } == [24, 23, 14])
        #expect(parts("in a week").map { [$0.month, $0.day] } == [10, 1])
        #expect(parts("a couple of days").map { $0.day } == 26)
    }

    @Test func namedDaysAndTimesOfDay() {
        #expect(parts("tomorrow").map { [$0.day, $0.hour] } == [25, TimePhrase.morningHour])
        #expect(parts("tomorrow evening").map { [$0.day, $0.hour] } == [25, 18])
        #expect(parts("tomorrow at 2:30 pm").map { [$0.hour, $0.minute] } == [14, 30])
        #expect(parts("friday").map { [$0.day, $0.weekday] } == [25, 6])
        #expect(parts("next thursday at 10").map { [$0.day, $0.hour] } == [Optional(1), 10])
        #expect(parts("this weekend").map { [$0.day, $0.weekday, $0.hour] } == [26, 7, 9])
        #expect(parts("next week").map { [$0.day, $0.weekday] } == [28, 2])
    }

    @Test func nextWeekNeverDuplicatesTomorrow() {
        let sunday = calendar.date(from: DateComponents(year: 2026, month: 9, day: 27, hour: 10))!
        let result = TimePhrase.parse("next week", now: sunday, calendar: calendar)
        #expect(result.map { calendar.component(.day, from: $0) } == Optional(5))
    }

    @Test func todayTimesRollForwardOnlyWhenPast() {
        #expect(parts("9am").map { [$0.day, $0.hour] } == [25, 9])
        #expect(parts("at 11:30pm").map { [$0.day, $0.hour, $0.minute] } == [24, 23, 30])
    }

    @Test func rejectsNonsenseAndThePast() {
        #expect(TimePhrase.parse("", now: now, calendar: calendar) == nil)
        #expect(TimePhrase.parse("whenever", now: now, calendar: calendar) == nil)
        #expect(TimePhrase.parse("tonight", now: now, calendar: calendar) == nil)
    }
}
