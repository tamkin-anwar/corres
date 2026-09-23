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
    /// Defaults to `.approved`'s raw value, not `.pending`: a real row that
    /// predates this column existing was, by construction, already in the
    /// account's inbox before the Screener shipped, exactly the case
    /// `isInitialSync` already treats as auto-approved elsewhere (see
    /// `SenderDecision`'s doc comment in Correspondence.swift).
    public var senderDecisionRaw: String = SenderDecision.approved.rawValue
    public var imagesTrusted: Bool = false
    /// JSON-encoded `[MailAttachment]`, the same one-column choice
    /// `PersistedOutboxEntry.draftData` already made for `Draft`: a small,
    /// self-contained value with no query needs of its own.
    ///
    /// Every non-optional property added to this model after its first
    /// shipped version needs its own `= <default>` literal, this one
    /// included: without one, SwiftData's automatic lightweight migration
    /// has nothing to backfill into existing on-disk rows that predate the
    /// column, and fails outright ("missing attribute values on mandatory
    /// destination attribute") the moment a real device with real synced
    /// mail tries to open the store, rather than a fresh install where no
    /// migration is ever exercised. Caught live, on a real device, after
    /// Batch 24 shipped without it on three properties at once
    /// (`attachmentsData`/`isUnread`/`labelIds`); `senderDecisionRaw` and
    /// `imagesTrusted` above were missing theirs too and fixed in the same
    /// pass rather than waiting to hit this again next release. See
    /// Docs/Architecture.md.
    public var attachmentsData: Data = Data()
    public var isUnread: Bool = false
    public var labelIds: [String] = []

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
        self.isUnread = correspondence.isUnread
        self.labelIds = correspondence.labelIds
    }

    public var asCorrespondence: Correspondence {
        Correspondence(id: ThreadID(account: account, providerID: providerID), sender: sender, senderEmail: senderEmail,
                       organization: organization, subject: subject, excerpt: excerpt, body: body, htmlBody: htmlBody,
                       messageIdHeader: messageIdHeader, latestMessageID: latestMessageID, receivedAt: receivedAt, dueAt: dueAt,
                       reason: reason, attention: Attention(rawValue: attentionRaw) ?? .quiet,
                       isPinned: isPinned, snoozedUntil: snoozedUntil,
                       senderDecision: SenderDecision(rawValue: senderDecisionRaw) ?? .approved,
                       imagesTrusted: imagesTrusted,
                       attachments: (try? JSONDecoder().decode([MailAttachment].self, from: attachmentsData)) ?? [],
                       isUnread: isUnread, labelIds: labelIds)
    }

    public static func compositeID(account: String, providerID: String) -> String { "\(account)|\(providerID)" }
}
