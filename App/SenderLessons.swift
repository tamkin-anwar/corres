import Foundation

/// What you've taught Corres by correcting it, kept on this iPhone and
/// shown in Settings → Sorting → What Corres Has Learned, where any lesson
/// can be forgotten. Gmail's Priority Inbox learns from "not important"
/// too, but out of sight; here every lesson is said when it's learned
/// ("Won't flag Google again"), listed, and taken back by Undo.
///
/// - Saying "No action needed" about mail Apple Intelligence put in Needs
///   You: it won't bring that sender's mail in again, and takes back what
///   it already brought in.
/// - Moving a sender's automated mail into Needs You yourself: it won't
///   take that sender's mail out.
///
/// Rules and VIPs are untouched; this steers the on-device model.
@MainActor
enum SenderLessons {
    struct Lesson: Codable, Hashable, Identifiable {
        enum Kind: String, Codable { case quiet, keep }
        let email: String
        var name: String
        var kind: Kind
        var learnedAt: Date
        /// The kind of their mail it's about ("receipts"), so quieting a
        /// shop's newsletters leaves its receipts alone, where Apple's
        /// Categorize Sender moves everything from them at once. Nil: all
        /// of it (lessons from before kinds were kept).
        var mailKind: MailDigest.Kind?
        var id: String { email + "|" + (mailKind?.rawValue ?? "") }

        var summary: String {
            let what = mailKind.map { "Its \($0.plural)" } ?? "Its mail"
            switch kind {
            case .quiet: return "\(what) need no action from you"
            case .keep: return "\(what) belong in Needs You"
            }
        }
    }

    private static let lessonsKey = "corres.lessons"
    static let enabledKey = "corres.lessons.enabled"

    /// Settings → Sorting → Learn from My Changes.
    static var isEnabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    /// Read once; checked for every thread on every sorting pass.
    private static var cache: [Lesson]?
    static var all: [Lesson] {
        get {
            if let cache { return cache }
            let loaded = UserDefaults.standard.data(forKey: lessonsKey)
                .flatMap { try? JSONDecoder().decode([Lesson].self, from: $0) } ?? []
            cache = loaded
            return loaded
        }
        set {
            cache = newValue
            UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: lessonsKey)
        }
    }

    /// The lesson about this thread: its sender and its kind of mail.
    private static func lesson(for thread: Correspondence) -> Lesson? {
        guard isEnabled, let email = thread.senderEmail?.lowercased() else { return nil }
        let theirs = all.filter { $0.email == email }
        guard !theirs.isEmpty else { return nil }
        // Working out the kind of email reads its text; only for senders
        // with a lesson.
        let kind = thread.mailKind
        return theirs.first { $0.mailKind == nil || $0.mailKind == kind }
    }

    static func isQuieted(_ thread: Correspondence) -> Bool { lesson(for: thread)?.kind == .quiet }
    static func isKept(_ thread: Correspondence) -> Bool { lesson(for: thread)?.kind == .keep }

    /// Learns from a move you made, and says what it learned (for the Undo
    /// pill), or nil when the move taught nothing.
    static func learn(from thread: Correspondence, was previous: Attention, now attention: Attention) -> String? {
        guard isEnabled, let email = thread.senderEmail?.lowercased(), !thread.isFromAccountOwner else { return nil }
        let kind: Lesson.Kind
        if previous == .needsYou, attention == .quiet, thread.wasPromotedByIntelligence {
            kind = .quiet
        } else if attention == .needsYou, previous != .needsYou, thread.looksAutomated {
            kind = .keep
        } else {
            return nil
        }
        let mailKind = thread.mailKind
        var lessons = all.filter { !($0.email == email && ($0.mailKind == mailKind || $0.mailKind == nil)) }
        lessons.append(Lesson(email: email, name: thread.sender, kind: kind, learnedAt: .now, mailKind: mailKind))
        all = lessons
        let what = "\(thread.sender)\u{2019}s \(mailKind.plural)"
        return kind == .quiet ? "Won't flag \(what) again" : "\(what) stay in Needs You"
    }

    static func forget(_ id: String) { all = all.filter { $0.id != id } }
    static func forgetAll() { all = [] }
}

extension MailDigest.Kind {
    /// "receipts", for "Amazon's receipts".
    var plural: String {
        switch self {
        case .personal: "emails"
        case .receipt: "receipts"
        case .shipping: "delivery updates"
        case .code: "codes"
        case .invite: "invitations"
        case .newsletter: "newsletters"
        case .notification: "notifications"
        }
    }
}

extension Correspondence {
    /// What kind of email this is, from what's on hand (no body needed).
    var mailKind: MailDigest.Kind {
        MailDigest.kind(subject: subject, text: excerpt, senderEmail: senderEmail,
                        isBulk: listUnsubscribeMailto != nil || listUnsubscribeURL != nil,
                        looksAutomated: looksAutomated, hasEvent: false, labelIds: labelIds)
    }

    /// In Needs You because the on-device model brought it in: automated
    /// mail, assessed at its latest message, with no rule of Corres's own
    /// behind it.
    var wasPromotedByIntelligence: Bool {
        attention == .needsYou && looksAutomated && triagedMessageID != nil && triagedMessageID == latestMessageID
            && !InboxClassifier.ruleReasons.contains(reason)
    }
}
