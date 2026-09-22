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

    @discardableResult
    public func setAttention(_ attention: Attention, for id: ThreadID) throws -> Correspondence {
        try mutate(id) { $0.attentionRaw = attention.rawValue }
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
            // realThreadID is the real Gmail account + thread id when
            // OutboxService already sent this via Gmail; falling back to the
            // local "sample" account only when it stayed local-only (no
            // account connected).
            let created = Correspondence(
                id: realThreadID ?? ThreadID(account: Self.localAccount, providerID: UUID().uuidString),
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

    public func deleteSampleData() throws {
        let account = Self.localAccount
        let descriptor = FetchDescriptor<PersistedCorrespondence>(predicate: #Predicate { $0.account == account })
        let matches = try modelContext.fetch(descriptor)
        guard !matches.isEmpty else { return }
        for model in matches { modelContext.delete(model) }
        try modelContext.save()
    }

    @discardableResult
    public func upsert(_ incoming: [Correspondence], isInitialSync: Bool) throws -> Int {
        // A real message's content never changes after it's received, so only
        // new messages need inserting. An existing thread (and any manual
        // attention/pin/snooze on it) is left completely untouched.
        let existingModels = try modelContext.fetch(FetchDescriptor<PersistedCorrespondence>())
        let existingIDs = Set(existingModels.map(\.compositeID))
        var knownSenderDecisions = Self.senderDecisions(in: existingModels)
        let knownImageTrust = Self.imageTrust(in: existingModels)
        var inserted = 0
        for var item in incoming {
            let compositeID = PersistedCorrespondence.compositeID(account: item.id.account, providerID: item.id.providerID)
            guard !existingIDs.contains(compositeID) else { continue }
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
            modelContext.insert(PersistedCorrespondence(from: item))
            inserted += 1
        }
        if inserted > 0 { try modelContext.save() }
        return inserted
    }

    public func setSenderDecision(_ decision: SenderDecision, forSenderEmail senderEmail: String, account: String) throws {
        let descriptor = FetchDescriptor<PersistedCorrespondence>(
            predicate: #Predicate { $0.account == account && $0.senderEmail == senderEmail })
        let matches = try modelContext.fetch(descriptor)
        guard !matches.isEmpty else { return }
        for model in matches { model.senderDecisionRaw = decision.rawValue }
        try modelContext.save()
    }

    public func trustSenderImages(forSenderEmail senderEmail: String, account: String) throws {
        let descriptor = FetchDescriptor<PersistedCorrespondence>(
            predicate: #Predicate { $0.account == account && $0.senderEmail == senderEmail })
        let matches = try modelContext.fetch(descriptor)
        guard !matches.isEmpty else { return }
        for model in matches { model.imagesTrusted = true }
        try modelContext.save()
    }

    public func outboxEntries() throws -> [OutboxRecord] {
        try modelContext.fetch(FetchDescriptor<PersistedOutboxEntry>()).compactMap(\.asRecord)
    }

    public func saveOutboxEntry(_ entry: OutboxRecord) throws {
        var descriptor = FetchDescriptor<PersistedOutboxEntry>(predicate: #Predicate { $0.id == entry.id })
        descriptor.fetchLimit = 1
        if let existing = try modelContext.fetch(descriptor).first {
            existing.statusRaw = entry.status.rawValue
        } else {
            modelContext.insert(PersistedOutboxEntry(from: entry))
        }
        try modelContext.save()
    }

    public func removeOutboxEntry(id: UUID) throws {
        var descriptor = FetchDescriptor<PersistedOutboxEntry>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        guard let existing = try modelContext.fetch(descriptor).first else { return }
        modelContext.delete(existing)
        try modelContext.save()
    }

    private static func senderKey(account: String, senderEmail: String) -> String { "\(account)|\(senderEmail)" }

    private static func senderDecisions(in models: [PersistedCorrespondence]) -> [String: SenderDecision] {
        var map: [String: SenderDecision] = [:]
        for model in models {
            guard let senderEmail = model.senderEmail else { continue }
            map[senderKey(account: model.account, senderEmail: senderEmail)] = SenderDecision(rawValue: model.senderDecisionRaw) ?? .approved
        }
        return map
    }

    private static func imageTrust(in models: [PersistedCorrespondence]) -> [String: Bool] {
        var map: [String: Bool] = [:]
        for model in models {
            guard let senderEmail = model.senderEmail, model.imagesTrusted else { continue }
            map[senderKey(account: model.account, senderEmail: senderEmail)] = true
        }
        return map
    }

    private func insertSampleData(now: Date) {
        for item in SampleCorrespondence.make(now: now) {
            modelContext.insert(PersistedCorrespondence(from: item))
        }
    }

    @discardableResult
    private func mutate(_ id: ThreadID, _ change: (PersistedCorrespondence) -> Void) throws -> Correspondence {
        let model = try fetchOne(id)
        change(model)
        try modelContext.save()
        return model.asCorrespondence
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
