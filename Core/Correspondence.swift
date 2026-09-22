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

    public init(id: ThreadID, sender: String, senderEmail: String? = nil, organization: String, subject: String,
                excerpt: String, body: String, htmlBody: String? = nil, messageIdHeader: String? = nil,
                receivedAt: Date, dueAt: Date?, reason: String, attention: Attention,
                isPinned: Bool = false, snoozedUntil: Date? = nil) {
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
public struct Draft: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable { case new, reply, replyAll, forward }

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
        return threads.filter { item in
            (!hideSnoozed || !item.isSnoozed(at: now)) &&
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
