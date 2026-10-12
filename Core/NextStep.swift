import Foundation

/// The one thing an email asks you to do, with its link: "Book" an
/// appointment, "Pay" a bill, "Track" a package. Shown in place of a
/// summary on a short email, where a summary only repeated it (reported by
/// a tester: "it says the same thing, link instead"). Found in the email
/// itself, without Apple Intelligence, so it can't be made up.
public struct NextStep: Equatable, Codable, Sendable {
    /// What to do, short: "Book", "Pay your bill", "Track package".
    public let label: String
    public let url: URL

    /// Where the link goes, for showing beside the label.
    public var host: String {
        (url.host ?? "").replacingOccurrences(of: #"^www\."#, with: "", options: .regularExpression)
    }

    public init(label: String, url: URL) {
        self.label = label
        self.url = url
    }
}

extension MailDigest {
    /// The email's main call to action and its link, or nil when there
    /// isn't a clear one. Marketing and newsletters are left out: their
    /// "Shop now" is the email's whole purpose, not a step for you.
    public static func nextStep(text: String, html: String?, kind: Kind) -> NextStep? {
        guard kind != .newsletter, kind != .code else { return nil }
        let links = self.links(text: text, html: html).filter { isActionable($0.url) }
        guard !links.isEmpty else { return nil }

        // A link whose own words say what it does: "Book an appointment".
        var best: (link: Link, score: Int, label: String)?
        for (index, link) in links.enumerated() {
            let anchor = link.anchor.trimmingCharacters(in: .whitespacesAndNewlines)
            var score = 0
            var label: String?
            if actionVerb(in: anchor) != nil, isReadableAnchor(anchor) {
                score += 6
                label = anchorLabel(anchor)
            }
            if label == nil, let verb = actionVerb(in: link.context) {
                score += 3
                label = verbLabel(verb)
            }
            // Later links are usually the footer.
            score -= index * 1
            if let label, score > 0, score > (best?.score ?? 0) { best = (link, score, label) }
        }
        if let best { return NextStep(label: best.label, url: best.link.url) }

        // One link, and a sentence that says what it's for: "Please visit
        // the link to book."
        if links.count == 1, let verb = actionVerb(in: text) {
            return NextStep(label: verbLabel(verb), url: links[0].url)
        }
        return nil
    }

    struct Link {
        let url: URL
        /// The link's own words (HTML), or empty.
        let anchor: String
        /// The text just before the link, where "click below to pay" is.
        let context: String
    }

