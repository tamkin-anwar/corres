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

    // MARK: Weekends around the world

    private func calendar(_ locale: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: locale)
        calendar.timeZone = TimeZone(identifier: "Asia/Dhaka")!
        return calendar
    }

    private func day(_ calendar: Calendar, _ date: Date?) -> [Int?] {
        guard let date else { return [nil] }
        let parts = calendar.dateComponents([.day, .weekday, .hour], from: date)
        return [parts.day, parts.weekday, parts.hour]
    }

    /// Bangladesh rests on Friday and Saturday and starts the week on
    /// Sunday; the US and UK rest on Saturday and Sunday.
    @Test func weekendsFollowTheRegion() {
        for locale in ["bn_BD", "en_BD", "en_US", "en_GB"] {
            let calendar = calendar(locale)
            // Wednesday, October 21, 2026, 10 AM.
            let wednesday = calendar.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 10))!
            let bangladesh = locale.hasSuffix("BD")
            let weekend = TimePhrase.parse("this weekend", now: wednesday, calendar: calendar)
            #expect(day(calendar, weekend) == (bangladesh ? [23, 6, 9] : [24, 7, 9]), "\(locale)")
            let nextWeek = TimePhrase.parse("next week", now: wednesday, calendar: calendar)
            #expect(day(calendar, nextWeek) == (bangladesh ? [25, 1, 8] : [26, 2, 8]), "\(locale)")
        }
    }

    @Test func nextWeekSkipsTheWorkingDayThatIsTomorrow() {
        // Saturday in Bangladesh: Sunday is tomorrow, so next week is the Sunday after.
        let bd = calendar("bn_BD")
        let saturday = bd.date(from: DateComponents(year: 2026, month: 10, day: 24, hour: 10))!
        #expect(day(bd, TimePhrase.parse("next week", now: saturday, calendar: bd)) == [Optional(1), 1, 8])
        // Saturday in the UK: Monday is two days away.
        let gb = calendar("en_GB")
        #expect(day(gb, TimePhrase.parse("next week", now: saturday, calendar: gb)) == [26, 2, 8])
    }

    @Test func sendLaterOffersTheFirstWorkingDayBeforeTheWeekend() {
        let bd = calendar("bn_BD"), us = calendar("en_US"), gb = calendar("en_GB")
        func date(_ calendar: Calendar, _ day: Int) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: 10))!
        }
        // Thursday the 22nd: Bangladesh's weekend starts tomorrow.
        #expect(day(bd, TimePhrase.workWeekStartForSendLater(now: date(bd, 22), calendar: bd)).first == 25)
        #expect(TimePhrase.workWeekStartForSendLater(now: date(us, 22), calendar: us) == nil)
        // Friday the 23rd: Monday in the US and UK, Sunday in Bangladesh.
        #expect(day(us, TimePhrase.workWeekStartForSendLater(now: date(us, 23), calendar: us)).first == 26)
        #expect(day(gb, TimePhrase.workWeekStartForSendLater(now: date(gb, 23), calendar: gb)).first == 26)
        #expect(day(bd, TimePhrase.workWeekStartForSendLater(now: date(bd, 23), calendar: bd)).first == 25)
        // The weekend's last day: the working day is tomorrow, already offered.
        #expect(TimePhrase.workWeekStartForSendLater(now: date(bd, 24), calendar: bd) == nil)
        #expect(TimePhrase.workWeekStartForSendLater(now: date(gb, 25), calendar: gb) == nil)
        #expect(day(gb, TimePhrase.workWeekStartForSendLater(now: date(gb, 24), calendar: gb)).first == 26)
    }

    // MARK: Other languages

    /// [phrase: [day, hour]] from Thursday, September 24, 9:14 PM.
    private func expectAll(_ cases: [String: [Int]], sourceLocation: SourceLocation = #_sourceLocation) {
        for (phrase, expected) in cases {
            #expect(parts(phrase).map { [$0.day!, $0.hour!] } == expected, "\(phrase)", sourceLocation: sourceLocation)
        }
    }

    @Test func japanese() {
        expectAll(["明日の夜": [25, 20], "3日後 9時": [27, 9], "来週の金曜": [2, TimePhrase.morningHour],
                   "明日 9時": [25, 9], "明日 午後3時半": [25, 15], "三日後": [27, TimePhrase.morningHour],
                   "２時間後": [24, 23], "今夜10時": [24, 22]])
    }

    @Test func korean() {
        expectAll(["내일 저녁": [25, 18], "3일 후 오전 9시": [27, 9], "다음 주 금요일": [2, TimePhrase.morningHour],
                   "내일 오전 9시": [25, 9], "내일 오후 2시 30분": [25, 14], "모레": [26, TimePhrase.morningHour]])
    }

    /// 12 at night is midnight, the end of the day it's said with; 12 by
    /// day stays noon.
    @Test func midnightAndNoon() {
        expectAll(["오늘 밤 12시": [25, 0], "내일 밤 12시": [26, 0], "자정": [25, 0], "내일 자정": [26, 0],
                   "내일 밤 12시 30분": [26, 0], "내일 낮 12시": [25, 12], "내일 오후 12시": [25, 12], "내일 정오": [25, 12],
                   "내일 밤 9시": [25, 21],
                   "আজ রাত ১২টা": [25, 0], "আগামীকাল রাত ১২টায়": [26, 0], "মধ্যরাতে": [25, 0],
                   "আগামীকাল দুপুর ১২টা": [25, 12], "আগামীকাল রাত ৯টায়": [25, 21],
                   "明天晚上12点": [26, 0], "tonight at 12": [25, 0], "tomorrow at midnight": [26, 0],
                   "tomorrow at noon": [25, 12]])
        #expect(parts("내일 밤 12시 30분")?.minute == 30)
    }

    @Test func chinese() {
        expectAll(["明天晚上": [25, 20], "3天后 上午9点": [27, 9], "下周五": [2, TimePhrase.morningHour],
                   "明天上午9点": [25, 9], "三天后": [27, TimePhrase.morningHour], "明天下午3点半": [25, 15],
                   "星期六": [26, TimePhrase.morningHour]])
    }

    @Test func bengali() {
        expectAll(["আগামীকাল সন্ধ্যায়": [25, 18], "৩ দিন পরে সকাল ৯টা": [27, 9], "আগামী শুক্রবার": [25, TimePhrase.morningHour],
                   "আগামীকাল সকাল ৯টা": [25, 9], "কাল বিকেল ৪টায়": [25, 16], "২ ঘণ্টা পরে": [24, 23]])
    }

    @Test func german() {
        expectAll(["morgen Abend": [25, 18], "in 3 Tagen um 9 Uhr": [27, 9], "nächsten Freitag": [25, TimePhrase.morningHour],
                   "morgen um 9 Uhr": [25, 9], "übermorgen": [26, TimePhrase.morningHour], "morgen früh": [25, TimePhrase.morningHour]])
    }

    @Test func french() {
        expectAll(["demain soir": [25, 18], "dans 3 jours à 9h": [27, 9], "vendredi prochain": [25, TimePhrase.morningHour],
                   "demain à 9h": [25, 9], "demain 14h30": [25, 14], "après-demain": [26, TimePhrase.morningHour]])
    }

    @Test func spanish() {
        expectAll(["mañana por la tarde": [25, 14], "en 3 días a las 9": [27, 9], "el próximo viernes": [25, TimePhrase.morningHour],
                   "mañana a las 9": [25, 9], "manana a las 5 de la tarde": [25, 17], "pasado mañana": [26, TimePhrase.morningHour]])
    }

    @Test func portuguese() {
        expectAll(["amanhã à noite": [25, 20], "em 3 dias às 9h": [27, 9], "próxima sexta": [25, TimePhrase.morningHour],
                   "amanhã às 9h": [25, 9], "depois de amanhã": [26, TimePhrase.morningHour]])
    }

    @Test func englishIsUnchangedByTheOtherLanguages() {
        expectAll(["this weekend": [26, 9], "in a week": [1, TimePhrase.morningHour], "tonight at 11": [24, 23],
                   "in 2h": [24, 23], "a couple of days": [26, TimePhrase.morningHour]])
    }
}
