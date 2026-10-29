import Foundation
import SwiftData
import Testing
@testable import CorresCore

/// What a reply arriving, a change made offline, a rule pass or another
/// device must never get wrong about the mail.
struct MailCorrectnessTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let account = "me@example.com"

    private func message(_ id: String, from sender: String = "ana@example.com", minutes: Double,
                         labels: [String] = ["INBOX"]) -> Correspondence {
        Correspondence(id: ThreadID(account: account, providerID: "t1"), sender: "Ana Lima", senderEmail: sender,
                       organization: "", subject: "Plans", excerpt: "", body: "", latestMessageID: id,
                       receivedAt: now.addingTimeInterval(minutes * 60), dueAt: nil, reason: "", attention: .quiet,
                       labelIds: labels)
    }

    // MARK: The HTML of an opened conversation

    @Test func aReplyIsNeverShownWithTheMessageBeforeIt() {
        let id = ThreadID(account: account, providerID: "t1")
        var content = OpenedContent(limit: 40)
        content.remember("<p>First</p>", for: id, messageID: "m1")
        #expect(content.isKnown(id, messageID: "m1"))
        #expect(content.html(for: id, messageID: "m1") == "<p>First</p>")
        // The reply arrived: what's kept is the first message's.
        #expect(!content.isKnown(id, messageID: "m2"))
        #expect(content.html(for: id, messageID: "m2") == nil)
        content.remember("<p>Reply</p>", for: id, messageID: "m2")
        #expect(content.html(for: id, messageID: "m2") == "<p>Reply</p>")
        #expect(content.ids == [id])
    }

    @Test func readWithoutHTMLIsStillKnown() {
        let id = ThreadID(account: account, providerID: "plain")
        var content = OpenedContent(limit: 40)
        content.remember(nil, for: id, messageID: "m1")
        #expect(content.isKnown(id, messageID: "m1"))
        #expect(content.html(for: id, messageID: "m1") == nil)
    }

    @Test func theOldestOpenedGoFirst() {
        var content = OpenedContent(limit: 2)
        let ids = (1...3).map { ThreadID(account: account, providerID: "t\($0)") }
        for id in ids { content.remember("<p/>", for: id, messageID: "m") }
        #expect(content.ids == Array(ids.suffix(2)))
        #expect(!content.isKnown(ids[0], messageID: "m"))
    }

    // MARK: A change made offline

    @Test func nothingNewMeansTheWholeConversation() {
        let messages = [message("m1", minutes: 0), message("m2", minutes: 5)]
        #expect(WaitingChange.messagesKnown(atMessage: "m2", at: now.addingTimeInterval(300), in: messages) == nil)
    }

    @Test func aReplySinceIsLeftOut() {
        let messages = [message("m1", minutes: 0), message("m2", minutes: 5), message("m3", minutes: 9)]
        #expect(WaitingChange.messagesKnown(atMessage: "m2", at: now.addingTimeInterval(300), in: messages) == ["m1", "m2"])
    }

    @Test func yourOwnReplyIsntNewMail() {
        let messages = [message("m1", minutes: 0), message("m2", from: account, minutes: 9, labels: ["SENT"])]
        #expect(WaitingChange.messagesKnown(atMessage: "m1", at: now, in: messages) == nil)
    }

    @Test func aMessageWithANewIdIsFoundByTime() {
        // An IMAP message's id changes when it moves.
        let messages = [message("1:7:Archive", minutes: 0), message("1:9:INBOX", minutes: 9)]
        #expect(WaitingChange.messagesKnown(atMessage: "1:3:INBOX", at: now, in: messages) == ["1:7:Archive"])
        #expect(WaitingChange.messagesKnown(atMessage: "1:3:INBOX", at: nil, in: messages) == nil)
    }

    // MARK: Categories

    @Test func aCategoryMoveChangesOnlyTheCategory() {
        let labels = ["INBOX", "CATEGORY_PROMOTIONS", "STARRED", "Label_7"]
        #expect(InboxCategory.labels(labels, withCategories: ["CATEGORY_PERSONAL"]) == ["INBOX", "STARRED", "Label_7", "CATEGORY_PERSONAL"])
        // Undo after a flag landed: the flag stays, the category goes back.
        let flaggedSince = ["INBOX", "STARRED", "Label_7", "CATEGORY_PERSONAL", "UNREAD"]
        #expect(InboxCategory.labels(flaggedSince, withCategories: ["CATEGORY_PROMOTIONS"])
                == ["INBOX", "STARRED", "Label_7", "UNREAD", "CATEGORY_PROMOTIONS"])
        #expect(InboxCategory.labels(flaggedSince, withCategories: []) == ["INBOX", "STARRED", "Label_7", "UNREAD"])
    }

    // MARK: Your other devices

    @Test func aMoveAppliesOnlyToTheMessageItWasMadeOn() {
        #expect(SyncMerge.moveApplies(madeOn: "m1", latest: "m1"))
        #expect(!SyncMerge.moveApplies(madeOn: "m1", latest: "m2"))
        // Kept without its message: it never sends a reply back to Handled.
        #expect(!SyncMerge.moveApplies(madeOn: nil, latest: "m2"))
        #expect(SyncMerge.moveApplies(madeOn: nil, latest: nil))
    }

    private struct Decision: Equatable {
        let decision: String
        let account: String
        let at: Date
    }

    @Test func senderDecisionsAreKeptPerAccount() {
        let work = "me@work.example", home = "Me@Home.example"
        var decisions: [String: Decision] = [:]
        decisions[SyncMerge.decisionKey(account: work, sender: "Ana@Shop.example")] = Decision(decision: "approved", account: work, at: now)
        decisions[SyncMerge.decisionKey(account: home, sender: "ana@shop.example")] = Decision(decision: "blocked", account: home, at: now)
        #expect(decisions.count == 2)
        #expect(SyncMerge.accountKeyed(decisions, account: \.account, at: \.at) == decisions)
        #expect(SyncMerge.decisionSender(key: "me@home.example|ana@shop.example", account: home) == "ana@shop.example")
    }

    @Test func olderDecisionsMoveUnderTheirAccount() {
        let work = "me@work.example"
        let old = Decision(decision: "blocked", account: work, at: now)
        let newer = Decision(decision: "approved", account: work, at: now.addingTimeInterval(60))
        // Written by an older Corres, keyed by the sender alone.
        let migrated = SyncMerge.accountKeyed(["ana@shop.example": old], account: \.account, at: \.at)
        #expect(migrated == ["me@work.example|ana@shop.example": old])
        // Both kinds there: the later decision wins, whichever key it had.
        let both = SyncMerge.accountKeyed(["ana@shop.example": old, "me@work.example|ana@shop.example": newer],
                                          account: \.account, at: \.at)
        #expect(both == ["me@work.example|ana@shop.example": newer])
        let olderNew = SyncMerge.accountKeyed(["ana@shop.example": newer, "me@work.example|ana@shop.example": old],
                                              account: \.account, at: \.at)
        #expect(olderNew == ["me@work.example|ana@shop.example": newer])
    }

    // MARK: Back to the Inbox

    @Test func archivedMailMovesBackByItsLabelsNotBySavingItAgain() async throws {
        let schema = Schema(CorresSchemaV1.models)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let repository = SwiftDataMailRepository(modelContainer: try ModelContainer(for: schema, migrationPlan: CorresMigrationPlan.self,
                                                                                    configurations: [configuration]))
        let archived = message("m1", minutes: 0, labels: ["CATEGORY_PERSONAL"])
        try await repository.upsert([archived], isInitialSync: true)
        #expect(try await repository.threads().first?.isArchivedCopy == true)
        // The same message again changes nothing: why Move to Inbox sets
        // the labels itself (`MailStore.adoptIntoInbox`).
        var inInbox = archived
        inInbox.labelIds = ["CATEGORY_PERSONAL", "INBOX"]
        try await repository.upsert([inInbox], isInitialSync: true)
        #expect(try await repository.threads().first?.isArchivedCopy == true)
        let moved = try await repository.setLabelIds(inInbox.labelIds, for: archived.id)
        #expect(!moved.isArchivedCopy)
        #expect(try await repository.threads().first?.isArchivedCopy == false)
    }
}