    static func links(text: String, html: String?) -> [Link] {
        var found: [Link] = []
        var seen = Set<String>()
        if let html, let anchorRegex = try? NSRegularExpression(
            pattern: #"<a\b[^>]*?href\s*=\s*["']([^"']+)["'][^>]*>(.*?)</a>"#,
            options: [.caseInsensitive, .dotMatchesLineSeparators]) {
            let range = NSRange(html.startIndex..., in: html)
            for match in anchorRegex.matches(in: html, range: range) {
                guard let hrefRange = Range(match.range(at: 1), in: html), let innerRange = Range(match.range(at: 2), in: html),
                      let url = URL(string: decodeEntities(String(html[hrefRange]))) else { continue }
                let anchor = decodeEntities(String(html[innerRange])
                    .replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression))
                    .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                let start = html.index(hrefRange.lowerBound, offsetBy: -min(600, html.distance(from: html.startIndex, to: hrefRange.lowerBound)))
                let before = decodeEntities(String(html[start..<hrefRange.lowerBound])
                    .replacingOccurrences(of: #"<[^>]*>?"#, with: " ", options: .regularExpression))
                guard seen.insert(url.absoluteString).inserted else { continue }
                found.append(Link(url: url, anchor: anchor, context: lastSentence(of: before)))
            }
        }
        if found.isEmpty, let urlRegex = try? NSRegularExpression(pattern: #"https?://[^\s<>"')\]]+"#) {
            let range = NSRange(text.startIndex..., in: text)
            for match in urlRegex.matches(in: text, range: range) {
                guard let urlRange = Range(match.range, in: text) else { continue }
                let raw = String(text[urlRange]).trimmingCharacters(in: CharacterSet(charactersIn: ".,;:"))
                guard let url = URL(string: raw), seen.insert(url.absoluteString).inserted else { continue }
                let before = String(text[..<urlRange.lowerBound].suffix(400))
                found.append(Link(url: url, anchor: "", context: lastSentence(of: before)))
            }
        }
        return found
    }

    /// Links that are a step for you, not the email's plumbing.
    static func isActionable(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = url.host?.lowercased() else { return false }
        let whole = url.absoluteString.lowercased()
        let plumbing = ["unsubscribe", "optout", "opt-out", "preferences", "manage-subscription", "email-settings",
                        "privacy", "terms", "legal", "view-in-browser", "viewinbrowser", "webversion", "view_online"]
        if plumbing.contains(where: whole.contains) { return false }
        let social = ["facebook.com", "twitter.com", "x.com", "instagram.com", "linkedin.com", "youtube.com",
                      "tiktok.com", "pinterest.com", "apps.apple.com", "itunes.apple.com", "play.google.com"]
        if social.contains(where: { host == $0 || host.hasSuffix("." + $0) }) { return false }
        // Images and tracking pixels.
        if whole.range(of: #"\.(png|jpe?g|gif|svg|webp)(\?|$)"#, options: .regularExpression) != nil { return false }
        return true
    }

    /// The action a sentence or link names: "book", "pay", "track".
    static func actionVerb(in text: String) -> String? {
        let lower = text.lowercased()
        for (pattern, verb) in actionPatterns where lower.range(of: pattern, options: .regularExpression) != nil {
            return verb
        }
        return nil
    }

    private static let actionPatterns: [(String, String)] = [
        (#"\b(book|booking|schedule|reschedule)\b"#, "book"),
        (#"\b(pay|payment due|make a payment)\b"#, "pay"),
        (#"\b(track|tracking)\b"#, "track"),
        (#"\b(confirm|confirmation required)\b"#, "confirm"),
        (#"\b(verify|verification)\b"#, "verify"),
        (#"\b(sign the|e-?sign|docusign|signature)\b"#, "sign"),
        (#"\b(rsvp|respond to (the )?invitation)\b"#, "rsvp"),
        (#"\b(register|sign up|enrol|enroll)\b"#, "register"),
        (#"\b(reset (your )?password)\b"#, "reset"),
        (#"\b(complete (your|the)|fill (in|out))\b"#, "complete"),
        (#"\b(check[- ]?in)\b"#, "checkin"),
        (#"\b(view|see) (your )?(order|receipt|invoice|statement|bill|results?|booking|reservation|appointment)\b"#, "view"),
        (#"\b(review|approve)\b"#, "review"),
        (#"\b(join (the )?(meeting|call|zoom|webinar))\b"#, "join"),
    ]

    private static func verbLabel(_ verb: String) -> String {
        switch verb {
        case "book": "Book"
        case "pay": "Pay"
        case "track": "Track package"
        case "confirm": "Confirm"
        case "verify": "Verify"
        case "sign": "Sign"
        case "rsvp": "RSVP"
        case "register": "Register"
        case "reset": "Reset password"
        case "complete": "Complete it"
        case "checkin": "Check in"
        case "view": "View"
        case "review": "Review"
        case "join": "Join"
        default: verb.capitalized
        }
    }

    /// A link's own words, when they read as a label ("Book an
    /// appointment"), not a URL or "click here".
    private static func isReadableAnchor(_ anchor: String) -> Bool {
        let words = anchor.split(separator: " ")
        guard (1...7).contains(words.count), anchor.count <= 48,
              anchor.range(of: #"https?://|www\.|\.com\b"#, options: [.regularExpression, .caseInsensitive]) == nil else { return false }
        return !["here", "click here", "link", "this link", "tap here", "more"].contains(anchor.lowercased())
    }

    private static func anchorLabel(_ anchor: String) -> String {
        let trimmed = anchor.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "›»→>")))
        // "BOOK NOW" reads as "Book now".
        let cased = trimmed == trimmed.uppercased() ? trimmed.lowercased() : trimmed
        return cased.prefix(1).uppercased() + cased.dropFirst()
    }

    private static func lastSentence(of text: String) -> String {
        let cleaned = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        let parts = cleaned.components(separatedBy: CharacterSet(charactersIn: ".!?\n"))
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return parts.suffix(2).joined(separator: ". ")
    }

    private static func decodeEntities(_ text: String) -> String {
        text.replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&#39;", with: "'").replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
    }
}

/// What a receipt, delivery or bill says at a glance, read straight from
/// its own lines, the way Gmail's summary cards are: no model, so nothing
/// can be made up. "Payment failed", "Total £14.62", "Order 112-4471".
public struct Glance: Equatable, Codable, Sendable {
    /// The email's status line, when it has one: "Failed payment",
    /// "Delivered", "Payment due".
    public let status: String?
    /// Something has gone wrong or needs doing ("failed", "overdue").
    public let isAlert: Bool
    public let facts: [Fact]

    public struct Fact: Equatable, Codable, Sendable, Hashable {
        public let label: String
        public let value: String
        public init(label: String, value: String) { self.label = label; self.value = value }
    }

    public init(status: String?, isAlert: Bool, facts: [Fact]) {
        self.status = status; self.isAlert = isAlert; self.facts = facts
    }
}

extension MailDigest {
    /// The status and key figures of designed mail. Nil for mail people
    /// write, and when there's nothing clear enough to show.
    public static func glance(text: String, kind: Kind) -> Glance? {
        guard [.receipt, .shipping, .notification].contains(kind) else { return nil }
        let lines = text.split(separator: "\n").map {
            $0.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty && wordCount($0) <= 9 }

        var status: String?
        var isAlert = false
        for line in lines.prefix(12) where wordCount(line) <= 5 && !line.contains("?") {
            if line.range(of: alertStatus, options: .regularExpression) != nil { status = line; isAlert = true; break }
            if status == nil, line.range(of: calmStatus, options: .regularExpression) != nil { status = line }
        }

        var total: Glance.Fact?, otherAmount: Glance.Fact?, date: Glance.Fact?, reference: Glance.Fact?
        for line in lines {
            if total == nil || otherAmount == nil, let fact = labelled(line, valuePattern: "(" + amountPattern + ")") {
                if fact.label.range(of: totalLabel, options: .regularExpression) != nil {
                    if total == nil { total = fact }
                } else if otherAmount == nil, fact.label.range(of: partLabel, options: .regularExpression) == nil {
                    otherAmount = fact
                }
            }
            if date == nil, let fact = labelled(line, valuePattern: #"(.*\d.*)"#),
               fact.label.range(of: dateLabel, options: .regularExpression) != nil {
                date = fact
            }
            if reference == nil, let fact = labelled(line, valuePattern: #"#?\s*((?=[A-Z0-9-]*\d)[A-Z0-9][A-Z0-9-]{3,})"#),
               fact.label.range(of: referenceLabel, options: .regularExpression) != nil {
                reference = fact
            }
        }
        let facts = [total ?? otherAmount, date, reference].compactMap { $0 }
        // A status alone, or a single figure without one, isn't a card.
        guard facts.count >= (status == nil ? 2 : 1) else { return nil }
        if let status, facts.contains(where: { $0.value == status }) { return Glance(status: nil, isAlert: isAlert, facts: facts) }
        return Glance(status: status.map(tidyStatus), isAlert: isAlert, facts: facts)
    }

    /// "Total £14.62", "Total: £14.62", "Estimated delivery – Thu, 9 Oct":
    /// a short label of words, then the value.
    private static func labelled(_ line: String, valuePattern: String) -> Glance.Fact? {
        let pattern = #"^([\p{L}][\p{L} '’&/().]{1,32})\s*[:\-–—]?\s+"# + valuePattern + #"\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let labelRange = Range(match.range(at: 1), in: line),
              let valueRange = Range(match.range(at: 2), in: line) else { return nil }
        let label = String(line[labelRange]).trimmingCharacters(in: .whitespaces.union(.init(charactersIn: ":-–—")))
        let value = String(line[valueRange]).trimmingCharacters(in: .whitespaces)
        guard wordCount(label) <= 4, !value.isEmpty else { return nil }
        return Glance.Fact(label: label.prefix(1).uppercased() + label.dropFirst(), value: value)
    }

    private static func tidyStatus(_ line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespaces.union(.init(charactersIn: ".!:")))
        let cased = trimmed == trimmed.uppercased() ? trimmed.lowercased() : trimmed
        return cased.prefix(1).uppercased() + cased.dropFirst()
    }

    private static let alertStatus = #"(?i)\b(fail(ed|ure)?|declined|unsuccessful|overdue|past due|action (required|needed)|suspended|cancel(l)?ed|delayed|returned to sender|unable to deliver|could ?n[o']t (be )?(charge|deliver|process))\b"#
    private static let calmStatus = #"(?i)\b(delivered|shipped|dispatched|out for delivery|on (its|the) way|order (confirmed|received|placed)|payment (received|confirmed|successful)|refund(ed)?|receipt|paid|booking confirmed|confirmed)\b"#
    private static let totalLabel = #"(?i)^(grand |order |trip |amount )?total|amount (due|paid|charged|owed)|balance( due)?|you paid|you('ll| will) pay|charged|to pay|payment( amount)?|amount$"#
    private static let partLabel = #"(?i)\b(sub ?total|fee|tax|vat|tip|discount|fare|shipping|delivery|promo|credit|savings?|item|price)\b"#
    private static let dateLabel = #"(?i)^(due( date| by| on)?|pay by|payment due|(estimated |expected )?(delivery|arrival)( date)?|arriv(es|ing)|deliver(s|ing) (on|by)|renews( on)?|expires( on)?|ships( on)?|date)$"#
    private static let referenceLabel = #"(?i)^(order|confirmation|booking|reservation|invoice|ticket|tracking|reference|ref|receipt)( (number|no\.?|#|id|code))?$"#
}
