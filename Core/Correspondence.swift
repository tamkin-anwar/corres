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
    public let receivedAt: Date
    public let dueAt: Date?
    /// Human-readable evidence, never an unexplained importance score.
    public var reason: String
    public var attention: Attention
    public var isPinned: Bool
    /// A deliberate deferral, not a due date. Hidden from active views until it passes.
    public var snoozedUntil: Date?
    public var senderDecision: SenderDecision

    public init(id: ThreadID, sender: String, senderEmail: String? = nil, organization: String, subject: String,
                excerpt: String, body: String, htmlBody: String? = nil, messageIdHeader: String? = nil,
                receivedAt: Date, dueAt: Date?, reason: String, attention: Attention,
                isPinned: Bool = false, snoozedUntil: Date? = nil, senderDecision: SenderDecision = .approved) {
        self.id = id
        self.sender = sender
        self.senderEmail = senderEmail
        self.organization = organization
        self.subject = subject
        self.excerpt = excerpt
        self.body = body
        self.htmlBody = htmlBody
        self.messageIdHeader = messageIdHeader
        self.receivedAt = receivedAt
        self.dueAt = dueAt
        self.reason = reason
        self.attention = attention
        self.isPinned = isPinned
        self.snoozedUntil = snoozedUntil
        self.senderDecision = senderDecision
    }

    public var initials: String {
        sender.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined()
    }

    public func isSnoozed(at now: Date) -> Bool {
        guard let snoozedUntil else { return false }
        return snoozedUntil > now
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
