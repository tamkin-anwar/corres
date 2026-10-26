import Foundation
import Testing
@testable import CorresCore

struct TodayBriefTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Dhaka")!
        return calendar
    }()
    /// Sunday, October 25, 2026, 10:30 AM in Dhaka.
    private var now: Date { at(hour: 10, minute: 30) }

    private func at(day: Int = 25, hour: Int, minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    private func mail(_ id: String, sender: String = "Maya Chen", subject: String = "Hello",
                      received: Date? = nil, due: Date? = nil) -> Correspondence {
        Correspondence(id: ThreadID(account: "a@example.com", providerID: id), sender: sender, organization: "",
                       subject: subject, excerpt: "", body: "", receivedAt: received ?? at(day: 24, hour: 9),
                       dueAt: due, reason: "", attention: .needsYou)
    }

    private func brief(_ needsYou: [Correspondence], deliveries: [Correspondence] = [],
                       meetings: Set<String> = [], people: Set<String>? = nil) -> TodayBrief {
        TodayBrief.make(needsYou: needsYou, deliveries: deliveries, now: now, calendar: calendar,
                        isMeeting: { meetings.contains($0.id.providerID) },
                        isPerson: { people?.contains($0.id.providerID) ?? true })
    }

    @Test func ordersDueThenMeetingsThenDeliveriesThenTheLongestOwedReply() {
        let owedNewer = mail("owed-newer", received: at(day: 24, hour: 18))
        let owedOlder = mail("owed-older", received: at(day: 20, hour: 9))
        let dueLater = mail("due-later", due: at(hour: 17))
        let overdue = mail("overdue", due: at(day: 23, hour: 12))
        let meeting = mail("meeting", due: at(hour: 15))
        let parcel = mail("parcel")
        let result = TodayBrief.make(needsYou: [owedNewer, owedOlder, dueLater, overdue, meeting], deliveries: [parcel],
                                     now: now, calendar: calendar, limit: 10,
                                     isMeeting: { $0.id.providerID == "meeting" }, isPerson: { _ in true })
        #expect(result.top.map(\.id.providerID) == ["overdue", "due-later", "meeting", "parcel", "owed-older"])
        #expect(result.top.map(\.kind) == [.overdue, .dueToday, .meeting, .delivery, .reply])
        #expect(result.due == 2)
        #expect(result.overdue == 1)
        #expect(result.meetings == 1)
        #expect(result.deliveries == 1)
        #expect(result.replies == 2)
    }

    @Test func keepsToThreeRows() {
        let items = (0..<5).map { mail("due-\($0)", due: at(hour: 12 + $0)) }
        let result = brief(items)
        #expect(result.top.count == 3)
        #expect(result.due == 5)
    }

    @Test func tomorrowIsNotToday() {
        let result = brief([mail("tomorrow", due: at(day: 26, hour: 9))], people: [])
        #expect(result.isEmpty)
        #expect(result.top.isEmpty)
    }

    @Test func aDayWithoutATimeIsDueUntilItEnds() {
        let result = brief([mail("by-today", due: at(hour: 0)), mail("by-yesterday", due: at(day: 24, hour: 0))])
        #expect(result.top.first { $0.id.providerID == "by-today" }?.kind == .dueToday)
        #expect(result.top.first { $0.id.providerID == "by-today" }?.hasTime == false)
        #expect(result.top.first { $0.id.providerID == "by-yesterday" }?.kind == .overdue)
    }

    @Test func aTimedDeadlineThatPassedThisMorningIsOverdue() {
        let result = brief([mail("nine", due: at(hour: 9))])
        #expect(result.top.first?.kind == .overdue)
        #expect(result.top.first?.hasTime == true)
    }

    @Test func meetingsDropAnHourAfterTheyStart() {
        let result = brief([mail("early", due: at(hour: 8)), mail("now", due: at(hour: 10)), mail("later", due: at(hour: 16))],
                           meetings: ["early", "now", "later"])
        #expect(result.top.map(\.id.providerID) == ["now", "later"])
        #expect(result.meetings == 2)
        #expect(result.due == 0)
    }

    @Test func anEarlierDaysInvitationStillInNeedsYouIsOverdueAsTheListSays() {
        let result = brief([mail("last-week", due: at(day: 20, hour: 15))], meetings: ["last-week"])
        #expect(result.top.first?.kind == .overdue)
        #expect(result.meetings == 0)
    }

    @Test func automatedMailIsNotARepliesOwed() {
        let result = brief([mail("newsletter")], people: [])
        #expect(result.isEmpty)
    }

    @Test func aDeliveryOnlyUntilItIsDelivered() {
        let out = mail("out", received: at(hour: 7))
        let delivered = mail("delivered", received: at(hour: 9))
        let otherStore = mail("other", received: at(hour: 8))
        let arriving = TodayBrief.arriving(
            from: [(delivered, "Delivered"), (out, "Out for delivery"), (otherStore, "Out for delivery")],
            store: { $0.id.providerID == "other" ? "b.example" : "a.example" })
        #expect(arriving.map(\.id.providerID) == ["other"])
    }

    @Test func hasTimeIgnoresMidnightAndTheDaysLastMinute() {
        #expect(!TodayBrief.hasTime(at(hour: 0), calendar: calendar))
        #expect(!TodayBrief.hasTime(at(hour: 23, minute: 59), calendar: calendar))
        #expect(TodayBrief.hasTime(at(hour: 17), calendar: calendar))
    }
}
