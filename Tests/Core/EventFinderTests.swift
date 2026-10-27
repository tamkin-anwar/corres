import Foundation
import Testing
@testable import CorresCore

/// The calendar suggestion under an email: its date and time.
struct EventFinderTests {
    let calendar = Calendar.current
    /// Sunday 11 October 2026, 16:15: when the tester opened the email.
    var now: Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: 11, hour: 16, minute: 15))! }
    var sent: Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: 7, hour: 8, minute: 30))! }

    func parts(_ date: Date?) -> DateComponents? {
        date.map { calendar.dateComponents([.month, .day, .hour, .minute], from: $0) }
    }

    /// What a tester saw: a meeting on Thursday the 15th offered as today,
    /// Sunday the 11th, at 19:15, from a time written on its own.
    @Test func aDayAndATimeWrittenApartArePutTogether() {
        let body = "Join us for the 2026 Annual General Meeting on Thursday 15 October 2026. Registration from 19:15."
        let event = EventFinder.fromWording(body, subject: "Annual General Meeting - Thursday 15 October 2026",
                                            receivedAt: sent, now: now)
        let when = parts(event?.start)
        #expect(when?.day == 15)
        #expect(when?.hour == 19)
        #expect(when?.minute == 15)
    }

    @Test func aBritishDottedTimeIsNotADate() {
        let body = "The Annual General Meeting will take place on Thursday 15th October at 7.15pm."
        let when = parts(EventFinder.fromWording(body, subject: "AGM", receivedAt: sent, now: now)?.start)
        #expect(when?.day == 15)
        #expect(when?.hour == 19)
    }

    /// The suggestion's title and confirmation, as the calendar would keep them.
    @Test func titleAndConfirmationAreReadCarefully() {
        let body = "Your reservation is on Thursday 15 October 2026 at 7:00 PM. A confirmation email was sent to you."
        let event = EventFinder.fromWording(body, subject: "Re: Fwd: Dinner reservation", receivedAt: sent, now: now)
        #expect(event?.title == "Dinner reservation")
        #expect(event?.confirmation == nil)
        let coded = EventFinder.fromWording("Meeting on Thursday 15 October 2026 at 7:00 PM. Confirmation number: ABC123",
                                            subject: "Meeting", receivedAt: sent, now: now)
        #expect(coded?.title == "Meeting")
        #expect(coded?.confirmation == "ABC123")
        let pending = EventFinder.fromWording("Meeting on Thursday 15 October 2026 at 7:00 PM. Confirmation: pending",
                                              subject: "Planning", receivedAt: sent, now: now)
        #expect(pending?.confirmation == nil)
        #expect(pending?.title == "Planning")
    }

    @Test func aTimeAloneInOldMailIsNotToday() {
        let body = "Our meeting starts at 19:15, see you there."
        #expect(EventFinder.fromWording(body, subject: "Meeting", receivedAt: sent, now: now) == nil)
    }

    @Test func aFullDateAndTimeStillWork() {
        let body = "Your appointment is on Thursday 15th October 2026 at 2:30pm."
        let when = parts(EventFinder.fromWording(body, subject: "Appointment", receivedAt: sent, now: now)?.start)
        #expect(when?.day == 15)
        #expect(when?.hour == 14)
        #expect(when?.minute == 30)
    }

    /// "12/3(木)": the weekday in brackets after a numeric date, as
    /// Japanese, Chinese and Korean mail writes it, says which way round
    /// the date is: December 3rd, 2026 is a Thursday, March 12th, 2027 a
    /// Friday. A short email has too little kana to say so otherwise.
    @Test func aBracketedWeekdaySettlesANumericDate() {
        func start(_ body: String, _ subject: String) -> [Int?]? {
            parts(EventFinder.fromWording(body, subject: subject, receivedAt: sent, now: now)?.start)
                .map { [$0.month, $0.day, $0.hour, $0.minute] }
        }
        #expect(start("12/3(木)14:00 会議室A", "打ち合わせ") == [12, 3, 14, 0])
        #expect(start("12/3（木）14:00 会議室", "会議") == [12, 3, 14, 0])
        #expect(start("12/3(周四)14:00 会议室", "会议") == [12, 3, 14, 0])
        #expect(start("12/3(목) 14:00 회의실", "회의") == [12, 3, 14, 0])
        // Written day first, and the weekday says so.
        #expect(start("3/12(木)14:00 会議室A", "打ち合わせ") == [12, 3, 14, 0])
        // A weekday neither reading falls on settles nothing.
        #expect(start("12/3(月)14:00 会議室A", "打ち合わせ") == nil)
        // A deadline is read the same way.
        let due = MailSignals.deadline(in: "締切：12/3(木)", now: now, horizon: 90 * 86_400)
        #expect(due.map { calendar.dateComponents([.month, .day], from: $0) }.map { [$0.month, $0.day] } == [12, 3])
    }

    /// "14:00〜" (from 14:00) and "14:00～15:00": Japanese and Chinese write
    /// a time's range with a wave dash (U+301C) or a full-width tilde
    /// (U+FF5E). The date detector read no time at all in either.
    @Test func aWaveDashRangeKeepsItsTime() {
        func event(_ body: String, _ subject: String) -> [Int?]? {
            EventFinder.fromWording(body, subject: subject, receivedAt: sent, now: now).map { event in
                let start = calendar.dateComponents([.month, .day, .hour, .minute], from: event.start)
                let end = event.end.map { calendar.component(.hour, from: $0) }
                return [start.month, start.day, start.hour, start.minute, end]
            }
        }
        #expect(event("12/3(木)14:00〜 会議室A", "打ち合わせ") == [12, 3, 14, 0, nil])
        #expect(event("12/3(木)14:00〜15:00 会議室A", "打ち合わせ") == [12, 3, 14, 0, 15])
        #expect(event("12/3(木)14:00～15:00 会議室A", "打ち合わせ") == [12, 3, 14, 0, 15])
        #expect(event("12/3(木)14:00 ～ 15:00 会議室A", "打ち合わせ") == [12, 3, 14, 0, 15])
        #expect(event("12/3(周四)14:00～15:00 会议室", "会议") == [12, 3, 14, 0, 15])
        #expect(event("12/3(周四)14:00~15:00 会议室", "会议") == [12, 3, 14, 0, 15])
        // A range's "00-15" is not a date: the range alone read as today.
        #expect(event("The webinar is on Thursday 15 October 2026. Sessions run 14:00-15:00.", "Webinar")?.prefix(3)
                == [10, 15, 14])
        // A deadline keeps its time too.
        let due = MailSignals.deadline(in: "12/3 17:00～までにご提出ください。", now: now, horizon: 90 * 86_400)
        #expect(due.map { calendar.dateComponents([.month, .day, .hour], from: $0) }.map { [$0.month, $0.day, $0.hour] } == [12, 3, 17])
        // A tilde that isn't after a time is left alone.
        #expect(MailSignals.withTimeRangesForDetector("約3〜5日") == "約3〜5日")
        #expect(MailSignals.withTimeRangesForDetector("14:00〜15:00、16:00～") == "14:00-15:00、16:00 ")
    }
}
