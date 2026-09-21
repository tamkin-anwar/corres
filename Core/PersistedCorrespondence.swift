import Foundation
import SwiftData

/// The persistence-layer shape of a conversation. Kept deliberately separate
/// from `Correspondence` (a plain Sendable value type) so persistence details
/// never leak past the repository boundary — views and MailStore only ever
/// see `Correspondence`. `attentionRaw` exists because @Model properties must
/// be primitive/Codable-friendly; `Attention` itself is not stored directly.
@Model
public final class PersistedCorrespondence {
    @Attribute(.unique) public var compositeID: String
    public var account: String
    public var providerID: String
    public var sender: String
    public var organization: String
    public var subject: String
    public var excerpt: String
    public var body: String
    public var receivedAt: Date
    public var dueAt: Date?
    public var reason: String
    public var attentionRaw: String
    public var isPinned: Bool
    public var snoozedUntil: Date?

    public init(from correspondence: Correspondence) {
        self.compositeID = Self.compositeID(account: correspondence.id.account, providerID: correspondence.id.providerID)
        self.account = correspondence.id.account
        self.providerID = correspondence.id.providerID
        self.sender = correspondence.sender
        self.organization = correspondence.organization
        self.subject = correspondence.subject
        self.excerpt = correspondence.excerpt
        self.body = correspondence.body
        self.receivedAt = correspondence.receivedAt
        self.dueAt = correspondence.dueAt
        self.reason = correspondence.reason
        self.attentionRaw = correspondence.attention.rawValue
        self.isPinned = correspondence.isPinned
        self.snoozedUntil = correspondence.snoozedUntil
    }

    public func apply(_ change: Correspondence) {
        sender = change.sender
        organization = change.organization
        subject = change.subject
        excerpt = change.excerpt
        body = change.body
        receivedAt = change.receivedAt
        dueAt = change.dueAt
        reason = change.reason
        attentionRaw = change.attention.rawValue
        isPinned = change.isPinned
        snoozedUntil = change.snoozedUntil
    }

    public var asCorrespondence: Correspondence {
        Correspondence(id: ThreadID(account: account, providerID: providerID), sender: sender, organization: organization,
                       subject: subject, excerpt: excerpt, body: body, receivedAt: receivedAt, dueAt: dueAt,
                       reason: reason, attention: Attention(rawValue: attentionRaw) ?? .quiet,
                       isPinned: isPinned, snoozedUntil: snoozedUntil)
    }

    public static func compositeID(account: String, providerID: String) -> String { "\(account)|\(providerID)" }
}
