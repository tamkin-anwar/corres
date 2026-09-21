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
}
