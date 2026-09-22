import Foundation
import Testing
@testable import CorresCore

struct CorresCoreTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func briefReflectsAttentionChangesAndDeadlineWindow() async throws {
        let repository = SampleMailRepository(now: now)
        let original = await repository.threads()
        let before = BriefSnapshot(threads: original, now: now)
        #expect(before.needsYou == 3)
        #expect(before.waiting == 2)
        #expect(before.upcoming == 2)
        try await repository.setAttention(.handled, for: original[0].id)
        let after = BriefSnapshot(threads: await repository.threads(), now: now)
        #expect(after.needsYou == 2)
        #expect(after.upcoming == 1)
        #expect(after.waiting == before.waiting)
    }

    @Test func deadlinesExcludePastAndBeyondHorizon() {
        let threads = SampleCorrespondence.make(now: now)
        #expect(BriefSnapshot(threads: threads, now: now, horizon: 7 * 3600).upcoming == 0)
        #expect(BriefSnapshot(threads: threads, now: now, horizon: 8 * 3600).upcoming == 1)
        #expect(BriefSnapshot(threads: threads, now: now.addingTimeInterval(21 * 3600)).upcoming == 0)
    }

    @Test func searchCombinesAttentionWithTrimmedCaseInsensitiveQuery() {
        let threads = SampleCorrespondence.make(now: now)
        #expect(MailQuery.filter(threads, attention: .needsYou, search: "  MAYA \n").count == 1)
        #expect(MailQuery.filter(threads, attention: .waiting, search: "Maya").isEmpty)
        #expect(MailQuery.filter(threads, search: "Fieldwork").first?.sender == "Oliver Grant")
        #expect(MailQuery.filter(threads, search: "   ").count == threads.count)
        #expect(MailQuery.filter(threads, search: "not-a-person").isEmpty)
    }

    @Test func unknownAccountCannotMutateAnotherAccountsThread() async throws {
        let repository = SampleMailRepository(now: now)
        let original = await repository.threads()
        let wrongAccount = ThreadID(account: "another-account", providerID: original[0].id.providerID)
        await #expect(throws: RepositoryError.threadNotFound) {
            try await repository.setAttention(.handled, for: wrongAccount)
        }
        #expect(await repository.threads() == original)
    }

    @Test func concurrentIndependentChangesAreNotLost() async throws {
        let repository = SampleMailRepository(now: now)
        let original = await repository.threads()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for thread in original {
                group.addTask { try await repository.setAttention(.handled, for: thread.id) }
            }
            try await group.waitForAll()
        }
        #expect(await repository.threads().allSatisfy { $0.attention == .handled })
    }

    @Test func attentionCanBeRestoredAndNewSessionsReset() async throws {
        let repository = SampleMailRepository(now: now)
        let original = await repository.threads()
        try await repository.setAttention(.handled, for: original[0].id)
        try await repository.setAttention(original[0].attention, for: original[0].id)
        #expect(await repository.threads() == original)
        #expect(await SampleMailRepository(now: now).threads() == original)
    }

    @Test func threadDataRoundTripsWithoutLosingIdentityOrDates() throws {
        let threads = SampleCorrespondence.make(now: now)
        let encoded = try JSONEncoder().encode(threads)
        #expect(try JSONDecoder().decode([Correspondence].self, from: encoded) == threads)
    }

    @Test func replyingMovesTheThreadToWaitingWithEvidence() async throws {
        let repository = SampleMailRepository(now: now)
        let original = try #require(await repository.threads().first { $0.attention == .needsYou })
        let draft = Draft(kind: .reply, threadID: original.id, to: original.sender, subject: "Re: \(original.subject)", body: "On it.")
        let updated = try await repository.send(draft, sentAt: now, realThreadID: nil)
        #expect(updated.attention == .waiting)
        #expect(updated.reason.contains("replied"))
        let stored = try #require(await repository.threads().first { $0.id == original.id })
        #expect(stored.attention == .waiting)
    }

    @Test func newDraftWithNoThreadCreatesAWaitingConversation() async throws {
        let repository = SampleMailRepository(now: now)
        let before = await repository.threads().count
        let draft = Draft(kind: .new, to: "Nadia Osei", subject: "Introduction", body: "Hello.")
        let created = try await repository.send(draft, sentAt: now, realThreadID: nil)
        #expect(created.attention == .waiting)
        #expect(created.sender == "Nadia Osei")
        #expect(await repository.threads().count == before + 1)
    }

    @Test func newDraftSentViaGmailIsFiledUnderTheRealThreadIDNotASyntheticOne() async throws {
        let repository = SampleMailRepository(now: now)
        let draft = Draft(kind: .new, to: "someone@example.com", subject: "Kickoff", body: "Hello.")
        let realID = ThreadID(account: "gmail:me@example.com", providerID: "197abc")
        let created = try await repository.send(draft, sentAt: now, realThreadID: realID)
        #expect(created.id == realID)
        #expect(await repository.threads().contains { $0.id == realID })
    }

    @Test func sendingToAMissingThreadThrowsWithoutMutatingState() async throws {
        let repository = SampleMailRepository(now: now)
        let original = await repository.threads()
        let ghost = ThreadID(account: "sample", providerID: "does-not-exist")
        let draft = Draft(kind: .reply, threadID: ghost, to: "Someone", subject: "Re: Gone", body: "")
        await #expect(throws: RepositoryError.threadNotFound) {
            _ = try await repository.send(draft, sentAt: now, realThreadID: nil)
        }
        #expect(await repository.threads() == original)
    }

    @Test func snoozedThreadsAreExcludedFromActiveViewsAndCountsUntilTheyExpire() async throws {
        let repository = SampleMailRepository(now: now)
        let target = try #require(await repository.threads().first { $0.attention == .needsYou })
        try await repository.snooze(target.id, until: now.addingTimeInterval(3600))
        let threads = await repository.threads()

        #expect(!MailQuery.filter(threads, attention: .needsYou, now: now).contains { $0.id == target.id })
        #expect(BriefSnapshot(threads: threads, now: now).needsYou < BriefSnapshot(threads: threads, now: now.addingTimeInterval(7200)).needsYou)
        #expect(MailQuery.filter(threads, attention: .needsYou, now: now.addingTimeInterval(7200)).contains { $0.id == target.id })
    }

    @Test func snoozedThreadsStayVisibleInMailAndInSearchResults() async throws {
        let repository = SampleMailRepository(now: now)
        let target = try #require(await repository.threads().first { $0.attention == .needsYou })
        try await repository.snooze(target.id, until: now.addingTimeInterval(3600))
        let threads = await repository.threads()

        // Mail (no attention filter) is the catch-all view: still shows it.
        #expect(MailQuery.filter(threads, now: now).contains { $0.id == target.id })
        // Searching within its own curated queue still finds it.
        #expect(MailQuery.filter(threads, attention: .needsYou, search: target.sender, now: now)
            .contains { $0.id == target.id })
    }

    @Test func pinnedThreadsSortBeforeUnpinnedRegardlessOfRecency() {
        var threads = SampleCorrespondence.make(now: now)
        let oldestIndex = threads.count - 1
        threads[oldestIndex].isPinned = true
        let sorted = MailQuery.filter(threads, now: now)
        #expect(sorted.first?.id == threads[oldestIndex].id)
    }

    @Test func upsertInsertsOnlyPreviouslyUnseenThreadsAndNeverTouchesExisting() async throws {
        let repository = SampleMailRepository(now: now)
        let existing = try #require(await repository.threads().first)
        try await repository.setAttention(.handled, for: existing.id)
        try await repository.setPinned(true, for: existing.id)

        // Re-syncing the SAME thread with different incoming content (as a
        // real Gmail sync would, if it ever fetched a thread already known)
        // must not touch the user's manual attention/pin decision.
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
        #expect(unchanged.subject == existing.subject) // content untouched, not overwritten
        #expect(afterward.contains { $0.id == brandNew.id })
    }

    @Test func deleteSampleDataRemovesOnlySampleThreadsRealMailUntouched() async throws {
        let repository = SampleMailRepository(now: now)
        let sampleCountBefore = await repository.threads().count
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

    @Test func initialSyncAutoApprovesEverySenderAlreadyInTheInbox() async throws {
        let repository = SampleMailRepository(items: [])
        let fromNewAccount = Correspondence(
            id: ThreadID(account: "gmail:me@example.com", providerID: "1"), sender: "Jane Doe", senderEmail: "jane@example.com",
            organization: "Example", subject: "Hello", excerpt: "hi", body: "hi", receivedAt: now, dueAt: nil,
            reason: "Unread in Gmail.", attention: .needsYou)
        try await repository.upsert([fromNewAccount], isInitialSync: true)
        let threads = try await repository.threads()
        #expect(threads.first?.senderDecision == .approved)
        // A sender established at the first sync is never quarantined: their
        // mail must show up in ordinary (non-search) browsing immediately.
        #expect(MailQuery.filter(threads, now: now).contains { $0.id == fromNewAccount.id })
    }

    @Test func incrementalSyncHoldsAGenuinelyNewSenderForScreeningButKeepsItSearchable() async throws {
        let repository = SampleMailRepository(items: [])
        let fromUnknownSender = Correspondence(
            id: ThreadID(account: "gmail:me@example.com", providerID: "2"), sender: "New Person", senderEmail: "newperson@example.com",
            organization: "Example", subject: "First contact", excerpt: "hi", body: "hi", receivedAt: now, dueAt: nil,
            reason: "Unread in Gmail.", attention: .needsYou)
        try await repository.upsert([fromUnknownSender], isInitialSync: false)
        let threads = try await repository.threads()
        #expect(threads.first?.senderDecision == .pending)
        #expect(!MailQuery.filter(threads, now: now).contains { $0.id == fromUnknownSender.id })
        #expect(!MailQuery.filter(threads, attention: .needsYou, now: now).contains { $0.id == fromUnknownSender.id })
        // Held from ordinary browsing, same as HEY's Screener, but never
        // truly hidden: an explicit search still finds it, matching the
        // existing snooze precedent.
        #expect(MailQuery.filter(threads, search: "First contact", now: now).contains { $0.id == fromUnknownSender.id })
    }

    @Test func approvingOrBlockingASenderAppliesToEveryThreadFromThemAtOnce() async throws {
        let repository = SampleMailRepository(items: [])
        let first = Correspondence(
            id: ThreadID(account: "gmail:me@example.com", providerID: "3"), sender: "New Person", senderEmail: "newperson@example.com",
            organization: "Example", subject: "First", excerpt: "hi", body: "hi", receivedAt: now, dueAt: nil,
            reason: "Unread in Gmail.", attention: .needsYou)
        let second = Correspondence(
            id: ThreadID(account: "gmail:me@example.com", providerID: "4"), sender: "New Person", senderEmail: "newperson@example.com",
            organization: "Example", subject: "Second", excerpt: "hi", body: "hi", receivedAt: now, dueAt: nil,
            reason: "Unread in Gmail.", attention: .needsYou)
        try await repository.upsert([first, second], isInitialSync: false)

        try await repository.setSenderDecision(.approved, forSenderEmail: "newperson@example.com", account: "gmail:me@example.com")
        let approved = try await repository.threads()
        #expect(approved.allSatisfy { $0.senderDecision == .approved })
        #expect(MailQuery.filter(approved, now: now).count == 2)

        try await repository.setSenderDecision(.blocked, forSenderEmail: "newperson@example.com", account: "gmail:me@example.com")
        let blocked = try await repository.threads()
        #expect(blocked.allSatisfy { $0.senderDecision == .blocked })
        #expect(MailQuery.filter(blocked, now: now).isEmpty)
    }

    @Test func trustingASenderForImagesAppliesToExistingAndFutureThreadsFromThem() async throws {
        let repository = SampleMailRepository(items: [])
        let firstMessage = Correspondence(
            id: ThreadID(account: "gmail:me@example.com", providerID: "5"), sender: "Newsletter", senderEmail: "news@example.com",
            organization: "Example", subject: "First issue", excerpt: "hi", body: "hi", receivedAt: now, dueAt: nil,
            reason: "Unread in Gmail.", attention: .needsYou)
        try await repository.upsert([firstMessage], isInitialSync: true)
        #expect(try await repository.threads().first?.imagesTrusted == false)

        try await repository.trustSenderImages(forSenderEmail: "news@example.com", account: "gmail:me@example.com")
        let afterTrust = try await repository.threads()
        #expect(afterTrust.first?.imagesTrusted == true)

        // A later issue from the same, already-trusted sender arrives
        // already trusted, the same propagation SenderDecision already uses.
        let secondMessage = Correspondence(
            id: ThreadID(account: "gmail:me@example.com", providerID: "6"), sender: "Newsletter", senderEmail: "news@example.com",
            organization: "Example", subject: "Second issue", excerpt: "hi", body: "hi", receivedAt: now, dueAt: nil,
            reason: "Unread in Gmail.", attention: .needsYou)
        try await repository.upsert([secondMessage], isInitialSync: false)
        let afterSecondIssue = try await repository.threads()
        #expect(afterSecondIssue.first { $0.id == secondMessage.id }?.imagesTrusted == true)
    }
}
