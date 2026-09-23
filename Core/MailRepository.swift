import Foundation

/// Views never depend on Gmail DTOs or authentication credentials.
public protocol MailRepository: Sendable {
    func threads() async throws -> [Correspondence]
    /// Each returns the single thread as it now stands, the same pattern
    /// `send` already used: lets a caller splice just that one item into an
    /// in-memory list instead of re-fetching every thread just to find the
    /// one that changed (a real, measured inefficiency `MailStore.mutate`
    /// used to have, fixed 2026-09-21 to match `send`'s already-correct
    /// pattern; see Docs/Architecture.md's performance sweep entry).
    @discardableResult
    func setAttention(_ attention: Attention, for id: ThreadID) async throws -> Correspondence
    @discardableResult
    func setPinned(_ isPinned: Bool, for id: ThreadID) async throws -> Correspondence
    @discardableResult
    func snooze(_ id: ThreadID, until: Date?) async throws -> Correspondence
    /// Replying or forwarding moves the source thread to Waiting: the user has
    /// acted and is now the one expecting a response. A new draft opens a thread
    /// in the same state, since nothing has come back yet either way.
    ///
    /// `realThreadID` is the thread identity a real Gmail send already
    /// established (the App layer calls `GmailAPIClient.send` before this,
    /// and passes the real account + Gmail-assigned thread id it returned),
    /// used instead of inventing a local-only id for a brand-new draft: a
    /// later sync then recognizes the same thread rather than duplicating
    /// it. nil for a draft that stayed local-only (no Gmail account
    /// connected, or replying within an already-local/sample thread).
    func send(_ draft: Draft, sentAt: Date, realThreadID: ThreadID?) async throws -> Correspondence
    /// Removes a single thread outright, unconditionally, regardless of
    /// account. Used for Archive and Trash: both make a thread disappear
    /// from Corres entirely, the App layer already told Gmail about it (or
    /// there is no Gmail account, for a sample thread) before this is ever
    /// called, so there is nothing provider-specific left to decide here.
    /// Throws `RepositoryError.threadNotFound` if the thread is already gone.
    func remove(_ id: ThreadID) async throws
    /// Populates fictional starter data on first use. A no-op for a repository
    /// that is already seeded at construction (SampleMailRepository); real
    /// work for a persisted, empty store.
    func seedIfNeeded(now: Date) async throws
    /// Explicit, user-triggered return to a clean fictional demo state, not
    /// called automatically. The local-data equivalent of sign-out purge until
    /// real accounts exist to scope a purge to.
    func resetToSampleData(now: Date) async throws
    /// Removes every fictional sample thread (account == "sample") and
    /// nothing else, real synced mail included. Called once a Gmail account
    /// actually connects (ADR 004's "real per-account purge... until real
    /// accounts exist," now that one does): the demo content served its
    /// purpose before that and has no business still mixing into Brief/Needs
    /// You/Waiting counts and copy alongside a person's real mail.
    func deleteSampleData() async throws
    /// Merges freshly-fetched provider data (e.g. a Gmail sync pass) into the
    /// store. A given *message* is immutable once received, so a re-fetch of
    /// one already known (same thread, same `latestMessageID`) never touches
    /// its thread; but a genuinely new message arriving in an already-known
    /// thread (a real reply, or the first real content behind a
    /// locally-created placeholder) does update that thread's content, and
    /// its attention/reason too unless the new message is only our own sent
    /// copy showing back up (see `Correspondence.updatingContent`). Manual,
    /// thread-level facts (pin, snooze, Screener decision, image trust)
    /// are never touched by this either way (ADR 002/005). Returns the
    /// number of brand-new threads inserted (updates to existing threads are
    /// not counted here; callers that care already have the return value of
    /// `threads()` to compare against).
    ///
    /// `isInitialSync` is the Screener's baseline (ADR 005/006): true for a
    /// full-listing sync (an account's first ever sync, or any resync after
    /// a stored history cursor expired), meaning every sender already in the
    /// inbox is auto-approved rather than quarantined; false for an ordinary
    /// incremental sync, where a sender never seen before gets held as
    /// `.pending` until reviewed. A sender already known from an earlier
    /// insert keeps whatever decision they already have either way.
    @discardableResult
    func upsert(_ incoming: [Correspondence], isInitialSync: Bool) async throws -> Int

    /// Applies `decision` to every thread from `senderEmail` on `account`,
    /// approving or blocking them all at once (HEY's Screener is a one-time,
    /// per-sender decision, not per-message). Silent no-op if no thread from
    /// that sender exists yet.
    func setSenderDecision(_ decision: SenderDecision, forSenderEmail senderEmail: String, account: String) async throws

    /// Marks `senderEmail` trusted for remote images, applied to every
    /// existing thread from them at once and, like `SenderDecision`, looked
    /// up and stamped onto every future thread from the same sender too
    /// (see `upsert`'s doc comment; the mechanism is identical, just a
    /// different per-sender fact). Not the Screener: a sender can be
    /// image-trusted without being Screener-approved or vice versa, they
    /// answer different questions. Silent no-op if no thread from that
    /// sender exists yet.
    func trustSenderImages(forSenderEmail senderEmail: String, account: String) async throws

    /// The durable outbox (ADR 005/007): every send still `pending` or
    /// `failed` as of the last time the repository was read, so it survives
    /// the app being force-quit mid-undo-window instead of only ever living
    /// in OutboxService's in-memory state.
    func outboxEntries() async throws -> [OutboxRecord]
    func saveOutboxEntry(_ entry: OutboxRecord) async throws
    func removeOutboxEntry(id: UUID) async throws
}

public enum RepositoryError: Error, Equatable { case threadNotFound }

