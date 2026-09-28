import Foundation

/// What a message itself says, read with plain rules so it works the same
/// on every device, with or without Apple Intelligence. These are the
/// content and thread signals Gmail's Priority Inbox leans on (does it ask
/// something of you, did you reply, is there a date attached), not a score.
public enum MailSignals {
    /// The writer's own words, without the quoted history below them.
    public static func ownText(_ body: String) -> String {
        var kept: [Substring] = []
        for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(">") { continue }
            if trimmed.range(of: #"^On .+ wrote:$"#, options: .regularExpression) != nil { break }
            if trimmed.hasPrefix("-----Original Message-----") || trimmed.hasPrefix("---------- Forwarded message") { break }
            kept.append(line)
        }
        return kept.joined(separator: "\n")
    }

    /// Phrases that ask the reader for something even without a question
    /// mark ("Let me know", "Please confirm").
    private static let requestPattern = #"(?i)\b(can|could|would|will) you\b|\blet me know\b|\bplease (confirm|advise|review|send|reply|respond|approve|sign|share|rsvp|let)\b|\bwhat do you think\b|\byour thoughts\b|\bany (update|news)\b|\bare you (free|available|around)\b|\bwhen (works|would work|are you)\b|\bget back to me\b|\blooking forward to (hearing|your reply)\b|\brsvp\b"#

    /// Whether the writer asks the reader something: a real question or a
    /// request. Links are removed first, since their query strings carry
    /// question marks.
    public static func asksSomething(_ text: String) -> Bool {
        let own = ownText(text).replacingOccurrences(of: #"https?://\S+"#, with: "", options: .regularExpression)
        if own.range(of: #"[\p{L}\p{N})"'’]\s?\?"#, options: .regularExpression) != nil { return true }
        return own.range(of: requestPattern, options: .regularExpression) != nil
    }

    /// Words that make a date a deadline when they come right before it:
    /// "due Friday", "by Oct 3", "RSVP by the 12th". Deliberately tight;
    /// a date on its own ("Posted Sep 3") is not a deadline.
    private static let deadlineLeadIn = #"(?i)\b(due|by|before|until|no later than|deadline(\s+is)?:?|expires?|expiring|rsvp(\s+by)?|respond by|reply by|closes?)\s*(on\s+|the\s+)?$"#

    /// The earliest upcoming deadline the message names, within `horizon`.
    /// Relative dates ("by Friday") resolve against now, so this is meant
    /// for mail read as it arrives.
    public static func deadline(in text: String, now: Date = .now, horizon: TimeInterval = 45 * 86_400) -> Date? {
        let own = String(ownText(text).prefix(4_000))
        guard !own.isEmpty,
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else { return nil }
        let ns = own as NSString
        var earliest: Date?
        for match in detector.matches(in: own, range: NSRange(location: 0, length: ns.length)) {
            guard let date = match.date,
                  date > now.addingTimeInterval(-3_600), date < now.addingTimeInterval(horizon) else { continue }
            let start = max(0, match.range.location - 32)
            let before = ns.substring(with: NSRange(location: start, length: match.range.location - start))
            guard before.range(of: deadlineLeadIn, options: .regularExpression) != nil else { continue }
            if earliest.map({ date < $0 }) ?? true { earliest = date }
        }
        return earliest
    }

    /// For automated mail about an appointment, bill or signature, any date
    /// in the next few days is the one that matters, however it's worded:
    /// "Your appointment is tomorrow at 9:00 AM" has no "by" or "due" in
    /// it. Promotions never get here (see `InboxClassifier`).
    public static func timeSensitiveDate(in text: String, now: Date = .now, within: TimeInterval = 3 * 86_400) -> Date? {
        if let due = deadline(in: text, now: now, horizon: within) { return due }
        guard isObligation(text),
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else { return nil }
        let own = String(ownText(text).prefix(4_000))
        return detector.matches(in: own, range: NSRange(location: 0, length: (own as NSString).length))
            .compactMap(\.date)
            .filter { $0 > now.addingTimeInterval(-3_600) && $0 < now.addingTimeInterval(within) }
            .min()
    }

    /// Automated mail that carries a real obligation for this person: a
    /// bill, a signature, a renewal, an appointment. Only ever combined
    /// with a detected deadline, and never applied to promotions.
    /// Something the reader has to do, not just something that will
    /// happen: "payment due", "sign by", "your appointment", "verify".
    /// A welcome, receipt or autopay notice ("will be charged
    /// automatically", "thanks for your payment") is information, never an
    /// obligation, however many dates it names.
    public static func isObligation(_ text: String) -> Bool {
        let lower = text.lowercased()
        let action = #"\b(payment (is )?(due|failed|declined|overdue)|past due|amount due|due (date|on|by)|pay (by|now|your)|bill (is )?(due|ready)|balance (is )?due|invoice (is )?due|sign (by|the|your|here)|signature (requested|required|needed)|please sign|verify (your|by)|action (is )?required|expires? (on|in|soon|today|tomorrow)|expiring|renew (by|before|now)|appointment|check-in|reservation|rsvp|deadline)\b"#
        let notice = #"\b(will be (charged|billed|renewed) (automatically|monthly|annually)|(automatically|auto-?) ?(charged|billed|renews?)|thank(s| you) for (your )?(payment|order|purchase)|payment (received|confirmed|successful)|receipt|welcome to)\b"#
        guard lower.range(of: action, options: .regularExpression) != nil else { return false }
        // An appointment or reservation reminder stays even if it thanks you.
        let reminder = lower.range(of: #"\b(appointment|reservation|check-in|rsvp)\b"#, options: .regularExpression) != nil
        return reminder || lower.range(of: notice, options: .regularExpression) == nil
    }

    /// Whether anyone you wrote to is a person rather than a no-reply
    /// system address: waiting on `noreply@` makes no sense.
    public static func hasPersonRecipient(_ recipients: [String], account: String) -> Bool {
        recipients.contains { address in
            let lower = address.lowercased()
            return lower != account.lowercased()
                && lower.range(of: Correspondence.automatedLocalPart, options: .regularExpression) == nil
        }
    }
}
