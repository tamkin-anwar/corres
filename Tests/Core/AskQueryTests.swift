import Foundation
import Testing
@testable import CorresCore

struct AskQueryTests {
    // Thursday, October 8, 2026, noon, in a fixed time zone.
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return calendar
    }
    private var now: Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: 8, hour: 12))! }

    private func thread(_ id: String, sender: String, email: String, subject: String, body: String = "",
                        daysAgo: Double = 0, attachments: [MailAttachment] = []) -> Correspondence {
        Correspondence(id: ThreadID(account: "me@x.test", providerID: id), sender: sender, senderEmail: email,
                       organization: "", subject: subject, excerpt: body, body: body,
                       receivedAt: now.addingTimeInterval(-daysAgo * 86_400), dueAt: nil, reason: "", attention: .quiet,
                       attachments: attachments)
    }

    @Test func attachmentsFromAPerson() {
        let query = AskQuery("Attachments from Oliver", now: now, calendar: calendar)
        #expect(query.wantsAttachments && query.person == "oliver" && query.keywords.isEmpty && query.isList)
        let file = MailAttachment(id: "a", filename: "deck.pdf", mimeType: "application/pdf", sizeBytes: 10)
        #expect(query.matches(thread("1", sender: "Oliver Grant", email: "oliver@x.test", subject: "Deck", attachments: [file])))
        #expect(!query.matches(thread("2", sender: "Oliver Grant", email: "oliver@x.test", subject: "Hi")))
        #expect(!query.matches(thread("3", sender: "Maya", email: "maya@x.test", subject: "Deck", attachments: [file])))
        #expect(query.gmailQuery == "from:oliver has:attachment")
    }

    @Test func receiptsThisMonth() {
        let query = AskQuery("Receipts this month", now: now, calendar: calendar)
        #expect(query.topic == .receipts && query.keywords.isEmpty)
        #expect(query.matches(thread("1", sender: "Apple", email: "no_reply@apple.com", subject: "Your receipt from Apple", daysAgo: 2)))
        #expect(!query.matches(thread("2", sender: "Apple", email: "no_reply@apple.com", subject: "Your receipt from Apple", daysAgo: 12)))
        #expect(!query.matches(thread("3", sender: "Maya", email: "maya@x.test", subject: "Lunch?", daysAgo: 1)))
    }

    @Test func whatDidSomeoneAsk() {
        let query = AskQuery("What did Maya ask me?", now: now, calendar: calendar)
        #expect(query.person == "maya" && query.keywords.isEmpty && !query.isList)
    }

    @Test func flightsSearchByWordsNotKind() {
        let query = AskQuery("When is my next flight?", now: now, calendar: calendar)
        #expect(query.topic == .travel && query.person == nil && query.keywords.isEmpty)
    }

    @Test func plainKeywordsStillWork() {
        let query = AskQuery("Denver hotel confirmation", now: now, calendar: calendar)
        #expect(query.keywords.contains("denver") && query.keywords.contains("confirmation"))
    }
}
