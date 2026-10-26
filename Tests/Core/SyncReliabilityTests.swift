import Foundation
import SwiftData
import Testing
@testable import CorresCore

/// What keeps sync from repeating itself or losing your sorting: the list
/// of messages to try again, removals that leave nothing behind, and an
/// email that comes back under a new id.
struct SyncReliabilityTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema(CorresSchemaV1.models)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, migrationPlan: CorresMigrationPlan.self, configurations: [configuration])
    }

    // MARK: Missed messages

    @Test func missedMessageIsLetGoAfterFiveFailedTries() {
        var missed = MissedMessages()
        missed = missed.after(failed: ["a"], tried: [], now: now)
        #expect(missed.entries["a"]?.attempts == 1)
        for pass in 2...4 {
            missed = missed.after(failed: ["a"], tried: ["a"], now: now.addingTimeInterval(Double(pass) * 20))
            #expect(missed.entries["a"]?.attempts == pass)
        }
        missed = missed.after(failed: ["a"], tried: ["a"], now: now.addingTimeInterval(100))
        #expect(missed.isEmpty)
    }

    /// A pass whose retry request failed outright (offline) didn't really
    /// try again, so it doesn't count against the message.
    @Test func untriedMissedMessageKeepsItsCount() {
        let missed = MissedMessages().after(failed: ["a"], tried: [], now: now)
        let next = missed.after(failed: ["a"], tried: [], now: now.addingTimeInterval(20))
        #expect(next.entries["a"] == MissedMessages.Entry(attempts: 1, since: now))
    }

    @Test func missedMessageIsLetGoAfterThreeDays() {
        let missed = MissedMessages().after(failed: ["a"], tried: [], now: now)
        let later = missed.after(failed: ["a"], tried: [], now: now.addingTimeInterval(MissedMessages.maxAge + 1))
        #expect(later.isEmpty)
    }

    @Test func fetchedOrGoneMessagesLeaveTheList() {
        let missed = MissedMessages().after(failed: ["a", "b"], tried: [], now: now)
        let next = missed.after(failed: ["b", "c"], tried: ["a", "b"], now: now.addingTimeInterval(20))
        #expect(Set(next.entries.keys) == ["b", "c"])
        #expect(next.entries["b"]?.attempts == 2)
        #expect(next.entries["c"]?.attempts == 1)
        #expect(next.ids == ["b", "c"])
    }

    @Test func missedListKeepsTheNewestWhenFull() {
        let old = MissedMessages().after(failed: Set((0..<150).map { "old\($0)" }), tried: [], now: now)
        let full = old.after(failed: Set(old.entries.keys).union((0..<100).map { "new\($0)" }), tried: [],
                             now: now.addingTimeInterval(20))
        #expect(full.entries.count == MissedMessages.maxTracked)
        #expect((0..<100).allSatisfy { full.entries["new\($0)"] != nil })
    }

    // MARK: Removals

    /// Removed elsewhere: the message's HTML goes with its conversation.
    @Test func remoteRemovalDeletesStoredContent() async throws {
        let container = try makeContainer()
        let repository = SwiftDataMailRepository(modelContainer: container)
        let account = "me@example.com"
        let item = Correspondence(id: ThreadID(account: account, providerID: "t1"), sender: "S", senderEmail: "s@x.test",
                                  organization: "", subject: "s", excerpt: "", body: "Hello", htmlBody: "<p>Hello</p>",
                                  latestMessageID: "m1", receivedAt: now, dueAt: nil, reason: InboxClassifier.personalUnreadReason,
                                  attention: .needsYou, isUnread: true, labelIds: ["INBOX", "UNREAD"])
        try await repository.upsert([item], isInitialSync: true)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<PersistedMessageContent>()) == 1)

        let changed = try await repository.applyRemoteChanges([
            RemoteMessageChange(threadID: item.id, messageID: "m1", currentLabelIds: nil, removed: true),
        ])
        #expect(changed == 1)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<PersistedMessageContent>()) == 0)
    }

    /// Outlook removals known only by message id, many at once, each found.
    @Test func manyRemovalsByMessageAloneAreFound() async throws {
        let repository = SwiftDataMailRepository(modelContainer: try makeContainer())
        let account = "me@outlook.test"
        let items = (1...700).map { n in
            Correspondence(id: ThreadID(account: account, providerID: "conv\(n)"), sender: "S", senderEmail: "s@x.test",
                           organization: "", subject: "s", excerpt: "", body: "", latestMessageID: "m\(n)",
                           receivedAt: now, dueAt: nil, reason: InboxClassifier.personalUnreadReason,
                           attention: .needsYou, isUnread: true, labelIds: ["INBOX", "UNREAD"])
        }
        try await repository.upsert(items, isInitialSync: true)
        let changed = try await repository.applyRemoteChanges((1...600).map { n in
            RemoteMessageChange(threadID: ThreadID(account: account, providerID: ""), messageID: "m\(n)", currentLabelIds: nil, removed: true)
        })
        #expect(changed == 600)
        #expect(try await repository.threads().count == 100)
    }

    // MARK: The same email under a new id

    /// An IMAP message listed again (or moved back into the Inbox) gets a
    /// new id. It's the same email, so how you sorted it stays.
    @Test func sameMessageUnderNewIDKeepsYourSorting() async throws {
        let repository = SwiftDataMailRepository(modelContainer: try makeContainer())
        let account = "me@icloud.test"
        let id = ThreadID(account: account, providerID: "root@x.test")
        func message(_ key: String, labels: [String]) -> Correspondence {
            Correspondence(id: id, sender: "Friend", senderEmail: "friend@x.test", organization: "", subject: "Plans",
                           excerpt: "", body: "Can you come?", messageIdHeader: "root@x.test", latestMessageID: key,
                           receivedAt: now, dueAt: nil, reason: InboxClassifier.personalUnreadReason,
                           attention: .needsYou, isUnread: labels.contains("UNREAD"), labelIds: labels)
        }
        try await repository.upsert([message("1:10:INBOX", labels: ["INBOX", "UNREAD"])], isInitialSync: true)
        try await repository.setAttention(.handled, for: id)

        try await repository.upsert([message("2:44:INBOX", labels: ["INBOX"])], isInitialSync: false)

        let stored = try #require(await repository.thread(id))
        #expect(stored.attention == .handled)
        #expect(stored.latestMessageID == "2:44:INBOX")
        #expect(stored.isUnread == false)
        // Known by its new id now, so changes reported for it apply.
        let changed = try await repository.applyRemoteChanges([
            RemoteMessageChange(threadID: id, messageID: "2:44:INBOX", currentLabelIds: ["INBOX", "STARRED"], removed: false),
        ])
        #expect(changed == 1)
    }

    @Test func sameMessageNeedsMatchingHeadersAndARealCopy() {
        let item = Correspondence(id: ThreadID(account: "a", providerID: "t"), sender: "S", organization: "", subject: "s",
                                  excerpt: "", body: "", messageIdHeader: "<ABC@x.test>", latestMessageID: "new",
                                  receivedAt: now, dueAt: nil, reason: "", attention: .quiet)
        #expect(SwiftDataMailRepository.isSameMessage(incoming: item, existingMessageID: "old", existingHeader: "abc@x.test"))
        #expect(!SwiftDataMailRepository.isSameMessage(incoming: item, existingMessageID: "old", existingHeader: "other@x.test"))
        // A copy Corres saved itself always gives way in full.
        #expect(!SwiftDataMailRepository.isSameMessage(incoming: item, existingMessageID: nil, existingHeader: "abc@x.test"))
    }
}
