import Foundation

/// Primary, Promotions, Social and Updates: Gmail's tabs and Apple Mail's
/// categories, decided from Gmail's own category and Corres's reading,
/// and then by what you've taught it (`override`).
///
/// Primary is people, and anything that needs you wherever it came from
/// (a failed payment, a deadline), as Apple Mail lets time-sensitive mail
/// into Primary.
public enum InboxCategory: String, Codable, CaseIterable, Sendable {
    case primary, promotions, social, updates

    public var title: String {
        switch self {
        case .primary: "Primary"
        case .promotions: "Promotions"
        case .social: "Social"
        case .updates: "Updates"
        }
    }

    /// Gmail's own label for it, so a move here teaches Gmail too.
    public var gmailLabel: String {
        switch self {
        case .primary: "CATEGORY_PERSONAL"
        case .promotions: "CATEGORY_PROMOTIONS"
        case .social: "CATEGORY_SOCIAL"
        case .updates: "CATEGORY_UPDATES"
        }
    }

    public static let gmailLabels: Set<String> = ["CATEGORY_PERSONAL", "CATEGORY_PROMOTIONS", "CATEGORY_SOCIAL",
                                                  "CATEGORY_UPDATES", "CATEGORY_FORUMS"]

    /// What the rest of the mailbox says about senders: where most of each
    /// one's bulk mail sits, for the mail Gmail left without a category.
    /// Built once per list, from the mail on hand.
    public struct Context: Sendable {
        /// Sender → the category most of their bulk mail is in (at least
        /// three emails, two in three of them there).
        public var senderLean: [String: InboxCategory] = [:]
        public init(senderLean: [String: InboxCategory] = [:]) { self.senderLean = senderLean }
    }

    public static func context(for threads: [Correspondence]) -> Context {
        var counts: [String: [InboxCategory: Int]] = [:]
        for thread in threads {
            guard let email = thread.senderEmail?.lowercased(), !thread.isFromAccountOwner,
                  let kind = InboxClassifier.bulkKind(labelIds: thread.labelIds, looksAutomated: thread.looksAutomated) else { continue }
            counts[email, default: [:]][gmailPlacement(kind), default: 0] += 1
        }
        var lean: [String: InboxCategory] = [:]
        for (email, byCategory) in counts {
            let total = byCategory.values.reduce(0, +)
            guard total >= 3, let top = byCategory.max(by: { $0.value < $1.value }), top.value * 3 >= total * 2 else { continue }
            lean[email] = top.key
        }
        return Context(senderLean: lean)
    }

    /// Where `thread` belongs. `override`: what you've said about it, its
    /// sender or its kind of mail. Better than a copy of Gmail's tab:
    /// - people, and anything that needs you, are Primary;
    /// - so is what's urgent right now: a security alert, a sign-in code
    ///   or reset link in its first hour, an appointment in the next two
    ///   days (Apple Mail lets time-sensitive mail into Primary too);
    /// - social networks are Social, wherever Gmail put them;
    /// - an obvious offer ("20% off", "last chance") is Promotions, even
    ///   when Gmail called it an update, but a receipt, delivery or code
    ///   never is;
    /// - and mail Gmail didn't place goes where its sender's other mail
    ///   is (`context`).
    public static func of(_ thread: Correspondence, override: InboxCategory? = nil,
                          context: Context? = nil, now: Date = .now) -> InboxCategory {
        if let override { return override }
        if thread.attention == .needsYou || thread.attention == .waiting { return .primary }
        guard let kind = InboxClassifier.bulkKind(labelIds: thread.labelIds, looksAutomated: thread.looksAutomated) else {
            return .primary
        }
        if isTimeSensitive(thread, now: now) { return .primary }
        let email = thread.senderEmail?.lowercased() ?? ""
        if isSocialNetwork(email) { return .social }
        let gmail = gmailPlacement(kind)
        let transactional = isTransactional(thread)
        if !transactional, gmail != .social, looksPromotional(thread.subject) { return .promotions }
        // Where Gmail gave no category (no tabs on this account, or none
        // given), the sender's other mail decides. Gmail's own reading of
        // an email is never overruled by it: that moved a credit bureau's
        // real alerts into Promotions alongside its offers.
        if kind == .automated, let lean = context?.senderLean[email], lean != gmail, !(lean == .promotions && transactional) {
            return lean
        }
        if gmail == .promotions, transactional { return .updates }
        return gmail
    }

    private static func gmailPlacement(_ kind: InboxClassifier.BulkKind) -> InboxCategory {
        switch kind {
        case .promotions: .promotions
        case .social: .social
        case .forums, .updates, .automated: .updates
        }
    }

    // MARK: Signals

