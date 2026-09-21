import Foundation
import SwiftData

/// Local-first persisted storage. Survives relaunch; holds both the fictional
/// sample data and, once connected, real synced Gmail messages side by side
/// (see PersistedCorrespondence). @ModelActor gives this its own
/// actor-isolated ModelContext, the documented safe pattern for using
/// SwiftData under Swift 6 strict concurrency: the container is Sendable and
/// crosses actor boundaries, but the context never does.
@ModelActor
public actor SwiftDataMailRepository: MailRepository {
    public func threads() throws -> [Correspondence] {
        try modelContext.fetch(FetchDescriptor<PersistedCorrespondence>()).map(\.asCorrespondence)
    }

    public func setAttention(_ attention: Attention, for id: ThreadID) throws {
        try mutate(id) { $0.attentionRaw = attention.rawValue }
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
            // Still "sample": sending is not real yet (read-only Gmail scope,
            // per Docs/Product.md's V1 order), so a locally-composed draft has
            // no real account to send from regardless of who is signed in.
            let created = Correspondence(
                id: ThreadID(account: Self.localAccount, providerID: UUID().uuidString),
                sender: sender, organization: "", subject: subject,
                excerpt: draft.body, body: draft.body, receivedAt: sentAt, dueAt: nil,
                reason: "You started this conversation. Waiting for a response.",
                attention: .waiting)
            modelContext.insert(PersistedCorrespondence(from: created))
            try modelContext.save()
            return created
        }
        let model = try fetchOne(threadID)
        model.attentionRaw = Attention.waiting.rawValue
        model.snoozedUntil = nil
        let verb = draft.kind == .forward ? "forwarded this" : "replied"
        model.reason = "You \(verb) just now. Waiting for their response."
        try modelContext.save()
        return model.asCorrespondence
    }

    public func seedIfNeeded(now: Date) throws {
        guard try modelContext.fetchCount(FetchDescriptor<PersistedCorrespondence>()) == 0 else { return }
        insertSampleData(now: now)
        try modelContext.save()
    }

    public func resetToSampleData(now: Date) throws {
        try modelContext.delete(model: PersistedCorrespondence.self)
        insertSampleData(now: now)
        try modelContext.save()
    }

    @discardableResult
    public func upsert(_ incoming: [Correspondence]) throws -> Int {
        // A real message's content never changes after it's received, so only
        // new messages need inserting. An existing thread (and any manual
        // attention/pin/snooze on it) is left completely untouched.
        let existing = try Set(modelContext.fetch(FetchDescriptor<PersistedCorrespondence>()).map(\.compositeID))
        var inserted = 0
        for item in incoming {
            let compositeID = PersistedCorrespondence.compositeID(account: item.id.account, providerID: item.id.providerID)
            guard !existing.contains(compositeID) else { continue }
            modelContext.insert(PersistedCorrespondence(from: item))
            inserted += 1
        }
        if inserted > 0 { try modelContext.save() }
        return inserted
    }

    private func insertSampleData(now: Date) {
        for item in SampleCorrespondence.make(now: now) {
            modelContext.insert(PersistedCorrespondence(from: item))
        }
    }

    private func mutate(_ id: ThreadID, _ change: (PersistedCorrespondence) -> Void) throws {
        let model = try fetchOne(id)
        change(model)
        try modelContext.save()
    }

    private func fetchOne(_ id: ThreadID) throws -> PersistedCorrespondence {
        let compositeID = PersistedCorrespondence.compositeID(account: id.account, providerID: id.providerID)
        var descriptor = FetchDescriptor<PersistedCorrespondence>(
            predicate: #Predicate { $0.compositeID == compositeID })
        descriptor.fetchLimit = 1
        guard let model = try modelContext.fetch(descriptor).first else {
            throw RepositoryError.threadNotFound
        }
        return model
    }

    private static let localAccount = "sample"
}
