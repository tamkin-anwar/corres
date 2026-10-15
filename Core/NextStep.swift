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

    /// Where the link goes, for showing beside the label. Empty when it
    /// only passes through a sender's click tracker ("click.e.example.com",
    /// "track.pstmrk.it"), which isn't where it ends up and reads as
    /// suspicious.
    public var host: String {
        let host = (url.host ?? "").lowercased().replacingOccurrences(of: #"^www\."#, with: "", options: .regularExpression)
        if host.range(of: #"^(click|clicks|track|tracking|links?|email|e|l|t|r|go|trk|mail|em|url\d*|ablink|ct)\.|^(track|click|trk|link)[a-z0-9]{0,4}\.|pstmrk|sendgrid|awstrack|sailthru|list-manage|mailchimp|hubspotlinks|mandrillapp|mcsv\.net|exacttarget|rs6\.net|cmail\d*\.com"#,
                      options: .regularExpression) != nil { return "" }
        return host
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
        // Designed (HTML) mail is full of buttons; only one whose own words name
        // the step counts, and never a sales one ("Book now", "Sign up").
        // Guessing from the words around a link gave a news story about
        // wages a "Pay" button.
        // Plain-text notices read like letters ("Please visit the link to
        // book"), so the words around a link count there.
        let isDesigned = kind != .personal && html?.isEmpty == false
        var best: (link: Link, score: Int, label: String)?
        for (index, link) in links.enumerated() {
            let anchor = link.anchor.trimmingCharacters(in: .whitespacesAndNewlines)
            if isDesigned, anchor.range(of: salesButton, options: .regularExpression) != nil { continue }
            var score = 0
            var label: String?
            if actionVerb(in: anchor) != nil, isReadableAnchor(anchor) {
                score += 6
                label = anchorLabel(anchor)
            }
            if label == nil, !isDesigned, let verb = actionVerb(in: link.context) {
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
        if links.count == 1, !isDesigned, let verb = actionVerb(in: text) {
            return NextStep(label: verbLabel(verb), url: links[0].url)
        }
        return nil
    }

    private static let salesButton = #"(?i)\b(now|today|sign ?up|subscribe|shop|buy|deals?|offer|save|earn|join|explore|discover|learn more|get started|download|upgrade)\b"#

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
        (#"\b(update|fix|change) (your )?(payment|card|billing)( (method|info(rmation)?|details))?\b"#, "update"),
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
        case "update": "Update payment"
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
    ///
    /// Real receipts are laid out every way: a table row ("Total £14.62"),
    /// a label over its amount (Lyft), one long run of text (Stripe's
    /// "…Total $18.50 Amount paid $18.50…"), or a sentence (DoorDash's
    /// "unable to process your recent payment of $9.99"). Each is read.
    public static func glance(text: String, subject: String = "", kind: Kind) -> Glance? {
        guard [.receipt, .shipping, .notification].contains(kind) else { return nil }
        let lines = text.split(separator: "\n").map {
            $0.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }
        // A short label alone on its line, its amount on the next, joined.
        var merged: [String] = []
        for line in lines {
            if let last = merged.last, wordCount(last) <= 6, !last.contains(where: \.isNumber) || last.count < 40,
               line.range(of: "^(" + amountPattern + #")(\s+[A-Z]{3})?$"#, options: .regularExpression) != nil {
                merged[merged.count - 1] = last + " " + line
            } else {
                merged.append(line)
            }
        }
        let body = String(merged.joined(separator: "\n").prefix(8_000))

        // What happened, in the same few words whoever sent it.
        let top = subject + "\n" + merged.prefix(25).joined(separator: "\n")
        var status = statusRules.first { top.range(of: $0.pattern, options: .regularExpression) != nil }
        // A receipt, by its own subject, is for something paid.
        if status == nil, subject.range(of: #"(?i)\breceipt\b"#, options: .regularExpression) != nil {
            status = StatusRule(pattern: "", label: "Paid", isAlert: false)
        }

        var facts: [Glance.Fact] = []
        if let amount = firstFact(in: body, labels: paidLabels) ?? firstFact(in: body, labels: dueLabels)
            ?? firstFact(in: body, labels: totalLabels) ?? cardCharge(in: body) ?? proseAmount(in: body)
            // Last resort: a bare "Amount: Tk 1,250" (bKash, Nagad, bank
            // alerts), then "paid Tk 1,250", when nothing names it better.
            ?? firstFact(in: body, labels: "amount") ?? firstFact(in: body, labels: "paid") {
            facts.append(amount)
        }
        if let date = firstFact(in: body, labels: dateLabels, value: datePattern) { facts.append(date) }
        if let reference = firstFact(in: body, labels: referenceLabels, value: #"#?\s*((?=[A-Z0-9-]*\d)[A-Z0-9][A-Z0-9-]{3,})\b"#) {
            facts.append(reference)
        }
        // A status alone, or a single figure without one, isn't a card.
        guard facts.count >= (status == nil ? 2 : 1) else { return nil }
        return Glance(status: status?.label, isAlert: status?.isAlert ?? false, facts: Array(facts.prefix(3)))
    }

    /// "Amount paid $18.50", "Total: £14.62": the label as written, the
    /// value after it.
    private static func firstFact(in text: String, labels: String, value: String? = nil) -> Glance.Fact? {
        let pattern = #"(?i)(?<![\p{L}])("# + labels + #")\s*[:\-–—]?\s*"# + (value ?? "(" + amountPattern + ")")
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let labelRange = Range(match.range(at: 1), in: text),
              let valueRange = Range(match.range(at: 2), in: text) else { return nil }
        let label = text[labelRange].lowercased().trimmingCharacters(in: .whitespaces.union(.init(charactersIn: "#")))
        let value = String(text[valueRange]).trimmingCharacters(in: .whitespaces.union(.init(charactersIn: ",.")))
        return Glance.Fact(label: label.prefix(1).uppercased() + label.dropFirst(), value: value)
    }

    /// Lyft's "Apple Pay (Discover) $21.83": what the card was charged.
    private static func cardCharge(in text: String) -> Glance.Fact? {
        let pattern = #"(?i)\b(apple pay|google pay|paypal|visa|mastercard|amex|american express|discover)\b[^\n]{0,30}?\s("# + amountPattern + ")"
        guard let range = text.range(of: pattern, options: .regularExpression),
              let amount = text[range].range(of: amountPattern, options: .regularExpression) else { return nil }
        return Glance.Fact(label: "Charged", value: String(text[range][amount]))
    }

    /// "your recent payment of $9.99", "a charge of €40".
    private static func proseAmount(in text: String) -> Glance.Fact? {
        let pattern = #"(?i)\b(payment|charge|bill|balance|refund) of ("# + amountPattern + ")"
        guard let range = text.range(of: pattern, options: .regularExpression),
              let amount = text[range].range(of: amountPattern, options: .regularExpression) else { return nil }
        let noun = text[range].split(separator: " ").first.map { $0.lowercased() } ?? "amount"
        return Glance.Fact(label: noun == "refund" ? "Refund" : "Amount", value: String(text[range][amount]))
    }

    private struct StatusRule { let pattern: String; let label: String; let isAlert: Bool }

    /// Problems first: a failed payment's email also says "receipt".
    private static let statusRules: [StatusRule] = [
        .init(pattern: #"(?i)\b(payment|charge|card|transaction)\b[^\n.]{0,40}\b(failed|declined|unsuccessful|did ?n[o']t go through)\b|\b(unable|couldn'?t|could not|were not able) (to )?(process|charge|complete)\b[^\n.]{0,30}\b(payment|card|charge)|\bfailed payment\b|\bpayment failure\b"#,
              label: "Payment failed", isAlert: true),
        .init(pattern: #"(?i)\b(delivery|package|parcel|shipment)\b[^\n.]{0,30}\b(failed|delayed|exception|attempted)\b|\bunable to deliver\b|\bmissed (your )?delivery\b|\breturned to sender\b"#,
              label: "Delivery problem", isAlert: true),
        .init(pattern: #"(?i)\b(overdue|past due|late fee)\b"#, label: "Overdue", isAlert: true),
        .init(pattern: #"(?i)\b(was|been|has been|is) delivered\b|^delivered\b"#, label: "Delivered", isAlert: false),
        .init(pattern: #"(?i)\bout for delivery\b"#, label: "Out for delivery", isAlert: false),
        .init(pattern: #"(?i)\b(has|have|was|been) (shipped|dispatched|picked up)\b|\bon (its|the) way\b"#, label: "On its way", isAlert: false),
        .init(pattern: #"(?i)\brefund(ed| (has been |was )?(issued|processed))\b"#, label: "Refunded", isAlert: false),
        .init(pattern: #"(?i)\b(payment (request|reminder|due)|amount due|bill is ready|statement is ready|rent (is )?due)\b"#, label: "Payment due", isAlert: false),
        .init(pattern: #"(?i)\b(payment (received|confirmed|successful|processed)|successfully (processed|paid)|thank you for your payment|receipt from)\b"#, label: "Paid", isAlert: false),
        .init(pattern: #"(?i)\b(order (confirmed|received|placed)|we got your order|thanks? (you )?for your order)\b"#, label: "Order confirmed", isAlert: false),
    ]

    private static let paidLabels = #"amount paid|total paid|amount charged|total charged|you paid|charged|initial charge"#
    private static let dueLabels = #"amount due|total due|balance due|minimum (?:payment )?due|payment due|amount owed|balance"#
    private static let totalLabels = #"grand total|order total|trip total|total"#
    private static let dateLabels = #"due date|due on|due by|pay by|payment due(?: date)?|estimated delivery(?: date)?|expected delivery|delivery date|arriving(?: on| by)?|arrives(?: on| by)?|renews on|expires on"#
    private static let referenceLabels = #"order(?: number| no\.?| #| id)?|confirmation(?: number| code)?|booking(?: reference| number)?|reservation(?: number)?|invoice(?: number| no\.?| id)?|receipt(?: number| #)?|tracking(?: number| #)?|case(?: number| #)?"#
    /// "Thu, 15 Oct", "October 20, 2026", "20 October 2026", "10/20/2026".
    private static let datePattern = #"((?:(?:mon|tue|wed|thu|fri|sat|sun)[a-z]*\.?,?\s+)?(?:\d{1,2}(?:st|nd|rd|th)?\s+(?:jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?|(?:jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?\s+\d{1,2}(?:st|nd|rd|th)?)(?:,?\s+\d{4})?|\d{1,2}/\d{1,2}(?:/\d{2,4})?)"#
}