    /// Social networks and communities, by the domains they mail from.
    static let socialDomains: Set<String> = [
        "linkedin.com", "facebookmail.com", "facebook.com", "instagram.com", "mail.instagram.com", "x.com", "twitter.com",
        "reddit.com", "redditmail.com", "tiktok.com", "pinterest.com", "snapchat.com", "discord.com", "nextdoor.com",
        "quora.com", "threads.net", "bsky.app", "tumblr.com", "meetup.com", "strava.com", "goodreads.com",
        "letterboxd.com", "twitch.tv", "mastodon.social", "whatsapp.com", "telegram.org", "vk.com", "xing.com",
    ]

    static func isSocialNetwork(_ email: String) -> Bool {
        guard let domain = email.split(separator: "@").last.map(String.init) else { return false }
        return socialDomains.contains { domain == $0 || domain.hasSuffix("." + $0) }
    }

    private static let securityPattern = #"(?i)\b(security (alert|notice|warning)|new (sign-?in|login|device)|sign-?in (attempt|from|on)|suspicious (activity|sign-?in|login)|unusual (activity|sign-?in|login)|someone (signed|logged|tried)|password (was |has been )(changed|reset)|password changed|account (locked|suspended|compromised)|critical security|was (added|removed) (to|from) your account)\b"#
    private static let accessPattern = #"(?i)\b(verification code|security code|one-?time (pass(code|word)|code)|login code|sign-?in (code|link)|magic link|verify your (email|account|identity)|confirm your (email|account)|reset (your )?password|password reset|temporary (access )?code|access code|\b2fa\b|two-?factor)\b"#

    /// Urgent right now; back to its usual place once it isn't.
    static func isTimeSensitive(_ thread: Correspondence, now: Date) -> Bool {
        let age = now.timeIntervalSince(thread.receivedAt)
        let subject = thread.subject
        if age < 3 * 86_400, subject.patternRange(securityPattern) != nil { return true }
        if age < 3_600, subject.patternRange(accessPattern) != nil
            || MailDigest.verificationCode(in: subject + "\n" + thread.excerpt.prefix(300)) != nil { return true }
        if let due = thread.dueAt, due > now, due < now.addingTimeInterval(2 * 86_400),
           MailSignals.isEvent(subject + "\n" + thread.excerpt) { return true }
        return false
    }

    /// A receipt, a delivery, a statement, a code: never an ad, whatever
    /// its sender sends otherwise.
    private static let transactionalPattern = #"(?i)\b(receipt|order (#|no\.?|number|confirm|confirmed|shipped|delivered|is on)|your order|has shipped|out for delivery|delivered|tracking|invoice|statement|payment (received|confirmed|due|failed)|bill(ing)? (is|for)|booking|reservation|itinerary|confirmation|confirmed|verification|password|security (alert|code|notice|update)|sign-?in|account (update|notice|alert)|appointment|ticket|refund|subscription (renewed|confirmed|canceled|cancelled))\b"#

    static func isTransactional(_ thread: Correspondence) -> Bool {
        transactionalMemo.value(thread.subject) {
            thread.subject.patternRange(transactionalPattern) != nil || thread.subject.patternRange(accessPattern) != nil
        }
    }
    private static let transactionalMemo = Memo<String, Bool>()
    private static let promotionalMemo = Memo<String, Bool>()

    /// Selling, said in the subject: what Gmail's Promotions catches, and
    /// what it misses when a shop's offer arrives as an "update".
    private static let promotionalPattern = #"(?i)(\b\d{1,3}\s?% off\b|\b(up to|extra|save|get) \$\d+|\b(up to|extra|save) \d{1,3}%|\$\d+ off\b|\bspend \$\d+|\b(flash|semi-annual|annual|holiday|black friday|cyber monday|clearance|end of season|warehouse|parking lot|summer|fall|winter|spring) sale\b|\bsale (ends|starts|is on|now)\b|\bon sale\b|\b(special|exclusive|limited|best|exclusive member|personal) (offers?|deals?)\b|\b(daily|weekly|digital|insider|holiday|today's) deals?\b|\bdeals? (end|ends|of the)\b|\bfree (shipping|delivery|gift)\b|\blast chance\b|\b(ends|ending) (tonight|today|tomorrow|soon|at midnight|sunday)\b|\blimited[- ]time\b|\bshop (now|the (sale|collection|look))\b|\b(promo|coupon|discount) code\b|\bcoupons?\b|\bbogo\b|\bbuy one,? get one\b|\bdoorbusters?\b|\bnew arrivals\b|\bjust dropped\b|\bgift guide\b|\b(picked|chosen|selected) (just )?for you\b|\byou may also like\b|\bdon'?t miss (out|this)\b|\b(points|rewards) (expire|are expiring)\b|\bprice drop\b|\bonly \$\d+)"#

    static func looksPromotional(_ subject: String) -> Bool {
        promotionalMemo.value(subject) { subject.patternRange(promotionalPattern) != nil }
    }
}
