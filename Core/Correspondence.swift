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
    /// Read/unread, orthogonal to `attention`: a thread can be Handled and
    /// still unread, or Needs You and already read. Seeded from Gmail's own
    /// `UNREAD` label at sync time (real mail always starts here in sync
    /// with Gmail; sample threads default read), but a manual toggle
    /// (`MailRepository.setUnread`) is its own fact afterward, the same way
    /// `attention` stops following Gmail's read state the moment a person
    /// makes their own decision about a thread (see ADR 002).
    public var isUnread: Bool
    /// Gmail's own raw label ids for this thread's latest message,
    /// unfiltered (system labels like INBOX/UNREAD/SENT/CATEGORY_* are
    /// mixed in alongside real user-created ones; Gmail's per-message
    /// resource carries no type info to tell them apart, only the separate
    /// labels catalog does). Deliberately just opaque provider ids here, the
    /// same treatment `latestMessageID`/`messageIdHeader` already get,
    /// rather than a richer type: the App layer's label directory (fetched
    /// once from Gmail's labels list, which does carry type/name) is what
    /// turns an id into something displayable, and filters out the system
    /// ones. Empty for sample/fictional threads.
    public var labelIds: [String]
    /// The original message's other recipients (bare addresses, lowercased),
    /// parsed from Gmail's own `To`/`Cc` headers. Per-message, like
    /// `attachments`: whichever message is currently latest is the one that
    /// matters. Exists for exactly one reason: `draft(kind: .replyAll)`
    /// cannot correctly reply to everyone without knowing who else was on
    /// the original message, and until this was added, Corres never
    /// captured that at all — "Reply All" silently behaved exactly like
    /// "Reply," a real, reported correctness bug, not a missing feature.
    public let toRecipients: [String]
    public let ccRecipients: [String]
    /// The `latestMessageID` semantic triage (`SemanticTriageService`) was
    /// last actually run against for this thread, or nil if it never has
    /// been. Deliberately left out of `updatingContent`'s explicit field
    /// list below: a genuinely new message arriving always builds its
    /// `Correspondence` fresh from Gmail (via `GmailAPIClient.map`), which
    /// never sets this itself, so it naturally comes back `nil` exactly
    /// when a new message means "this needs triage again" — the same
    /// signal already needed, for free, with no extra bookkeeping.
    public var triagedMessageID: String?
    /// `List-Unsubscribe` (RFC 2369), split into its two possible forms: a
    /// `mailto:` URI (the address plus any `?subject=...` query already
    /// attached, exactly as the sender wrote it) and/or an `https://` URL. A
    /// message can carry either, both, or neither; per-message, not
    /// per-sender, so refreshed from whichever message is currently latest
    /// (see `updatingContent`), same as `attachments`.
    public let listUnsubscribeMailto: String?
    public let listUnsubscribeURL: String?
    /// `List-Unsubscribe-Post` (RFC 8058): present means the sender is
    /// explicitly vouching that `listUnsubscribeURL` is safe to POST to
    /// automatically, no page visit or confirmation needed on their end.
    /// This is what lets `UnsubscribeService` prefer a real one-click POST
    /// over sending a `mailto:` opt-out message, when both are offered.
    public let listUnsubscribeOneClick: Bool
    /// A per-sender fact, stamped and propagated the same way
    /// `imagesTrusted`/`senderDecision` already are (see
    /// `MailRepository.markSenderUnsubscribed`): once acted on for one
    /// message from a sender, the unsubscribe banner has no reason to keep
    /// asking again for that sender's future mail.
    public var senderUnsubscribed: Bool
    /// Whether `body`/`htmlBody`/`attachments` hold the real message yet.
    /// Sync lists metadata first (sender, subject, snippet, labels) so the
    /// inbox appears in a second, then fills bodies in behind it; until
    /// then `body` is the snippet. Opening an unloaded thread loads it
    /// immediately.
    public var isBodyLoaded: Bool

    /// Flagged in iOS Mail, starred in Gmail: the same thing underneath, a
    /// Gmail `STARRED` label, so it mirrors both ways through the labels
    /// Corres already syncs. Distinct from `isPinned`, which is Corres's
    /// own "keep at top" and never leaves the device.
    public var isFlagged: Bool { labelIds.contains("STARRED") }

    public init(id: ThreadID, sender: String, senderEmail: String? = nil, organization: String, subject: String,
                excerpt: String, body: String, htmlBody: String? = nil, messageIdHeader: String? = nil,
                latestMessageID: String? = nil, receivedAt: Date, dueAt: Date?, reason: String, attention: Attention,
                isPinned: Bool = false, snoozedUntil: Date? = nil, senderDecision: SenderDecision = .approved,
                imagesTrusted: Bool = false, attachments: [MailAttachment] = [], isUnread: Bool = false,
                labelIds: [String] = [], toRecipients: [String] = [], ccRecipients: [String] = [],
                triagedMessageID: String? = nil,
                listUnsubscribeMailto: String? = nil, listUnsubscribeURL: String? = nil,
                listUnsubscribeOneClick: Bool = false, senderUnsubscribed: Bool = false,
                isBodyLoaded: Bool = true) {
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
        self.isUnread = isUnread
        self.labelIds = labelIds
        self.toRecipients = toRecipients
        self.triagedMessageID = triagedMessageID
        self.ccRecipients = ccRecipients
        self.listUnsubscribeMailto = listUnsubscribeMailto
        self.listUnsubscribeURL = listUnsubscribeURL
        self.listUnsubscribeOneClick = listUnsubscribeOneClick
        self.senderUnsubscribed = senderUnsubscribed
        self.isBodyLoaded = isBodyLoaded
    }

    public var initials: String {
        sender.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined()
    }

    public func isSnoozed(at now: Date) -> Bool {
        guard let snoozedUntil else { return false }
        return snoozedUntil > now
    }

    /// Real, RFC-grounded signals this message is bulk/automated mail
    /// rather than personal correspondence, not a guess: a `List-Unsubscribe`
    /// header (RFC 2369, already captured for the unsubscribe feature) is a
    /// near-certain marker, and a `no-reply@`/`noreply@`-style sender
    /// address is the same heuristic automated-reply-suppression systems
    /// already use industry-wide. Fed to `SemanticTriageService` as real
    /// context alongside the message itself, not used to decide anything on
    /// its own.
    public var looksAutomated: Bool {
        Self.isAutomated(listUnsubscribeMailto: listUnsubscribeMailto, listUnsubscribeURL: listUnsubscribeURL, senderEmail: senderEmail)
    }

    public static func isAutomated(listUnsubscribeMailto: String?, listUnsubscribeURL: String?, senderEmail: String?) -> Bool {
        if listUnsubscribeMailto != nil || listUnsubscribeURL != nil { return true }
        guard let senderEmail else { return false }
        return senderEmail.lowercased().range(of: #"^no.?reply@"#, options: .regularExpression) != nil
    }

    /// Whether `account` was addressed directly (`To`) rather than only
    /// copied (`Cc`) on this message — a real signal of whether a reply is
    /// actually expected of them, not a guess.
    public var isDirectRecipient: Bool {
        toRecipients.contains(id.account.lowercased())
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
            senderDecision: senderDecision, imagesTrusted: imagesTrusted, attachments: incoming.attachments,
            isUnread: preserveAttention ? isUnread : incoming.isUnread,
            // Labels reflect genuine Gmail mailbox-organization state, not a
            // triage decision Corres invented (unlike attention/reason):
            // always take the freshest known value, regardless of which
            // side sent the message that happened to trigger this update.
            labelIds: incoming.labelIds,
            toRecipients: incoming.toRecipients, ccRecipients: incoming.ccRecipients,
            // Per-message, like attachments: whatever the latest message
            // actually offers, not frozen from an earlier one.
            listUnsubscribeMailto: incoming.listUnsubscribeMailto, listUnsubscribeURL: incoming.listUnsubscribeURL,
            listUnsubscribeOneClick: incoming.listUnsubscribeOneClick,
            // Per-sender, like imagesTrusted/senderDecision: once acted on,
            // stays acted on regardless of what a later message offers.
            senderUnsubscribed: senderUnsubscribed,
            isBodyLoaded: incoming.isBodyLoaded)
    }
}

