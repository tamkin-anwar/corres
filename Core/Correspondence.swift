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
        case .needsYou: String(localized: "Needs You")
        case .waiting: String(localized: "Waiting")
        case .quiet: String(localized: "No action needed")
        case .handled: String(localized: "Handled")
        }
    }

    /// What each one means, shown under its name wherever you choose one
    /// (testers found the bare names arbitrary).
    public var explanation: String {
        switch self {
        case .needsYou: String(localized: "Asks something of you")
        case .waiting: String(localized: "You're waiting on their reply")
        case .quiet: String(localized: "Nothing for you to do")
        case .handled: String(localized: "Done: off your lists, still in Mail")
        }
    }

    /// Where you can move a conversation yourself. "No action needed" is
    /// Corres's own call for everything else; offered beside Handled it
    /// did the same thing under a vaguer name, and a tester lost mail to it.
    public static let choices: [Attention] = [.needsYou, .waiting, .handled]
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
    /// The message's Reply-To addresses: where a reply goes instead of the
    /// sender, when set.
    public let replyTo: [String]
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
    /// When this conversation started waiting on someone else: the moment
    /// you replied, or moved it to Waiting yourself. Nil for anything not
    /// waiting, and for threads that predate it (see `waitingReference`).
    public var waitingSince: Date?
    /// When you last wrote in this conversation, from any app; nil if you
    /// never have. Sent lists these, newest first.
    public var lastSentAt: Date?

    /// Flagged in iOS Mail, starred in Gmail: the same thing underneath, a
    /// Gmail `STARRED` label, so it mirrors both ways through the labels
    /// Corres already syncs. Distinct from `isPinned`, which is Corres's
    /// own "keep at top" and never leaves the device.
    public var isFlagged: Bool { labelIds.contains("STARRED") }

    /// Mail kept only so it can be found: archived, or in another folder,
    /// found by a search or by the background index of older mail. It
    /// never shows in Needs You, Waiting or Mail, as it doesn't in the
    /// Inbox of the service it lives in; Search finds it.
    public var isArchivedCopy: Bool {
        !labelIds.isEmpty && !labelIds.contains("INBOX") && !labelIds.contains("SENT") && !labelIds.contains("DRAFT")
    }

    public init(id: ThreadID, sender: String, senderEmail: String? = nil, organization: String, subject: String,
                excerpt: String, body: String, htmlBody: String? = nil, messageIdHeader: String? = nil,
                latestMessageID: String? = nil, receivedAt: Date, dueAt: Date?, reason: String, attention: Attention,
                isPinned: Bool = false, snoozedUntil: Date? = nil, senderDecision: SenderDecision = .approved,
                imagesTrusted: Bool = false, attachments: [MailAttachment] = [], isUnread: Bool = false,
                labelIds: [String] = [], toRecipients: [String] = [], ccRecipients: [String] = [], replyTo: [String] = [],
                triagedMessageID: String? = nil,
                listUnsubscribeMailto: String? = nil, listUnsubscribeURL: String? = nil,
                listUnsubscribeOneClick: Bool = false, senderUnsubscribed: Bool = false,
                isBodyLoaded: Bool = true, waitingSince: Date? = nil, lastSentAt: Date? = nil) {
        self.id = id
        // Sent with only an address: a name made from it, as people read it.
        self.sender = sender.contains("@") && PeopleIndex.isAddress(sender.trimmingCharacters(in: .whitespaces))
            ? Person.name(forAddress: sender.trimmingCharacters(in: .whitespaces)) : Person.readable(sender)
        self.senderEmail = senderEmail
        self.organization = organization
        self.subject = subject
        // "- Official - ITW…": a protective marking isn't the email.
        // Only a marking: set off by dashes or brackets ("- Official -",
        // "[OFFICIAL]") or in capitals; "Official results are in" stays.
        self.excerpt = excerpt.patternRange(#"^\s*(?:(?i:[\[\-–—]\s*(official(-sensitive)?|unclassified)\s*[\]\-–—])|(OFFICIAL(-SENSITIVE)?|UNCLASSIFIED)(?=\s))\s*"#).map { String(excerpt[$0.upperBound...]) } ?? excerpt
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
        self.replyTo = replyTo
        self.listUnsubscribeMailto = listUnsubscribeMailto
        self.listUnsubscribeURL = listUnsubscribeURL
        self.listUnsubscribeOneClick = listUnsubscribeOneClick
        self.senderUnsubscribed = senderUnsubscribed
        self.isBodyLoaded = isBodyLoaded
        self.waitingSince = waitingSince
        self.lastSentAt = lastSentAt ?? (senderEmail?.lowercased() == id.account.lowercased() ? receivedAt : nil)
    }

    /// What "waiting for N days" counts from: when you replied or moved it,
    /// falling back to the latest message for threads from before that was
    /// recorded.
    public var waitingReference: Date { waitingSince ?? receivedAt }

    /// "MF" for "myFICO Member Services", "MB" for "☕ Morning Brew":
    /// capitals, from words that start with a letter or digit.
    public var initials: String {
        sender.split(separator: " ").compactMap { $0.first(where: { $0.isLetter || $0.isNumber }) }
            .prefix(2).map { String($0).uppercased() }.joined()
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
        // A message never changes once sent: its answer is kept, keyed by
        // the message and whether its body has loaded yet.
        let key = "\(id.account)|\(id.providerID)|\(latestMessageID ?? subject)|\(isBodyLoaded)|\(listUnsubscribeMailto != nil || listUnsubscribeURL != nil)"
        return Self.automatedMemo.value(key) {
            Self.isAutomated(listUnsubscribeMailto: listUnsubscribeMailto, listUnsubscribeURL: listUnsubscribeURL, senderEmail: senderEmail,
                             senderName: sender, body: isBodyLoaded ? body : nil, html: htmlBody)
        }
    }
    private static let automatedMemo = Memo<String, Bool>()

    private static let automatedSenderMemo = Memo<String, Bool>()

    public static let automatedLocalPart =
        // A prefix too: "testflight_no_reply@" is as automated as "noreply@".
        #"^([^@]*[-_.])?(no[-_.]?reply|do[-_.]?not[-_.]?reply|notifications?|alerts?|mailer-daemon|postmaster|bounces?)([-_.+][^@]*)?@"#

    /// `senderName`, `body` (the full text, once loaded) and `html` catch
    /// bulk mail with no List-Unsubscribe, the kind Gmail would file as
    /// spam but Outlook's Focused often lets through.
    public static func isAutomated(listUnsubscribeMailto: String?, listUnsubscribeURL: String?, senderEmail: String?,
                                   senderName: String? = nil, body: String? = nil, html: String? = nil) -> Bool {
        if listUnsubscribeMailto != nil || listUnsubscribeURL != nil { return true }
        guard let senderEmail else { return false }
        // "noreply@", but also "noreply-purchases@", "no_reply.alerts@",
        // "donotreply@" and system senders like "notifications@".
        if automatedSenderMemo.value(senderEmail + "\u{1}" + (senderName ?? ""), {
            senderEmail.lowercased().patternRange(automatedLocalPart) != nil
                || senderName.map { namesAnotherSite($0, senderEmail: senderEmail) } == true
        }) { return true }
        if let body, let html, isRemoteImageOnly(body: body, html: html) { return true }
        return false
    }

    /// "Healthcare.com-ACA" <customerservice@retail.ispy-tech.com>: a name
    /// that is a website, sent from a different one. A real Booking.com
    /// email comes from booking.com (or mail.booking.com); a person's name
    /// is never a domain.
    static func namesAnotherSite(_ name: String, senderEmail: String) -> Bool {
        guard let match = name.lowercased().patternRange(#"\b[a-z0-9-]+\.(com|net|org|co|io|gov|us|info|biz)\b"#)
        else { return false }
        let named = String(name.lowercased()[match])
        let domain = senderEmail.lowercased().components(separatedBy: "@").last ?? ""
        return !(domain == named || domain.hasSuffix("." + named))
    }

    /// Nothing to read but pictures fetched from the web: a flyer, not a
    /// letter. A person's photo is embedded in the email (cid: or data:),
    /// never fetched, so it never counts.
    static func isRemoteImageOnly(body: String, html: String) -> Bool {
        // Counted only up to 8: splitting a whole newsletter into words to
        // learn it has more than seven was a real cost on every refresh.
        var words = 0
        var inWord = false
        for ch in body {
            if ch.isWhitespace || ch.isNewline { inWord = false } else if !inWord {
                inWord = true
                words += 1
                if words >= 8 { return false }
            }
        }
        let lower = html.lowercased()
        guard lower.patternRange(#"<img[^>]+src\s*=\s*["']?https?:"#) != nil else { return false }
        return lower.patternRange(#"<img[^>]+src\s*=\s*["']?(cid|data):"#) == nil
    }

    /// Whether `account` was addressed directly (`To`) rather than only
    /// copied (`Cc`) on this message — a real signal of whether a reply is
    /// actually expected of them, not a guess.
    public var isDirectRecipient: Bool {
        toRecipients.contains(id.account.lowercased())
    }

    /// Named in Cc but not in To. Only this exact case counts: mail that
    /// reached you through an alias or a group names neither, and isn't
    /// "copied".
    public var isCopiedOnly: Bool {
        Self.isCopiedOnly(account: id.account, to: toRecipients, cc: ccRecipients)
    }

    public static func isCopiedOnly(account: String, to: [String], cc: [String]) -> Bool {
        let me = account.lowercased()
        return cc.contains(me) && !to.contains(me)
    }

    /// Whether the latest message in this thread is your own.
    public var isFromAccountOwner: Bool {
        senderEmail?.lowercased() == id.account.lowercased()
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
            toRecipients: incoming.toRecipients, ccRecipients: incoming.ccRecipients, replyTo: incoming.replyTo,
            // Per-message, like attachments: whatever the latest message
            // actually offers, not frozen from an earlier one.
            listUnsubscribeMailto: incoming.listUnsubscribeMailto, listUnsubscribeURL: incoming.listUnsubscribeURL,
            listUnsubscribeOneClick: incoming.listUnsubscribeOneClick,
            // Per-sender, like imagesTrusted/senderDecision: once acted on,
            // stays acted on regardless of what a later message offers.
            senderUnsubscribed: senderUnsubscribed,
            isBodyLoaded: incoming.isBodyLoaded,
            waitingSince: preserveAttention ? waitingSince : nil,
            lastSentAt: [lastSentAt, incoming.lastSentAt].compactMap { $0 }.max())
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

extension Correspondence {
    /// A conversation you just started, as Corres records it the moment it's
    /// sent. Gmail's own copy (`sentCopy`) when Corres could fetch it: the
    /// real sender, recipients, labels and message id. Otherwise built from
    /// the draft, as yours: an earlier version used the recipient as the
    /// sender, so a new email showed as received from them, "To you", next
    /// to the real one.
    public static func started(by draft: Draft, id: ThreadID, sentAt: Date, sentCopy: Correspondence?,
                               attention: Attention, reason: String) -> Correspondence {
        var started = sentCopy ?? Correspondence(
            id: id, sender: "You", senderEmail: id.account, organization: "",
            subject: draft.subject.trimmingCharacters(in: .whitespacesAndNewlines),
            excerpt: draft.body, body: draft.body, receivedAt: sentAt, dueAt: nil,
            reason: reason, attention: attention, isUnread: false, labelIds: ["SENT"],
            toRecipients: Self.addresses(draft.to), ccRecipients: Self.addresses(draft.cc ?? ""))
        started.reason = reason
        started.attention = attention
        started.isUnread = false
        started.waitingSince = attention == .waiting ? sentAt : nil
        started.lastSentAt = sentAt
        return started
    }

    private static func addresses(_ list: String) -> [String] {
        PeopleIndex.entries(in: list)
    }

    /// Who a conversation went to, for showing a message you sent: "Maya
    /// Chen" from "Maya Chen <maya@example.com>", or the address.
    public var recipientNames: [String] {
        (toRecipients + ccRecipients).map { entry in
            let name = entry.components(separatedBy: "<").first?
                .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\""))) ?? ""
            if !name.isEmpty, !entry.hasPrefix("<") { return name }
            return entry.trimmingCharacters(in: CharacterSet(charactersIn: "<> "))
        }
    }
}

extension Correspondence {
    /// Who a reply goes to, as Mail and Gmail decide it: the message's
    /// Reply-To when it has one (support desks and lists send from no-reply
    /// addresses), the sender otherwise, and, when the last message is
    /// yours, the people you wrote to. Replying to your own message used to
    /// address the reply to you.
    /// You got this without being in its To or Cc: Bcc'd, or forwarded to
    /// you by a rule. Replying to all would show everyone you had it, so
    /// Compose says so first, as Gmail does. Not for mailing lists, where
    /// nobody is listed by name.
    public var reachedYouHidden: Bool {
        guard !isFromAccountOwner, listUnsubscribeMailto == nil, listUnsubscribeURL == nil else { return false }
        let me = id.account.lowercased()
        return !(toRecipients + ccRecipients).contains { $0.lowercased() == me }
    }

    public var replyAddresses: [String] {
        if isFromAccountOwner {
            let others = toRecipients.filter { $0.lowercased() != id.account.lowercased() }
            return others.isEmpty ? [senderEmail ?? sender] : others
        }
        if !replyTo.isEmpty { return replyTo }
        return [senderEmail ?? sender]
    }

    /// The other person in a conversation: the sender, or, when the latest
    /// message is yours (everything in Waiting), who you wrote to. Named as
    /// they sign their own mail when any of it is here (`knownNames`, from
    /// `knownSenderNames`), else from their address. Waiting used to read
    /// "Tamkin hasn't replied" about your own message.
    public func counterpartName(knownNames: [String: String] = [:]) -> String {
        guard isFromAccountOwner, let address = (toRecipients + ccRecipients).first(where: {
            $0.lowercased() != id.account.lowercased()
        }) else { return sender }
        let bare = address.components(separatedBy: "<").last?
            .trimmingCharacters(in: CharacterSet(charactersIn: "<> ")).lowercased() ?? address.lowercased()
        if let known = knownNames[bare] { return known }
        if let named = recipientNames.first, !named.contains("@") { return named }
        return Self.name(fromAddress: bare)
    }

    /// Everyone who has written to you, by address, as they sign.
    public static func knownSenderNames(_ threads: [Correspondence]) -> [String: String] {
        var names: [String: String] = [:]
        for thread in threads where !thread.isFromAccountOwner {
            if let email = thread.senderEmail?.lowercased(), names[email] == nil, !thread.sender.contains("@") {
                names[email] = thread.sender
            }
        }
        return names
    }

    /// An appointment or event in Needs You whose day is over: nothing is
    /// left to do, so it's out of Needs You (it stays in Mail), and shows
    /// "Was Sep 28" rather than "Overdue".
    public func isPastEvent(at now: Date = .now) -> Bool {
        guard attention == .needsYou, let due = dueAt, due < Calendar.current.startOfDay(for: now) else { return false }
        return MailSignals.isEvent(subject + "\n" + excerpt)
    }

    /// Where it sits now: a past event has left Needs You on its own.
    public func attention(at now: Date) -> Attention {
        isPastEvent(at: now) ? .quiet : attention
    }

    /// "sam.lee@example.com" reads as "Sam Lee".
    static func name(fromAddress address: String) -> String {
        let local = address.components(separatedBy: "@").first ?? address
        let words = local.split(whereSeparator: { ".-_+".contains($0) }).filter { !$0.allSatisfy(\.isNumber) }
        return words.isEmpty ? address : words.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }

    /// Reply All's Cc: everyone else on the message, never you or anyone
    /// already in To. A no-reply sender replaced by Reply-To isn't added
    /// back.
    public var replyAllCc: [String] {
        let me = id.account.lowercased()
        var seen = Set([me, (senderEmail ?? "").lowercased()] + replyAddresses.map { $0.lowercased() })
        var result: [String] = []
        let others = isFromAccountOwner ? ccRecipients : toRecipients + ccRecipients
        for email in others {
            let lowered = email.lowercased()
            guard !seen.contains(lowered) else { continue }
            seen.insert(lowered)
            result.append(email)
        }
        return result
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
    /// One of the account's Gmail send-as addresses ("hello@studio.com"),
    /// with its display name, when sending as other than the account's own
    /// address. Optional, like `cc`, so older queued sends decode.
    public var fromAddress: String?
    public var fromName: String?
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
    /// Like `cc`; optional for the same reason. Never stored on the sent
    /// message's local copy or shown to anyone else.
    public var bcc: String?
    public var subject: String
    public var body: String
    /// The same words as HTML when they're formatted (bold, lists, links);
    /// nil for plain text. Optional so older drafts decode.
    public var bodyHTML: String?
    /// An answer to a calendar invitation (iTIP METHOD:REPLY), sent as the
    /// email's calendar part. Optional so older drafts decode.
    public var calendarReply: String?
    /// "Remind me if no reply": how long after sending. Optional so older
    /// drafts decode.
    public var followUpAfter: TimeInterval?
    public var attachments: [PendingAttachment]
    /// The Gmail draft this was opened from (Mailboxes → Drafts), deleted
    /// once this is sent so the draft doesn't linger after it's gone out.
    public var gmailDraftID: String?

    public init(id: UUID = UUID(), kind: Kind, threadID: ThreadID? = nil, fromAccount: String? = nil,
                to: String, cc: String? = nil, bcc: String? = nil, subject: String, body: String = "", attachments: [PendingAttachment] = []) {
        self.id = id
        self.kind = kind
        self.threadID = threadID
        self.fromAccount = fromAccount
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.subject = subject
        self.body = body
        self.attachments = attachments
    }

    /// A recipient is enough; a missing subject is asked about, not
    /// blocked, the way Mail and Gmail both handle it.
    /// Bcc alone is enough too, as in Mail and Gmail.
    public var isSendable: Bool {
        [to, cc ?? "", bcc ?? ""].contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    public var hasSubject: Bool { !subject.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Every address in To, Cc and Bcc is shaped like one ("maya@x.com" or
    /// "Maya <maya@x.com>"), so a typo is caught before the undo window,
    /// not reported as a failed send after it.
    public var recipientsLookValid: Bool {
        // Split where an address list splits: `"Doe, Jane" <jane@x.com>` is one.
        let all = PeopleIndex.entries(in: to) + PeopleIndex.entries(in: cc ?? "") + PeopleIndex.entries(in: bcc ?? "")
        return !all.isEmpty && all.allSatisfy { PeopleIndex.parse($0) != nil }
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
        let active = threads.filter { !$0.isSnoozed(at: now) && !$0.isScreenedOut }
        needsYou = active.filter { $0.attention(at: now) == .needsYou }.count
        waiting = active.filter { $0.attention == .waiting }.count
        upcoming = active.filter {
            guard $0.attention(at: now) == .needsYou, let due = $0.dueAt else { return false }
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
    public static let readReason = "Already read."
    /// What `readReason` said before it was provider-neutral; still
    /// recognized on mail stored with it.
    public static let legacyReadReason = "Already read in Gmail."
    public static let questionReason = "Asks you something."
    public static let deadlineReason = "Mentions a deadline."
    public static let obligationReason = "Time-sensitive."
    public static let copiedReason = "You're copied, not asked. Kept out of Needs You."
    /// Where a thread goes after you write in it, from any app: Waiting if
    /// you asked something of a person, otherwise done for now.
    public static let vipReason = "From a VIP."
    public static let fyiReason = "From a person, nothing asked. Kept out of Needs You."
    public static let askedReason = "You asked. No reply yet."
    public static let repliedReason = "You replied. Nothing pending."
    /// A conversation you started: "replied" read wrong on a new email.
    public static let startedReason = "You sent this. Nothing pending."
    /// You told Corres a sender's mail needs nothing from you.
    public static let lessonReason = "You said mail like this needs no action."
    /// A payment failed, a card was declined, an account is on hold.
    public static let failureReason = "Something failed that only you can fix."
    /// A payment asked of you, with its amount.
    public static let paymentReason = "Asks you to pay."
    /// "You allowed Corres access…": nothing to do unless it wasn't you.
    /// Moved by the on-device check when it gave no reason we could show.
    /// Promotions without one no longer happen; kept to repair rows that
    /// carry it.
    public static let promotedReason = "Reads like it needs something from you."
    public static let demotedReason = "Nothing here asks anything of you."
    public static let fromYouReason = "From your other account. Kept out of Needs You."
    public static let confirmationReason = "Confirms something you did. Nothing to do unless it wasn't you."

    /// Every reason these rules can produce for unread mail: a thread
    /// carrying one of these (and never triaged) still reflects a pure rule
    /// decision nobody has overridden, so re-running the rules is safe.
    public static let ruleReasons: Set<String> = [legacyUnreadReason, personalUnreadReason, correspondentReason, staleReason,
                                                  readReason, legacyReadReason, questionReason, deadlineReason, obligationReason, copiedReason,
                                                  askedReason, repliedReason, startedReason, vipReason, fyiReason,
                                                  lessonReason, confirmationReason, fromYouReason, failureReason, paymentReason,
                                                  BulkKind.promotions.reason, BulkKind.social.reason, BulkKind.forums.reason,
                                                  BulkKind.updates.reason, BulkKind.automated.reason]

    /// People whose mail always lands in Needs You (lowercased addresses),
    /// set from Settings → Sorting.
    public nonisolated(unsafe) static var vipAddresses: Set<String> = []
    /// Every address that is you: your connected accounts and the aliases
    /// they send as (lowercased). Mail from one of them to another is a
    /// note to yourself, not someone needing you.
    public nonisolated(unsafe) static var ownAddresses: Set<String> = []

    /// The Screener's company rules: a new sender from a domain here gets
    /// that decision on arrival instead of waiting in the Screener
    /// ("Allow everyone from amazon.com"). Keyed by lowercased domain.
    public nonisolated(unsafe) static var domainDecisions: [String: SenderDecision] = [:]

    /// Free mail services, shared by unrelated people: never a company
    /// rule's domain.
    public static let personalDomains: Set<String> = [
        "gmail.com", "googlemail.com", "outlook.com", "hotmail.com", "live.com", "msn.com",
        "icloud.com", "me.com", "mac.com", "yahoo.com", "ymail.com", "aol.com", "proton.me",
        "protonmail.com", "pm.me", "zoho.com", "gmx.com", "gmx.net", "mail.com", "yandex.com",
        "hotmail.co.uk", "yahoo.co.uk", "btinternet.com", "outlook.co.uk", "live.co.uk",
    ]

    /// The domain a company rule would cover for this address, or nil for
    /// a free mail service. Subdomains count as the company's own
    /// ("email.amazon.com" → "amazon.com"), keeping country endings whole
    /// ("mail.tesco.co.uk" → "tesco.co.uk").
    public static func companyDomain(of email: String?) -> String? {
        guard let email, let at = email.lastIndex(of: "@") else { return nil }
        let host = email[email.index(after: at)...].lowercased()
        guard !personalDomains.contains(host) else { return nil }
        let parts = host.split(separator: ".").map(String.init)
        guard parts.count >= 2 else { return nil }
        let secondLevel = ["co", "com", "org", "net", "ac", "gov", "edu"]
        let keep = parts.count >= 3 && parts[parts.count - 1].count == 2 && secondLevel.contains(parts[parts.count - 2]) ? 3 : 2
        let domain = parts.suffix(keep).joined(separator: ".")
        return personalDomains.contains(domain) ? nil : domain
    }

    /// The company rule for a new sender, if one covers them.
    public static func domainDecision(for email: String?, rules: [String: SenderDecision]? = nil) -> SenderDecision? {
        let rules = rules ?? domainDecisions
        guard !rules.isEmpty, let domain = companyDomain(of: email) else { return nil }
        return rules[domain]
    }

    /// How much of person-to-person mail reaches Needs You.
    public enum Sensitivity: String, CaseIterable, Sendable {
        /// Only mail that asks something, has a deadline, or is from a VIP
        /// or someone you write to.
        case focused
        /// Everything written to you by a person, not mail you're copied on.
        case balanced
        /// Everything from a person, including mail you're copied on; the
        /// on-device model never moves it out.
        case inclusive
    }
    public nonisolated(unsafe) static var sensitivity: Sensitivity = .balanced

    public static func isVIP(_ senderEmail: String?) -> Bool {
        senderEmail.map { vipAddresses.contains($0.lowercased()) } ?? false
    }

    /// How long after you write something it still counts as waiting on a
    /// reply when first seen; older than this, the moment has passed.
    public static let waitingWindow: TimeInterval = 14 * 86_400

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
                                             isStale: Bool = false, isCopiedOnly: Bool = false,
                                             currentReason: String? = nil) -> (attention: Attention, reason: String)? {
        guard isUnread, isCorrespondent, !hasListUnsubscribe, !isStale,
              !isCopiedOnly || sensitivity == .inclusive else { return nil }
        // A more specific reason the rules already found says more than
        // "someone you've written to".
        if let currentReason, [questionReason, deadlineReason, vipReason].contains(currentReason) {
            return (.needsYou, currentReason)
        }
        return (.needsYou, correspondentReason)
    }

    /// The thread's latest message is yours, sent from Corres or any other
    /// app. Superhuman's "if no reply" reminders and Gmail's follow-up
    /// nudges both key off the same thing: did your message ask a person
    /// for something.
    public static func afterYouWrote(asksSomething: Bool, toPeople: Bool, sentAt: Date,
                                     now: Date = .now) -> (attention: Attention, reason: String) {
        if asksSomething, toPeople, now.timeIntervalSince(sentAt) < waitingWindow {
            return (.waiting, askedReason)
        }
        return (.quiet, repliedReason)
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

    /// `text` is the subject and whatever of the message is known yet;
    /// `deadline` comes from `MailSignals.deadline(in:)` over the same.
    public static func initialAttention(isUnread: Bool, labelIds: [String], looksAutomated: Bool,
                                        receivedAt: Date? = nil, now: Date = .now,
                                        isCopiedOnly: Bool = false, asksSomething: Bool = false,
                                        deadline: Date? = nil, text: String = "",
                                        isVIP: Bool = false,
                                        sensitivity: Sensitivity = InboxClassifier.sensitivity) -> (attention: Attention, reason: String) {
        guard isUnread else { return (.quiet, readReason) }
        let stale = receivedAt.map { isStale(receivedAt: $0, now: now) } ?? false
        if isVIP, !stale { return (.needsYou, vipReason) }
        if let kind = bulkKind(labelIds: labelIds, looksAutomated: looksAutomated) {
            // A bill due Thursday is an update that needs you; a sale ending
            // Thursday never is (promotions aren't promotable).
            if kind.isPromotable, !stale, deadline != nil, MailSignals.isObligation(text) {
                return (.needsYou, obligationReason)
            }
            // A failed payment needs you whether or not it names a date.
            if kind.isPromotable, !stale, MailSignals.isFailure(text) {
                return (.needsYou, failureReason)
            }
            if kind.isPromotable, !stale, MailSignals.isPaymentRequest(text) {
                return (.needsYou, paymentReason)
            }
            return (.quiet, kind.reason)
        }
        if stale { return (.quiet, staleReason) }
        // Copied on a thread addressed to someone else: Gmail's Priority
        // Inbox weighs To above Cc for the same reason.
        if isCopiedOnly, sensitivity != .inclusive { return (.quiet, copiedReason) }
        if deadline != nil { return (.needsYou, deadlineReason) }
        if asksSomething { return (.needsYou, questionReason) }
        if sensitivity == .focused { return (.quiet, fyiReason) }
        return (.needsYou, personalUnreadReason)
    }
}

public extension String {
    /// A row's preview line: entities decoded, and any markup a sender left
    /// in their preview text (`<a href="…">`) taken out.
    /// Inline images' placeholders (`[cid:image001.png@01DD…]`) too.
    var previewText: String {
        let decoded = decodingHTMLEntities
        guard decoded.contains("<") || decoded.contains("[cid:") else { return decoded }
        return decoded.replacingOccurrences(of: #"<[A-Za-z/!][^<>]{0,400}>"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\[cid:[^\]]{0,200}\]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

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
    /// Settings → Sorting → Screen new senders. Off (the default), a new
    /// sender's mail shows everywhere like anyone else's, marked as new,
    /// and can be allowed or blocked from the email; on, it waits in New
    /// senders until allowed. Blocked senders stay hidden either way.
    public nonisolated(unsafe) static var holdsNewSenders = false

    /// The curated lists in the order that matters: Needs You with the
    /// nearest deadline first, then newest; Waiting with whoever has gone
    /// quiet longest first, since that's the one to nudge. Pinned always
    /// leads. Mail stays chronological.
    public static func prioritized(_ threads: [Correspondence], attention: Attention,
                                   now: Date = .now, dueHorizon: TimeInterval = 3 * 86_400) -> [Correspondence] {
        let base = filter(threads, attention: attention, now: now)
        switch attention {
        case .needsYou:
            let horizon = now.addingTimeInterval(dueHorizon)
            return base.sorted {
                if $0.isPinned != $1.isPinned { return $0.isPinned }
                let a = $0.dueAt.flatMap { $0 <= horizon ? $0 : nil }
                let b = $1.dueAt.flatMap { $0 <= horizon ? $0 : nil }
                switch (a, b) {
                case let (a?, b?) where a != b: return a < b
                case (.some, nil): return true
                case (nil, .some): return false
                default: return $0.receivedAt > $1.receivedAt
                }
            }
        case .waiting:
            return base.sorted {
                if $0.isPinned != $1.isPinned { return $0.isPinned }
                return $0.waitingReference < $1.waitingReference
            }
        default:
            return base
        }
    }

    /// `serverMatches`: conversations a provider's own search found for
    /// this query. They show even when the words are only in a part of
    /// the message not on the device (the full body of older mail), the
    /// way Gmail's own results would.
    public static func filter(_ threads: [Correspondence], attention: Attention? = nil,
                              search: String = "", serverMatches: Set<ThreadID> = [], now: Date = .now) -> [Correspondence] {
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
        let terms = SearchTerms(query)
        let kept = threads.filter { item in
            (!hideSnoozed || !item.isSnoozed(at: now)) &&
            (!hideUnscreened || !item.isScreenedOut) &&
            (attention == nil || item.attention(at: now) == attention) &&
            (query.isEmpty || terms.matches(item, serverMatched: serverMatches.contains(item.id)))
        }
        return sortedNewestFirst(kept)
    }

    /// A search, read for Gmail's filters as well as words: `from:sam`,
    /// `to:alex`, `has:attachment`, `is:unread`, `is:flagged`, together or
    /// with ordinary words ("from:sam invoice"). Words match the sender,
    /// company, subject, preview, addresses and who it went to.
    public struct SearchTerms: Equatable, Sendable {
        public var words: String = ""
        public var from: [String] = []
        public var to: [String] = []
        public var hasAttachment = false
        public var unread = false
        public var flagged = false

        public init(_ query: String) {
            var words: [String] = []
            for token in query.split(whereSeparator: \.isWhitespace).map(String.init) {
                let lower = token.lowercased()
                if lower.hasPrefix("from:"), lower.count > 5 { from.append(String(token.dropFirst(5))) }
                else if lower.hasPrefix("to:"), lower.count > 3 { to.append(String(token.dropFirst(3))) }
                else if lower == "has:attachment" || lower == "has:attachments" { hasAttachment = true }
                else if lower == "is:unread" { unread = true }
                else if lower == "is:flagged" || lower == "is:starred" { flagged = true }
                else { words.append(token) }
            }
            self.words = words.joined(separator: " ")
        }

        public func matches(_ item: Correspondence, serverMatched: Bool = false) -> Bool {
            // Before its body loads a message's attachments aren't known;
            // the server's own search already checked for them.
            if hasAttachment && item.attachments.isEmpty && !(serverMatched && !item.isBodyLoaded) { return false }
            if unread && !item.isUnread { return false }
            if flagged && !item.isFlagged { return false }
            if serverMatched { return true }
            for name in from where ![item.sender, item.senderEmail ?? "", item.organization].contains(where: { $0.localizedStandardContains(name) }) {
                return false
            }
            for name in to where !(item.toRecipients + item.ccRecipients).contains(where: { $0.localizedStandardContains(name) }) {
                return false
            }
            guard !words.isEmpty else { return true }
            // Addresses too, and who it went to: mail you sent someone is
            // found by their name or address like mail they sent you. Each
            // word can be anywhere, the body included ("invoice march"
            // finds March's invoice), as Gmail's search does; a quoted
            // phrase stays together.
            let fields = [item.sender, item.organization, item.subject, item.excerpt, item.senderEmail ?? "", item.body]
                + item.toRecipients + item.ccRecipients
            return Self.searchWords(words).allSatisfy { word in fields.contains { $0.localizedStandardContains(word) } }
        }

        /// Words to look for: each on its own, a "quoted phrase" together.
        static func searchWords(_ text: String) -> [String] {
            var result: [String] = []
            var phrase = false
            for part in text.split(separator: "\"", omittingEmptySubsequences: false) {
                if phrase {
                    let trimmed = part.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty { result.append(trimmed) }
                } else {
                    result += part.split(whereSeparator: \.isWhitespace).map(String.init)
                }
                phrase.toggle()
            }
            return result.isEmpty ? [text] : result
        }
    }

    /// Pinned first, then newest. Sorts positions and small keys rather
    /// than the threads themselves: a thread is a large value, and moving
    /// thousands of them around was most of the cost of a sort.
    static func sortedNewestFirst(_ threads: [Correspondence]) -> [Correspondence] {
        let keys = threads.map { (pinned: $0.isPinned, date: $0.receivedAt) }
        func before(_ a: Int, _ b: Int) -> Bool {
            if keys[a].pinned != keys[b].pinned { return keys[a].pinned }
            if keys[a].date == keys[b].date { return threads[a].id.providerID < threads[b].id.providerID }
            return keys[a].date > keys[b].date
        }
        // Often already in order (the store keeps it close to this), in
        // which case there's nothing to move at all.
        if threads.indices.dropFirst().allSatisfy({ !before($0, $0 - 1) }) { return threads }
        return threads.indices.sorted(by: before).map { threads[$0] }
    }
}

extension Correspondence {
    /// Kept out of the lists: a blocked sender always, and a new sender
    /// only while Screen new senders is on (`MailQuery.holdsNewSenders`).
    public var isScreenedOut: Bool {
        switch senderDecision {
        case .approved: false
        case .blocked: true
        case .pending: MailQuery.holdsNewSenders
        }
    }
}
