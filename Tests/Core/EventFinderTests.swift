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
}
