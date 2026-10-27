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

    /// Read for an English reader unless `languages` says otherwise.
    private func parts(_ phrase: String, languages: [String] = ["en-US"]) -> DateComponents? {
        TimePhrase.parse(phrase, now: now, calendar: calendar, languages: languages)
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

    /// A bare hour reads the way calendars read it (Google Calendar,
    /// Fantastical, Apple Reminders): 1 to 6 is the afternoon, 7 to 11 the
    /// morning, 12 is noon. am/pm, a leading zero ("05:00") and 24-hour
    /// times say which they mean and are kept.
    @Test func bareHoursReadAsCalendarsReadThem() {
        expectAll(["tomorrow at 3": [25, 15], "tomorrow at 6": [25, 18], "tomorrow at 7": [25, 7],
                   "tomorrow at 11": [25, 11], "tomorrow at 12": [25, 12], "tomorrow at 3:30": [25, 15],
                   "tomorrow 9": [25, 9], "tomorrow 4": [25, 16], "friday 2": [25, 14], "friday at 10": [25, 10],
                   "tomorrow at 3am": [25, 3], "tomorrow at 3 pm": [25, 15], "tomorrow at 9pm": [25, 21],
                   "tomorrow at 05:00": [25, 5], "tomorrow at 15:00": [25, 15], "tomorrow at 17": [25, 17],
                   "tomorrow at 0:30": [25, 0], "tonight at 10": [24, 22], "tonight at 12": [25, 0],
                   "in 3 days at 4": [27, 16]])
        // In the other languages' bare hours too; their own am/pm words win.
        expectAll(["明日 3時": [25, 15], "明日 午前3時": [25, 3], "明天3点": [25, 15], "明天上午3点": [25, 3],
                   "내일 3시": [25, 15], "내일 오전 3시": [25, 3], "কাল ৪টায়": [25, 16], "morgen um 3": [25, 15],
                   "morgen um 15 Uhr": [25, 15], "demain à 3h": [25, 15], "demain 15h": [25, 15],
                   "mañana a las 3": [25, 15], "amanhã às 3h": [25, 15], "demain 9h": [25, 9]])
    }

    /// "1h", "30m", "1 hr": a span from now, as Superhuman and Spark read
    /// them, not one o'clock.
    /// French writes the time "9h": alone, it's nine o'clock to a French
    /// reader. A span is "dans 1h" or "pendant 2h". Anyone else's "1h"
    /// stays an hour from now.
    @Test func aLoneHourIsAClockTimeInFrench() {
        for french in [["fr-FR"], ["fr-CA", "en-CA"]] {
            #expect(parts("9h", languages: french).map { [$0.day, $0.hour, $0.minute] } == [25, 9, 0], "\(french)")
            #expect(parts("9 h", languages: french).map { [$0.day, $0.hour, $0.minute] } == [25, 9, 0], "\(french)")
            #expect(parts("15h", languages: french).map { [$0.day, $0.hour, $0.minute] } == [25, 15, 0], "\(french)")
            #expect(parts("dans 1h", languages: french).map { [$0.day, $0.hour, $0.minute] } == [24, 22, 14], "\(french)")
            #expect(parts("pendant 2h", languages: french).map { [$0.day, $0.hour, $0.minute] } == [24, 23, 14], "\(french)")
            #expect(parts("demain 9h", languages: french).map { [$0.day, $0.hour] } == [25, 9], "\(french)")
        }
        for other in [["en-US"], ["de-DE"], ["en-GB", "fr-FR"], ["bn-BD"]] {
            #expect(parts("1h", languages: other).map { [$0.day, $0.hour, $0.minute] } == [24, 22, 14], "\(other)")
            #expect(parts("9h", languages: other).map { [$0.day, $0.hour, $0.minute] } == [25, 6, 14], "\(other)")
            // A French phrase reads its time whoever types it.
            #expect(parts("demain 9h", languages: other).map { [$0.day, $0.hour] } == [25, 9], "\(other)")
        }
    }

    @Test func shortSpansAreFromNow() {
        #expect(parts("1h").map { [$0.day, $0.hour, $0.minute] } == [24, 22, 14])
        #expect(parts("2h").map { [$0.day, $0.hour, $0.minute] } == [24, 23, 14])
        #expect(parts("30m").map { [$0.day, $0.hour, $0.minute] } == [24, 21, 44])
        #expect(parts("1 hr").map { [$0.day, $0.hour, $0.minute] } == [24, 22, 14])
        #expect(parts("in 2 hrs").map { [$0.day, $0.hour, $0.minute] } == [24, 23, 14])
        #expect(parts("3d").map { [$0.day, $0.hour] } == [27, TimePhrase.morningHour])
        #expect(parts("1w").map { [$0.month, $0.day] } == [10, 1])
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
        // In Europe's languages too: each was tomorrow at noon.
        expectAll(["demain à minuit": [26, 0], "morgen um Mitternacht": [26, 0], "mañana a medianoche": [26, 0],
                   "mañana a las 12 de la noche": [26, 0], "amanhã à meia-noite": [26, 0], "amanhã às 12h da noite": [26, 0],
                   // Japanese writes midnight as "午前0時".
                   "明日の午前0時": [25, 0], "午前0時": [25, 0]])
    }

    /// "This evening", "esta tarde", "cet après-midi": today, at that time,
    /// and never tomorrow's once it has begun.
    @Test func thisMorningAfternoonAndEvening() {
        let morning = calendar.date(from: DateComponents(year: 2026, month: 9, day: 24, hour: 10))!
        func hour(_ phrase: String, at time: Date) -> [Int]? {
            TimePhrase.parse(phrase, now: time, calendar: calendar)
                .map { calendar.dateComponents([.day, .hour], from: $0) }.map { [$0.day!, $0.hour!] }
        }
        for phrase in ["this afternoon", "esta tarde", "cet après-midi"] {
            #expect(hour(phrase, at: morning) == [24, 14], "\(phrase)")
        }
        #expect(hour("this evening", at: morning) == [24, 18])
        #expect(hour("this evening", at: now) == nil)
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
