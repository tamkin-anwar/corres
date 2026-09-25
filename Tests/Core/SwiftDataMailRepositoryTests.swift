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

    @Test func setUnreadTogglesIndependentlyOfAttentionAndPersistsAcrossRelaunch() async throws {
        let container = try makeContainer()
        let first = SwiftDataMailRepository(modelContainer: container)
        try await first.seedIfNeeded(now: now)
        let target = try #require(await first.threads().first)
        let updated = try await first.setUnread(true, for: target.id)
        #expect(updated.isUnread == true)
        #expect(updated.attention == target.attention)

        let second = SwiftDataMailRepository(modelContainer: container)
        let reloaded = try #require(await second.threads().first { $0.id == target.id })
        #expect(reloaded.isUnread == true)
    }

    @Test func setLabelIdsReplacesTheFullSetAndPersistsAcrossRelaunch() async throws {
        let container = try makeContainer()
        let first = SwiftDataMailRepository(modelContainer: container)
        try await first.seedIfNeeded(now: now)
        let target = try #require(await first.threads().first)
        try await first.setLabelIds(["Label_1", "Label_2"], for: target.id)

        let second = SwiftDataMailRepository(modelContainer: container)
        let reloaded = try #require(await second.threads().first { $0.id == target.id })
        #expect(reloaded.labelIds == ["Label_1", "Label_2"])
    }

    /// Labels reflect genuine Gmail mailbox-organization state, not a
    /// triage decision Corres invented (unlike attention/reason): unlike
    /// isUnread, a genuinely new message updates labelIds regardless of
    /// whether it's our own sent copy or a real inbound reply.
    @Test func upsertUpdatesLabelIdsRegardlessOfWhoSentTheMessage() async throws {
        let repository = SwiftDataMailRepository(modelContainer: try makeContainer())
        let placeholder = Correspondence(
            id: ThreadID(account: "me@example.com", providerID: "thread-labels"),
            sender: "Ridu", organization: "", subject: "Hello", excerpt: "Hi", body: "Hi",
            receivedAt: now, dueAt: nil, reason: "You started this conversation. Waiting for a response.",
            attention: .waiting, labelIds: [])
        try await repository.upsert([placeholder], isInitialSync: true)

        let ownSentCopy = Correspondence(
            id: placeholder.id, sender: "Me", senderEmail: "me@example.com", organization: "",
            subject: "Hello", excerpt: "Hi", body: "Hi", latestMessageID: "msg-sent",
            receivedAt: now, dueAt: nil, reason: "Already read in Gmail.", attention: .quiet,
            labelIds: ["SENT", "Label_1"])
        try await repository.upsert([ownSentCopy], isInitialSync: false)

        let afterSentCopy = try #require(await repository.threads().first { $0.id == placeholder.id })
        #expect(afterSentCopy.labelIds == ["SENT", "Label_1"])
    }

    /// The reply-sync fix (Batch 17) already covers content/attention
    /// updating on a genuine new message versus our own sent copy
    /// preserving it; this confirms isUnread rides the same two paths.
    @Test func upsertUpdatesIsUnreadOnlyForAGenuineInboundMessage() async throws {
        let repository = SwiftDataMailRepository(modelContainer: try makeContainer())
        let placeholder = Correspondence(
            id: ThreadID(account: "me@example.com", providerID: "thread-unread"),
            sender: "Ridu", organization: "", subject: "Hello", excerpt: "Hi", body: "Hi",
            receivedAt: now, dueAt: nil, reason: "You started this conversation. Waiting for a response.",
            attention: .waiting, isUnread: false)
        try await repository.upsert([placeholder], isInitialSync: true)

        let ownSentCopy = Correspondence(
            id: placeholder.id, sender: "Me", senderEmail: "me@example.com", organization: "",
            subject: "Hello", excerpt: "Hi", body: "Hi", latestMessageID: "msg-sent",
            receivedAt: now, dueAt: nil, reason: "Already read in Gmail.", attention: .quiet, isUnread: false)
        try await repository.upsert([ownSentCopy], isInitialSync: false)

        let herReply = Correspondence(
            id: placeholder.id, sender: "Ridu", senderEmail: "ridu@example.com", organization: "",
            subject: "Re: Hello", excerpt: "Got it", body: "Got it", latestMessageID: "msg-reply",
            receivedAt: now.addingTimeInterval(60), dueAt: nil, reason: "Unread in Gmail.",
            attention: .needsYou, isUnread: true)
        try await repository.upsert([herReply], isInitialSync: false)

        let afterReply = try #require(await repository.threads().first { $0.id == placeholder.id })
        #expect(afterReply.isUnread == true)
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

    /// Regression test for a real race: `SemanticTriageService` snapshots a
    /// thread's attention, then hands it to an on-device model whose
    /// inference is genuinely slow enough that the person can act on the
    /// same thread before the result comes back — mark it Handled, move it
    /// to Waiting. `applySemanticTriage` must not blindly stomp that
    /// decision back to `.quiet` just because the (now-stale) model result
    /// says the message didn't need a reply; it should only ever apply the
    /// downgrade if the thread is still sitting exactly where triage found
    /// it (`.needsYou`).
    @Test func semanticTriageDoesNotOverwriteADecisionMadeWhileItWasThinking() async throws {
        let repository = SwiftDataMailRepository(modelContainer: try makeContainer())
        let id = ThreadID(account: "gmail:me@example.com", providerID: "7")
        let message = Correspondence(
            id: id, sender: "Newsletter", organization: "Example", subject: "Marketing blast",
            excerpt: "hi", body: "hi", latestMessageID: "msg-1", receivedAt: now, dueAt: nil,
            reason: "Unread in Gmail.", attention: .needsYou)
        try await repository.upsert([message], isInitialSync: true)

        // The person acts on the thread — moves it to Handled — while
        // inference is still in flight for the same thread.
        try await repository.setAttention(.handled, for: id)

        // The (now-stale) triage result arrives and says it didn't need a
        // reply, which would normally downgrade a `.needsYou` thread to
        // `.quiet`.
        try await repository.applySemanticTriage(id, from: .needsYou, to: .quiet,
                                                 reason: "Marketing newsletter, no action needed.", messageID: "msg-1")

        let updated = try await repository.threads().first { $0.id == id }
        #expect(updated?.attention == .handled)
        #expect(updated?.reason == "Unread in Gmail.")
        // The bookkeeping still applies regardless, so this exact message
        // isn't re-triaged forever just because its result arrived too late.
        #expect(updated?.triagedMessageID == "msg-1")
    }

    @Test func semanticTriageDowngradesAttentionWhenTheThreadIsStillUntouched() async throws {
        let repository = SwiftDataMailRepository(modelContainer: try makeContainer())
        let id = ThreadID(account: "gmail:me@example.com", providerID: "8")
        let message = Correspondence(
            id: id, sender: "Newsletter", organization: "Example", subject: "Marketing blast",
            excerpt: "hi", body: "hi", latestMessageID: "msg-1", receivedAt: now, dueAt: nil,
            reason: "Unread in Gmail.", attention: .needsYou)
        try await repository.upsert([message], isInitialSync: true)

        try await repository.applySemanticTriage(id, from: .needsYou, to: .quiet,
                                                 reason: "Marketing newsletter, no action needed.", messageID: "msg-1")

        let updated = try await repository.threads().first { $0.id == id }
        #expect(updated?.attention == .quiet)
        #expect(updated?.reason == "Marketing newsletter, no action needed.")
    }

    @Test func semanticTriageCanPromoteAnUntouchedUpdateButNotOneThePersonHandled() async throws {
        let repository = SwiftDataMailRepository(modelContainer: try makeContainer())
        let billID = ThreadID(account: "gmail:me@example.com", providerID: "9")
        let alertID = ThreadID(account: "gmail:me@example.com", providerID: "10")
        let bill = Correspondence(
            id: billID, sender: "Utility", organization: "Example", subject: "Payment due Friday",
            excerpt: "hi", body: "hi", latestMessageID: "msg-9", receivedAt: now, dueAt: nil,
            reason: InboxClassifier.BulkKind.updates.reason, attention: .quiet, isUnread: true)
        let alert = Correspondence(
            id: alertID, sender: "Bank", organization: "Example", subject: "New sign-in",
            excerpt: "hi", body: "hi", latestMessageID: "msg-10", receivedAt: now, dueAt: nil,
            reason: InboxClassifier.BulkKind.updates.reason, attention: .quiet, isUnread: true)
        try await repository.upsert([bill, alert], isInitialSync: true)
        try await repository.setAttention(.handled, for: alertID)

        try await repository.applySemanticTriage(billID, from: .quiet, to: .needsYou, reason: "Payment due Friday.", messageID: "msg-9")
        try await repository.applySemanticTriage(alertID, from: .quiet, to: .needsYou, reason: "Unrecognized sign-in.", messageID: "msg-10")

        let threads = try await repository.threads()
        #expect(threads.first { $0.id == billID }?.attention == .needsYou)
        #expect(threads.first { $0.id == alertID }?.attention == .handled)
    }

    /// Someone this account has written to lands in Needs You even when
    /// Gmail filed their mail under Updates; their newsletter doesn't, and a
    /// stranger's automated update doesn't either.
    @Test func mailFromSomeoneYouveWrittenToIsCorrespondence() async throws {
        let repository = SwiftDataMailRepository(modelContainer: try makeContainer())
        let me = "me@example.com"
        func message(_ n: Int, from sender: String, to: [String] = ["me@example.com"], labels: [String] = [],
                     unsubscribe: String? = nil, unread: Bool = true) -> Correspondence {
            let automated = Correspondence.isAutomated(listUnsubscribeMailto: nil, listUnsubscribeURL: unsubscribe, senderEmail: sender)
            let (attention, reason) = InboxClassifier.initialAttention(isUnread: unread, labelIds: labels, looksAutomated: automated)
            return Correspondence(id: ThreadID(account: me, providerID: "\(n)"), sender: sender, senderEmail: sender,
                                  organization: "", subject: "s\(n)", excerpt: "", body: "", latestMessageID: "m\(n)",
                                  receivedAt: now, dueAt: nil, reason: reason, attention: attention, isUnread: unread,
                                  labelIds: labels, toRecipients: to, listUnsubscribeURL: unsubscribe)
        }
        try await repository.upsert([message(1, from: me, to: ["Friend@Example.com"], labels: ["SENT"], unread: false)], isInitialSync: true)
        try await repository.upsert([
            message(2, from: "friend@example.com", labels: ["INBOX", "UNREAD", "CATEGORY_UPDATES"]),
            message(3, from: "friend@example.com", labels: ["INBOX", "UNREAD"], unsubscribe: "https://example.com/u"),
            message(4, from: "alerts@stranger.com", labels: ["INBOX", "UNREAD", "CATEGORY_UPDATES"]),
        ], isInitialSync: true)

        let byID = Dictionary(uniqueKeysWithValues: try await repository.threads().map { ($0.id.providerID, $0) })
        #expect(byID["2"]?.attention == .needsYou)
        #expect(byID["2"]?.reason == InboxClassifier.correspondentReason)
        #expect(byID["3"]?.attention == .quiet)
        #expect(byID["4"]?.attention == .quiet)
    }

    /// Changes made in Gmail's own app, on the web, or in another client
    /// show up here: read state mirrors in place without moving the thread
    /// out of Needs You, an archive elsewhere removes it, and a change to
    /// an older message or an unknown thread is ignored.
    @Test func remoteChangesMirrorReadArchiveAndIgnoreStaleMessages() async throws {
        let repository = SwiftDataMailRepository(modelContainer: try makeContainer())
        let account = "me@example.com"
        func thread(_ n: Int) -> Correspondence {
            Correspondence(id: ThreadID(account: account, providerID: "t\(n)"), sender: "S", senderEmail: "s@x.test",
                           organization: "", subject: "s", excerpt: "", body: "", latestMessageID: "m\(n)",
                           receivedAt: now, dueAt: nil, reason: InboxClassifier.personalUnreadReason,
                           attention: .needsYou, isUnread: true, labelIds: ["INBOX", "UNREAD"])
        }
        try await repository.upsert([thread(1), thread(2), thread(3)], isInitialSync: true)

        let changed = try await repository.applyRemoteChanges([
            RemoteMessageChange(threadID: ThreadID(account: account, providerID: "t1"), messageID: "m1",
                                currentLabelIds: ["INBOX"], removed: false),
            RemoteMessageChange(threadID: ThreadID(account: account, providerID: "t2"), messageID: "m2",
                                currentLabelIds: [], removed: true),
            RemoteMessageChange(threadID: ThreadID(account: account, providerID: "t3"), messageID: "older",
                                currentLabelIds: [], removed: true),
            RemoteMessageChange(threadID: ThreadID(account: account, providerID: "unknown"), messageID: "x",
                                currentLabelIds: [], removed: true),
        ])

        let byID = Dictionary(uniqueKeysWithValues: try await repository.threads().map { ($0.id.providerID, $0) })
        #expect(changed == 2)
        #expect(byID["t1"]?.isUnread == false)
        #expect(byID["t1"]?.attention == .needsYou)
        #expect(byID["t2"] == nil)
        #expect(byID["t3"] != nil)
    }

    /// The one-time repair for mailboxes synced under the old "every unread
    /// message is Needs You" rule: bulk mail still carrying that untouched
    /// default moves out, personal mail stays, and anything the person or
    /// the AI already decided on is left exactly as it is.
    @Test func reclassifyingLegacyDefaultsSortsOnlyUntouchedThreads() async throws {
        let repository = SwiftDataMailRepository(modelContainer: try makeContainer())
        func thread(_ n: Int, labels: [String] = [], unsubscribe: String? = nil, reason: String = InboxClassifier.legacyUnreadReason,
                    attention: Attention = .needsYou, excerpt: String = "hi") -> Correspondence {
            Correspondence(id: ThreadID(account: "gmail:me@example.com", providerID: "\(n)"), sender: "S\(n)",
                           senderEmail: "s\(n)@example.com", organization: "Example", subject: "Subject \(n)",
                           excerpt: excerpt, body: "hi", latestMessageID: "m\(n)", receivedAt: now, dueAt: nil,
                           reason: reason, attention: attention, isUnread: true, labelIds: labels,
                           listUnsubscribeURL: unsubscribe)
        }
        try await repository.upsert([
            thread(1, labels: ["INBOX", "UNREAD", "CATEGORY_PROMOTIONS"], excerpt: "Don&#39;t miss it &amp; more"),
            thread(2, unsubscribe: "https://example.com/unsub"),
            thread(3, labels: ["INBOX", "UNREAD", "CATEGORY_PERSONAL"]),
            thread(4, labels: ["CATEGORY_PROMOTIONS"], reason: "Asks you to confirm a date."),
            thread(5, labels: ["CATEGORY_PROMOTIONS"], attention: .handled),
        ], isInitialSync: true)

        let changed = try await repository.reclassifyLegacySyncDefaults()
        let byID = Dictionary(uniqueKeysWithValues: try await repository.threads().map { ($0.id.providerID, $0) })

        #expect(changed == 2)
        #expect(byID["1"]?.attention == .quiet)
        #expect(byID["1"]?.reason == InboxClassifier.BulkKind.promotions.reason)
        #expect(byID["1"]?.excerpt == "Don't miss it & more")
        #expect(byID["2"]?.attention == .quiet)
        #expect(byID["3"]?.attention == .needsYou)
        #expect(byID["3"]?.reason == InboxClassifier.personalUnreadReason)
        #expect(byID["4"]?.attention == .needsYou)
        #expect(byID["5"]?.attention == .handled)
    }
}
