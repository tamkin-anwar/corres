import Foundation
import Testing
@testable import CorresCore


struct SenderHabitsTests {
    private let now = Date(timeIntervalSince1970: 1_791_800_000)
    private func daysAgo(_ days: Double) -> Date { now.addingTimeInterval(-days * 86_400) }

    @Test func neverOpenedListSuggestsUnsubscribe() {
        var habits = SenderHabits()
        for day in [1.0, 4, 8] { habits.recordRemovedUnread("news@medium.com", at: daysAgo(day)) }
        // Three isn't a habit yet.
        #expect(habits.suggestion(for: "news@medium.com", name: "Medium", isList: true, isPerson: false, isVIP: false, now: now) == nil)
        habits.recordRemovedUnread("news@medium.com", at: daysAgo(0.5))
        #expect(habits.suggestion(for: "news@medium.com", name: "Medium", isList: true, isPerson: false, isVIP: false, now: now)
                == .unsubscribe(email: "news@medium.com", name: "Medium", unopened: 4))
        // Not a list: nothing to unsubscribe from.
        #expect(habits.suggestion(for: "news@medium.com", name: "Medium", isList: false, isPerson: false, isVIP: false, now: now) == nil)
    }

    @Test func openingOnceMeansItMatters() {
        var habits = SenderHabits()
        for day in [1.0, 2, 3, 4, 5] { habits.recordRemovedUnread("news@x.com", at: daysAgo(day)) }
        habits.recordOpen("news@x.com", receivedAt: daysAgo(6), at: daysAgo(6))
        #expect(habits.suggestion(for: "news@x.com", name: "X", isList: true, isPerson: false, isVIP: false, now: now) == nil)
    }

    @Test func quickReaderBecomesVIPSuggestion() {
        var habits = SenderHabits()
        for day in [1.0, 2, 3, 5, 8] {
            habits.recordOpen("sara@x.com", receivedAt: daysAgo(day), at: daysAgo(day).addingTimeInterval(8 * 60))
        }
        #expect(habits.suggestion(for: "sara@x.com", name: "Sara", isList: false, isPerson: true, isVIP: false, now: now)
                == .vip(email: "sara@x.com", name: "Sara", reason: .readsQuickly(minutes: 8)))
        #expect(habits.suggestion(for: "sara@x.com", name: "Sara", isList: false, isPerson: true, isVIP: true, now: now) == nil)
        #expect(habits.suggestion(for: "sara@x.com", name: "Sara", isList: false, isPerson: false, isVIP: false, now: now) == nil)
    }

    @Test func frequentRepliesBecomeVIPSuggestion() {
        var habits = SenderHabits()
        for day in [1.0, 5, 9] { habits.recordReply(to: "ash@x.com", at: daysAgo(day)) }
        #expect(habits.suggestion(for: "ash@x.com", name: "Ash", isList: false, isPerson: true, isVIP: false, now: now)
                == .vip(email: "ash@x.com", name: "Ash", reason: .repliesOften(count: 3)))
    }

    @Test func oldHabitsFadeAndNotNowWaitsAMonth() {
        var habits = SenderHabits()
        for day in [70.0, 75, 80, 85] { habits.recordRemovedUnread("old@x.com", at: daysAgo(day)) }
        #expect(habits.suggestion(for: "old@x.com", name: "Old", isList: true, isPerson: false, isVIP: false, now: now) == nil)

        for day in [1.0, 2, 3, 4] { habits.recordRemovedUnread("news@x.com", at: daysAgo(day)) }
        let offer = habits.suggestion(for: "news@x.com", name: "X", isList: true, isPerson: false, isVIP: false, now: now)!
        habits.decline(offer, forever: false, at: now)
        #expect(habits.suggestion(for: "news@x.com", name: "X", isList: true, isPerson: false, isVIP: false, now: now) == nil)
        #expect(habits.suggestion(for: "news@x.com", name: "X", isList: true, isPerson: false, isVIP: false,
                                  now: now.addingTimeInterval(31 * 86_400)) != nil) // a month later, it may ask once more
        habits.decline(offer, forever: true, at: now)
        #expect(habits.suggestion(for: "news@x.com", name: "X", isList: true, isPerson: false, isVIP: false,
                                  now: now.addingTimeInterval(31 * 86_400)) == nil)
    }

    @Test func atMostOneSuggestionADay() {
        var habits = SenderHabits()
        for day in [1.0, 2, 3, 4] { habits.recordRemovedUnread("a@x.com", at: daysAgo(day)) }
        for day in [1.0, 2, 3, 4] { habits.recordRemovedUnread("b@x.com", at: daysAgo(day)) }
        #expect(habits.suggestion(for: "a@x.com", name: "A", isList: true, isPerson: false, isVIP: false, now: now) != nil)
        habits.markOffered(at: now)
        #expect(habits.suggestion(for: "b@x.com", name: "B", isList: true, isPerson: false, isVIP: false, now: now.addingTimeInterval(3_600)) == nil)
        #expect(habits.suggestion(for: "b@x.com", name: "B", isList: true, isPerson: false, isVIP: false, now: now.addingTimeInterval(86_400)) != nil)
    }

    @Test func snoozeUsualNeedsAHabit() {
        var snooze = SnoozeHabits()
        snooze.record("thisWeekend", for: "receipt")
        snooze.record("thisWeekend", for: "receipt")
        #expect(snooze.usual(for: "receipt") == nil)
        snooze.record("thisWeekend", for: "receipt")
        #expect(snooze.usual(for: "receipt") == "thisWeekend")
        snooze.record("tomorrow", for: "receipt")
        snooze.record("tomorrow", for: "receipt")
        // 3 of 5 is still most of the time; 3 of 6 isn't.
        #expect(snooze.usual(for: "receipt") == "thisWeekend")
        snooze.record("tomorrow", for: "receipt")
        #expect(snooze.usual(for: "receipt") == nil)
        #expect(snooze.usual(for: "personal") == nil)
    }
}
