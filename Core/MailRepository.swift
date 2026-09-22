import Foundation

/// Views never depend on Gmail DTOs or authentication credentials.
public protocol MailRepository: Sendable {
    func threads() async throws -> [Correspondence]
    func setAttention(_ attention: Attention, for id: ThreadID) async throws
    func setPinned(_ isPinned: Bool, for id: ThreadID) async throws
    func snooze(_ id: ThreadID, until: Date?) async throws
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
    /// store. A real message's content is immutable once received, so this
    /// only inserts threads not already present; an existing thread (and
    /// any manual attention/pin/snooze on it) is never touched, let alone
    /// silently rewritten (ADR 002). Returns the number of threads inserted.
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

    public func setAttention(_ attention: Attention, for id: ThreadID) throws {
        try mutate(id) { $0.attention = attention }
    }

    public func setPinned(_ isPinned: Bool, for id: ThreadID) throws {
        try mutate(id) { $0.isPinned = isPinned }
    }

    public func snooze(_ id: ThreadID, until: Date?) throws {
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

    private func mutate(_ id: ThreadID, _ change: (inout Correspondence) -> Void) throws {
        guard let index = items.firstIndex(where: { $0.id == id }) else {
            throw RepositoryError.threadNotFound
        }
        change(&items[index])
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
        // A real message's content never changes after it's received, so only
        // new messages need inserting. An existing thread (and any manual
        // attention/pin/snooze on it) is left completely untouched.
        let existingIDs = Set(items.map(\.id))
        var knownSenderDecisions = Self.senderDecisions(in: items)
        var newItems: [Correspondence] = []
        for var item in incoming where !existingIDs.contains(item.id) {
            if let senderEmail = item.senderEmail {
                let key = Self.senderKey(account: item.id.account, senderEmail: senderEmail)
                if let known = knownSenderDecisions[key] {
                    item.senderDecision = known
                } else {
                    item.senderDecision = isInitialSync ? .approved : .pending
                    knownSenderDecisions[key] = item.senderDecision
                }
            }
            newItems.append(item)
        }
        items.append(contentsOf: newItems)
        return newItems.count
    }

    public func setSenderDecision(_ decision: SenderDecision, forSenderEmail senderEmail: String, account: String) {
        for index in items.indices where items[index].id.account == account && items[index].senderEmail == senderEmail {
            items[index].senderDecision = decision
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
}
