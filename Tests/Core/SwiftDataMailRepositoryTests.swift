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

    @Test func upsertInsertsOnlyPreviouslyUnseenThreadsAndNeverTouchesExisting() async throws {
        let repository = SwiftDataMailRepository(modelContainer: try makeContainer())
        try await repository.seedIfNeeded(now: now)
        let existing = try #require(await repository.threads().first)
        try await repository.setAttention(.handled, for: existing.id)
        try await repository.setPinned(true, for: existing.id)

        let sameIDDifferentContent = Correspondence(
            id: existing.id, sender: "Someone Else", organization: "Different", subject: "Changed",
            excerpt: "changed", body: "changed", receivedAt: now, dueAt: nil,
            reason: "Unread in Gmail.", attention: .needsYou)
        let brandNew = Correspondence(
            id: ThreadID(account: "gmail:me@example.com", providerID: "new-1"),
            sender: "New Sender", organization: "Example", subject: "New Subject",
            excerpt: "hello", body: "hello", receivedAt: now, dueAt: nil,
            reason: "Unread in Gmail.", attention: .needsYou)

        let insertedCount = try await repository.upsert([sameIDDifferentContent, brandNew], isInitialSync: false)
        #expect(insertedCount == 1)

        let afterward = try await repository.threads()
        let unchanged = try #require(afterward.first { $0.id == existing.id })
        #expect(unchanged.attention == .handled)
        #expect(unchanged.isPinned == true)
        #expect(unchanged.subject == existing.subject)
        #expect(afterward.contains { $0.id == brandNew.id })
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
}