/// Deliberately transient, fictional data. No mail or credentials are persisted.
public actor SampleMailRepository: MailRepository {
    private var items: [Correspondence]
    private var outbox: [OutboxRecord] = []
    private let account = "sample"

    public init(now: Date = .now) { items = SampleCorrespondence.make(now: now) }
    public init(items: [Correspondence]) { self.items = items }
    public func threads() -> [Correspondence] { items }

    public func outboxEntries() -> [OutboxRecord] { outbox }

    public func saveOutboxEntry(_ entry: OutboxRecord) {
        if let index = outbox.firstIndex(where: { $0.id == entry.id }) {
            outbox[index] = entry
        } else {
            outbox.append(entry)
        }
    }

    public func removeOutboxEntry(id: UUID) {
        outbox.removeAll { $0.id == id }
    }

    @discardableResult
    public func setAttention(_ attention: Attention, for id: ThreadID) throws -> Correspondence {
        try mutate(id) { $0.attention = attention }
    }

    @discardableResult
    public func setPinned(_ isPinned: Bool, for id: ThreadID) throws -> Correspondence {
        try mutate(id) { $0.isPinned = isPinned }
    }

    @discardableResult
    public func snooze(_ id: ThreadID, until: Date?) throws -> Correspondence {
        try mutate(id) { $0.snoozedUntil = until }
    }

    public func send(_ draft: Draft, sentAt: Date, realThreadID: ThreadID?) throws -> Correspondence {
        guard let threadID = draft.threadID else {
            let sender = draft.to.trimmingCharacters(in: .whitespacesAndNewlines)
            let subject = draft.subject.trimmingCharacters(in: .whitespacesAndNewlines)
            let created = Correspondence(
                id: realThreadID ?? ThreadID(account: account, providerID: UUID().uuidString),
                sender: sender, organization: "", subject: subject,
                excerpt: draft.body, body: draft.body, receivedAt: sentAt, dueAt: nil,
                reason: "You started this conversation. Waiting for a response.",
                attention: .waiting)
            items.insert(created, at: 0)
            return created
        }
        guard let index = items.firstIndex(where: { $0.id == threadID }) else {
            throw RepositoryError.threadNotFound
        }
        items[index].attention = .waiting
        items[index].snoozedUntil = nil
        let verb = draft.kind == .forward ? "forwarded this" : "replied"
        items[index].reason = "You \(verb) just now. Waiting for their response."
        return items[index]
    }

    @discardableResult
    private func mutate(_ id: ThreadID, _ change: (inout Correspondence) -> Void) throws -> Correspondence {
        guard let index = items.firstIndex(where: { $0.id == id }) else {
            throw RepositoryError.threadNotFound
        }
        change(&items[index])
        return items[index]
    }

    public func remove(_ id: ThreadID) throws {
        guard let index = items.firstIndex(where: { $0.id == id }) else {
            throw RepositoryError.threadNotFound
        }
        items.remove(at: index)
    }

    public func seedIfNeeded(now: Date) {}

    public func resetToSampleData(now: Date) {
        items = SampleCorrespondence.make(now: now)
    }

    public func deleteSampleData() {
        items.removeAll { $0.id.account == account }
    }

    @discardableResult
    public func upsert(_ incoming: [Correspondence], isInitialSync: Bool) -> Int {
        var indexByID: [ThreadID: Int] = [:]
        for (index, item) in items.enumerated() { indexByID[item.id] = index }
        var knownSenderDecisions = Self.senderDecisions(in: items)
        let knownImageTrust = Self.imageTrust(in: items)
        var insertedCount = 0
        for var item in incoming {
            if let index = indexByID[item.id] {
                let existing = items[index]
                guard let incomingMessageID = item.latestMessageID, incomingMessageID != existing.latestMessageID,
                      item.receivedAt >= existing.receivedAt else { continue }
                let isFromAccountOwner = item.senderEmail != nil && item.senderEmail == item.id.account
                items[index] = existing.updatingContent(from: item, preserveAttention: isFromAccountOwner)
                continue
            }
            if let senderEmail = item.senderEmail {
                let key = Self.senderKey(account: item.id.account, senderEmail: senderEmail)
                if let known = knownSenderDecisions[key] {
                    item.senderDecision = known
                } else {
                    item.senderDecision = isInitialSync ? .approved : .pending
                    knownSenderDecisions[key] = item.senderDecision
                }
                if knownImageTrust[key] == true { item.imagesTrusted = true }
            }
            indexByID[item.id] = items.count
            items.append(item)
            insertedCount += 1
        }
        return insertedCount
    }

    public func setSenderDecision(_ decision: SenderDecision, forSenderEmail senderEmail: String, account: String) {
        for index in items.indices where items[index].id.account == account && items[index].senderEmail == senderEmail {
            items[index].senderDecision = decision
        }
    }

    public func trustSenderImages(forSenderEmail senderEmail: String, account: String) {
        for index in items.indices where items[index].id.account == account && items[index].senderEmail == senderEmail {
            items[index].imagesTrusted = true
        }
    }

    private static func senderKey(account: String, senderEmail: String) -> String { "\(account)|\(senderEmail)" }

    private static func senderDecisions(in items: [Correspondence]) -> [String: SenderDecision] {
        var map: [String: SenderDecision] = [:]
        for item in items {
            guard let senderEmail = item.senderEmail else { continue }
            map[senderKey(account: item.id.account, senderEmail: senderEmail)] = item.senderDecision
        }
        return map
    }

    private static func imageTrust(in items: [Correspondence]) -> [String: Bool] {
        var map: [String: Bool] = [:]
        for item in items {
            guard let senderEmail = item.senderEmail, item.imagesTrusted else { continue }
            map[senderKey(account: item.id.account, senderEmail: senderEmail)] = true
        }
        return map
    }
}
