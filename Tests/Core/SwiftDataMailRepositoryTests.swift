import Foundation
import SwiftData
import Testing
@testable import CorresCore

struct SwiftDataMailRepositoryTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema(CorresSchemaV1.models)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, migrationPlan: CorresMigrationPlan.self, configurations: [configuration])
    }

    @Test func seedIfNeededPopulatesOnceAndIsIdempotent() async throws {
        let repository = SwiftDataMailRepository(modelContainer: try makeContainer())
        try await repository.seedIfNeeded(now: now)
        let count = try await repository.threads().count
        #expect(count > 0)
        try await repository.setAttention(.handled, for: ThreadID(account: "sample", providerID: "sample-0"))
        try await repository.seedIfNeeded(now: now) // must not re-seed over the change
        let unchanged = try await repository.threads().first { $0.id.providerID == "sample-0" }
        #expect(unchanged?.attention == .handled)
    }

    @Test func mutationsPersistAcrossANewRepositoryInstanceOnTheSameContainer() async throws {
        let container = try makeContainer()
        let first = SwiftDataMailRepository(modelContainer: container)
        try await first.seedIfNeeded(now: now)
        let target = try #require(await first.threads().first)
        try await first.setPinned(true, for: target.id)
        try await first.snooze(target.id, until: now.addingTimeInterval(3600))

        // A fresh actor over the SAME container simulates relaunching the app.
        let second = SwiftDataMailRepository(modelContainer: container)
        let reloaded = try #require(await second.threads().first { $0.id == target.id })
        #expect(reloaded.isPinned == true)
        #expect(reloaded.snoozedUntil == now.addingTimeInterval(3600))
    }

    @Test func replyingPersistsTheWaitingTransitionWithEvidence() async throws {
        let repository = SwiftDataMailRepository(modelContainer: try makeContainer())
        try await repository.seedIfNeeded(now: now)
        let original = try #require(await repository.threads().first { $0.attention == .needsYou })
        let draft = Draft(kind: .reply, threadID: original.id, to: original.sender, subject: "Re: \(original.subject)", body: "On it.")
        let updated = try await repository.send(draft, sentAt: now, realThreadID: nil)
        #expect(updated.attention == .waiting)
        #expect(updated.reason.contains("replied"))
    }

    @Test func newDraftCreatesATrimmedWaitingConversation() async throws {
        let repository = SwiftDataMailRepository(modelContainer: try makeContainer())
        try await repository.seedIfNeeded(now: now)
        let before = try await repository.threads().count
        let draft = Draft(kind: .new, to: "  Nadia Osei  ", subject: "  Introduction  ", body: "Hello.")
        let created = try await repository.send(draft, sentAt: now, realThreadID: nil)
        #expect(created.sender == "Nadia Osei")
        #expect(created.subject == "Introduction")
        #expect(created.attention == .waiting)
        #expect(try await repository.threads().count == before + 1)
    }

    /// Attachments are stored as one JSON-encoded column (`attachmentsData`),
    /// not individual fields, the same choice `PersistedOutboxEntry` already
    /// made for `Draft`; this is what actually exercises the encode/decode
    /// round trip through a real SwiftData save and a fresh actor instance.
    @Test func attachmentsRoundTripAcrossRelaunch() async throws {
        let container = try makeContainer()
        let first = SwiftDataMailRepository(modelContainer: container)
        let attachment = MailAttachment(id: "att-1", filename: "invoice.pdf", mimeType: "application/pdf", sizeBytes: 48_213)
        let withAttachment = Correspondence(
            id: ThreadID(account: "me@example.com", providerID: "thread-att"),
            sender: "Billing", senderEmail: "billing@example.com", organization: "Example",
            subject: "Your invoice", excerpt: "Attached", body: "Attached",
            receivedAt: now, dueAt: nil, reason: "Unread in Gmail.", attention: .needsYou,
            attachments: [attachment])
        try await first.upsert([withAttachment], isInitialSync: true)

        let second = SwiftDataMailRepository(modelContainer: container)
        let reloaded = try #require(await second.threads().first { $0.id == withAttachment.id })
        #expect(reloaded.attachments == [attachment])
    }

    /// Backs Archive and Trash (App layer): both end with this after telling
    /// Gmail, or immediately for a sample thread with no Gmail account to tell.
    @Test func removeDropsExactlyOneThreadAndPersistsAcrossRelaunch() async throws {
        let container = try makeContainer()
        let first = SwiftDataMailRepository(modelContainer: container)
        try await first.seedIfNeeded(now: now)
        let before = try await first.threads()
        let target = try #require(before.first)
        try await first.remove(target.id)

        let second = SwiftDataMailRepository(modelContainer: container)
        let after = try await second.threads()
        #expect(after.count == before.count - 1)
        #expect(!after.contains { $0.id == target.id })
    }

    @Test func removingAMissingThreadThrows() async throws {
        let repository = SwiftDataMailRepository(modelContainer: try makeContainer())
        try await repository.seedIfNeeded(now: now)
        let ghost = ThreadID(account: "sample", providerID: "does-not-exist")
        await #expect(throws: RepositoryError.threadNotFound) {
            try await repository.remove(ghost)
        }
    }

    @Test func sendingToAMissingThreadThrows() async throws {
        let repository = SwiftDataMailRepository(modelContainer: try makeContainer())
        try await repository.seedIfNeeded(now: now)
        let ghost = ThreadID(account: "sample", providerID: "does-not-exist")
        let draft = Draft(kind: .reply, threadID: ghost, to: "Someone", subject: "Re: Gone", body: "")
        await #expect(throws: RepositoryError.threadNotFound) {
            _ = try await repository.send(draft, sentAt: now, realThreadID: nil)
        }
    }

    @Test func resetToSampleDataDiscardsChangesAndRestoresOriginalState() async throws {
        let repository = SwiftDataMailRepository(modelContainer: try makeContainer())
        try await repository.seedIfNeeded(now: now)
        let original = try await repository.threads()
        let target = try #require(original.first)
        try await repository.setAttention(.handled, for: target.id)
        try await repository.resetToSampleData(now: now)
        let afterReset = try await repository.threads()
        #expect(afterReset.count == original.count)
        #expect(afterReset.first { $0.id == target.id }?.attention == target.attention)
    }

    @Test func deleteSampleDataRemovesOnlySampleThreadsRealMailUntouched() async throws {
        let repository = SwiftDataMailRepository(modelContainer: try makeContainer())
        try await repository.seedIfNeeded(now: now)
        let sampleCountBefore = try await repository.threads().count
        #expect(sampleCountBefore > 0)
        let realThread = Correspondence(
            id: ThreadID(account: "gmail:me@example.com", providerID: "real-1"),
            sender: "Real Sender", senderEmail: "real@example.com", organization: "Example", subject: "Real mail",
            excerpt: "hi", body: "hi", receivedAt: now, dueAt: nil, reason: "Unread in Gmail.", attention: .needsYou)
        try await repository.upsert([realThread], isInitialSync: true)

        try await repository.deleteSampleData()

        let afterward = try await repository.threads()
        #expect(!afterward.contains { $0.id.account == "sample" })
        #expect(afterward.contains { $0.id == realThread.id })
        #expect(afterward.count == 1)
    }

    @Test func upsertInsertsUnseenThreadsAndIgnoresARefetchOfTheSameMessage() async throws {
        let repository = SwiftDataMailRepository(modelContainer: try makeContainer())
        try await repository.seedIfNeeded(now: now)
        let existing = try #require(await repository.threads().first)
        try await repository.setAttention(.handled, for: existing.id)
        try await repository.setPinned(true, for: existing.id)

        // No latestMessageID set (matches `existing`'s, both nil), so this is
        // indistinguishable from a re-fetch of a message already known, not
        // a genuinely new one, and must not touch the thread.
        let sameMessageRefetched = Correspondence(
            id: existing.id, sender: "Someone Else", organization: "Different", subject: "Changed",
            excerpt: "changed", body: "changed", receivedAt: now, dueAt: nil,
            reason: "Unread in Gmail.", attention: .needsYou)
        let brandNew = Correspondence(
            id: ThreadID(account: "gmail:me@example.com", providerID: "new-1"),
            sender: "New Sender", organization: "Example", subject: "New Subject",
            excerpt: "hello", body: "hello", receivedAt: now, dueAt: nil,
            reason: "Unread in Gmail.", attention: .needsYou)

        let insertedCount = try await repository.upsert([sameMessageRefetched, brandNew], isInitialSync: false)
        #expect(insertedCount == 1)

        let afterward = try await repository.threads()
        let unchanged = try #require(afterward.first { $0.id == existing.id })
        #expect(unchanged.attention == .handled)
        #expect(unchanged.isPinned == true)
        #expect(unchanged.subject == existing.subject)
        #expect(afterward.contains { $0.id == brandNew.id })
    }

    /// The bug this segment fixes: a reply to a thread Corres started (via
    /// OutboxService's local placeholder, which has no real latestMessageID
    /// yet) must actually surface, not sit silently ignored forever.
    @Test func upsertUpdatesAnExistingThreadWhenAGenuinelyNewMessageArrives() async throws {
        let repository = SwiftDataMailRepository(modelContainer: try makeContainer())
        let placeholder = Correspondence(
            id: ThreadID(account: "me@example.com", providerID: "thread-1"),
            sender: "Ridu", organization: "", subject: "Hello",
            excerpt: "Hi Ridu", body: "Hi Ridu", receivedAt: now, dueAt: nil,
            reason: "You started this conversation. Waiting for a response.", attention: .waiting)
        try await repository.upsert([placeholder], isInitialSync: true)
        try await repository.setPinned(true, for: placeholder.id)

        // Our own sent copy shows back up in a later Sent sync: content
        // should fill in, but Waiting must not be downgraded just because
        // Gmail says our own sent mail is "read."
        let ownSentCopy = Correspondence(
            id: placeholder.id, sender: "Me", senderEmail: "me@example.com", organization: "",
            subject: "Hello", excerpt: "Hi Ridu", body: "Hi Ridu", latestMessageID: "msg-sent",
            receivedAt: now, dueAt: nil, reason: "Already read in Gmail.", attention: .quiet)
        try await repository.upsert([ownSentCopy], isInitialSync: false)
        let afterSentCopy = try #require(await repository.threads().first { $0.id == placeholder.id })
        #expect(afterSentCopy.attention == .waiting)
        #expect(afterSentCopy.isPinned == true)

        // Ridu actually replies: a genuinely new, inbound message. This must
        // surface as Needs You with her reply's own content, which is
        // exactly what silently never happened before this fix.
        let herReply = Correspondence(
            id: placeholder.id, sender: "Ridu", senderEmail: "ridu@example.com", organization: "",
            subject: "Re: Hello", excerpt: "Got it, thanks!", body: "Got it, thanks!", latestMessageID: "msg-reply",
            receivedAt: now.addingTimeInterval(60), dueAt: nil, reason: "Unread in Gmail.", attention: .needsYou)
        try await repository.upsert([herReply], isInitialSync: false)
        let afterReply = try #require(await repository.threads().first { $0.id == placeholder.id })
        #expect(afterReply.attention == .needsYou)
        #expect(afterReply.body == "Got it, thanks!")
        #expect(afterReply.isPinned == true) // manual facts still survive a real content update

        // A later re-sync of the exact same reply message must be a no-op.
        try await repository.upsert([herReply], isInitialSync: false)
        let afterRefetch = try #require(await repository.threads().first { $0.id == placeholder.id })
        #expect(afterRefetch.attention == .needsYou)
    }

    @Test func outboxEntryPersistsAcrossRelaunchAndStatusUpdatesInPlace() async throws {
        let container = try makeContainer()
        let first = SwiftDataMailRepository(modelContainer: container)
        let draft = Draft(kind: .new, to: "someone@example.com", subject: "Kickoff", body: "Hello.")
        let record = OutboxRecord(draft: draft, status: .pending, createdAt: now)
        try await first.saveOutboxEntry(record)

        // A fresh actor over the SAME container simulates relaunching the
        // app: the durable outbox exists precisely to survive that.
        let second = SwiftDataMailRepository(modelContainer: container)
        let resumed = try await second.outboxEntries()
        #expect(resumed.count == 1)
        #expect(resumed.first?.id == record.id)
        #expect(resumed.first?.status == .pending)
        #expect(resumed.first?.draft.subject == "Kickoff")

        // Re-saving the same id (e.g. a failed send) updates in place rather
        // than duplicating the entry.
        try await second.saveOutboxEntry(OutboxRecord(id: record.id, draft: draft, status: .failed, createdAt: now))
        let afterUpdate = try await second.outboxEntries()
        #expect(afterUpdate.count == 1)
        #expect(afterUpdate.first?.status == .failed)

        try await second.removeOutboxEntry(id: record.id)
        #expect(try await second.outboxEntries().isEmpty)
    }

    @Test func trustingASenderForImagesPersistsAndAppliesToLaterThreadsFromThem() async throws {
        let repository = SwiftDataMailRepository(modelContainer: try makeContainer())
        let firstMessage = Correspondence(
            id: ThreadID(account: "gmail:me@example.com", providerID: "5"), sender: "Newsletter", senderEmail: "news@example.com",
            organization: "Example", subject: "First issue", excerpt: "hi", body: "hi", receivedAt: now, dueAt: nil,
            reason: "Unread in Gmail.", attention: .needsYou)
        try await repository.upsert([firstMessage], isInitialSync: true)

        try await repository.trustSenderImages(forSenderEmail: "news@example.com", account: "gmail:me@example.com")
        #expect(try await repository.threads().first?.imagesTrusted == true)

        let secondMessage = Correspondence(
            id: ThreadID(account: "gmail:me@example.com", providerID: "6"), sender: "Newsletter", senderEmail: "news@example.com",
            organization: "Example", subject: "Second issue", excerpt: "hi", body: "hi", receivedAt: now, dueAt: nil,
            reason: "Unread in Gmail.", attention: .needsYou)
        try await repository.upsert([secondMessage], isInitialSync: false)
        let afterSecondIssue = try await repository.threads()
        #expect(afterSecondIssue.first { $0.id == secondMessage.id }?.imagesTrusted == true)
    }
}