/// A message the user is composing: a reply/forward in an existing conversation, or a new one.
/// Codable so it can round-trip through the durable outbox (ADR 005/007);
/// see OutboxRecord.
/// A file the person is attaching to an outgoing message, held entirely in
/// memory (and, for a queued send, JSON-encoded into the durable outbox
/// alongside the rest of the `Draft`, the same one-column choice
/// `PersistedOutboxEntry` already made) rather than written through a
/// separate blob store: attachments are capped small enough (see
/// `Draft.maxAttachmentsBytes`) that this is simple and correct, not a
/// deliberate choice to scale to large files.
public struct PendingAttachment: Identifiable, Hashable, Sendable, Codable {
    public let id: UUID
    public let filename: String
    public let mimeType: String
    public let data: Data

    public init(id: UUID = UUID(), filename: String, mimeType: String, data: Data) {
        self.id = id
        self.filename = filename
        self.mimeType = mimeType
        self.data = data
    }
}

public struct Draft: Identifiable, Hashable, Sendable, Codable {
    public enum Kind: String, Hashable, Sendable, Codable { case new, reply, replyAll, forward }

    /// Gmail's own real limit on a single outgoing message (25 MB), enforced
    /// here rather than only discovered as a send failure after the person
    /// already waited through the undo window.
    public static let maxAttachmentsBytes = 25_000_000

