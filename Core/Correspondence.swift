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
    public var htmlBody: String?
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
    /// Whether the HTML is only remote images (a sign of bulk mail), saved
    /// with the conversation so it's known without the HTML, which the
    /// lists don't hold. Nil when not worked out.
    public var htmlImageOnly: Bool?

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
        // Every preview the same: whatever the service sent, or what was
        // stored before this cleanup existed.
        let excerpt = excerpt.previewText
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
        let key = "\(id.account)|\(id.providerID)|\(latestMessageID ?? subject)|\(isBodyLoaded)|\(listUnsubscribeMailto != nil || listUnsubscribeURL != nil)|\(htmlImageOnly == true)"
        return Self.automatedMemo.value(key) {
            Self.isAutomated(listUnsubscribeMailto: listUnsubscribeMailto, listUnsubscribeURL: listUnsubscribeURL, senderEmail: senderEmail,
                             senderName: sender, body: isBodyLoaded ? body : nil, html: htmlBody, imageOnly: htmlImageOnly == true)
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
                                   senderName: String? = nil, body: String? = nil, html: String? = nil,
                                   imageOnly: Bool = false) -> Bool {
        if listUnsubscribeMailto != nil || listUnsubscribeURL != nil || imageOnly { return true }
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
        // Each Chinese, Japanese or Thai letter counts as one: written
        // without spaces, a colleague's whole note ("王总，附件是报价单，请
        // 查收。") was one "word", so with a logo in the signature it read
        // as an image-only flyer and went to bulk.
        var words = 0
        var inWord = false
        for ch in body {
            if ch.isWhitespace || ch.isNewline { inWord = false } else if MailDigest.isUnspaced(ch) {
                inWord = false
                words += 1
                if words >= 8 { return false }
            } else if !inWord {
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
        let me = id.account.lowercased()
        return toRecipients.contains { $0 == me || Self.bareAddress($0) == me }
    }

    /// Named in Cc but not in To. Only this exact case counts: mail that
    /// reached you through an alias or a group names neither, and isn't
    /// "copied".
    public var isCopiedOnly: Bool {
        Self.isCopiedOnly(account: id.account, to: toRecipients, cc: ccRecipients)
    }

    /// Outlook and IMAP keep recipients with their names ("Tamkin Anwar
    /// <me@outlook.com>"), so each is read for its address: compared as
    /// written, mail you were only copied on never counted as that.
    public static func isCopiedOnly(account: String, to: [String], cc: [String]) -> Bool {
        let me = account.lowercased()
        func isMe(_ entry: String) -> Bool { entry == me || bareAddress(entry) == me }
        return cc.contains(where: isMe) && !to.contains(where: isMe)
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
    /// `messageIdHeader`: the Message-ID it went with, kept on a stand-in
    /// so the real copy can be found by it later.
    public static func started(by draft: Draft, id: ThreadID, sentAt: Date, sentCopy: Correspondence?,
                               attention: Attention, reason: String, messageIdHeader: String? = nil) -> Correspondence {
        var started = sentCopy ?? Correspondence(
            id: id, sender: "You", senderEmail: id.account, organization: "",
            subject: draft.subject.trimmingCharacters(in: .whitespacesAndNewlines),
            excerpt: draft.body, body: draft.body, messageIdHeader: messageIdHeader, receivedAt: sentAt, dueAt: nil,
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
        let own = ownAddresses
        return !(toRecipients + ccRecipients).contains { own.contains(Self.bareAddress($0)) }
    }

    /// Every address that is you, for this conversation's account: the
    /// account itself, your other accounts and every address they send as
    /// (`InboxClassifier.ownAddresses`, kept up to date by the app).
    public var ownAddresses: Set<String> {
        InboxClassifier.ownAddresses.union([id.account.lowercased()])
    }

    /// "Maya Chen <Maya@X.com>" and "maya@x.com" are the same person.
    public static func bareAddress(_ entry: String) -> String {
        PeopleIndex.parse(entry)?.email ?? entry.trimmingCharacters(in: CharacterSet(charactersIn: "<> ")).lowercased()
    }

    public var replyAddresses: [String] { replyAddresses(own: ownAddresses) }

    /// `own`: every address that is you (lowercased). This account is
    /// always one of them.
    public func replyAddresses(own: Set<String>) -> [String] {
        let own = Set(own.map { $0.lowercased() }).union([id.account.lowercased()])
        if own.contains((senderEmail ?? "").lowercased()) {
            let others = toRecipients.filter { !own.contains(Self.bareAddress($0)) }
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
        // Compared by address: "Tamkin <me@x.com>" in Cc is you, and the
        // name shown is this recipient's, never the first one's.
        let me = id.account.lowercased()
        guard isFromAccountOwner, let address = (toRecipients + ccRecipients).first(where: {
            Self.bareAddress($0) != me
        }) else { return sender }
        let bare = address.components(separatedBy: "<").last?
            .trimmingCharacters(in: CharacterSet(charactersIn: "<> ")).lowercased() ?? address.lowercased()
        if let known = knownNames[bare] { return known }
        let named = address.components(separatedBy: "<").first?
            .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\""))) ?? ""
        if address.contains("<"), !named.isEmpty, !named.contains("@") { return named }
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
    /// Addresses are compared bare ("Me <me@x.com>" is still you), and
    /// every address of yours is left out: this account, your other
    /// accounts and their send-as addresses.
    public var replyAllCc: [String] { replyAllCc(own: ownAddresses) }

    public func replyAllCc(own: Set<String>) -> [String] {
        let own = Set(own.map { $0.lowercased() }).union([id.account.lowercased()])
        let fromYou = own.contains((senderEmail ?? "").lowercased())
        var seen = own.union([(senderEmail ?? "").lowercased()])
            .union(replyAddresses(own: own).map(Self.bareAddress))
        var result: [String] = []
        let others = fromYou ? ccRecipients : toRecipients + ccRecipients
        for email in others {
            let bare = Self.bareAddress(email)
            guard !seen.contains(bare) else { continue }
            seen.insert(bare)
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
    /// For a reply: the Message-ID it answers and the conversation's first
    /// (both without `<>`), kept with the draft so a reply sent later (a
    /// retry, or a send resumed after a restart) still joins its
    /// conversation when the thread itself isn't to hand. Optional so older
    /// drafts decode.
    public var inReplyTo: String?
    public var rootReference: String?
    /// Compose has added the signature already (it was opened before:
    /// put aside, scheduled, undone), so opening it again doesn't add a
    /// second one. Optional so older drafts decode.
    public var signatureAdded: Bool?

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

/// Messages a sync couldn't fetch, kept to try again on later passes, each
/// with how many passes failed it and since when. One that keeps failing
/// is let go after a few tries or a few days: kept forever, it was asked
/// for on every 20-second check, and each check looked like a change that
/// reloaded the whole mailbox. Pure, so it can be tested.
public struct MissedMessages: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var attempts: Int
        public var since: Date

        public init(attempts: Int, since: Date) {
            self.attempts = attempts
            self.since = since
        }
    }

    public static let maxAttempts = 5
    public static let maxAge: TimeInterval = 3 * 86_400
    /// Bounded, so a pass that failed hundreds can't grow it without end.
    public static let maxTracked = 200

    public private(set) var entries: [String: Entry]

    public init(entries: [String: Entry] = [:]) {
        self.entries = entries
    }

    /// What to ask for again, oldest first.
    public var ids: [String] {
        entries.sorted { ($0.value.since, $0.key) < ($1.value.since, $1.key) }.map(\.key)
    }

    public var isEmpty: Bool { entries.isEmpty }

    /// After a pass. `failed` is everything it couldn't fetch; `tried` the
    /// ids from this list it really asked for again (not when the whole
    /// request failed, offline say). One tried that failed again counts
    /// another try, one newly failed starts at one, and anything not in
    /// `failed` arrived or is gone. Past `maxAttempts` or `maxAge` an id
    /// is let go; past `maxTracked`, the newest are kept.
    public func after(failed: Set<String>, tried: Set<String>, now: Date) -> MissedMessages {
        var next: [String: Entry] = [:]
        for id in failed {
            var entry = entries[id] ?? Entry(attempts: 0, since: now)
            if entries[id] == nil || tried.contains(id) { entry.attempts += 1 }
            guard entry.attempts < Self.maxAttempts, now.timeIntervalSince(entry.since) <= Self.maxAge else { continue }
            next[id] = entry
        }
        if next.count > Self.maxTracked {
            let kept = next.sorted { ($0.value.since, $0.key) > ($1.value.since, $1.key) }.prefix(Self.maxTracked)
            next = Dictionary(uniqueKeysWithValues: kept.map { ($0.key, $0.value) })
        }
        return MissedMessages(entries: next)
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
    /// Placed by a rule you set (Settings → Sorting → Rules).
    public static let ruleReason = "Placed here by your rule."
    /// An out-of-office or other automatic reply: its "until Monday" and
    /// "could you contact Sam?" are for anyone who writes, not asks of you.
    public static let autoReplyReason = "Automatic reply. Kept out of Needs You."

    /// Every reason these rules can produce for unread mail: a thread
    /// carrying one of these (and never triaged) still reflects a pure rule
    /// decision nobody has overridden, so re-running the rules is safe.
    public static let ruleReasons: Set<String> = [legacyUnreadReason, personalUnreadReason, correspondentReason, staleReason,
                                                  readReason, legacyReadReason, questionReason, deadlineReason, obligationReason, copiedReason,
                                                  askedReason, repliedReason, startedReason, vipReason, fyiReason,
                                                  lessonReason, confirmationReason, fromYouReason, failureReason, paymentReason,
                                                  autoReplyReason,
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
    public static let personalDomains: Set<String> = {
        var domains: Set<String> = [
            "gmail.com", "googlemail.com", "outlook.com", "hotmail.com", "live.com", "msn.com",
            "icloud.com", "me.com", "mac.com", "yahoo.com", "ymail.com", "aol.com", "proton.me",
            "protonmail.com", "pm.me", "zoho.com", "gmx.com", "gmx.net", "mail.com", "yandex.com",
            "hotmail.co.uk", "yahoo.co.uk", "btinternet.com", "outlook.co.uk", "live.co.uk",
            // China, Korea, Japan, India.
            "qq.com", "foxmail.com", "163.com", "126.com", "yeah.net", "sina.com", "sina.cn", "sohu.com", "aliyun.com",
            "naver.com", "daum.net", "hanmail.net", "kakao.com", "nate.com",
            "yahoo.co.jp", "docomo.ne.jp", "ezweb.ne.jp", "au.com", "softbank.ne.jp", "i.softbank.jp", "ymobile.ne.jp",
            "rediffmail.com",
            // Europe, Australia, Canada, the UK, Russia.
            "web.de", "gmx.de", "gmx.at", "gmx.ch", "t-online.de", "freenet.de", "orange.fr", "wanadoo.fr", "free.fr",
            "laposte.net", "sfr.fr", "libero.it", "virgilio.it", "tiscali.it", "bigpond.com", "bigpond.net.au",
            "optusnet.com.au", "rogers.com", "shaw.ca", "sympatico.ca", "telus.net", "sky.com", "virginmedia.com",
            "talktalk.net", "yandex.ru", "mail.ru", "rambler.ru",
        ]
        // Outlook, Hotmail, Live and Yahoo in each country they serve.
        let countries = ["co.uk", "com.au", "ca", "de", "fr", "es", "it", "nl", "be", "at", "ch", "se", "dk", "no",
                         "fi", "ie", "pt", "com.br", "com.mx", "com.ar", "co.in", "in", "co.jp", "jp", "co.kr", "kr",
                         "com.sg", "sg", "com.my", "com.ph", "co.id", "co.za", "co.nz", "com.hk", "com.tw", "com.bd", "pl"]
        for brand in ["outlook", "hotmail", "live", "yahoo"] {
            for country in countries { domains.insert(brand + "." + country) }
        }
        return domains
    }()

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
        // Japan's "co.jp", "ne.jp", "or.jp", "go.jp"; Latin America's
        // "gob.mx"; "nic.in"; "res.in".
        let secondLevel = ["co", "com", "org", "net", "ac", "gov", "edu", "ne", "or", "go", "gob", "nic", "res"]
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
              !isCopiedOnly || sensitivity == .inclusive,
              // Someone you wrote to, answering automatically that they're away.
              currentReason != autoReplyReason else { return nil }
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
        if MailSignals.isAutoReply(text) { return (.quiet, autoReplyReason) }
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
    /// Inline images' placeholders (`[cid:image001.png@01DD…]`) too, the
    /// invisible padding newsletters put after their preview (`&zwnj;`,
    /// zero-width spaces, soft hyphens) so a row doesn't read "‌ ‌ ‌", and
    /// rules drawn with dashes or underscores.
    var previewText: String { cleanedPreview.droppingImageLabel }

    /// "Logo Hello Tamkin, …": a newsletter's first image has no text but
    /// its label, and the label lands at the start of the preview. Only a
    /// lone first word that names an image, with real text after it.
    private var droppingImageLabel: String {
        guard let space = firstIndex(of: " ") else { return self }
        let word = self[..<space].lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ":|-"))
        guard ["logo", "image", "img", "banner", "header", "spacer"].contains(word) else { return self }
        let rest = self[index(after: space)...].trimmingCharacters(in: .whitespaces)
        // A sentence starts after it ("Logo Hello Tamkin, …"); "Logo design
        // brief attached" is a subject about a logo, and stays.
        guard rest.count >= 12, rest.first?.isUppercase == true,
              rest.prefix(60).contains(where: { ",.!?:".contains($0) }) else { return self }
        return rest
    }

    private var cleanedPreview: String {
        guard unicodeScalars.contains(where: { $0 == "&" || $0 == "<" || $0 == "[" || Self.isPreviewNoise($0) })
                || contains("---") || contains("___") || contains("===") else { return self }
        var text = decodingHTMLEntities
        if text.contains("<") || text.contains("[cid:") {
            text = text.replacingOccurrences(of: #"<[A-Za-z/!][^<>]{0,400}>"#, with: " ", options: .regularExpression)
                .replacingOccurrences(of: #"\[cid:[^\]]{0,200}\]"#, with: " ", options: .regularExpression)
        }
        text.unicodeScalars.removeAll(where: Self.isPreviewNoise)
        return text.replacingOccurrences(of: #"[-_=*~]{3,}"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// Characters that take no space: zero-width space, non-joiner, joiner,
    /// word joiner, byte-order mark, soft hyphen, combining grapheme joiner,
    /// Mongolian vowel separator, and the Braille blank some senders use.
    private static func isPreviewNoise(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x200B...0x200F, 0x2060...0x2064, 0xFEFF, 0x00AD, 0x034F, 0x180E, 0x2800, 0x061C: true
        default: false
        }
    }

    /// Gmail's `snippet` field is HTML-escaped (`Don&#39;t`, `&amp;`), and
    /// was being shown verbatim in every row preview and notification.
    var decodingHTMLEntities: String {
        guard contains("&") else { return self }
        let named: [String: String] = [
            "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ", "zwnj": "\u{200C}", "zwj": "\u{200D}",
            "shy": "\u{00AD}", "ensp": " ", "emsp": " ", "thinsp": " ", "hellip": "…", "mdash": "—", "ndash": "–",
            "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”", "copy": "©", "reg": "®", "trade": "™", "bull": "•",
        ]
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

/// What happens to someone's first email (Settings › Senders), as in
/// Spark's Gatekeeper: held for review, held only when it's a company's,
/// shown in Mail marked New (the default), or let in like anyone else's.
/// Blocked senders stay hidden in every mode.
public enum NewSenderMode: String, CaseIterable, Sendable {
    case reviewEveryone, reviewCompanies, inMail, acceptAll
}

public enum MailQuery {
    public nonisolated(unsafe) static var newSenderMode = NewSenderMode.inMail

    /// A first email's sender: waiting for your OK, or simply let in when
    /// every new sender is (so nothing piles up to review, and choosing a
    /// Review mode later doesn't hide them all at once).
    public static var firstEmailDecision: SenderDecision { newSenderMode == .acceptAll ? .approved : .pending }

    /// Whether any new sender's mail is held back for review.
    public static var holdsNewSenders: Bool { [.reviewEveryone, .reviewCompanies].contains(newSenderMode) }

    /// The curated lists in the order that matters: Needs You with the
    /// nearest deadline first, then newest; Waiting with whoever has gone
    /// quiet longest first, since that's the one to nudge. Pinned always
    /// leads. Mail stays chronological.
    public static func prioritized(_ threads: [Correspondence], attention: Attention,
                                   now: Date = .now, dueHorizon: TimeInterval = 3 * 86_400) -> [Correspondence] {
        let base = filter(threads, attention: attention, now: now)
        // Sorted by what decides the order, read once per conversation,
        // then the conversations put in that order: sorting them whole
        // moved every one of them around, several times, on each change
        // to the mail. The same order, ties included (the sort is stable).
        switch attention {
        case .needsYou:
            let horizon = now.addingTimeInterval(dueHorizon)
            let keys = base.map { thread in
                PriorityKey(pinned: thread.isPinned, due: thread.dueAt.flatMap { $0 <= horizon ? $0 : nil },
                            date: thread.receivedAt)
            }
            return base.indices.sorted { i, j in
                let a = keys[i], b = keys[j]
                if a.pinned != b.pinned { return a.pinned }
                switch (a.due, b.due) {
                case let (x?, y?) where x != y: return x < y
                case (.some, nil): return true
                case (nil, .some): return false
                default: return a.date > b.date
                }
            }.map { base[$0] }
        case .waiting:
            let keys = base.map { (pinned: $0.isPinned, since: $0.waitingReference) }
            return base.indices.sorted { i, j in
                if keys[i].pinned != keys[j].pinned { return keys[i].pinned }
                return keys[i].since < keys[j].since
            }.map { base[$0] }
        default:
            return base
        }
    }

    private struct PriorityKey {
        let pinned: Bool
        let due: Date?
        let date: Date
    }

    /// The same as `filter` with no search, without putting them in order:
    /// for counting, where sorting the whole mailbox bought nothing.
    public static func unordered(_ threads: [Correspondence], attention: Attention? = nil, now: Date = .now) -> [Correspondence] {
        let hideSnoozed = attention != nil
        return threads.filter { item in
            (!hideSnoozed || !item.isSnoozed(at: now)) && !item.isScreenedOut
                && (attention == nil || item.attention(at: now) == attention)
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
        let kept = threads.filter { item in
            (!hideSnoozed || !item.isSnoozed(at: now)) &&
            (!hideUnscreened || !item.isScreenedOut) &&
            (attention == nil || item.attention(at: now) == attention)
        }
        guard !query.isEmpty else { return sortedNewestFirst(kept) }
        // The search read once, and each conversation's text from the
        // index rather than lowercased and compared again every time.
        let terms = SearchTerms(query)
        let folded = terms.folded
        let entries = SearchIndex.shared.entries(for: kept)
        return sortedNewestFirst(kept.indices.compactMap { index in
            terms.matches(kept[index], entry: entries[index], folded: folded,
                          serverMatched: serverMatches.contains(kept[index].id)) ? kept[index] : nil
        })
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
            matches(item, entry: SearchIndex.Entry(item), folded: folded, serverMatched: serverMatched)
        }

        /// `entry` is `item`'s text from `SearchIndex`, `folded` this
        /// search's: both lowercased and without accents, so each word is
        /// a plain byte search, as `localizedStandardContains` would find it.
        func matches(_ item: Correspondence, entry: SearchIndex.Entry, folded: Folded, serverMatched: Bool) -> Bool {
            // Before its body loads a message's attachments aren't known;
            // the server's own search already checked for them.
            if hasAttachment && item.attachments.isEmpty && !(serverMatched && !item.isBodyLoaded) { return false }
            if unread && !item.isUnread { return false }
            if flagged && !item.isFlagged { return false }
            if serverMatched { return true }
            for name in folded.from where !entry.from.contains(name) { return false }
            for name in folded.to where !entry.to.contains(name) { return false }
            // Addresses too, and who it went to: mail you sent someone is
            // found by their name or address like mail they sent you. Each
            // word can be anywhere, the body included ("invoice march"
            // finds March's invoice), as Gmail's search does; a quoted
            // phrase stays together.
            return folded.words.allSatisfy { entry.fields.contains($0) || entry.body.contains($0) }
        }

        /// This search's names and words, folded once for a whole mailbox.
        struct Folded: Sendable {
            let from: [SearchText]
            let to: [SearchText]
            let words: [SearchText]
        }

        var folded: Folded {
            Folded(from: from.map(SearchText.init), to: to.map(SearchText.init),
                   words: words.isEmpty ? [] : Self.searchWords(words).map(SearchText.init))
        }

        /// Whether everything this search finds, `previous` found too: the
        /// same search typed further ("invoi", then "invoice", or another
        /// word), so its matches can be looked through instead of the whole
        /// mailbox. Each earlier word has to be inside one of the new ones.
        public func narrows(_ previous: SearchTerms) -> Bool {
            guard previous != SearchTerms(""), !previous.hasAttachment || hasAttachment,
                  !previous.unread || unread, !previous.flagged || flagged else { return false }
            func covered(_ old: [SearchText], by new: [SearchText]) -> Bool {
                old.allSatisfy { word in new.contains { $0.contains(word) } }
            }
            let new = folded, old = previous.folded
            return covered(old.from, by: new.from) && covered(old.to, by: new.to) && covered(old.words, by: new.words)
        }

        /// How well a match fits, for Top Results: the words in who it's
        /// from count most, then the subject, then the text; newer, flagged,
        /// unread and Needs You mail a little more.
        public func relevance(of item: Correspondence, now: Date) -> Double {
            relevance(of: item, entry: SearchIndex.Entry(item), ranking: ranking, now: now)
        }

        /// This search's words as Top Results compares them, read once for
        /// every match rather than again for each.
        struct Ranking: Sendable {
            struct Word: Sendable {
                let text: LowercasedText
                let afterSpace: LowercasedText
                let afterAt: LowercasedText
                let afterDot: LowercasedText
                let folded: SearchText
            }
            let words: [Word]
        }

        var ranking: Ranking {
            Ranking(words: Self.searchWords(words).map { $0.lowercased() }.filter { !$0.isEmpty }.map { word in
                Ranking.Word(text: LowercasedText(word), afterSpace: LowercasedText(" " + word), afterAt: LowercasedText("@" + word),
                             afterDot: LowercasedText("." + word), folded: SearchText(word))
            })
        }

        func relevance(of item: Correspondence, entry: SearchIndex.Entry, ranking: Ranking, now: Date) -> Double {
            var score = 0.0
            let sender = entry.lowercasedSender
            let subject = entry.lowercasedSubject
            let preview = entry.lowercasedPreview
            func startsWord(_ word: Ranking.Word, in text: LowercasedText) -> Bool {
                text.hasPrefix(word.text) || text.contains(word.afterSpace) || text.contains(word.afterAt) || text.contains(word.afterDot)
            }
            for word in ranking.words {
                if sender.contains(word.text) { score += startsWord(word, in: sender) ? 6 : 4 }
                if subject.contains(word.text) { score += startsWord(word, in: subject) ? 4 : 3 }
                if preview.contains(word.text) { score += 1.5 } else if entry.body.contains(word.folded) { score += 1 }
            }
            if !from.isEmpty { score += 3 }
            let days = max(0, now.timeIntervalSince(item.receivedAt) / 86_400)
            score += 4 * exp(-days / 30)
            if item.isFlagged || item.isPinned { score += 1.5 }
            if item.attention == .needsYou { score += 1 }
            if item.isUnread { score += 0.5 }
            if item.isArchivedCopy { score -= 0.5 }
            return score
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

    /// The few best matches for a search, shown above the rest (which stay
    /// newest first), as Mail's Top Results do. None for a handful of
    /// results, where the list is already short enough to scan.
    public static func topResults(_ matches: [Correspondence], search: String, limit: Int = 5,
                                  now: Date = .now) -> [Correspondence] {
        guard matches.count > limit + 3 else { return [] }
        return Array(ranked(matches, search: search, now: now).prefix(limit))
    }

    /// Every match, best first, as Top Results orders them; none for a
    /// search with no words or names to rank by.
    static func ranked(_ matches: [Correspondence], search: String, now: Date = .now) -> [Correspondence] {
        let terms = SearchTerms(search)
        guard !terms.words.isEmpty || !terms.from.isEmpty else { return [] }
        let entries = SearchIndex.shared.entries(for: matches)
        let ranking = terms.ranking
        // Positions and scores sorted, not the threads themselves (see
        // `sortedNewestFirst`); equal ones stay in the order they came.
        let scores = matches.indices.map { terms.relevance(of: matches[$0], entry: entries[$0], ranking: ranking, now: now) }
        let dates = matches.map(\.receivedAt)
        return matches.indices.sorted {
            if scores[$0] != scores[$1] { return scores[$0] > scores[$1] }
            if dates[$0] != dates[$1] { return dates[$0] > dates[$1] }
            return $0 < $1
        }.map { matches[$0] }
    }

    /// Pinned first, then newest. Sorts positions and small keys rather
    /// than the threads themselves: a thread is a large value, and moving
    /// thousands of them around was most of the cost of a sort.
    static func sortedNewestFirst(_ threads: [Correspondence]) -> [Correspondence] {
        // The keys side by side with each conversation's place, sorted
        // as they are: looking each up through the list on every
        // comparison was most of the time a mailbox took to sort.
        let keys = threads.indices.map { NewestKey(pinned: threads[$0].isPinned, date: threads[$0].receivedAt.timeIntervalSinceReferenceDate, index: $0) }
        func before(_ a: NewestKey, _ b: NewestKey) -> Bool {
            if a.pinned != b.pinned { return a.pinned }
            if a.date == b.date { return threads[a.index].id.providerID < threads[b.index].id.providerID }
            return a.date > b.date
        }
        // Often already in order (the store keeps it close to this), in
        // which case there's nothing to move at all.
        if keys.indices.dropFirst().allSatisfy({ !before(keys[$0], keys[$0 - 1]) }) { return threads }
        return keys.sorted(by: before).map { threads[$0.index] }
    }

    private struct NewestKey {
        let pinned: Bool
        let date: Double
        let index: Int
    }
}

/// Text as `localizedStandardContains` compares it: lowercased and without
/// accents, in this locale ("Café" and "CAFE" both read "cafe"). With both
/// sides folded once, each comparison is a plain byte search.
struct SearchText: Sendable {
    private var text: String

    init(_ text: String) {
        self.text = Self.folded(text)
        self.text.makeContiguousUTF8()
    }

    /// Several fields as one, each folded on its own and kept apart by a
    /// character no search contains, so a word never runs across two.
    init(_ parts: [String]) {
        text = parts.map(Self.folded).joined(separator: "\u{1F}")
        text.makeContiguousUTF8()
    }

    /// Case, width ("ｶﾀｶﾅ" and "カタカナ", "ＡＢＣ" and "ABC") and, in Latin,
    /// Greek and Cyrillic, accents folded. Other scripts keep their marks:
    /// there they are letters, not accents. "が" is not "か", and a
    /// Bengali or Hindi vowel sign changes the word; folded away, a search
    /// for one matched the other.
    static func folded(_ text: String) -> String {
        let all: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]
        guard text.unicodeScalars.contains(where: isOtherScript) else {
            return text.folding(options: all, locale: .current)
        }
        // Case and width for all of it, then only the combining accents
        // Latin, Greek and Cyrillic use, which is what Foundation's
        // accent folding takes away there. Other scripts' marks stay.
        let caseAndWidth = text.folding(options: [.caseInsensitive, .widthInsensitive], locale: .current)
        // Most often there's no accented Latin letter at all to fold.
        guard text.unicodeScalars.contains(where: { (0x80..<0x0530).contains($0.value) || (0x1D00...0x1FFF).contains($0.value) }) else {
            return caseAndWidth
        }
        let decomposed = caseAndWidth.decomposedStringWithCanonicalMapping.unicodeScalars
            .filter { !isCombiningAccent($0) }
        return String(String.UnicodeScalarView(decomposed)).precomposedStringWithCanonicalMapping
    }

    private static func isCombiningAccent(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0300...0x036F, 0x1AB0...0x1AFF, 0x1DC0...0x1DFF, 0x20D0...0x20FF, 0xFE20...0xFE2F: true
        default: false
        }
    }

    /// Never true for nothing, as `localizedStandardContains("")` isn't.
    func contains(_ other: SearchText) -> Bool {
        !other.text.isEmpty && text.bytesContain(other.text)
    }

    /// A letter or mark of a script whose marks are letters: not Latin,
    /// Greek, Cyrillic (or their full-width forms), nor Hebrew and Arabic,
    /// whose vowel points people leave out when they search. ASCII,
    /// punctuation, symbols and emoji are none.
    private static func isOtherScript(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0..<0x0530, 0x0590...0x06FF, 0x1D00...0x2BFF, 0x3000...0x303F, 0xFE00...0xFE0F, 0xFF01...0xFF5E, 0x1F000...: false
        default: true
        }
    }
}

/// Lowercased text as Top Results compares it, with `String.contains`.
/// Where both sides are plain ASCII, nearly always, that's the same as
/// comparing the bytes, which is much quicker.
struct LowercasedText: Sendable {
    private var text: String
    private let isASCII: Bool

    /// `text` already lowercased.
    init(_ text: String) {
        self.text = text
        self.text.makeContiguousUTF8()
        isASCII = text.utf8.allSatisfy { $0 < 0x80 }
    }

    func contains(_ other: LowercasedText) -> Bool {
        isASCII && other.isASCII ? !other.text.isEmpty && text.bytesContain(other.text) : text.contains(other.text)
    }

    func hasPrefix(_ other: LowercasedText) -> Bool { text.hasPrefix(other.text) }
}

extension String {
    /// Whether `other`'s UTF-8 appears in this string's, byte for byte.
    fileprivate func bytesContain(_ other: String) -> Bool {
        guard other.utf8.count <= utf8.count else { return false }
        let found = utf8.withContiguousStorageIfAvailable { haystack in
            other.utf8.withContiguousStorageIfAvailable { needle in
                memmem(haystack.baseAddress, haystack.count, needle.baseAddress, needle.count) != nil
            }
        }
        return (found ?? nil) ?? (utf8.firstRange(of: other.utf8) != nil)
    }
}

extension MailQuery {
    /// Each conversation's text ready for search (`SearchText`), worked out
    /// once per message instead of on every search. Searching a whole
    /// mailbox lowercased and compared every field of every conversation,
    /// the body included, again for each word typed.
    final class SearchIndex: @unchecked Sendable {
        static let shared = SearchIndex()
        private let lock = NSLock()
        private var entries: [ThreadID: Entry] = [:]
        /// Several accounts' worth; cleared past this, like `Memo`.
        private static let limit = 60_000

        /// Low on memory: built again on the next search.
        func clear() {
            lock.lock()
            entries.removeAll()
            lock.unlock()
        }

        struct Entry: Sendable {
            /// What it was made from: a new message in the conversation, or
            /// its body loading, makes a new one.
            let message: String?
            let isBodyLoaded: Bool
            let subject: String
            let excerpt: String
            /// Only for conversations without a message id (samples, a
            /// message just sent), where nothing else tells them apart.
            let bodySize: Int?
            /// Who it's from: name, address and company, for `from:`.
            let from: SearchText
            /// Who it went to, for `to:`.
            let to: SearchText
            /// Everything a word can be in but the body.
            let fields: SearchText
            let body: SearchText
            /// For Top Results, which compares these lowercased as they are.
            let lowercasedSender: LowercasedText
            let lowercasedSubject: LowercasedText
            let lowercasedPreview: LowercasedText

            init(_ item: Correspondence) {
                message = item.latestMessageID
                isBodyLoaded = item.isBodyLoaded
                subject = item.subject
                excerpt = item.excerpt
                bodySize = item.latestMessageID == nil ? item.body.utf8.count : nil
                from = SearchText([item.sender, item.senderEmail ?? "", item.organization])
                to = SearchText(item.toRecipients + item.ccRecipients)
                fields = SearchText([item.sender, item.organization, item.subject, item.excerpt, item.senderEmail ?? ""]
                                    + item.toRecipients + item.ccRecipients)
                body = SearchText(item.body)
                lowercasedSender = LowercasedText([item.sender, item.organization, item.senderEmail ?? ""].joined(separator: " ").lowercased())
                lowercasedSubject = LowercasedText(item.subject.lowercased())
                lowercasedPreview = LowercasedText(item.excerpt.lowercased())
            }

            func isCurrent(for item: Correspondence) -> Bool {
                message == item.latestMessageID && isBodyLoaded == item.isBodyLoaded
                    && subject == item.subject && excerpt == item.excerpt
                    && (message != nil || bodySize == item.body.utf8.count)
            }
        }

        /// One entry per thread, in the same order; the ones missing or out
        /// of date are made on every core at once.
        func entries(for threads: [Correspondence]) -> [Entry] {
            var found = [Entry?](repeating: nil, count: threads.count)
            var missing: [Int] = []
            lock.lock()
            for index in threads.indices {
                if let entry = entries[threads[index].id], entry.isCurrent(for: threads[index]) {
                    found[index] = entry
                } else {
                    missing.append(index)
                }
            }
            lock.unlock()
            guard !missing.isEmpty else { return found.compactMap { $0 } }
            let made = Self.make(missing.map { threads[$0] })
            lock.lock()
            // Past the limit: only conversations no longer searched go (a
            // removed account's, deleted ones), not the whole copy, which
            // made every later search build it all again.
            if entries.count + made.count > Self.limit {
                let current = Set(threads.map(\.id))
                entries = entries.filter { current.contains($0.key) }
            }
            for (index, entry) in zip(missing, made) {
                found[index] = entry
                entries[threads[index].id] = entry
            }
            lock.unlock()
            return found.compactMap { $0 }
        }

        private static func make(_ threads: [Correspondence]) -> [Entry] {
            guard threads.count > 200 else { return threads.map(Entry.init) }
            let chunk = 100
            let made = Made(count: threads.count)
            DispatchQueue.concurrentPerform(iterations: (threads.count + chunk - 1) / chunk) { part in
                let range = (part * chunk)..<min(threads.count, (part + 1) * chunk)
                made.set(range, threads[range].map(Entry.init))
            }
            return made.entries.compactMap { $0 }
        }

        /// Entries being made on several threads at once, each into its own slots.
        private final class Made: @unchecked Sendable {
            private let lock = NSLock()
            private(set) var entries: [Entry?]
            init(count: Int) { entries = Array(repeating: nil, count: count) }
            func set(_ range: Range<Int>, _ made: [Entry]) {
                lock.lock()
                entries.replaceSubrange(range, with: made)
                lock.unlock()
            }
        }
    }
}

/// Search for a list: the matches for what's typed, found away from the
/// main thread once the mailbox is large, so typing and scrolling never
/// wait on it. The list keeps showing what it had until they're found.
@MainActor
public final class MailSearch {
    public struct Request: Equatable {
        public var search: String
        public var attention: Attention?
        public var serverMatches: Set<ThreadID>
        /// What the conversations searched are: anything that changes when
        /// they do (the store's revision, the account shown).
        public var source: AnyHashable

        public init(search: String, attention: Attention? = nil, serverMatches: Set<ThreadID> = [], source: AnyHashable) {
            self.search = search.trimmingCharacters(in: .whitespacesAndNewlines)
            self.attention = attention
            self.serverMatches = serverMatches
            self.source = source
        }

        /// Its matches are all among `previous`'s: the same conversations,
        /// searched for more. The provider's own matches skip the words, so
        /// they can't be new ones.
        func narrows(_ previous: Request) -> Bool {
            source == previous.source && attention == previous.attention
                && serverMatches.isSubset(of: previous.serverMatches)
                && MailQuery.SearchTerms(search).narrows(MailQuery.SearchTerms(previous.search))
        }
    }

    /// Searched right away up to this many conversations; a few
    /// milliseconds.
    public static let inlineLimit = 2_000
    private var found: (request: Request, matches: [Correspondence], ranked: [ThreadID])?
    private var pending: Request?

    public init() {}

    /// The matches for `request` among `threads`, or nil while they're
    /// still being found; `onFound` runs once they are, to show them.
    /// Typing more of the same search looks through what the last one
    /// found rather than the whole mailbox.
    public func matches(for request: Request, in threads: () -> [Correspondence], now: Date = .now,
                        onFound: @escaping @MainActor () -> Void) -> [Correspondence]? {
        if let found, found.request == request { return found.matches }
        let input = if let found, request.narrows(found.request) { found.matches } else { threads() }
        let (search, attention, serverMatches) = (request.search, request.attention, request.serverMatches)
        @Sendable func run() -> (matches: [Correspondence], ranked: [ThreadID]) {
            let matches = MailQuery.filter(input, attention: attention, search: search, serverMatches: serverMatches, now: now)
            return (matches, MailQuery.ranked(matches, search: search, now: now).map(\.id))
        }
        if input.count <= Self.inlineLimit {
            let result = run()
            found = (request, result.matches, result.ranked)
            pending = nil
            return result.matches
        }
        // The same search on mail that's still changing (a sync landing
        // every half second): the last results stay up meanwhile, rather
        // than the whole unsearched list.
        let provisional = found.flatMap { $0.request.search == request.search && $0.request.attention == request.attention ? $0.matches : nil }
        guard pending != request else { return provisional }
        pending = request
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) { run() }.value
            guard let self, let pending = self.pending else { return }
            // A newer request for the same search: these are kept to show
            // until it's done, instead of thrown away.
            guard pending == request || (pending.search == request.search && pending.attention == request.attention) else { return }
            self.found = (request, result.matches, result.ranked)
            if pending == request { self.pending = nil }
            onFound()
        }
        return provisional
    }

    /// Top Results (`MailQuery.topResults`) among `shown`, the last
    /// matches as the list shows them (less any hidden), from the order
    /// worked out with them rather than ranking them again here.
    public func topResults(_ shown: [Correspondence], limit: Int = 5) -> [Correspondence] {
        guard let found, shown.count > limit + 3 else { return [] }
        let byID = Dictionary(shown.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return Array(found.ranked.lazy.compactMap { byID[$0] }.prefix(limit))
    }

    /// Reads the mailbox's text ahead of the first search (when Search
    /// opens), away from the main thread, so the first results are quick.
    public nonisolated static func prepare(_ threads: [Correspondence]) {
        Task.detached(priority: .utility) { _ = MailQuery.SearchIndex.shared.entries(for: threads) }
    }
}

extension Correspondence {
    /// Kept out of the lists: a blocked sender always, and a new sender
    /// while `MailQuery.newSenderMode` holds them (only companies, in
    /// Review Companies: a first email from a person comes straight in).
    public var isScreenedOut: Bool {
        switch senderDecision {
        case .approved: false
        case .blocked: true
        case .pending:
            switch MailQuery.newSenderMode {
            case .reviewEveryone: true
            case .reviewCompanies: isFromCompany
            case .inMail, .acceptAll: false
            }
        }
    }

    /// Marked New, with Allow and Block in the email: a new sender's mail
    /// that's in the lists, unless every new sender is simply let in.
    public var showsAsNewSender: Bool {
        senderDecision == .pending && MailQuery.newSenderMode != .acceptAll && !isScreenedOut
    }

    /// Mail a company sends (newsletters, receipts, notifications) rather
    /// than a person writing, as the New Senders screen splits them.
    public var isFromCompany: Bool {
        InboxClassifier.bulkKind(labelIds: labelIds, looksAutomated: looksAutomated) != nil
    }
}

extension InboxClassifier {
    /// The reasons above in the reader's language. They're stored in
    /// English (they're compared and re-run as rules), so they're translated
    /// only when shown. A reason the on-device check wrote is already in the
    /// email's own language and passes through unchanged.
    public static func displayReason(_ reason: String) -> String {
        if let known = displayReasons[reason] { return known }
        // Written when you send, with a verb or a name in it.
        if reason == "You replied just now. Waiting for their response." {
            return String(localized: "You replied just now. Waiting for their response.")
        }
        if reason == "You forwarded this just now. Waiting for their response." {
            return String(localized: "You forwarded this just now. Waiting for their response.")
        }
        if let match = reason.firstMatch(of: /^No reply from (.+) since (.+)\. Follow up\?$/) {
            let name = String(match.1), day = String(match.2)
            return String(localized: "No reply from \(name) since \(day). Follow up?")
        }
        return reason
    }

    private static let displayReasons: [String: String] = [
        legacyUnreadReason: String(localized: "Unread."),
        personalUnreadReason: String(localized: "Unread, from a person."),
        correspondentReason: String(localized: "Unread, from someone you've written to."),
        staleReason: String(localized: "Unread for over a month. Kept out of Needs You."),
        readReason: String(localized: "Already read."),
        legacyReadReason: String(localized: "Already read."),
        questionReason: String(localized: "Asks you something."),
        deadlineReason: String(localized: "Mentions a deadline."),
        obligationReason: String(localized: "Time-sensitive."),
        copiedReason: String(localized: "You're copied, not asked. Kept out of Needs You."),
        vipReason: String(localized: "From a VIP."),
        fyiReason: String(localized: "From a person, nothing asked. Kept out of Needs You."),
        askedReason: String(localized: "You asked. No reply yet."),
        repliedReason: String(localized: "You replied. Nothing pending."),
        startedReason: String(localized: "You sent this. Nothing pending."),
        lessonReason: String(localized: "You said mail like this needs no action."),
        failureReason: String(localized: "Something failed that only you can fix."),
        paymentReason: String(localized: "Asks you to pay."),
        promotedReason: String(localized: "Reads like it needs something from you."),
        demotedReason: String(localized: "Nothing here asks anything of you."),
        fromYouReason: String(localized: "From your other account. Kept out of Needs You."),
        confirmationReason: String(localized: "Confirms something you did. Nothing to do unless it wasn't you."),
        ruleReason: String(localized: "Placed here by your rule."),
        autoReplyReason: String(localized: "Automatic reply. Kept out of Needs You."),
        BulkKind.promotions.reason: String(localized: "Promotion. Kept out of Needs You."),
        BulkKind.social.reason: String(localized: "Social notification. Kept out of Needs You."),
        BulkKind.forums.reason: String(localized: "Mailing list. Kept out of Needs You."),
        BulkKind.updates.reason: String(localized: "Automated update. Kept out of Needs You."),
        BulkKind.automated.reason: String(localized: "Bulk mail. Kept out of Needs You."),
        "You started this conversation. Waiting for a response.": String(localized: "You started this conversation. Waiting for a response."),
        // As they read once "Kept out of Needs You" is taken off, where the
        // line already says so.
        "Promotion.": String(localized: "Promotion."),
        "Social notification.": String(localized: "Social notification."),
        "Mailing list.": String(localized: "Mailing list."),
        "Automated update.": String(localized: "Automated update."),
        "Bulk mail.": String(localized: "Bulk mail."),
        "Unread for over a month.": String(localized: "Unread for over a month."),
        "You're copied, not asked.": String(localized: "You're copied, not asked."),
        "From a person, nothing asked.": String(localized: "From a person, nothing asked."),
        "From your other account.": String(localized: "From your other account."),
        "Automatic reply.": String(localized: "Automatic reply."),
    ]
}

extension Correspondence {
    /// `reason`, in the reader's language.
    public var displayReason: String { InboxClassifier.displayReason(reason) }
}

/// Text written into a raw email so any mail server carries it as typed:
/// paragraphs of any length and words in any script.
public enum MailEncoding {
    /// RFC 2045 quoted-printable over UTF-8, with CRLF line endings and no
    /// line longer than 76 characters. Sent as 8bit, a long paragraph (or a
    /// short one in Bengali, three bytes a letter) passed SMTP's 998-byte
    /// line limit and arrived broken.
    public static func quotedPrintable(_ text: String) -> String {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let hex = Array("0123456789ABCDEF".utf8)
        func escaped(_ byte: UInt8) -> String {
            String(decoding: [UInt8(ascii: "="), hex[Int(byte >> 4)], hex[Int(byte & 0x0F)]], as: UTF8.self)
        }
        return normalized.components(separatedBy: "\n").map { line -> String in
            let bytes = Array(line.utf8)
            var tokens: [String] = []
            for (index, byte) in bytes.enumerated() {
                let isLast = index == bytes.count - 1
                switch byte {
                case UInt8(ascii: " "), UInt8(ascii: "\t"):
                    // Spaces at the end of a line are dropped in transit.
                    tokens.append(isLast ? escaped(byte) : String(UnicodeScalar(byte)))
                case 33...60, 62...126:
                    tokens.append(String(UnicodeScalar(byte)))
                default:
                    tokens.append(escaped(byte))
                }
            }
            // Soft line breaks ("=" at the end) keep each line at 76,
            // never splitting an "=XX".
            var lines: [String] = []
            var current = ""
            for token in tokens {
                if current.count + token.count > 75 {
                    lines.append(current + "=")
                    current = ""
                }
                current += token
            }
            lines.append(current)
            return lines.joined(separator: "\r\n")
        }.joined(separator: "\r\n")
    }

    /// A header value as RFC 2047 encoded words when it isn't plain ASCII,
    /// each word at most 75 characters (as the RFC requires) and split
    /// between characters, never inside one, folded onto lines of their
    /// own. Plain ASCII comes back as it is.
    public static func encodedWords(_ text: String) -> String {
        guard !text.allSatisfy(\.isASCII) else { return text }
        // "=?UTF-8?B?" and "?=" take 12, leaving 63: 60 characters of
        // base64, which is 45 bytes.
        let maxBytes = 45
        var chunks: [[UInt8]] = []
        var current: [UInt8] = []
        func add(_ bytes: [UInt8]) {
            if !current.isEmpty, current.count + bytes.count > maxBytes {
                chunks.append(current)
                current = []
            }
            current += bytes
        }
        for character in text {
            let bytes = Array(String(character).utf8)
            if bytes.count <= maxBytes {
                add(bytes)
            } else {
                // One very long character (a family emoji): split between
                // its scalars, still never inside a UTF-8 sequence.
                for scalar in character.unicodeScalars { add(Array(String(scalar).utf8)) }
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks.map { "=?UTF-8?B?\(Data($0).base64EncodedString())?=" }.joined(separator: "\r\n ")
    }
}
