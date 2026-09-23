import Foundation

/// Account-scoped identity prevents collisions when another provider is added.
public struct ThreadID: Hashable, Codable, Sendable {
    public let account: String
    public let providerID: String

    public init(account: String, providerID: String) {
        self.account = account
        self.providerID = providerID
    }
}

public enum Attention: String, Codable, CaseIterable, Sendable {
    case needsYou, waiting, quiet, handled

    public var title: String {
        switch self {
        case .needsYou: "Needs You"
        case .waiting: "Waiting"
        case .quiet: "For reference"
        case .handled: "Handled"
        }
    }
}

/// The Screener: a sender earns entry once, the same instinct already
/// applied to remote images (blocked by default, revealed on request),
/// generalized to who reaches a person's attention at all. `pending` means
/// this sender has never been decided on and their mail is held out of
/// Brief/Needs You/Waiting/Mail until reviewed (still findable via explicit
/// search, matching how a snoozed thread stays findable; see MailQuery).
/// `approved` is the default for sample/local threads (no real sender to
/// screen) and, per ADR 005/HEY's own model, for every sender already in an
/// account's inbox the first time it syncs: only a genuinely new sender
/// arriving after that baseline gets screened, so connecting Gmail never
/// quarantines an entire existing mailbox on day one.
public enum SenderDecision: String, Codable, Sendable {
    case pending, approved, blocked
}

/// A file attached to a message, identified but not downloaded: `id` is
/// Gmail's own `attachmentId`, only meaningful together with the parent
/// message's id (`Correspondence.latestMessageID`), which is what
/// `GmailAPIClient.fetchAttachmentData` needs to actually fetch the bytes.
public struct MailAttachment: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let filename: String
    public let mimeType: String
    public let sizeBytes: Int

    public init(id: String, filename: String, mimeType: String, sizeBytes: Int) {
        self.id = id
        self.filename = filename
        self.mimeType = mimeType
        self.sizeBytes = sizeBytes
    }
}

public struct Correspondence: Identifiable, Hashable, Codable, Sendable {
    public let id: ThreadID
    public let sender: String
    /// The sender's actual address, when known (real Gmail mail always has
    /// one; sample/fictional threads do not). `sender` is a display name and
    /// is not a valid reply-to address on its own, e.g. Gmail formats
    /// `"Jane Doe" <jane@example.com>`, and only the address half belongs in
    /// a "To" field.
    public let senderEmail: String?
    public let organization: String
    public let subject: String
    public let excerpt: String
    public let body: String
    /// The message's original rich-text rendering, when the provider sent
    /// one. `body` is always a plain-text-safe fallback; this is what
    /// actually renders when present (sanitized, isolated; see ADR 006).
    public let htmlBody: String?
    /// The RFC 5322 `Message-ID` of this message, without its surrounding
    /// `<...>`, when the provider sent one. Real Gmail threading of an
    /// outgoing reply depends on echoing this back as `In-Reply-To`/
    /// `References` (see ADR 005); nil for sample/fictional threads, which
    /// never really send.
    public let messageIdHeader: String?
    /// The provider's id for the single message this thread currently shows,
    /// when known (real Gmail mail always has one; sample/fictional threads
    /// and a just-sent placeholder do not yet). `id.providerID` is the
    /// *thread* id and never changes; this is what lets `upsert` tell "the
    /// same message arriving again" apart from "a genuinely new message
    /// (e.g. a reply) landed in this thread," since a thread keeps one
    /// providerID for its whole life but gets a new message each time
    /// someone writes into it (see ADR 005's reply-sync fix).
    public let latestMessageID: String?
    public let receivedAt: Date
    public let dueAt: Date?
    /// Human-readable evidence, never an unexplained importance score.
    public var reason: String
    public var attention: Attention
    public var isPinned: Bool
    /// A deliberate deferral, not a due date. Hidden from active views until it passes.
    public var snoozedUntil: Date?
    public var senderDecision: SenderDecision
    /// Not the Screener: this is "do I trust this sender's remote images,"
    /// not "do I trust this sender at all." Set once per sender (see
    /// `MailRepository.trustSenderImages`), it stamps this thread and every
    /// future thread from the same sender, so a newsletter you've already
    /// chosen to trust never needs a repeat "Show Images" tap. Chosen as
    /// the smaller, no-infrastructure alternative to Apple's own Mail
    /// Privacy Protection (a server-side image relay that would need
    /// Corres to run a real backend, which it deliberately doesn't yet).
    public var imagesTrusted: Bool
    /// What's attached, not the bytes themselves: attachment content can be
    /// large and is fetched on demand (a single tap, see
    /// `GmailAPIClient.fetchAttachmentData`), the same "collapsed by
    /// default, load on request" instinct already applied to remote images.
    /// Empty for sample/fictional threads, which never really have any.
    public let attachments: [MailAttachment]

    public init(id: ThreadID, sender: String, senderEmail: String? = nil, organization: String, subject: String,
                excerpt: String, body: String, htmlBody: String? = nil, messageIdHeader: String? = nil,
                latestMessageID: String? = nil, receivedAt: Date, dueAt: Date?, reason: String, attention: Attention,
                isPinned: Bool = false, snoozedUntil: Date? = nil, senderDecision: SenderDecision = .approved,
                imagesTrusted: Bool = false, attachments: [MailAttachment] = []) {
        self.id = id
        self.sender = sender
        self.senderEmail = senderEmail
        self.organization = organization
        self.subject = subject
        self.excerpt = excerpt
        self.body = body
        self.htmlBody = htmlBody
        self.messageIdHeader = messageIdHeader
        self.latestMessageID = latestMessageID
        self.receivedAt = receivedAt
        self.dueAt = dueAt
        self.reason = reason
        self.attention = attention
        self.isPinned = isPinned
        self.snoozedUntil = snoozedUntil
        self.senderDecision = senderDecision
        self.imagesTrusted = imagesTrusted
        self.attachments = attachments
    }

