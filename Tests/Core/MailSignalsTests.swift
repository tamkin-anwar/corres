import Foundation
import SwiftData
import Testing
@testable import CorresCore

struct MailSignalsTests {
    /// Absolute dates, since the system date detector resolves relative
    /// ones ("Friday") against the real clock.
    private func spelled(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMMM d, yyyy"
        return formatter.string(from: date)
    }

    @Test func questionsAndRequestsCountButLinksAndQuotesDoNot() {
        #expect(MailSignals.asksSomething("Could you review the draft by tomorrow"))
        #expect(MailSignals.asksSomething("Does Thursday work?"))
        #expect(MailSignals.asksSomething("Let me know what you think."))
        #expect(!MailSignals.asksSomething("Thanks, that's perfect."))
        #expect(!MailSignals.asksSomething("Details here: https://example.com/page?id=4&ref=mail"))
        // A question in the quoted history belongs to the earlier message.
        #expect(!MailSignals.asksSomething("Sounds good.\n\nOn Mon, Sep 21, 2026 at 9:00 AM, Maya wrote:\n> Can you make it?"))
    }

    @Test func aDateIsADeadlineOnlyWhenTheWordingSaysSo() {
        let now = Date()
        let soon = now.addingTimeInterval(5 * 86_400)
        let due = MailSignals.deadline(in: "Please sign the lease by \(spelled(soon)).", now: now)
        #expect(due.map { Calendar.current.isDate($0, inSameDayAs: soon) } == true)
        #expect(MailSignals.deadline(in: "RSVP by \(spelled(soon)) so we can plan.", now: now) != nil)
        // Just a date, not a deadline.
        #expect(MailSignals.deadline(in: "We met on \(spelled(soon)) at the studio.", now: now) == nil)
        // Past dates and ones far off aren't "due soon".
        #expect(MailSignals.deadline(in: "Due \(spelled(now.addingTimeInterval(-10 * 86_400))).", now: now) == nil)
        #expect(MailSignals.deadline(in: "Due \(spelled(now.addingTimeInterval(200 * 86_400))).", now: now) == nil)
    }

    @Test func noReplyAddressesAreNotPeople() {
        #expect(MailSignals.hasPersonRecipient(["maya@studio.test"], account: "me@x.test"))
        #expect(!MailSignals.hasPersonRecipient(["noreply@bank.test", "me@x.test"], account: "me@x.test"))
    }

