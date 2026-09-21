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
    func send(_ draft: Draft, sentAt: Date) async throws -> Correspondence
    /// Populates fictional starter data on first use. A no-op for a repository
    /// that is already seeded at construction (SampleMailRepository); real
    /// work for a persisted, empty store.
    func seedIfNeeded(now: Date) async throws
    /// Explicit, user-triggered return to a clean fictional demo state — not
    /// called automatically. The local-data equivalent of sign-out purge until
    /// real accounts exist to scope a purge to.
    func resetToSampleData(now: Date) async throws
    /// Merges freshly-fetched provider data (e.g. a Gmail sync pass) into the
    /// store. A real message's content is immutable once received, so this
    /// only inserts threads not already present — an existing thread (and
    /// any manual attention/pin/snooze on it) is never touched, let alone
    /// silently rewritten (ADR 002). Returns the number of threads inserted.
    @discardableResult
    func upsert(_ incoming: [Correspondence]) async throws -> Int
}

public enum RepositoryError: Error, Equatable { case threadNotFound }

/// Deliberately transient, fictional data. No mail or credentials are persisted.
public actor SampleMailRepository: MailRepository {
    private var items: [Correspondence]
    private let account = "sample"

    public init(now: Date = .now) { items = SampleCorrespondence.make(now: now) }
    public init(items: [Correspondence]) { self.items = items }
    public func threads() -> [Correspondence] { items }

    public func setAttention(_ attention: Attention, for id: ThreadID) throws {
        try mutate(id) { $0.attention = attention }
    }

    public func setPinned(_ isPinned: Bool, for id: ThreadID) throws {
        try mutate(id) { $0.isPinned = isPinned }
    }

    public func snooze(_ id: ThreadID, until: Date?) throws {
        try mutate(id) { $0.snoozedUntil = until }
    }

    public func send(_ draft: Draft, sentAt: Date) throws -> Correspondence {
        guard let threadID = draft.threadID else {
            let sender = draft.to.trimmingCharacters(in: .whitespacesAndNewlines)
            let subject = draft.subject.trimmingCharacters(in: .whitespacesAndNewlines)
            let created = Correspondence(
                id: ThreadID(account: account, providerID: UUID().uuidString),
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

    @discardableResult
    public func upsert(_ incoming: [Correspondence]) -> Int {
        // A real message's content never changes after it's received — only
        // new messages need inserting. An existing thread (and any manual
        // attention/pin/snooze on it) is left completely untouched.
        let existingIDs = Set(items.map(\.id))
        let newItems = incoming.filter { !existingIDs.contains($0.id) }
        items.append(contentsOf: newItems)
        return newItems.count
    }
}