    public var initials: String {
        sender.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined()
    }

    public func isSnoozed(at now: Date) -> Bool {
        guard let snoozedUntil else { return false }
        return snoozedUntil > now
    }

    /// A genuinely new message landed in this same thread (a real reply, or
    /// the first real sync of a message this thread's local placeholder was
    /// only guessing at), used by `upsert` once it has already confirmed
    /// `incoming.latestMessageID` differs from this thread's. Keeps every
    /// manual, thread-level fact (pin, snooze, Screener decision, image
    /// trust) untouched, replaces the content with whatever the new message
    /// actually says, and updates attention/reason from it too unless
    /// `preserveAttention` is set: that's for the case where the "new"
    /// message is only our own sent copy of what we already sent showing up
    /// in a later sync, which must never downgrade a thread still
    /// legitimately Waiting on a reply that hasn't arrived yet.
    public func updatingContent(from incoming: Correspondence, preserveAttention: Bool) -> Correspondence {
        Correspondence(
            id: id, sender: incoming.sender, senderEmail: incoming.senderEmail, organization: incoming.organization,
            subject: incoming.subject, excerpt: incoming.excerpt, body: incoming.body, htmlBody: incoming.htmlBody,
            messageIdHeader: incoming.messageIdHeader, latestMessageID: incoming.latestMessageID,
            receivedAt: incoming.receivedAt, dueAt: incoming.dueAt,
            reason: preserveAttention ? reason : incoming.reason,
            attention: preserveAttention ? attention : incoming.attention,
            isPinned: isPinned, snoozedUntil: snoozedUntil,
            senderDecision: senderDecision, imagesTrusted: imagesTrusted, attachments: incoming.attachments)
    }
}

/// A message the user is composing: a reply/forward in an existing conversation, or a new one.
/// Codable so it can round-trip through the durable outbox (ADR 005/007);
/// see OutboxRecord.
public struct Draft: Identifiable, Hashable, Sendable, Codable {
    public enum Kind: String, Hashable, Sendable, Codable { case new, reply, replyAll, forward }

    public let id: UUID
    public let kind: Kind
    public let threadID: ThreadID?
    public var to: String
    public var subject: String
    public var body: String

    public init(id: UUID = UUID(), kind: Kind, threadID: ThreadID? = nil,
                to: String, subject: String, body: String = "") {
        self.id = id
        self.kind = kind
        self.threadID = threadID
        self.to = to
        self.subject = subject
        self.body = body
    }

    public var isSendable: Bool {
        !to.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// A durable record of a queued send, surviving the app being force-quit
/// mid-undo-window (ADR 005's still-open gap: OutboxService alone only held
/// this in memory). `pending` means it was queued but never confirmed sent
/// or failed by the time the app last quit; the safest resolution on next
/// launch is to finish sending it rather than silently lose a message the
/// person already asked to send. `failed` means a real Gmail send attempt
/// already came back with an error, and is restored so the Retry/Discard
/// banner reappears instead of the failure vanishing unexplained.
public struct OutboxRecord: Identifiable, Sendable, Codable {
    public enum Status: String, Sendable, Codable { case pending, failed }

    public let id: UUID
    public let draft: Draft
    public var status: Status
    public let createdAt: Date

    public init(id: UUID = UUID(), draft: Draft, status: Status, createdAt: Date = .now) {
        self.id = id
        self.draft = draft
        self.status = status
        self.createdAt = createdAt
    }
}

public struct BriefSnapshot: Equatable, Sendable {
    public let needsYou: Int
    public let waiting: Int
    public let upcoming: Int

    public init(threads: [Correspondence], now: Date, horizon: TimeInterval = 86_400) {
        let active = threads.filter { !$0.isSnoozed(at: now) }
        needsYou = active.filter { $0.attention == .needsYou }.count
        waiting = active.filter { $0.attention == .waiting }.count
        upcoming = active.filter {
            guard $0.attention == .needsYou, let due = $0.dueAt else { return false }
            return due >= now && due <= now.addingTimeInterval(horizon)
        }.count
    }
}

public enum MailQuery {
    public static func filter(_ threads: [Correspondence], attention: Attention? = nil,
                              search: String = "", now: Date = .now) -> [Correspondence] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        // Snooze hides a thread from its curated attention queue (that is the
        // point of snoozing it), but never from the catch-all Mail view and
        // never from an explicit search: a snoozed thread is still real mail
        // and must stay findable.
        let hideSnoozed = attention != nil && query.isEmpty
        // Same rule as snooze: held out of ordinary browsing, but still
        // findable if the person explicitly searches for it, never truly
        // hidden or deleted.
        let hideUnscreened = query.isEmpty
        return threads.filter { item in
            (!hideSnoozed || !item.isSnoozed(at: now)) &&
            (!hideUnscreened || item.senderDecision == .approved) &&
            (attention == nil || item.attention == attention) &&
            (query.isEmpty || [item.sender, item.organization, item.subject, item.excerpt]
                .contains { $0.localizedStandardContains(query) })
        }.sorted {
            if $0.isPinned != $1.isPinned { return $0.isPinned }
            if $0.receivedAt == $1.receivedAt { return $0.id.providerID < $1.id.providerID }
            return $0.receivedAt > $1.receivedAt
        }
    }
}
