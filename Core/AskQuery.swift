import Foundation

/// A question to Ask, read for the parts plain keyword search misses: a
/// person ("from Oliver", "what did Maya ask"), "attachments", a kind of
/// mail (receipts, packages, flights), and a time ("this month"). Keyword
/// search alone required every word to appear in an email, so "Receipts
/// this month" looked for the words "receipts" and "month" and found
/// nothing, and "attachments" never checked for an attachment at all.
public struct AskQuery: Equatable, Sendable {
    public enum Topic: String, Sendable { case receipts, packages, travel }

    /// A name or address fragment the sender must match.
    public var person: String?
    public var wantsAttachments = false
    public var topic: Topic?
    public var range: DateInterval?
    /// What's left to search for as words.
    public var keywords: [String] = []

    /// Whether this can be answered by filtering alone, without the model.
    public var isList: Bool { wantsAttachments || topic == .receipts || topic == .packages }

    public init(_ question: String, now: Date = .now, calendar: Calendar = .current) {
        var text = " " + question.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "@.'-")).inverted)
            .joined(separator: " ") + " "

        func take(_ pattern: String) -> [String]? {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
            let groups = (0..<match.numberOfRanges).map { index -> String in
                guard let range = Range(match.range(at: index), in: text) else { return "" }
                return String(text[range])
            }
            if let whole = Range(match.range, in: text) { text.replaceSubrange(whole, with: " ") }
            return groups
        }

        // Time.
        let startOfToday = calendar.startOfDay(for: now)
        func interval(_ component: Calendar.Component, offset: Int = 0) -> DateInterval? {
            guard let current = calendar.dateInterval(of: component, for: now) else { return nil }
            guard offset != 0, let start = calendar.date(byAdding: component, value: offset, to: current.start),
                  let shifted = calendar.dateInterval(of: component, for: start) else { return current }
            return shifted
        }
        if take(#" (this|current) month "#) != nil { range = interval(.month) }
        else if take(#" last month "#) != nil { range = interval(.month, offset: -1) }
        else if take(#" (this|current) week "#) != nil { range = interval(.weekOfYear) }
        else if take(#" last week "#) != nil { range = interval(.weekOfYear, offset: -1) }
        else if take(#" today "#) != nil { range = DateInterval(start: startOfToday, duration: 86_400) }
        else if take(#" yesterday "#) != nil {
            range = DateInterval(start: startOfToday.addingTimeInterval(-86_400), duration: 86_400)
        } else if let days = take(#" (last|past) (\d{1,3}) days "#), let count = Int(days[2]) {
            range = DateInterval(start: startOfToday.addingTimeInterval(Double(-count) * 86_400), end: now)
        }

        // Attachments and kinds of mail.
        if take(#" (attachments?|attached|files?|pdfs?|documents?|docs|photos|pictures|images) "#) != nil {
            wantsAttachments = true
        }
        if take(#" (receipts?|orders?|invoices?|purchases?|bills?|charges?|payments?|spent|spend) "#) != nil {
            topic = .receipts
        } else if take(#" (packages?|parcels?|deliver(y|ies)|shipments?|shipping|tracking) "#) != nil {
            topic = .packages
        } else if text.range(of: #" (flights?|trips?|travel|itinerar(y|ies)|boarding|hotel|reservations?|check-?in) "#,
                             options: .regularExpression) != nil {
            topic = .travel
        }

        // A person: "from X", or "did X ask/say/send/want".
        if let from = take(#" from ([a-z0-9@.'-]+) "#) {
            person = from[1]
        } else if let did = take(#" (did|has|have) ([a-z0-9@.'-]+) (ask|asked|say|said|send|sent|want|wanted|need|needed|mention|write|wrote) "#) {
            person = did[2]
        }
        if let name = person, Self.notPeople.contains(name) { person = nil }

        keywords = text.split(separator: " ").map(String.init)
            .filter { $0.count > 1 && !Self.stopWords.contains($0) }
        // Travel is found by its words, not a kind of email.
        if topic == .travel { keywords = keywords.filter { !["flight", "flights", "next", "upcoming"].contains($0) } }
    }

    /// Whether a thread fits everything but the words.
    public func matches(_ thread: Correspondence) -> Bool {
        if wantsAttachments && thread.attachments.isEmpty { return false }
        if let range, !range.contains(thread.receivedAt) { return false }
        if let person {
            let sender = (thread.sender + " " + (thread.senderEmail ?? "")).lowercased()
            if !sender.contains(person) { return false }
        }
        switch topic {
        case .receipts?:
            return MailDigest.kind(subject: thread.subject, text: thread.excerpt + "\n" + thread.body,
                                   senderEmail: thread.senderEmail, isBulk: true,
                                   looksAutomated: thread.looksAutomated, hasEvent: false) == .receipt
        case .packages?:
            return MailDigest.kind(subject: thread.subject, text: thread.excerpt + "\n" + thread.body,
                                   senderEmail: thread.senderEmail, isBulk: true,
                                   looksAutomated: thread.looksAutomated, hasEvent: false) == .shipping
        default:
            return true
        }
    }

    /// The same question in Gmail's search operators, to reach older mail
    /// that hasn't synced: "from:oliver has:attachment after:2026/10/01".
    public var gmailQuery: String {
        var parts: [String] = []
        if let person { parts.append("from:\(person)") }
        if wantsAttachments { parts.append("has:attachment") }
        switch topic {
        case .receipts?: parts.append("(receipt OR order OR invoice)")
        case .packages?: parts.append("(shipped OR delivery OR tracking)")
        case .travel?: parts.append("(flight OR itinerary OR reservation OR boarding)")
        case nil: break
        }
        if let range {
            let format = DateFormatter()
            format.dateFormat = "yyyy/MM/dd"
            format.locale = Locale(identifier: "en_US_POSIX")
            parts.append("after:\(format.string(from: range.start.addingTimeInterval(-86_400)))")
            parts.append("before:\(format.string(from: range.end.addingTimeInterval(86_400)))")
        }
        parts += keywords
        return parts.joined(separator: " ")
    }

    /// A heading for a list answer: "Attachments from Oliver this month".
    public func title(count: Int) -> String {
        var what: String
        if wantsAttachments { what = count == 1 ? "1 email with attachments" : "\(count) emails with attachments" }
        else if topic == .receipts { what = count == 1 ? "1 receipt" : "\(count) receipts" }
        else if topic == .packages { what = count == 1 ? "1 package" : "\(count) packages" }
        else { what = count == 1 ? "1 email" : "\(count) emails" }
        if let person { what += " from \(person.prefix(1).uppercased() + person.dropFirst())" }
        return what
    }

    static let notPeople: Set<String> = ["me", "my", "you", "us", "them", "the", "a", "an", "this", "last", "today",
                                         "yesterday", "work", "home", "amazon"]

    static let stopWords: Set<String> = [
        "a", "an", "the", "my", "me", "i", "is", "are", "was", "were", "do", "does", "did", "what", "whats",
        "what's", "when", "where", "who", "whom", "which", "how", "why", "can", "could", "to", "of", "for", "in",
        "on", "at", "from", "with", "about", "any", "there", "it", "and", "or", "be", "been", "has", "have", "had",
        "will", "would", "should", "you", "your", "tell", "show", "find", "email", "emails", "mail", "message",
        "messages", "latest", "last", "recent", "send", "sent", "leave", "get", "got", "that", "this", "ask",
        "asked", "say", "said", "want", "wanted", "need", "needed", "mention", "write", "wrote", "all", "some",
        "list", "please", "anything", "everything",
    ]
}
