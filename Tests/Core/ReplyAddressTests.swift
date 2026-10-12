import Foundation
import Testing
@testable import CorresCore

/// Who Reply and Reply All address, as Mail and Gmail do it.
struct ReplyAddressTests {
    let me = "me@example.com"

    func message(from: String?, to: [String], cc: [String] = [], replyTo: [String] = []) -> Correspondence {
        Correspondence(id: ThreadID(account: me, providerID: "t"), sender: "Someone", senderEmail: from,
                       organization: "", subject: "Hi", excerpt: "", body: "", receivedAt: .now, dueAt: nil,
                       reason: "", attention: .quiet, toRecipients: to, ccRecipients: cc, replyTo: replyTo)
    }

    @Test func aReplyGoesToTheSender() {
        let mail = message(from: "sam@example.com", to: [me, "alex@example.com"])
        #expect(mail.replyAddresses == ["sam@example.com"])
        #expect(mail.replyAllCc == ["alex@example.com"])
    }

    /// A booking system writing from no-reply, asking for replies elsewhere.
    @Test func replyToWinsOverANoReplySender() {
        let mail = message(from: "noreply@clinic.example", to: [me], replyTo: ["reception@clinic.example"])
        #expect(mail.replyAddresses == ["reception@clinic.example"])
        #expect(!mail.replyAllCc.contains("noreply@clinic.example"))
    }

    /// Following up on your own email (Waiting) used to address it to you.
    @Test func replyingToYourOwnMessageGoesToWhoYouWroteTo() {
        let mail = message(from: me, to: ["sam@example.com", "alex@example.com"], cc: ["jo@example.com"])
        #expect(mail.replyAddresses == ["sam@example.com", "alex@example.com"])
        #expect(mail.replyAllCc == ["jo@example.com"])
        #expect(!mail.replyAddresses.contains(me))
    }

    @Test func youAreNeverCopied() {
        let mail = message(from: "sam@example.com", to: ["ME@example.com"], cc: [me, "alex@example.com"])
        #expect(mail.replyAllCc == ["alex@example.com"])
    }
}

extension ReplyAddressTests {
    /// Waiting is your own messages: the Brief named you as the one who
    /// hadn't replied.
    @Test func waitingIsNamedForWhoYouWroteTo() {
        let mine = message(from: me, to: ["sam.lee@example.com"])
        #expect(mine.counterpartName() == "Sam Lee")
        let fromSam = message(from: "sam.lee@example.com", to: [me])
        let known = Correspondence.knownSenderNames([Correspondence(
            id: ThreadID(account: me, providerID: "s"), sender: "Samantha Lee", senderEmail: "sam.lee@example.com",
            organization: "", subject: "", excerpt: "", body: "", receivedAt: .now, dueAt: nil, reason: "", attention: .quiet)])
        #expect(mine.counterpartName(knownNames: known) == "Samantha Lee")
        #expect(fromSam.counterpartName() == "Someone")
    }

    /// Bcc'd (or forwarded by a rule): Reply All would show everyone.
    @Test func bccdMailIsNoticed() {
        func mail(to: [String], cc: [String] = []) -> Correspondence {
            Correspondence(id: ThreadID(account: "me@x.test", providerID: UUID().uuidString), sender: "Ana", senderEmail: "ana@y.test",
                           organization: "", subject: "Plans", excerpt: "", body: "", receivedAt: .now, dueAt: nil,
                           reason: "", attention: .needsYou, toRecipients: to, ccRecipients: cc)
        }
        #expect(mail(to: ["bo@y.test"]).reachedYouHidden)
        #expect(!mail(to: ["bo@y.test"], cc: ["Me@X.test"]).reachedYouHidden)
        #expect(!mail(to: ["me@x.test"]).reachedYouHidden)
    }

    @Test func bccAloneIsSendable() {
        #expect(Draft(kind: .new, to: "", bcc: "a@x.test", subject: "Hi").isSendable)
        #expect(Draft(kind: .new, to: "", bcc: "a@x.test", subject: "Hi").recipientsLookValid)
        #expect(!Draft(kind: .new, to: "", bcc: "not an address", subject: "Hi").recipientsLookValid)
    }
}
