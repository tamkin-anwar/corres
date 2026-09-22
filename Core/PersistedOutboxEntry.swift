import Foundation
import SwiftData

/// The persistence-layer shape of a durable outbox record (ADR 005/007).
/// `Draft` is stored JSON-encoded in a single column rather than broken into
/// separate columns: it is a small, self-contained value with no query
/// needs of its own (nothing ever searches or filters by draft subject/body
/// at the persistence layer), so one column is simpler than five for no
/// real cost, unlike `PersistedCorrespondence` where individual columns
/// genuinely earn their keep (fetch predicates, sender grouping, etc.).
@Model
public final class PersistedOutboxEntry {
    @Attribute(.unique) public var id: UUID
    public var draftData: Data
    public var statusRaw: String
    public var createdAt: Date

    public init(from record: OutboxRecord) {
        self.id = record.id
        self.draftData = (try? JSONEncoder().encode(record.draft)) ?? Data()
        self.statusRaw = record.status.rawValue
        self.createdAt = record.createdAt
    }

    public var asRecord: OutboxRecord? {
        guard let draft = try? JSONDecoder().decode(Draft.self, from: draftData),
              let status = OutboxRecord.Status(rawValue: statusRaw) else { return nil }
        return OutboxRecord(id: id, draft: draft, status: status, createdAt: createdAt)
    }
}
