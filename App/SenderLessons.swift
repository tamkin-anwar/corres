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
        /// quiet/keep steer Needs You; the rest are where a sender's mail
        /// (or one kind of it) goes: Primary, Promotions, Social, Updates.
        enum Kind: String, Codable { case quiet, keep, primary, promotions, social, updates }
        let email: String
        var name: String
        var kind: Kind
        var learnedAt: Date
        /// The kind of their mail it's about ("receipts"), so quieting a
        /// shop's newsletters leaves its receipts alone, where Apple's
        /// Categorize Sender moves everything from them at once. Nil: all
        /// of it (lessons from before kinds were kept).
        var mailKind: MailDigest.Kind?
        var id: String { email + "|" + (mailKind?.rawValue ?? "") + "|" + (category == nil ? "needs" : "category") }

        var summary: String {
            let what = mailKind.map { "Its \($0.plural)" } ?? "Its mail"
            switch kind {
            case .quiet: return "\(what) need no action from you"
            case .keep: return "\(what) belong in Needs You"
            case .primary, .promotions, .social, .updates:
                return "\(what) go to \(category?.title ?? "")"
            }
        }

        var category: InboxCategory? {
            switch kind {
            case .primary: .primary
            case .promotions: .promotions
            case .social: .social
            case .updates: .updates
            case .quiet, .keep: nil
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

    /// The lesson about this thread: its sender and its kind of mail; a
    /// rule for that kind wins over one for everything they send.
    /// Where mail goes is a rule you made, so it holds with Learn from My
    /// Changes off; that setting is about what Corres works out itself.
    private static func lesson(for thread: Correspondence, where wanted: (Lesson) -> Bool, always: Bool = false) -> Lesson? {
        guard isEnabled || always, let email = thread.senderEmail?.lowercased() else { return nil }
        let theirs = all.filter { $0.email == email && wanted($0) }
        guard !theirs.isEmpty else { return nil }
        // Working out the kind of email reads its text; only for senders
        // with a lesson.
        let kind = thread.mailKind
        return theirs.first { $0.mailKind == kind } ?? theirs.first { $0.mailKind == nil }
    }

    static func isQuieted(_ thread: Correspondence) -> Bool { lesson(for: thread, where: { $0.kind == .quiet }) != nil }
    static func isKept(_ thread: Correspondence) -> Bool { lesson(for: thread, where: { $0.kind == .keep }) != nil }

    // MARK: Categories

    private static let threadCategoryKey = "corres.lessons.threadCategories"
    private static var threadCategoryCache: [String: String]?
    private static var threadCategories: [String: String] {
        get {
            if let threadCategoryCache { return threadCategoryCache }
            let loaded = UserDefaults.standard.dictionary(forKey: threadCategoryKey) as? [String: String] ?? [:]
            threadCategoryCache = loaded
            return loaded
        }
        set {
            threadCategoryCache = newValue
            UserDefaults.standard.set(newValue, forKey: threadCategoryKey)
        }
    }
    private static func key(_ thread: Correspondence) -> String { thread.id.account + "|" + thread.id.providerID }

    /// Where you've said this email (or its sender, or that kind of their
    /// mail) goes, if anywhere.
    static func category(for thread: Correspondence) -> InboxCategory? {
        if let raw = threadCategories[key(thread)], let category = InboxCategory(rawValue: raw) { return category }
        return lesson(for: thread, where: { $0.category != nil }, always: true)?.category
    }

    enum CategoryScope { case thisEmail, thisKind, sender }

    /// Puts it in `category`, for this email, this kind of the sender's
    /// mail, or all of it. Returns what to say ("Uber's receipts go to
    /// Primary"), and how to take it back.
    static func setCategory(_ category: InboxCategory, for thread: Correspondence, scope: CategoryScope) -> (said: String, undo: () -> Void) {
        let beforeLessons = all
        let beforeThreads = threadCategories
        let undo = { all = beforeLessons; threadCategories = beforeThreads }
        guard scope != .thisEmail, let email = thread.senderEmail?.lowercased() else {
            threadCategories[key(thread)] = category.rawValue
            return ("Moved to \(category.title)", undo)
        }
        let mailKind: MailDigest.Kind? = scope == .thisKind ? thread.mailKind : nil
        let kind = Lesson.Kind(rawValue: category.rawValue) ?? .primary
        // A newer rule about the same mail replaces the older one.
        var lessons = all.filter { !($0.email == email && $0.category != nil && ($0.mailKind == mailKind || mailKind == nil)) }
        lessons.append(Lesson(email: email, name: thread.sender, kind: kind, learnedAt: .now, mailKind: mailKind))
        all = lessons
        threadCategories[key(thread)] = nil
        let what = mailKind.map { "\(thread.sender)\u{2019}s \($0.plural)" } ?? "Mail from \(thread.sender)"
        return ("\(what) \(mailKind == nil ? "goes" : "go") to \(category.title)", undo)
    }

    /// Learns from a move you made, and says what it learned (for the Undo
    /// pill), or nil when the move taught nothing.
    static func learn(from thread: Correspondence, was previous: Attention, now attention: Attention) -> String? {
        guard isEnabled, let email = thread.senderEmail?.lowercased(), !thread.isFromAccountOwner else { return nil }
        let kind: Lesson.Kind
        if previous == .needsYou, attention == .quiet, thread.wasPromotedByIntelligence {
            kind = .quiet
        } else if attention == .needsYou, previous == .quiet, thread.looksAutomated {
            // Only from "No action needed", where Corres put it: bringing
            // back something you'd marked Handled or Waiting isn't a
            // correction of Corres, just a change of plan.
            kind = .keep
        } else {
            return nil
        }
        let mailKind = thread.mailKind
        // Replaces only an earlier Needs You lesson about the same mail,
        // never where their mail goes.
        var lessons = all.filter { !($0.email == email && $0.category == nil && ($0.mailKind == mailKind || $0.mailKind == nil)) }
        lessons.append(Lesson(email: email, name: thread.sender, kind: kind, learnedAt: .now, mailKind: mailKind))
        all = lessons
        let what = "\(thread.sender)\u{2019}s \(mailKind.plural)"
        return kind == .quiet ? "Won't flag \(what) again" : "\(what) stay in Needs You"
    }

    static func forget(_ id: String) { all = all.filter { $0.id != id } }
    static func forgetAll() {
        all = []
        threadCategories = [:]
    }
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
    /// Read without Gmail's tab: moving an email to Primary mustn't turn
    /// its newsletters into "notifications" and slip past its own rule.
    var mailKind: MailDigest.Kind {
        MailDigest.kind(subject: subject, text: excerpt, senderEmail: senderEmail,
                        isBulk: listUnsubscribeMailto != nil || listUnsubscribeURL != nil,
                        looksAutomated: looksAutomated, hasEvent: false,
                        labelIds: labelIds.filter { !InboxCategory.gmailLabels.contains($0) })
    }

    /// In Needs You because the on-device model brought it in: automated
    /// mail, assessed at its latest message, with no rule of Corres's own
    /// behind it.
    var wasPromotedByIntelligence: Bool {
        attention == .needsYou && looksAutomated && triagedMessageID != nil && triagedMessageID == latestMessageID
            && !InboxClassifier.ruleReasons.contains(reason)
    }
}
