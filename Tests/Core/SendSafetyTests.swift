import Foundation
import SwiftData
import Testing
@testable import CorresCore

/// Sending that never goes twice and leaves nothing behind, and a reply of
/// yours that doesn't hide what happens to the conversation elsewhere.
struct SendSafetyTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let account = "me@example.com"

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema(CorresSchemaV1.models)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, migrationPlan: CorresMigrationPlan.self, configurations: [configuration])
    }

    private func message(_ id: String, thread: String = "t1", from sender: String, header: String? = nil,
                         labels: [String], at offset: TimeInterval = 0) -> Correspondence {
        Correspondence(id: ThreadID(account: account, providerID: thread), sender: "S", senderEmail: sender,
                       organization: "", subject: "Plans", excerpt: "", body: "", messageIdHeader: header, latestMessageID: id,
                       receivedAt: now.addingTimeInterval(offset), dueAt: nil, reason: InboxClassifier.personalUnreadReason,
                       attention: .needsYou, isUnread: labels.contains("UNREAD"), labelIds: labels)
    }

    // MARK: SMTP

    @Test func anUnansweredHandoffIsNeverNotSent() {
        var handoffs = SMTPHandoffs()
        #expect(handoffs.verdict(for: "a@corres.app", account: account, foundIn: nil) == .notSent)
        handoffs.handOver("<a@corres.app>", account: account, at: now)
        #expect(handoffs.verdict(for: "a@corres.app", account: account, foundIn: nil) == .unknown)
        // A copy the server filed itself settles it.
        #expect(handoffs.verdict(for: "a@corres.app", account: account, foundIn: "conv") == .sent(conversation: "conv"))
        // Taken by the server, then Corres closed before filing it in Sent.
        handoffs.accepted("a@corres.app", account: account, conversation: "a@corres.app", at: now)
        #expect(handoffs.verdict(for: "A@corres.app", account: "ME@example.com", foundIn: nil) == .sent(conversation: "a@corres.app"))
        // Refused, or sent again by hand.
        handoffs.forget("a@corres.app", account: account)
        #expect(handoffs.verdict(for: "a@corres.app", account: account, foundIn: nil) == .notSent)
    }

    @Test func unconfirmedHandoffsOutlastAcceptedOnes() {
        var handoffs = SMTPHandoffs()
        handoffs.handOver("old-unconfirmed", account: account, at: now)
        handoffs.accepted("old-accepted", account: account, conversation: "c", at: now)
        let later = handoffs.pruned(now: now.addingTimeInterval(30 * 86_400))
        #expect(later.state(of: "old-unconfirmed", account: account) == .unconfirmed)
        #expect(later.state(of: "old-accepted", account: account) == nil)
        #expect(handoffs.pruned(now: now.addingTimeInterval(91 * 86_400)).entries.isEmpty)
    }

    // MARK: Outlook drafts

    @Test func aLeftoverDraftIsDeletedOnlyWhenItCannotHaveGone() {
        let neverAsked = LeftoverDrafts.Entry(account: account, draftID: "d1", messageID: "a@corres.app", sendAskedAt: nil)
        let asked = LeftoverDrafts.Entry(account: account, draftID: "d2", messageID: "a@corres.app", sendAskedAt: now)
        #expect(LeftoverDrafts.action(for: neverAsked, isDraft: true, now: now) == .delete)
        // Graph may still be sending it.
        #expect(LeftoverDrafts.action(for: asked, isDraft: true, now: now.addingTimeInterval(60)) == .wait)
        #expect(LeftoverDrafts.action(for: asked, isDraft: true, now: now.addingTimeInterval(LeftoverDrafts.settleTime)) == .delete)
        // Sent: that's the copy in Sent Items, never deleted.
        #expect(LeftoverDrafts.action(for: asked, isDraft: false, now: now.addingTimeInterval(3_600)) == .forget)
        #expect(LeftoverDrafts.action(for: neverAsked, isDraft: false, now: now) == .forget)
        // Already gone.
        #expect(LeftoverDrafts.action(for: neverAsked, isDraft: nil, now: now) == .forget)
    }

    @Test func leftoverDraftsAreKeptPerAccountOnce() {
        var leftovers = LeftoverDrafts()
        leftovers.add(.init(account: account, draftID: "d1", messageID: nil, sendAskedAt: nil))
        leftovers.add(.init(account: account, draftID: "d1", messageID: nil, sendAskedAt: now))
        leftovers.add(.init(account: "other@example.com", draftID: "d2", messageID: nil, sendAskedAt: nil))
        #expect(leftovers.entries(for: account).map(\.sendAskedAt) == [now])
        leftovers.remove(draftID: "d1", account: account)
        #expect(leftovers.entries(for: account).isEmpty)
        #expect(leftovers.entries.count == 1)
    }

    // MARK: Your reply is the latest

    @Test func archivedBehindYourReplyIsAskedAbout() {
        let yourReply = message("m2", from: account, labels: ["SENT"], at: 60)
        let theirs = message("m9", thread: "t2", from: "friend@x.test", labels: ["INBOX"])
        let changes = [
            // Archived on the web: only their message had the Inbox label.
            RemoteMessageChange(threadID: yourReply.id, messageID: "m1", currentLabelIds: ["IMPORTANT"], removed: true),
            RemoteMessageChange(threadID: theirs.id, messageID: "m8", currentLabelIds: [], removed: true),
        ]
        #expect(RemoteMessageChange.archivedBehindLatest(changes, stored: [yourReply, theirs]) == [yourReply.id])
        // Trashed, not archived: your reply is trashed with it and its own
        // change handles that.
        let trashed = [RemoteMessageChange(threadID: yourReply.id, messageID: "m1", currentLabelIds: ["TRASH"], removed: true)]
        #expect(RemoteMessageChange.archivedBehindLatest(trashed, stored: [yourReply]).isEmpty)
        // A change for the latest itself goes the usual way.
        let both = changes + [RemoteMessageChange(threadID: yourReply.id, messageID: "m2", currentLabelIds: ["SENT"], removed: false)]
        #expect(RemoteMessageChange.archivedBehindLatest(both, stored: [yourReply]).isEmpty)
        #expect(RemoteMessageChange.stillInInbox([["SENT"], ["IMPORTANT"]]) == false)
        #expect(RemoteMessageChange.stillInInbox([["SENT"], ["INBOX", "UNREAD"]]))
    }

    @Test func readElsewhereBehindYourReplyIsRead() async throws {
        let repository = SwiftDataMailRepository(modelContainer: try makeContainer())
        try await repository.upsert([message("m1", from: "friend@x.test", labels: ["INBOX", "UNREAD"])], isInitialSync: true)
        // You replied from the web without opening it here.
        try await repository.upsert([message("m2", from: account, labels: ["SENT"], at: 60)], isInitialSync: false)
        let id = ThreadID(account: account, providerID: "t1")
        #expect(try await repository.thread(id)?.isUnread == true)

        // Starred, still unread: nothing to change.
        var changed = try await repository.applyRemoteChanges([
            RemoteMessageChange(threadID: id, messageID: "m1", currentLabelIds: ["INBOX", "UNREAD", "STARRED"], removed: false),
        ])
        #expect(changed == 0)
        changed = try await repository.applyRemoteChanges([
            RemoteMessageChange(threadID: id, messageID: "m1", currentLabelIds: ["INBOX"], removed: false),
        ])
        #expect(changed == 1)
        let stored = try await repository.thread(id)
        #expect(stored?.isUnread == false)
        #expect(stored?.labelIds == ["SENT"])
    }

    @Test func anOlderMessageReadDoesNotReadANewerOneOfTheirs() async throws {
        let repository = SwiftDataMailRepository(modelContainer: try makeContainer())
        try await repository.upsert([message("m3", from: "friend@x.test", labels: ["INBOX", "UNREAD"], at: 120)], isInitialSync: true)
        let id = ThreadID(account: account, providerID: "t1")
        let changed = try await repository.applyRemoteChanges([
            RemoteMessageChange(threadID: id, messageID: "m1", currentLabelIds: ["INBOX"], removed: false),
        ])
        #expect(changed == 0)
        #expect(try await repository.thread(id)?.isUnread == true)
    }

    // MARK: The sent copy

    @Test func theSentCopyIsTheOneWithItsMessageID() {
        let sent = message("m1", from: account, header: "<a@corres.app>", labels: ["SENT"])
        let reply = message("m2", from: "friend@x.test", header: "b@x.test", labels: ["INBOX"], at: 60)
        let later = message("m3", from: account, header: "c@corres.app", labels: ["SENT"], at: 120)
        #expect(Correspondence.sentCopy(in: [sent, reply, later], messageID: "a@corres.app")?.latestMessageID == "m1")
        // Not found (a provider that drops the header): your newest, as before.
        #expect(Correspondence.sentCopy(in: [sent, reply, later], messageID: "zzz@corres.app")?.latestMessageID == "m3")
        #expect(Correspondence.sentCopy(in: [reply], messageID: nil)?.latestMessageID == "m2")
    }
}