    public let id: UUID
    public let kind: Kind
    public let threadID: ThreadID?
    /// Which connected Gmail account this sends as. Always derivable for a
    /// reply/forward (`threadID.account`); only meaningfully ambiguous for a
    /// brand-new compose with more than one account connected, which is why
    /// ComposeView surfaces a "From" picker exactly when this matters. `nil`
    /// falls back to the first connected account (see `OutboxService`),
    /// matching pre-multi-account behavior for anyone with just one.
    public var fromAccount: String?
    public var to: String
    /// Comma-separated, matching `to`'s own shape; empty/nil both mean "no
    /// Cc." `Optional`, not a plain `String = ""`, specifically so an
    /// already-queued outbox entry's persisted JSON (from before this field
    /// existed) still decodes: a non-optional property with only an
    /// initializer default still needs the key present to decode
    /// successfully, but Swift's synthesized `Decodable` treats a missing
    /// key as `nil` automatically for a genuinely `Optional` property (the
    /// same reasoning already applied to `fromAccount` above).
    public var cc: String?
    public var subject: String
    public var body: String
    public var attachments: [PendingAttachment]

    public init(id: UUID = UUID(), kind: Kind, threadID: ThreadID? = nil, fromAccount: String? = nil,
                to: String, cc: String? = nil, subject: String, body: String = "", attachments: [PendingAttachment] = []) {
        self.id = id
        self.kind = kind
        self.threadID = threadID
        self.fromAccount = fromAccount
        self.to = to
        self.cc = cc
        self.subject = subject
        self.body = body
        self.attachments = attachments
    }

    public var isSendable: Bool {
        !to.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var attachmentsSizeBytes: Int { attachments.reduce(0) { $0 + $1.data.count } }
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
        // Same exclusions `MailQuery.filter` applies to the lists these
        // counts link to; without the Screener check, Brief said 149 while
        // the Needs You list it opens showed 110.
        let active = threads.filter { !$0.isSnoozed(at: now) && $0.senderDecision == .approved }
        needsYou = active.filter { $0.attention == .needsYou }.count
        waiting = active.filter { $0.attention == .waiting }.count
        upcoming = active.filter {
            guard $0.attention == .needsYou, let due = $0.dueAt else { return false }
            return due >= now && due <= now.addingTimeInterval(horizon)
        }.count
    }
}

/// A change made to an already-synced message somewhere else — read in
/// Gmail's own app, archived on the web, deleted from Apple Mail — as
/// reported by Gmail's history API. Provider-neutral so the repository can
/// apply it without knowing Gmail's wire format (ADR 002).
public struct RemoteMessageChange: Sendable, Equatable {
    public let threadID: ThreadID
    public let messageID: String
    /// The message's full current label set after the change, when known.
    public let currentLabelIds: [String]?
    /// Archived, trashed, marked spam, or deleted elsewhere: the thread
    /// leaves Corres exactly as it would after archiving it here.
    public let removed: Bool

    public init(threadID: ThreadID, messageID: String, currentLabelIds: [String]?, removed: Bool) {
        self.threadID = threadID
        self.messageID = messageID
        self.currentLabelIds = currentLabelIds
        self.removed = removed
    }
}

/// Decides where a freshly-synced message starts, before any on-device AI
/// looks at it. Needs You is opt-in, not the default: every reference
/// client that does this well (Gmail's Primary tab, Apple Mail's Primary
/// category, Superhuman's Important split, Spark's People) starts from
/// "not important" and admits only person-to-person mail, sending
/// marketing, social, and automated updates elsewhere. Corres used to do
/// the opposite — every unread message was Needs You — which buried the
/// handful of real ones under store promotions and newsletters.
///
/// Rules first, AI second: this works identically on every device,
/// whether or not Apple Intelligence is available, so Needs You is never
/// only as good as whether the model happens to be ready.
public enum InboxClassifier {
    /// Where a message was sorted out of Needs You, and why. `updates` and
    /// `automated` are the only kinds `SemanticTriageService` may promote
    /// back in (a bill due, a flight change, a verification request);
    /// promotions, social, and mailing-list mail never are, since marketing
    /// copy routinely dresses itself up as urgent ("sale ends tonight").
    public enum BulkKind: Sendable {
        case promotions, social, forums, updates, automated

        public var reason: String {
            switch self {
            case .promotions: "Promotion. Kept out of Needs You."
            case .social: "Social notification. Kept out of Needs You."
            case .forums: "Mailing list. Kept out of Needs You."
            case .updates: "Automated update. Kept out of Needs You."
            case .automated: "Bulk mail. Kept out of Needs You."
            }
        }

