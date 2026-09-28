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

    /// Automated mail that carries a real obligation for this person: a
    /// bill, a signature, a renewal, an appointment. Only ever combined
    /// with a detected deadline, and never applied to promotions.
    public static func isObligation(_ text: String) -> Bool {
        text.range(of: #"(?i)\b(payment|pay|bill|invoice|balance|renew(al)?|expir\w*|sign(ature)?|verify|appointment|check-in|reservation|rsvp|deadline|due)\b"#,
                   options: .regularExpression) != nil
    }

    /// Whether anyone you wrote to is a person rather than a no-reply
    /// system address: waiting on `noreply@` makes no sense.
    public static func hasPersonRecipient(_ recipients: [String], account: String) -> Bool {
        recipients.contains { address in
            let lower = address.lowercased()
            return lower != account.lowercased()
                && lower.range(of: #"^(no.?reply|do.?not.?reply|notifications?|mailer-daemon)@"#, options: .regularExpression) == nil
        }
    }
}
