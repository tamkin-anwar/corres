import Foundation
import Testing
@testable import CorresCore

struct SchedulingTests {
    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return calendar
    }

    func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        // October 2026: the 19th is a Monday.
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    @Test func recognizesAsksForATime() {
        #expect(Scheduling.asksForTime("Hi! When are you free next week to go over the draft?"))
        #expect(Scheduling.asksForTime("What time works best for you on Thursday?"))
        #expect(Scheduling.asksForTime("Could we set up a call about the launch?"))
        #expect(Scheduling.asksForTime("Send me your availability and I'll book the room."))
        #expect(!Scheduling.asksForTime("Thanks for the update, the samples arrived."))
        #expect(!Scheduling.asksForTime("Your order is free of charge."))
    }

    @Test func offersOneTimePerWeekdaySkippingWhatsBusy() {
        // Monday 8am; Monday is booked 9 to 12.
        let busy = [(start: date(19, 9), end: date(19, 12))]
        let slots = Scheduling.freeSlots(busy: busy, from: date(19, 8), calendar: calendar)
        #expect(slots.count == 3)
        #expect(slots[0].start == date(19, 12))
        #expect(slots[1].start == date(20, 9))
        #expect(slots[2].start == date(21, 9))
    }

    @Test func neverOffersAWeekendOrTheNextHour() {
        // Friday 4:10pm: the next hour is past five, so Monday is next.
        let slots = Scheduling.freeSlots(busy: [], from: date(23, 16, 10), calendar: calendar)
        #expect(slots.first?.start == date(26, 9))
    }

    @Test func roundsUpToTheHalfHour() {
        #expect(Scheduling.roundedUpToHalfHour(date(19, 10, 5), calendar: calendar) == date(19, 10, 30))
        #expect(Scheduling.roundedUpToHalfHour(date(19, 10, 30), calendar: calendar) == date(19, 10, 30))
        #expect(Scheduling.roundedUpToHalfHour(date(19, 10, 45), calendar: calendar) == date(19, 11))
    }
}

struct SendLaterTimeTests {
    @Test func keepsAFutureTime() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let later = now.addingTimeInterval(3_600)
        #expect(Scheduling.sendLaterTime(later, now: now) == later)
    }

    @Test func movesAPastTimeToAMinuteFromNow() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(Scheduling.sendLaterTime(now.addingTimeInterval(-600), now: now) == now.addingTimeInterval(60))
        #expect(Scheduling.sendLaterTime(now.addingTimeInterval(30), now: now) == now.addingTimeInterval(60))
    }
}