    @Test func classifierUsesQuestionsDeadlinesAndCc() {
        let now = Date()
        let ask = InboxClassifier.initialAttention(isUnread: true, labelIds: [], looksAutomated: false,
                                                   asksSomething: true)
        #expect(ask.attention == .needsYou)
        #expect(ask.reason == InboxClassifier.questionReason)

        let deadline = InboxClassifier.initialAttention(isUnread: true, labelIds: [], looksAutomated: false,
                                                        deadline: now.addingTimeInterval(86_400))
        #expect(deadline.reason == InboxClassifier.deadlineReason)

        let copied = InboxClassifier.initialAttention(isUnread: true, labelIds: [], looksAutomated: false,
                                                      isCopiedOnly: true, asksSomething: true)
        #expect(copied.attention == .quiet)
        #expect(InboxClassifier.correspondentOverride(isUnread: true, hasListUnsubscribe: false, isCorrespondent: true,
                                                      isCopiedOnly: true) == nil)

        // A bill due soon is an update that needs you; a sale ending soon never is.
        let bill = InboxClassifier.initialAttention(isUnread: true, labelIds: ["CATEGORY_UPDATES"], looksAutomated: true,
                                                    deadline: now.addingTimeInterval(86_400),
                                                    text: "Your payment is due")
        #expect(bill.attention == .needsYou)
        let sale = InboxClassifier.initialAttention(isUnread: true, labelIds: ["CATEGORY_PROMOTIONS"], looksAutomated: true,
                                                    deadline: now.addingTimeInterval(86_400),
                                                    text: "Sale ends, last day to pay less")
        #expect(sale.attention == .quiet)
    }

    @Test func whatYouWroteDecidesWaiting() {
        let now = Date()
        #expect(InboxClassifier.afterYouWrote(asksSomething: true, toPeople: true, sentAt: now, now: now).attention == .waiting)
        #expect(InboxClassifier.afterYouWrote(asksSomething: false, toPeople: true, sentAt: now, now: now).attention == .quiet)
        #expect(InboxClassifier.afterYouWrote(asksSomething: true, toPeople: false, sentAt: now, now: now).attention == .quiet)
        // Weeks-old questions found on first sync aren't live anymore.
        let old = now.addingTimeInterval(-30 * 86_400)
        #expect(InboxClassifier.afterYouWrote(asksSomething: true, toPeople: true, sentAt: old, now: now).attention == .quiet)
    }

    /// Replying from Gmail on the web or Apple Mail moves the thread just
    /// like replying in Corres would.
    @Test func aReplySentFromAnotherAppLeavesNeedsYou() async throws {
        let schema = Schema(CorresSchemaV1.models)
        let container = try ModelContainer(for: schema, migrationPlan: CorresMigrationPlan.self,
                                           configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        let repository = SwiftDataMailRepository(modelContainer: container)
        let received = Date().addingTimeInterval(-3_600)
        let id = ThreadID(account: "me@x.test", providerID: "t1")
        let inbound = Correspondence(id: id, sender: "Maya", senderEmail: "maya@x.test", organization: "", subject: "Plan",
                                     excerpt: "Can you approve?", body: "Can you approve?", latestMessageID: "m1",
                                     receivedAt: received, dueAt: nil, reason: InboxClassifier.questionReason,
                                     attention: .needsYou, isUnread: true)
        try await repository.upsert([inbound], isInitialSync: true)

        let sentAt = Date()
        let yourReply = Correspondence(id: id, sender: "Me", senderEmail: "me@x.test", organization: "", subject: "Re: Plan",
                                       excerpt: "Approved. When can you start?", body: "Approved. When can you start?",
                                       latestMessageID: "m2", receivedAt: sentAt, dueAt: nil,
                                       reason: InboxClassifier.askedReason, attention: .waiting,
                                       toRecipients: ["maya@x.test"], waitingSince: sentAt)
        try await repository.upsert([yourReply], isInitialSync: false)
        let thread = try #require(await repository.threads().first { $0.id == id })
        #expect(thread.attention == .waiting)
        #expect(thread.waitingSince == sentAt)
    }

    @Test func listsLeadWithTheNearestDeadlineAndTheLongestWait() {
        let now = Date()
        func thread(_ n: String, _ attention: Attention, received: TimeInterval, due: TimeInterval? = nil,
                    waiting: TimeInterval? = nil) -> Correspondence {
            Correspondence(id: ThreadID(account: "a", providerID: n), sender: n, organization: "", subject: n,
                           excerpt: "", body: "", receivedAt: now.addingTimeInterval(received),
                           dueAt: due.map { now.addingTimeInterval($0) }, reason: "", attention: attention,
                           waitingSince: waiting.map { now.addingTimeInterval($0) })
        }
        let needs = MailQuery.prioritized([
            thread("newest", .needsYou, received: -60),
            thread("dueLater", .needsYou, received: -7_200, due: 2 * 86_400),
            thread("dueSoon", .needsYou, received: -9_000, due: 3_600),
        ], attention: .needsYou, now: now)
        #expect(needs.map(\.sender) == ["dueSoon", "dueLater", "newest"])

        let waiting = MailQuery.prioritized([
            thread("recent", .waiting, received: -60, waiting: -60),
            thread("quietFiveDays", .waiting, received: -9 * 86_400, waiting: -5 * 86_400),
        ], attention: .waiting, now: now)
        #expect(waiting.first?.sender == "quietFiveDays")
    }
}