        public var isPromotable: Bool { self == .updates || self == .automated }
    }

    /// The reason every unread message used to get, whatever it was.
    /// Kept only so `MailRepository.reclassifyLegacySyncDefaults` can find
    /// threads whose attention came from that old default and nothing else.
    public static let legacyUnreadReason = "Unread in Gmail."
    public static let personalUnreadReason = "Unread, from a person."
    public static let correspondentReason = "Unread, from someone you've written to."
    public static let staleReason = "Unread for over a month. Kept out of Needs You."
    public static let readReason = "Already read in Gmail."

    /// Every reason these rules can produce for unread mail: a thread
    /// carrying one of these (and never triaged) still reflects a pure rule
    /// decision nobody has overridden, so re-running the rules is safe.
    public static let ruleReasons: Set<String> = [legacyUnreadReason, personalUnreadReason, correspondentReason, staleReason,
                                                  BulkKind.promotions.reason, BulkKind.social.reason, BulkKind.forums.reason,
                                                  BulkKind.updates.reason, BulkKind.automated.reason]

    /// Sync now reaches hundreds of messages back; an unread personal email
    /// from months ago is history, not a decision waiting on you, and would
    /// otherwise flood Needs You on first sync. Still in Mail, still
    /// searchable.
    public static let staleAfter: TimeInterval = 30 * 86_400

    public static func isStale(receivedAt: Date, now: Date) -> Bool {
        now.timeIntervalSince(receivedAt) > staleAfter
    }

    /// Gmail Priority Inbox's own strongest signal is who you email, and
    /// Apple Mail's Primary favors your contacts; this is the local
    /// equivalent. An unread message from an address this account has
    /// itself written to is correspondence even when Gmail filed it under
    /// Updates, as it sometimes does with person-to-person mail. A
    /// `List-Unsubscribe` header still wins: replying once to a company's
    /// support address shouldn't let its newsletters through.
    public static func correspondentOverride(isUnread: Bool, hasListUnsubscribe: Bool, isCorrespondent: Bool,
                                             isStale: Bool = false) -> (attention: Attention, reason: String)? {
        guard isUnread, isCorrespondent, !hasListUnsubscribe, !isStale else { return nil }
        return (.needsYou, correspondentReason)
    }

    /// Gmail's own category labels come first because Gmail's classifier
    /// has seen the whole message and the sender's history, far more than
    /// anything available here. The unsubscribe/no-reply check catches
    /// bulk mail Gmail left uncategorized (or an account with categories
    /// turned off).
    public static func bulkKind(labelIds: [String], looksAutomated: Bool) -> BulkKind? {
        let labels = Set(labelIds)
        if labels.contains("CATEGORY_PROMOTIONS") { return .promotions }
        if labels.contains("CATEGORY_SOCIAL") { return .social }
        if labels.contains("CATEGORY_FORUMS") { return .forums }
        if labels.contains("CATEGORY_UPDATES") { return .updates }
        if looksAutomated { return .automated }
        return nil
    }

    public static func initialAttention(isUnread: Bool, labelIds: [String], looksAutomated: Bool,
                                        receivedAt: Date? = nil, now: Date = .now) -> (attention: Attention, reason: String) {
        guard isUnread else { return (.quiet, readReason) }
        if let kind = bulkKind(labelIds: labelIds, looksAutomated: looksAutomated) {
            return (.quiet, kind.reason)
        }
        if let receivedAt, isStale(receivedAt: receivedAt, now: now) {
            return (.quiet, staleReason)
        }
        return (.needsYou, personalUnreadReason)
    }
}

public extension String {
    /// Gmail's `snippet` field is HTML-escaped (`Don&#39;t`, `&amp;`), and
    /// was being shown verbatim in every row preview and notification.
    var decodingHTMLEntities: String {
        guard contains("&") else { return self }
        let named: [String: String] = ["amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " "]
        var result = ""
        var index = startIndex
        while index < endIndex {
            if self[index] == "&", let semicolon = self[index...].prefix(10).firstIndex(of: ";") {
                let entity = self[self.index(after: index)..<semicolon]
                var decoded: String?
                if entity.hasPrefix("#x") || entity.hasPrefix("#X") {
                    decoded = UInt32(entity.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
                } else if entity.hasPrefix("#") {
                    decoded = UInt32(entity.dropFirst()).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
                } else {
                    decoded = named[String(entity)]
                }
                if let decoded {
                    result += decoded
                    index = self.index(after: semicolon)
                    continue
                }
            }
            result.append(self[index])
            index = self.index(after: index)
        }
        return result
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
