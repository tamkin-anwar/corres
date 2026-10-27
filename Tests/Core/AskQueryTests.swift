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

    /// A question typed as a sentence ends in a full stop, not part of a name.
    @Test func aFullStopIsNotPartOfTheName() {
        let query = AskQuery("Show emails from Maya.", now: now, calendar: calendar)
        #expect(query.person == "maya")
        #expect(query.matches(thread("1", sender: "Maya Chen", email: "maya.chen@x.test", subject: "Hi")))
        #expect(AskQuery("Emails from maya@x.test.", now: now, calendar: calendar).person == "maya@x.test")
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

    /// "Hier" is yesterday in French and here in German: told apart by the
    /// question's other words, or by the reader's language when there
    /// are none to go by.
    @Test func hierIsYesterdayOnlyInFrench() {
        let yesterday = DateInterval(start: calendar.startOfDay(for: now).addingTimeInterval(-86_400), duration: 86_400)
        func range(_ question: String, _ languages: [String] = ["en-US"]) -> DateInterval? {
            AskQuery(question, now: now, calendar: calendar, languages: languages).range
        }
        #expect(range("les factures reçues hier") == yesterday)
        #expect(range("les mails d'hier") == yesterday)
        #expect(range("Zeig mir die Rechnungen hier") == nil)
        #expect(range("Was hat Maya hier geschrieben") == nil)
        #expect(!AskQuery("Zeig mir die Rechnungen hier", now: now, calendar: calendar).keywords.contains("hier"))
        // Nothing else to go by: the reader's language.
        #expect(range("hier", ["de-DE", "en-US"]) == nil)
        #expect(range("hier", ["fr-FR"]) == yesterday)
        #expect(range("gestern", ["fr-FR"]) == yesterday)
    }

    @Test func plainKeywordsStillWork() {
        let query = AskQuery("Denver hotel confirmation", now: now, calendar: calendar)
        #expect(query.keywords.contains("denver") && query.keywords.contains("confirmation"))
    }
}
