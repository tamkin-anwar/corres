import Foundation
import SwiftData

/// The persistence-layer shape of a conversation. Kept deliberately separate
/// from `Correspondence` (a plain Sendable value type) so persistence details
/// never leak past the repository boundary; views and MailStore only ever
/// see `Correspondence`. `attentionRaw` exists because @Model properties must
/// be primitive/Codable-friendly; `Attention` itself is not stored directly.
@Model
public final class PersistedCorrespondence {
    @Attribute(.unique) public var compositeID: String
    public var account: String
    public var providerID: String
    public var sender: String
    public var senderEmail: String?
    public var organization: String
    public var subject: String
    public var excerpt: String
    public var body: String
    public var htmlBody: String?
    public var messageIdHeader: String?
    public var latestMessageID: String?
    public var receivedAt: Date
    public var dueAt: Date?
    public var reason: String
    public var attentionRaw: String
    public var isPinned: Bool
    public var snoozedUntil: Date?
    public var senderDecisionRaw: String
    public var imagesTrusted: Bool
    /// JSON-encoded `[MailAttachment]`, the same one-column choice
    /// `PersistedOutboxEntry.draftData` already made for `Draft`: a small,
    /// self-contained value with no query needs of its own.
    public var attachmentsData: Data

    public init(from correspondence: Correspondence) {
        self.compositeID = Self.compositeID(account: correspondence.id.account, providerID: correspondence.id.providerID)
        self.account = correspondence.id.account
        self.providerID = correspondence.id.providerID
        self.sender = correspondence.sender
        self.senderEmail = correspondence.senderEmail
        self.organization = correspondence.organization
        self.subject = correspondence.subject
        self.excerpt = correspondence.excerpt
        self.body = correspondence.body
        self.htmlBody = correspondence.htmlBody
        self.messageIdHeader = correspondence.messageIdHeader
        self.latestMessageID = correspondence.latestMessageID
        self.receivedAt = correspondence.receivedAt
        self.dueAt = correspondence.dueAt
        self.reason = correspondence.reason
        self.attentionRaw = correspondence.attention.rawValue
        self.isPinned = correspondence.isPinned
        self.snoozedUntil = correspondence.snoozedUntil
        self.senderDecisionRaw = correspondence.senderDecision.rawValue
        self.imagesTrusted = correspondence.imagesTrusted
        self.attachmentsData = (try? JSONEncoder().encode(correspondence.attachments)) ?? Data()
    }

    public var asCorrespondence: Correspondence {
        Correspondence(id: ThreadID(account: account, providerID: providerID), sender: sender, senderEmail: senderEmail,
                       organization: organization, subject: subject, excerpt: excerpt, body: body, htmlBody: htmlBody,
                       messageIdHeader: messageIdHeader, latestMessageID: latestMessageID, receivedAt: receivedAt, dueAt: dueAt,
                       reason: reason, attention: Attention(rawValue: attentionRaw) ?? .quiet,
                       isPinned: isPinned, snoozedUntil: snoozedUntil,
                       senderDecision: SenderDecision(rawValue: senderDecisionRaw) ?? .approved,
                       imagesTrusted: imagesTrusted,
                       attachments: (try? JSONDecoder().decode([MailAttachment].self, from: attachmentsData)) ?? [])
    }

    public static func compositeID(account: String, providerID: String) -> String { "\(account)|\(providerID)" }
}
