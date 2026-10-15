import Foundation
import NaturalLanguage

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
    /// Shorter than this, an email reads in about the time its summary
    /// would: Mail and Gmail summarize only longer mail. At 35 words a
    /// short reminder got a summary that repeated it, right above it.
    public static let minimumWords = 100
    /// A conversation is worth summarizing sooner: the summary saves
    /// opening and piecing together several messages.
    public static let minimumConversationWords = 80

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
            case .newsletter: "Say what it covers, like headlines (\"TSMC's September sales; Amazon's 1,000th satellite\"), or its main offer and when it ends. It's written to many people: never say you got, paid, were charged or were sent anything."
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
        // Some senders' plain part only says to read the HTML one ("your
        // email client might not support HTML", Epic Games).
        let isPlaceholder = plain.range(of: #"(?i)(not support|unable to (display|view)|can'?t (display|see)|view (it|this( email)?) (online|in (a|your) browser)|html (formatted )?(e-?mail|version))"#,
                                        options: .regularExpression) != nil && wordCount(plain) < 400
        if wordCount(plain) >= 60 && !isPlaceholder { return plain }
        let converted = text(fromHTML: html)
        if isPlaceholder, !converted.isEmpty { return converted }
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
            // …or hide it other ways: collapsed to nothing, or Outlook-only hiding.
            #"(?is)<(span|div)\b[^>]*(max-height\s*:\s*0(px)?\s*[;"']|mso-hide\s*:\s*all|visibility\s*:\s*hidden)[^>]*>.*?</\1>"#,
        ]
        for pattern in removals { text = text.replacingOccurrences(of: pattern, with: " ", options: .regularExpression) }
        text = text.replacingOccurrences(of: #"(?i)<br\s*/?>"#, with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?i)</(p|div|tr|li|h[1-6]|table|blockquote|section|article)>"#, with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?i)<li\b[^>]*>"#, with: "\n• ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?i)</t[dh]>"#, with: " ", options: .regularExpression)
        // A quoted attribute can hold a ">" (an image's alt text with "<br>"
        // in it); a plain <[^>]+> stopped there and left CSS in the text.
        text = text.replacingOccurrences(of: #"<(?:[^>"']|"[^"]*"|'[^']*')*>"#, with: " ", options: .regularExpression)
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
            if line.range(of: cutFromPattern, options: .regularExpression) != nil
                || line.range(of: MailSignals.legalNoticePattern, options: .regularExpression) != nil { break }
            if line.range(of: MailSignals.protectiveMarkingLine, options: .regularExpression) != nil { index += 1; continue }
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

    public static func isWorthSummarizing(_ cleanedText: String) -> Bool {
        wordCount(cleanedText) >= minimumWords
    }

    /// Whether a summary only says what the email's opening already says,
    /// so it would repeat the first lines shown right below it. Judged by
    /// meaning words (word roots, so "booking" matches "book"), against the
    /// opening of the email.
    public static func restatesOpening(_ summary: String, of text: String, openingWords: Int = 70) -> Bool {
        let opening = text.split(whereSeparator: \.isWhitespace).prefix(openingWords).joined(separator: " ")
        let openingRoots = roots(in: opening)
        let words = contentWords(in: summary)
        guard words.count >= 3 else { return true }
        let covered = words.filter { $0.keys.contains(where: openingRoots.contains) }.count
        return Double(covered) / Double(words.count) >= 0.8
    }

    // MARK: - Kind

    /// `labelIds` are Gmail's: its Promotions tab is marketing, and its
    /// Updates tab is where receipts, bills and account notices land.
    public static func kind(subject: String, text: String, senderEmail: String?, isBulk: Bool,
                            looksAutomated: Bool, hasEvent: Bool, labelIds: [String] = []) -> Kind {
        let haystack = subject + "\n" + text.prefix(3_000)
        // A code email is short and says so up top; a newsletter with
        // "code:" somewhere in a story is not one.
        let words = text.split(whereSeparator: \.isWhitespace).count
        if words <= 300, verificationCode(in: subject + "\n" + text.prefix(400)) != nil { return .code }
        if labelIds.contains("CATEGORY_PROMOTIONS") { return .newsletter }
        // The subject says what an email is; its body only does near the
        // top of a short one. A newsletter's article about deliveries or
        // "your order" isn't a receipt (Morning Brew, TLDR, LinkedIn were).
        let opening = subject + "\n" + (wordCount(text) <= 300 ? String(text.prefix(400)) : "")
        if opening.range(of: shippingCue, options: .regularExpression) != nil { return .shipping }
        if opening.range(of: receiptCue, options: .regularExpression) != nil { return .receipt }
        if hasEvent || subject.range(of: #"(?i)^(invitation|updated invitation|accepted|declined):"#, options: .regularExpression) != nil {
            return .invite
        }
        if !isBulk && !looksAutomated { return .personal }
        // Updates are notices unless they read like an issue of something.
        // In real mail, notices and receipts run under ~450 words; Morning
        // Brew, TLDR and LinkedIn's newsletters run 850 to 3,300.
        if labelIds.contains("CATEGORY_UPDATES") { return wordCount(text) > 600 ? .newsletter : .notification }
        return isBulk && wordCount(text) > 120 ? .newsletter : .notification
    }

    private static let shippingCue = #"(?i)\b(has shipped|have shipped|out for delivery|was delivered|been delivered|tracking (number|#)|on (its|the) way|estimated delivery|arriving (today|tomorrow|on)|picked up)\b"#
    private static let receiptCue = #"(?i)\b(receipt|order (confirmation|confirmed|number|#|summary)|your order|invoice|payment (received|confirmation|confirmed|of|failed|declined|request|reminder)|payment (has|was) (failed|declined)|you paid|amount (paid|charged|due)|total charged|has been charged|billing statement|transaction|your (ride|trip) (with|to|on)|rent payment|statement is (ready|available)|bill is ready)\b"#

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
    /// An amount of money in any currency, written any way: a currency
    /// symbol (Unicode's whole currency category: $ € £ ¥ ৳ ₹ ₦ ₱ ₩ …) or
    /// ISO code (every one iOS knows, plus "Tk" and "Rs"), before or after
    /// a number in any grouping style.
    static let amountPattern: String = {
        let codes = (Locale.Currency.isoCurrencies.map(\.identifier) + ["Tk", "Rs", "Tsh", "Ksh"]).joined(separator: "|")
        let number = #"\d(?:[\d.,'\u00A0\u202F]*\d)?"#
        return #"\p{Sc}\s?"# + number + #"|\b(?:"# + codes + #")\.?\s?"# + number
            + #"|"# + number + #"\s?(?:\p{Sc}|\b(?:"# + codes + #")\b)"#
    }()

    public static func facts(in text: String) -> [String] {
        let source = String(text.prefix(8_000))
        var found: [(Int, String)] = []
        func add(_ range: Range<String.Index>) {
            let value = String(source[range]).trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters.subtracting(.init(charactersIn: "#"))))
            guard !value.isEmpty, !found.contains(where: { $0.1 == value }) else { return }
            found.append((source.distance(from: source.startIndex, to: range.lowerBound), value))
        }
        for range in source.regexRanges(of: amountPattern) { add(range) }
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
    /// Whether what you wrote says something is attached ("see attached",
    /// "I've attached", "PFA"), so Send can ask before it goes without one,
    /// as Gmail and Outlook do. Only your own words count: the quoted
    /// email you're replying to often mentions its own attachments.
    public static func mentionsAttachment(_ body: String) -> Bool {
        var own = body
        if let quote = own.range(of: #"\n\s*On .{4,200}wrote:\s*\n"#, options: .regularExpression) {
            own = String(own[..<quote.lowerBound])
        }
        own = own.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix(">") }
            .joined(separator: "\n")
        return own.range(of: #"(?i)\b(attached|attaching|attachments?|enclosed|pfa|please find (the )?(attached|enclosed))\b"#,
                         options: .regularExpression) != nil
            && own.range(of: #"(?i)\b(no|without( an?)?|forgot (the|to)) attach"#, options: .regularExpression) == nil
    }

    /// An alert confirming something you just did ("You allowed Corres
    /// access", "New sign-in on iPhone") whose only ask is conditional: act
    /// if it wasn't you. Worth seeing, never a to-do on its own; an
    /// on-device model once promoted one as "unauthorized access claim
    /// requires verification".
    public static func isConfirmationAlert(_ text: String) -> Bool {
        text.range(of: #"(?i)\b(if (you|this) (didn\S{0,5}t|did not|wasn\S{0,5}t|was not|don\S{0,5}t recogni[sz]e)|if this was you|wasn\S{0,5}t you\?)"#,
                   options: .regularExpression) != nil
    }

    public static func unsupportedClaims(in summary: String, source: String) -> [String] {
        let lowerSource = source.lowercased()
        var unsupported: [String] = []

        // Numbers match whole, never inside a longer one: "28" isn't
        // supported by "$1,284.63". Compared as values, in any locale:
        // "1,250.00", "1.250,00", "1,25,000"-style grouping and Bengali or
        // Arabic digits all read the same (`canonicalNumber`).
        let sourceNumbers = Set(numberTokens(in: lowerSource))
        for token in numberTokens(in: summary) where !sourceNumbers.contains(token) {
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
                // "Ultra's" is supported by "Ultra".
                var lower = token.lowercased()
                for suffix in ["'s", "’s"] where lower.hasSuffix(suffix) { lower = String(lower.dropLast(2)) }
                if commonCapitalized.contains(lower) || calendarStems[lower] != nil { continue }
                if !lowerSource.contains(lower) { unsupported.append(token) }
            }
        }
        for match in summary.regexRanges(of: #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#) {
            let email = summary[match].lowercased()
            if !lowerSource.contains(email) { unsupported.append(email) }
        }
        // Whole statements the email never makes ("Address change
        // approved" for an email of photos and captions).
        unsupported += ungroundedClaims(in: summary, source: source)
        var seen = Set<String>()
        return unsupported.filter { seen.insert($0.lowercased()).inserted }
    }

    /// Claims (sentences or clauses) whose meaningful words mostly don't
    /// appear in the email, in any form. The checks above catch a wrong
    /// number, date or name; this catches a statement made up whole. Word
    /// overlap is a weak judge of subtle edits inside a long summary, so it
    /// is applied claim by claim, matching word roots ("approval" is
    /// supported by "approve"), and leaves room for the words a summary
    /// adds to describe an email ("asks", "reminds", "wants").
    public static func ungroundedClaims(in summary: String, source: String) -> [String] {
        let sourceRoots = roots(in: source)
        return claims(in: summary).filter { claim in
            let words = contentWords(in: claim)
            guard words.count >= minimumClaimWords else { return false }
            let supported = words.filter { word in word.keys.contains(where: sourceRoots.contains) }.count
            return Double(supported) / Double(words.count) < minimumClaimSupport
        }
    }

    /// Below this share of supported words a claim counts as made up.
    /// Calibrated on faithful paraphrases and fabrications (see
    /// MailDigestTests): faithful summaries of real mail score 0.6 and up.
    static let minimumClaimSupport = 0.5
    /// One- and two-word claims ("Thanks, Maya.") are too short to judge.
    static let minimumClaimWords = 2

    private static func claims(in text: String) -> [String] {
        text.components(separatedBy: CharacterSet(charactersIn: ".!?;\n•"))
            .flatMap { $0.components(separatedBy: " — ") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// A word as the ways it can match: its lemma, its lowercase form, and
    /// a six-letter root for longer words, so "approval" meets "approve"
    /// and "confirmation" meets "confirm".
    private struct ContentWord { let keys: [String] }

    private static func keys(for word: String, lemma: String?) -> [String] {
        var keys = [word]
        if let lemma, lemma != word { keys.append(lemma) }
        for form in keys where form.count >= 7 { keys.append(String(form.prefix(6))) }
        return keys
    }

    private static func roots(in text: String) -> Set<String> {
        var roots = Set<String>()
        tagWords(in: text) { word, lemma, _ in roots.formUnion(keys(for: word, lemma: lemma)) }
        return roots
    }

    private static func contentWords(in claim: String) -> [ContentWord] {
        var words: [ContentWord] = []
        tagWords(in: claim) { word, lemma, tag in
            guard [.noun, .verb, .adjective].contains(tag), word.count >= 3,
                  !word.contains(where: \.isNumber),
                  !describingWords.contains(word), !describingWords.contains(lemma ?? word),
                  // Days and dates have their own check above.
                  !relativeDays.contains(word), calendarStems[word] == nil else { return }
            words.append(ContentWord(keys: keys(for: word, lemma: lemma)))
        }
        return words
    }

    private static func tagWords(in text: String, _ body: (String, String?, NLTag?) -> Void) {
        let tagger = NLTagger(tagSchemes: [.lexicalClass, .lemma])
        tagger.string = text
        let options: NLTagger.Options = [.omitPunctuation, .omitWhitespace, .omitOther]
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .lexicalClass, options: options) { tag, range in
            let word = text[range].lowercased().replacingOccurrences(of: "’", with: "'")
            let lemma = tagger.tag(at: range.lowerBound, unit: .word, scheme: .lemma).0?.rawValue.lowercased()
            body(word, lemma, tag)
            return true
        }
    }

    /// What a summary says about an email rather than from it: the act of
    /// writing ("asks", "reminds"), the reader, and the email itself.
    private static let describingWords: Set<String> = [
        "ask", "asks", "asked", "request", "requests", "requested", "want", "wants", "wanted", "need", "needs",
        "needed", "remind", "reminds", "reminder", "say", "says", "said", "tell", "tells", "told", "mention",
        "mentions", "note", "notes", "share", "shares", "shared", "send", "sends", "sent", "let", "lets", "know",
        "inform", "informs", "notify", "notifies", "invite", "invites", "invited", "offer", "offers", "suggest",
        "suggests", "propose", "proposes", "include", "includes", "expect", "expects", "follow", "follows",
        "reply", "replies", "respond", "responds", "response", "get", "gets", "make", "makes", "have", "has",
        "had", "is", "are", "was", "were", "be", "been", "being", "do", "does", "did", "will", "would", "can",
        "could", "should", "may", "might", "must", "email", "emails", "message", "messages", "note", "update",
        "updates", "thread", "conversation", "sender", "you", "your", "reader", "recipient", "details", "info",
        "information", "regarding", "about", "explain", "explains", "describe", "describes", "announce",
        "announces", "confirm's", "check", "checks", "see", "look", "looks", "plan", "plans", "hope", "hopes",
        "thank", "thanks", "thanked", "nothing", "anything", "something", "everything", "thing", "things",
    ]

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

    /// A newsletter's figures told as if they happened to the reader: "You
    /// got a charge of $81,801.71" (a market index in Morning Brew), "You
    /// got a $499 Alexa Tablet" (a review in The Verge). The figures are in
    /// the email, so `unsupportedClaims` can't catch it; the framing is the
    /// mistake. Only for mail written to many people.
    public static func claimsMoneyToReader(_ summary: String) -> Bool {
        let money = #"(\$|£|€|৳|₹|\b(usd|gbp|eur|tk|rs)\b|\d[\d,.]*\s?(dollars|pounds|euros))"#
        return summary.range(of: #"(?i)\byou(?:'ve| have)? (got|received|were charged|have been charged|paid|bought|won|earned|saved)\b[^.]{0,60}"# + money,
                             options: .regularExpression) != nil
            || summary.range(of: #"(?i)\b(a |the )?charge of\b"#, options: .regularExpression) != nil
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
        let ascii = asciiDigits(text)
        return ascii.regexRanges(of: #"(?<![\d.,])\d+(?:[.,:'\u00A0\u202F]\d+)*"#).map { canonicalNumber(String(ascii[$0])) }
    }

    /// Any script's digits as 0–9: "১২৫০" (Bengali) reads as "1250".
    static func asciiDigits(_ text: String) -> String {
        guard text.contains(where: { $0.isNumber && !$0.isASCII }) else { return text }
        return String(text.map { character -> Character in
            guard !character.isASCII, let value = character.wholeNumberValue, (0...9).contains(value) else { return character }
            return Character(String(value))
        })
    }

    /// A number as its value, whatever the locale writes: grouping removed
    /// ("1,250", "1.250", "1,25,000" → "1250"/"125000"), the decimal part
    /// kept without trailing zeros ("1,250.00" and "1.250,00" → "1250";
    /// "12.50" → "12.5"). Times ("3:00") and dates ("15.10.2026") as written.
    static func canonicalNumber(_ token: String) -> String {
        if token.contains(":") { return token }
        let separators: Set<Character> = [".", ",", "'", "\u{00A0}", "\u{202F}"]
        let parts = token.split(whereSeparator: { separators.contains($0) }).map(String.init)
        let used = token.filter { separators.contains($0) }
        guard parts.count > 1, let last = parts.last, let lastSeparator = used.last else { return token }
        // Grouping only: one kind of separator, ending in a group of three.
        if last.count == 3, Set(used).count == 1, lastSeparator != "." || parts.count > 2 || parts[0].count <= 3 {
            return parts.joined()
        }
        // A decimal part: the last separator, used nowhere earlier.
        if (1...2).contains(last.count), !used.dropLast().contains(lastSeparator) {
            var decimals = last
            while decimals.hasSuffix("0") { decimals.removeLast() }
            let whole = parts.dropLast().joined()
            return decimals.isEmpty ? whole : whole + "." + decimals
        }
        return token
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

    // MARK: - The ask, from the email's own sentences

    /// What a person's email asks of you, in their own words: the request
    /// or question addressed to you, preferring one with a deadline or an
    /// amount. Only for an email long enough that it could be missed, and
    /// only when it's past the opening lines, where it would be read anyway.
    /// Never a sentence the email doesn't have, never a guess at one.
    public static func buriedAsk(text: String) -> String? {
        guard wordCount(text) >= minimumWords else { return nil }
        let asks = sentences(in: text).filter { sentence in
            MailSignals.asksSomething(sentence) && !isBoilerplate(sentence) && !isPromptQuestion(sentence)
                && wordCount(sentence) >= 5
        }
        let pressing = asks.first { $0.range(of: #"\p{Sc}\s?\d|\b\d{1,2}(:\d{2})?\s?(am|pm)\b|\b(due|by|before|deadline|until|tomorrow|today|tonight|monday|tuesday|wednesday|thursday|friday|saturday|sunday)\b"#, options: [.regularExpression, .caseInsensitive]) != nil }
        guard let ask = pressing ?? asks.first, let range = text.range(of: ask) else { return nil }
        guard wordCount(String(text[..<range.lowerBound])) >= 40 else { return nil }
        return clipped(ask)
    }

    /// The parts of an email that are about the email or the app, never
    /// what it says: footers, legal lines, app and download prompts.
    static func isBoilerplate(_ sentence: String) -> Bool {
        sentence.range(of: boilerplatePattern, options: .regularExpression) != nil
    }

    private static let boilerplatePattern = #"(?i)\b(do not reply|don'?t reply|no-?reply|unsubscribe|you('re| are) receiving this|(this|the) (e-?mail|message) (was|is) (sent|intended)|sent to you because|all rights reserved|privacy (policy|notice|statement)|terms (of (use|service)|and conditions)|in (your|a) (web )?browser|having trouble (viewing|seeing)|address book|(email|notification|communication) preferences|download (the|our|your) (app|receipt|invoice|statement|pdf)|pdf format|get the app|app store|google play|follow us|registered (office|in)|company (no|number)|customer service is available)\b|©"#

    /// Questions an email asks to sell or help, not ones it needs answered:
    /// "Want to…?", "Need help?", "Questions?", "Not you?".
    static func isPromptQuestion(_ sentence: String) -> Bool {
        sentence.range(of: #"(?i)^(want|wanna|need|needing|looking|ready|interested|curious|tired|enjoying|love|loving|did you know|why not|have (any )?questions|got (a )?questions|questions|not you|didn'?t (request|ask|make)|wasn'?t (this )?you|forgot|having (issues|problems|trouble)|can'?t find)\b[^?]{0,90}\?"#,
                       options: .regularExpression) != nil
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
