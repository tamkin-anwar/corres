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
