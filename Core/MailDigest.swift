import Foundation

/// Everything Corres does to an email before and after its summarizer sees
/// it, kept here as plain text work so every rule is tested:
///
/// - the words actually worth reading (HTML turned to text, quoted history,
///   signatures, footers and tracking links removed),
/// - what kind of email it is, which shapes what a good summary says,
/// - the facts already in it (amounts, codes, order numbers, dates), handed
///   to the model to quote rather than paraphrase,
/// - a check that every number, date, name and code in a summary really is
///   in the email, so a wrong summary is never shown,
/// - a summary built only from the email's own sentences, for iPhones
///   without Apple Intelligence and as the fallback when a model summary
///   fails that check.
public enum MailDigest {

    /// Below this many words there's nothing a summary would add; the email
    /// already is one. About two short sentences.
    public static let minimumWords = 35

    public enum Kind: String, Codable, Sendable, CaseIterable {
        case personal, receipt, shipping, code, invite, newsletter, notification

        /// What a good summary of this kind of email leads with.
        public var guidance: String {
            switch self {
            case .personal: "Name the sender and lead with what they ask you to do, answer or decide, and by when (\"Sofia asks you to…\"). If nothing is asked, say what they told you."
            case .receipt: "Say what was bought or charged, by whom, the exact amount and the date. For a bill or statement, give the amount and due date, and say if it's paid automatically."
            case .shipping: "Say what is shipping, its status and the expected delivery date, as news, not as a task."
            case .code: "Give the code exactly, what it is for, and when it expires if the email says so, as a statement (\"Your … code is …\")."
            case .invite: "Say what the event is, when and where, and whether a reply or RSVP is needed."
            case .newsletter: "Give the one or two most important points or offers, with any dates or prices exactly as written."
            case .notification: "Say what happened, with any amount or date, and whether anything is needed from you, and by when."
            }
        }
    }

    // MARK: - Readable text

    /// The text a person would actually read: the plain-text part when it's
    /// real, otherwise the HTML turned into text. Many emails (newsletters,
    /// receipts) carry only HTML, and Gmail's snippet stands in for their
    /// plain text, so the richer of the two wins.
    public static func readableText(body: String, html: String?) -> String {
        let plain = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let html, !html.isEmpty else { return plain }
        if wordCount(plain) >= 60 { return plain }
        let converted = text(fromHTML: html)
        return wordCount(converted) > wordCount(plain) ? converted : plain
    }

    /// HTML to readable text: no head, styles, scripts, comments or hidden
    /// preheaders; block elements become line breaks; entities decoded.
    public static func text(fromHTML html: String) -> String {
        var text = html
        let removals = [
            #"(?is)<head\b.*?</head>"#, #"(?is)<style\b.*?</style>"#, #"(?is)<script\b.*?</script>"#,
            #"(?s)<!--.*?-->"#,
            // Hidden preheaders repeat the opening or pad it with filler.
            #"(?is)<(span|div)\b[^>]*display\s*:\s*none[^>]*>.*?</\1>"#,
        ]
        for pattern in removals { text = text.replacingOccurrences(of: pattern, with: " ", options: .regularExpression) }
        text = text.replacingOccurrences(of: #"(?i)<br\s*/?>"#, with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?i)</(p|div|tr|li|h[1-6]|table|blockquote|section|article)>"#, with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?i)<li\b[^>]*>"#, with: "\n• ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?i)</t[dh]>"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        return tidy(text.decodingHTMLEntities)
    }

    /// The writer's new words only: quoted history, forwarded headers,
    /// signatures, sent-from lines, unsubscribe/legal footers and raw links
    /// removed. What's left is what a summary should be about.
    public static func clean(_ text: String) -> String {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var kept: [String] = []
        var index = 0
        while index < lines.count {
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            if line.hasPrefix(">") { index += 1; continue }
            if startsQuotedHistory(lines, at: index) { break }
            if line == "--" || line == "-- " || line == "—" { break }
            if line.range(of: cutFromPattern, options: .regularExpression) != nil { break }
            if line.range(of: dropLinePattern, options: .regularExpression) != nil { index += 1; continue }
            kept.append(lines[index])
            index += 1
        }
        var result = kept.joined(separator: "\n")
        // Links carry no meaning for a summary; "(https://…)" and "<https://…>"
        // wrappers go with them.
        result = result.replacingOccurrences(of: #"[(<\[]\s*https?://[^\s)>\]]+\s*[)>\]]"#, with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: #"https?://\S+"#, with: "", options: .regularExpression)
        return tidy(result)
    }

    /// "On Mon, Sep 28 … wrote:" (often wrapped over two or three lines by
    /// Gmail), Outlook's "From: / Sent:" block, its underscore rule, and
    /// forwarded or original-message markers.
    private static func startsQuotedHistory(_ lines: [String], at index: Int) -> Bool {
        let line = lines[index].trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("-----Original Message") || line.hasPrefix("---------- Forwarded message")
            || line.hasPrefix("Begin forwarded message") || line.range(of: #"^_{10,}$"#, options: .regularExpression) != nil {
            return true
        }
        if line.range(of: #"^On .{4,}"#, options: .regularExpression) != nil {
            let window = lines[index..<min(lines.count, index + 3)].joined(separator: " ")
            if window.range(of: #"^\s*On .{4,}?\bwrote:"#, options: .regularExpression) != nil { return true }
        }
        if line.range(of: #"^\*?From:\*?\s"#, options: .regularExpression) != nil {
            let next = lines[(index + 1)..<min(lines.count, index + 4)].joined(separator: "\n")
            if next.range(of: #"(?m)^\s*\*?(Sent|Date|To|Subject):"#, options: .regularExpression) != nil { return true }
        }
        return false
    }

    /// Lines that end what's worth reading: legal disclaimers sit at the bottom.
    private static let cutFromPattern = #"(?i)^(confidentiality notice|this (e-?mail|message)( and any attachments)? (is|are|may be) (confidential|intended)|disclaimer:)"#

    /// Single lines that are never content.
    private static let dropLinePattern = #"(?i)^(sent from my (iphone|ipad|android|galaxy|mobile)|sent from (mail|outlook) for|get outlook for|sent via |sent with )|unsubscribe|manage (your )?(email |notification |subscription )?preferences|update (your )?preferences|view (this|it|the) (email |message )?in (your |a |the )?browser|view (this email )?online|you('re| are) receiving this|you received this (email|message)|this (email|message) was sent (to|by)|no longer wish to receive|©|\bcopyright\b|all rights reserved|^privacy policy|^terms (of (service|use)|& conditions)|please do not reply|do not reply to this|^add us to your address book"#

    /// Trimmed lines, single spaces, at most one blank line in a row, and
    /// no invisible characters (marketers pad preheaders with them).
    private static func tidy(_ text: String) -> String {
        let invisible = CharacterSet(charactersIn: "\u{200B}\u{200C}\u{200D}\u{2060}\u{FEFF}\u{034F}\u{00AD}\u{180E}")
        let scalars = text.unicodeScalars.filter { !invisible.contains($0) }
        var cleaned = String(String.UnicodeScalarView(scalars))
        cleaned = cleaned.replacingOccurrences(of: "\u{00A0}", with: " ")
        cleaned = cleaned.replacingOccurrences(of: #"[ \t]+"#, with: " ", options: .regularExpression)
        let lines = cleaned.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        var result: [String] = []
        for line in lines where !(line.isEmpty && (result.last?.isEmpty ?? true)) { result.append(line) }
        return result.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).filter { $0.contains(where: \.isLetter) || $0.contains(where: \.isNumber) }.count
    }

    /// Whether a summary would say something the email's opening doesn't.
    public static func isWorthSummarizing(_ cleanedText: String) -> Bool {
        wordCount(cleanedText) >= minimumWords
    }

    // MARK: - Kind

    public static func kind(subject: String, text: String, senderEmail: String?, isBulk: Bool,
                            looksAutomated: Bool, hasEvent: Bool) -> Kind {
        let haystack = subject + "\n" + text.prefix(3_000)
        if verificationCode(in: haystack) != nil { return .code }
        if haystack.range(of: #"(?i)\b(has shipped|have shipped|out for delivery|was delivered|been delivered|tracking (number|#)|on (its|the) way|estimated delivery|arriving (today|tomorrow|on))\b"#, options: .regularExpression) != nil {
            return .shipping
        }
        if haystack.range(of: #"(?i)\b(receipt|order (confirmation|confirmed|number|#)|your order|invoice|payment (received|confirmation|confirmed|of)|you paid|amount (paid|charged|due)|total charged|renewal|has been charged|billing statement)\b"#, options: .regularExpression) != nil {
            return .receipt
        }
        if hasEvent || subject.range(of: #"(?i)^(invitation|updated invitation|accepted|declined):"#, options: .regularExpression) != nil {
            return .invite
        }
        if !isBulk && !looksAutomated { return .personal }
        return isBulk && wordCount(text) > 120 ? .newsletter : .notification
    }

    // MARK: - Facts

    /// A one-time code: 4 to 8 digits (or a short letter/digit mix) close
    /// to words that say it's a code.
    public static func verificationCode(in text: String) -> String? {
        let pattern = #"(?i)\b(verification|security|login|log-in|sign[- ]?in|one[- ]time|2fa|two-factor|access|authentication|otp)\s+(code|pin|passcode)\b|\byour (code|passcode|pin) is\b|\bcode:\s"#
        guard let cue = text.range(of: pattern, options: .regularExpression) else { return nil }
        let window = text[cue.lowerBound..<(text.index(cue.upperBound, offsetBy: 120, limitedBy: text.endIndex) ?? text.endIndex)]
        guard let match = window.range(of: #"\b(?=[A-Z0-9-]*\d)[A-Z0-9]{3,4}-?[A-Z0-9]{2,4}\b|\b\d{4,8}\b"#, options: .regularExpression) else { return nil }
        return String(window[match])
    }

    /// Facts already in the email, exactly as written, for the model to
    /// quote rather than retype: amounts, codes, order/booking numbers and
    /// dates. At most eight, in the order they appear.
    public static func facts(in text: String) -> [String] {
        let source = String(text.prefix(8_000))
        var found: [(Int, String)] = []
        func add(_ range: Range<String.Index>) {
            let value = String(source[range]).trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters.subtracting(.init(charactersIn: "$€£#"))))
            guard !value.isEmpty, !found.contains(where: { $0.1 == value }) else { return }
            found.append((source.distance(from: source.startIndex, to: range.lowerBound), value))
        }
        for range in source.regexRanges(of: #"[$€£¥]\s?\d[\d,]*(\.\d{1,2})?|\b\d[\d,]*(\.\d{2})?\s?(USD|EUR|GBP|CAD|AUD)\b"#) { add(range) }
        for range in source.regexRanges(of: #"(?i:\b(order|confirmation|booking|reservation|invoice|ticket|case|tracking)\s*(number|no\.?|#|id|code)?\s*(is)?\s*:?\s*#?)(?=[A-Z0-9-]*\d)[A-Z0-9][A-Z0-9-]{3,}\b"#) { add(range) }
        if let code = verificationCode(in: source), let range = source.range(of: code) { add(range) }
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) {
            let ns = source as NSString
            for match in detector.matches(in: source, range: NSRange(location: 0, length: ns.length)).prefix(6) {
                if let range = Range(match.range, in: source) { add(range) }
            }
        }
        return found.sorted { $0.0 < $1.0 }.prefix(8).map(\.1)
    }

    // MARK: - Faithfulness

    /// Every number, month, weekday, relative day, proper name, address and
    /// code a summary mentions must be in the email itself. Returns what
    /// isn't, empty when the summary is faithful.
    public static func unsupportedClaims(in summary: String, source: String) -> [String] {
        let lowerSource = source.lowercased()
        let sourceDigits = lowerSource.replacingOccurrences(of: ",", with: "")
        var unsupported: [String] = []

        // Numbers match whole, never inside a longer one: "28" isn't
        // supported by "$1,284.63".
        let sourceNumbers = Set(numberTokens(in: sourceDigits))
        for token in numberTokens(in: summary.replacingOccurrences(of: ",", with: "")) where !sourceNumbers.contains(token) {
            // "3:00" is supported by a bare "3" ("3pm").
            if token.hasSuffix(":00"), sourceNumbers.contains(String(token.dropLast(3))) { continue }
            unsupported.append(token)
        }
        let words = summary.split(whereSeparator: { !$0.isLetter && $0 != "'" && $0 != "’" })
        for word in words {
            let lower = word.lowercased()
            if let stem = calendarStems[lower], !lowerSource.contains(stem) { unsupported.append(String(word)) }
            if relativeDays.contains(lower), !containsWord(lower, in: lowerSource) { unsupported.append(String(word)) }
        }
        // Names: capitalized words not starting a sentence.
        let sentences = summary.split(whereSeparator: { ".!?;:\n".contains($0) })
        for sentence in sentences {
            let tokens = sentence.split(separator: " ").map { $0.trimmingCharacters(in: .punctuationCharacters) }
            for token in tokens.dropFirst() where token.count >= 3 {
                guard let first = token.first, first.isUppercase else { continue }
                let lower = token.lowercased()
                if commonCapitalized.contains(lower) || calendarStems[lower] != nil { continue }
                if !lowerSource.contains(lower) { unsupported.append(token) }
            }
        }
        for match in summary.regexRanges(of: #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#) {
            let email = summary[match].lowercased()
            if !lowerSource.contains(email) { unsupported.append(email) }
        }
        var seen = Set<String>()
        return unsupported.filter { seen.insert($0.lowercased()).inserted }
    }

    /// Drops a relative day the email never used ("…across prototypes
    /// today."), the one slip worth repairing rather than discarding the
    /// whole summary. Nil when anything else is unsupported.
    public static func repairingRelativeDays(_ summary: String, source: String) -> String? {
        let unsupported = unsupportedClaims(in: summary, source: source)
        guard !unsupported.isEmpty,
              unsupported.allSatisfy({ relativeDays.contains($0.lowercased()) }) else { return nil }
        var repaired = summary
        for word in unsupported {
            let pattern = #"(?i)\s*\b(for |from |as of |until |by )?(\#(NSRegularExpression.escapedPattern(for: word)))\b"#
            repaired = repaired.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        repaired = repaired.replacingOccurrences(of: #"\s+([.,;!?])"#, with: "$1", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return isFaithful(repaired, source: source) && wordCount(repaired) >= 4 ? repaired : nil
    }

    /// The reader named in their own summary ("pending Tamkin's approval")
    /// reads as "your approval"; nil if the name is still there after that,
    /// since "Ship to: Tamkin" has no second-person form worth showing.
    public static func addressingReader(_ text: String, names: [String]) -> String? {
        var result = text
        for name in names where name.count >= 3 {
            let escaped = NSRegularExpression.escapedPattern(for: name)
            result = result.replacingOccurrences(of: #"\b"# + escaped + #"(’s|'s)\b"#, with: "your", options: .regularExpression)
            if result.range(of: #"\b"# + escaped + #"\b"#, options: [.regularExpression, .caseInsensitive]) != nil { return nil }
        }
        return result
    }

    /// Whether a summary slipped into the sender's voice ("I'd meet at…",
    /// "we'll ship…"); a summary talks to the reader about the email.
    public static func speaksAsSender(_ summary: String) -> Bool {
        summary.range(of: #"(^|[\s(“"])(I|I'd|I'll|I'm|I've|I’d|I’ll|I’m|I’ve)\b"#, options: .regularExpression) != nil
            || summary.range(of: #"(?i)\b(we|we'd|we'll|we're|we've|we’d|we’ll|we’re|we’ve|our|ours)\b"#, options: .regularExpression) != nil
    }

    /// A key point worth a line of its own: a phrase that stands alone
    /// ("Minimum payment $40.00 due Oct 22"), not a bare fragment ("$40.00",
    /// "10 PM") or a restatement of the summary.
    public static func isUsefulPoint(_ point: String, summary: String) -> Bool {
        let filler: Set<String> = ["the", "and", "for", "with", "from", "until", "starting", "due", "by", "on", "at", "of",
                                   "to", "in", "is", "are", "was", "be", "you", "your", "this", "that"]
        func content(_ text: String) -> [String] {
            text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map(String.init).filter { !filler.contains($0) && calendarStems[$0] == nil }
        }
        let words = content(point)
        let letterWords = words.filter { $0.count >= 3 && $0.allSatisfy(\.isLetter) }.count
        let hasFigure = point.contains(where: \.isNumber)
        // A real word with a figure ("Tax $0.87 on Sep 27"), else three.
        guard letterWords >= (hasFigure ? 1 : 3) else { return false }
        // A cut-off fragment from the model's notes ("Window. The team…").
        if point.range(of: #"^\p{L}+\.\s"#, options: .regularExpression) != nil { return false }
        // A bare link or domain says nothing on its own.
        if point.range(of: #"^\S+\.[a-z]{2,}(/\S*)?$"#, options: [.regularExpression, .caseInsensitive]) != nil { return false }
        let summaryWords = Set(content(summary))
        let overlap = words.filter(summaryWords.contains).count
        return Double(overlap) / Double(words.count) < 0.75
    }

    /// Whole numbers as written: "1284.63", "2026", "3:30", "10". Commas
    /// must already be removed.
    private static func numberTokens(in text: String) -> [String] {
        text.regexRanges(of: #"(?<![\d.])\d+(?:[.:]\d+)*"#).map { String(text[$0]) }
    }

    public static func isFaithful(_ summary: String, source: String) -> Bool {
        unsupportedClaims(in: summary, source: source).isEmpty
    }

    private static func containsWord(_ word: String, in text: String) -> Bool {
        text.range(of: #"\b"# + NSRegularExpression.escapedPattern(for: word) + #"\b"#, options: .regularExpression) != nil
    }

    private static let calendarStems: [String: String] = [
        "jan": "jan", "january": "jan", "feb": "feb", "february": "feb", "march": "mar",
        "apr": "apr", "april": "apr", "june": "jun", "july": "jul", "aug": "aug", "august": "aug",
        "sep": "sep", "sept": "sep", "september": "sep", "oct": "oct", "october": "oct",
        "nov": "nov", "november": "nov", "dec": "dec", "december": "dec",
        "monday": "mon", "tuesday": "tue", "wednesday": "wed", "thursday": "thu",
        "friday": "fri", "saturday": "sat", "sunday": "sun",
    ]

    /// Relative to when it's read, not when it was written, so a summary
    /// may only say "tomorrow" if the email itself does.
    private static let relativeDays: Set<String> = ["today", "tonight", "tomorrow", "yesterday", "weekend"]

    /// Capitalized words a summary legitimately uses mid-sentence that
    /// aren't names from the email.
    private static let commonCapitalized: Set<String> = [
        "you", "your", "you're", "you’re", "yours", "nothing", "the", "and", "for", "but", "not", "its", "it's", "this",
        "that", "there", "they", "their", "she", "her", "him", "his", "who", "what", "when", "where", "how", "why",
        "also", "rsvp", "asap", "pdf", "faq", "usa", "url", "pst", "pdt", "est", "edt", "cst", "cdt", "mst", "mdt",
        "utc", "gmt", "a.m", "p.m", "am", "pm", "okay", "yes", "no", "email", "note", "reply", "re", "fwd",
    ]

    // MARK: - Summary from the email's own sentences

    /// One or two sentences taken word for word from the email: the one that
    /// asks something or names a deadline, amount or code first, else the
    /// first real sentence after the greeting. Never adds a word the email
    /// doesn't have, so it can't be wrong, only less concise.
    public static func extractiveSummary(text: String, kind: Kind) -> String? {
        let sentences = self.sentences(in: text)
        guard !sentences.isEmpty else { return nil }
        if kind == .code, let code = verificationCode(in: text),
           let sentence = sentences.first(where: { $0.contains(code) }) {
            return clipped(sentence)
        }
        let scored = sentences.enumerated().map { index, sentence -> (Int, Double, String) in
            var score = max(0, 3.0 - Double(index) * 0.4)
            if MailSignals.asksSomething(sentence) { score += 4 }
            if sentence.range(of: #"[$€£]\s?\d|\b\d{1,2}(:\d{2})?\s?(am|pm)\b|\b(due|by|before|deadline|expires?)\b"#, options: [.regularExpression, .caseInsensitive]) != nil { score += 2 }
            let words = wordCount(sentence)
            if words < 6 { score -= 2 }
            if words > 45 { score -= 1.5 }
            return (index, score, sentence)
        }
        guard let best = scored.max(by: { $0.1 < $1.1 }), best.1 > 0 else { return nil }
        var chosen = [best]
        if wordCount(best.2) < 14, let next = scored.first(where: { $0.0 == best.0 + 1 }), wordCount(next.2) >= 5 {
            chosen.append(next)
        }
        return clipped(chosen.sorted { $0.0 < $1.0 }.map(\.2).joined(separator: " "))
    }

    /// Real sentences: greetings, pleasantries, sign-offs, bare link labels
    /// and fragments dropped.
    static func sentences(in text: String) -> [String] {
        let pieces = text.split(separator: "\n").flatMap { line -> [String] in
            let line = String(line)
            var result: [String] = []
            var current = ""
            for (index, character) in zip(line.indices, line) {
                current.append(character)
                let next = line.index(after: index)
                if ".!?".contains(character), next == line.endIndex || line[next] == " " {
                    result.append(current); current = ""
                }
            }
            if !current.isEmpty { result.append(current) }
            return result
        }
        return pieces.map { $0.trimmingCharacters(in: .whitespaces) }.filter { sentence in
            guard wordCount(sentence) >= 4 else { return false }
            return sentence.range(of: skipSentencePattern, options: .regularExpression) == nil
        }
    }

    private static let skipSentencePattern = #"(?i)^(hi|hello|hey|dear|good (morning|afternoon|evening)|greetings)\b[^.!?]{0,40}[,!:]?$|^(i )?hope (you|this|all|that|everything)|^i trust (you|this)|^(thanks|thank you)( so much)?( for (reaching out|your (email|message|note)|getting back))?[.!]?$|^(best|kind|warm)? ?regards|^(sincerely|cheers|best wishes|all the best)\b|^i wanted to (reach out|follow up|touch base)[.!]?$|^(view|shop|click|tap|learn more|read more|see (more|details))\b[^.]{0,30}$"#

    private static func clipped(_ text: String, maxWords: Int = 40) -> String {
        let words = text.split(separator: " ")
        guard words.count > maxWords else { return text }
        return words.prefix(maxWords).joined(separator: " ") + "…"
    }

    // MARK: - Conversations and long emails

    public struct Message: Sendable, Equatable {
        public let sender: String
        public let isFromReader: Bool
        public let date: Date
        public let text: String
        public init(sender: String, isFromReader: Bool, date: Date, text: String) {
            self.sender = sender; self.isFromReader = isFromReader; self.date = date; self.text = text
        }
    }

    /// A conversation as the model reads it, oldest first, within
    /// `budget` characters. The latest message keeps most of its text; the
    /// earlier ones share the rest, and a long thread keeps its first and
    /// most recent messages with the middle marked as omitted.
    public static func transcript(_ messages: [Message], budget: Int) -> (text: String, wasShortened: Bool) {
        guard let latest = messages.last else { return ("", false) }
        let dateStyle = Date.FormatStyle(date: .abbreviated, time: .shortened)
        func header(_ message: Message) -> String {
            (message.isFromReader ? "You" : message.sender) + " · " + message.date.formatted(dateStyle)
        }
        var earlier = Array(messages.dropLast())
        var omitted = 0
        if earlier.count > 7 {
            omitted = earlier.count - 6
            earlier = Array(earlier.prefix(2)) + Array(earlier.suffix(4))
        }
        let latestShare = earlier.isEmpty ? budget : Int(Double(budget) * 0.5)
        let (latestText, latestShortened) = shortened(latest.text, to: latestShare)
        let perEarlier = earlier.isEmpty ? 0 : max(160, (budget - latestText.count) / earlier.count)
        var parts: [String] = []
        var shortenedAny = latestShortened || omitted > 0
        for (index, message) in earlier.enumerated() {
            if omitted > 0 && index == 2 { parts.append("[\(omitted) earlier messages omitted]") }
            let (text, cut) = shortened(message.text, to: perEarlier)
            shortenedAny = shortenedAny || cut
            parts.append("[\(header(message))]\n\(text)")
        }
        parts.append("[\(header(latest)) — latest]\n\(latestText)")
        return (parts.joined(separator: "\n\n"), shortenedAny)
    }

    /// The opening and the closing (where asks and deadlines almost always
    /// are), joined by a marker, when `text` is over `limit`.
    public static func shortened(_ text: String, to limit: Int) -> (text: String, wasShortened: Bool) {
        guard text.count > limit, limit > 200 else { return (String(text.prefix(max(limit, 0))), text.count > limit) }
        let tail = limit / 3
        return (text.prefix(limit - tail - 40) + "\n[… middle omitted …]\n" + text.suffix(tail), true)
    }

    /// A long email split at paragraph breaks into pieces of about `size`
    /// characters, for reading section by section.
    public static func sections(of text: String, size: Int) -> [String] {
        guard text.count > size else { return [text] }
        var sections: [String] = []
        var current = ""
        for paragraph in text.components(separatedBy: "\n\n") {
            if current.count + paragraph.count > size, !current.isEmpty {
                sections.append(current); current = ""
            }
            if paragraph.count > size {
                var rest = Substring(paragraph)
                while rest.count > size { sections.append(String(rest.prefix(size))); rest = rest.dropFirst(size) }
                current = String(rest)
            } else {
                current += (current.isEmpty ? "" : "\n\n") + paragraph
            }
        }
        if !current.isEmpty { sections.append(current) }
        return sections
    }
}

private extension String {
    func regexRanges(of pattern: String) -> [Range<String.Index>] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: self, range: NSRange(startIndex..., in: self)).compactMap { Range($0.range, in: self) }
    }
}
