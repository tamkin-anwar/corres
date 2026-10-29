import Foundation

/// What the In short card says above an email, on every device, with or
/// without Apple Intelligence: what the email is, the one line worth
/// knowing, and the details you'd otherwise scroll for.
///
/// Every line is either Corres's own few words around facts copied from
/// the email (a code, a discount, a date, a role), or one of the email's
/// own sentences, quoted. Nothing is paraphrased, so nothing can be made
/// up; when there's nothing clear enough to say, it says nothing.
///
/// Measured on a real mailbox (`InShortReport`), the card before this said
/// only where the email was sorted ("No action needed: Automated update")
/// for 9 in 10 emails, with or without Apple Intelligence: the model's
/// summaries were mostly dropped for repeating the opening, and there was
/// no summary at all without it.
public struct InShort: Equatable, Sendable {
    /// What the email is, as the card's heading: "Job offer", "Sale",
    /// "Security alert". English underneath; shown through `display`.
    public var topic: Topic
    /// Corres's own words, built only from facts in the email.
    public var headline: String?
    /// The email's own sentence that says what it's about, when there's no
    /// headline. Shown in quotation marks: the sender's words, not ours.
    public var quote: String?
    /// Label and value pairs read from the email ("Start date", "Monday,
    /// January 11, 2027"), when there's no receipt card.
    public var details: [Glance.Fact]
    /// A receipt's, delivery's or bill's status and figures.
    public var glance: Glance?
    /// What a long personal email asks of you, in the sender's words.
    public var ask: String?
    public var nextStep: NextStep?

    public init(topic: Topic, headline: String? = nil, quote: String? = nil, details: [Glance.Fact] = [],
                glance: Glance? = nil, ask: String? = nil, nextStep: NextStep? = nil) {
        self.topic = topic; self.headline = headline; self.quote = quote; self.details = details
        self.glance = glance; self.ask = ask; self.nextStep = nextStep
    }

    public enum Topic: String, Codable, Sendable, CaseIterable {
        case personal, jobOffer, jobAlert, appointment, sale, promotion, newsletter, securityAlert, code, delivery, receipt,
             invitation, notification

        /// The card's heading, in the reader's language.
        public var title: String {
            switch self {
            case .personal: String(localized: "In short")
            case .jobOffer: String(localized: "Job offer")
            case .jobAlert: String(localized: "Job alert")
            case .appointment: String(localized: "Appointment")
            case .sale: String(localized: "Sale")
            case .promotion: String(localized: "Promotion")
            case .newsletter: String(localized: "Newsletter")
            case .securityAlert: String(localized: "Security alert")
            case .code: String(localized: "Security code")
            case .delivery: String(localized: "Delivery")
            case .receipt: String(localized: "Receipt")
            case .invitation: String(localized: "Invitation")
            case .notification: String(localized: "In short")
            }
        }

        /// The heading's symbol (SF Symbols).
        public var symbol: String {
            switch self {
            case .personal, .notification: "text.quote"
            case .jobOffer, .jobAlert: "briefcase"
            case .appointment: "calendar"
            case .sale: "tag"
            case .promotion: "megaphone"
            case .newsletter: "newspaper"
            case .securityAlert: "lock.shield"
            case .code: "number"
            case .delivery: "shippingbox"
            case .receipt: "doc.text"
            case .invitation: "calendar.badge.plus"
            }
        }

        /// What the email is, for the status line: "No action needed: a
        /// job alert." Nil where the stored reason says more.
        public var noun: String? {
            switch self {
            case .jobAlert: String(localized: "A job alert.")
            case .sale: String(localized: "A sale.")
            case .promotion: String(localized: "A promotion.")
            case .newsletter: String(localized: "A newsletter.")
            case .securityAlert: String(localized: "A security alert.")
            case .code: String(localized: "A one-time code.")
            case .delivery: String(localized: "A delivery update.")
            case .receipt: String(localized: "A receipt or bill.")
            case .invitation: String(localized: "A calendar invitation.")
            case .appointment: String(localized: "An appointment reminder.")
            case .jobOffer, .personal, .notification: nil
            }
        }
    }

    /// Whether the card has anything to say beyond where the email was
    /// sorted.
    public var saysOnlyWhereItIs: Bool {
        headline == nil && quote == nil && details.isEmpty && glance == nil && ask == nil && nextStep == nil
    }

    /// The card's lines as plain text, for the report and VoiceOver.
    public var lines: [String] {
        var lines: [String] = []
        if let headline { lines.append(topic.title + ": " + headline) }
        if let quote { lines.append(topic.title + ": \u{201C}" + quote + "\u{201D}") }
        if let glance {
            lines.append(([glance.status.map(Glance.display)].compactMap { $0 }
                + glance.facts.map { Glance.display($0.label) + " " + $0.value }).joined(separator: ", "))
        }
        if !details.isEmpty { lines.append(details.map { Glance.display($0.label) + ": " + $0.value }.joined(separator: "; ")) }
        if let ask { lines.append("Asks you: \u{201C}" + ask + "\u{201D}") }
        if let nextStep { lines.append("Next step: " + Glance.display(nextStep.label)) }
        return lines
    }
}

extension InShort {
    /// Everything the card shows for `thread`, read from the email alone.
    /// A full pass over its text and HTML: call it off the main thread.
    public static func make(for thread: Correspondence, now: Date = .now) -> InShort {
        guard thread.isBodyLoaded else { return InShort(topic: .notification) }
        let bulk = InboxClassifier.bulkKind(labelIds: thread.labelIds, looksAutomated: thread.looksAutomated)
        // The whole text, not the cleaned one: cleaning drops what follows a
        // sign-off, which is often exactly where the link is.
        let whole = MailDigest.readableText(body: thread.body, html: thread.htmlBody)
        let cleaned = MailDigest.clean(whole)
        let kind: MailDigest.Kind = bulk == .promotions ? .newsletter
            : MailDigest.kind(subject: thread.subject, text: cleaned, senderEmail: thread.senderEmail, isBulk: bulk != nil,
                              looksAutomated: thread.looksAutomated, hasEvent: false, labelIds: thread.labelIds)
        let blocks = MailDigest.clean(MailDigest.readableText(body: thread.body, html: thread.htmlBody, cellBreaks: true))
        return make(subject: thread.subject, sender: thread.sender, senderEmail: thread.senderEmail, whole: whole,
                    cleaned: cleaned, blocks: blocks, html: thread.htmlBody, kind: kind, isBulk: bulk != nil,
                    isPromotion: bulk == .promotions, isFromReader: thread.isFromAccountOwner,
                    receivedAt: thread.receivedAt, now: now)
    }

    /// The same from the email's parts, for tests. `blocks` is the text
    /// with each table cell on a line of its own (`MailDigest.text(fromHTML:
    /// cellBreaks:)`), where a sentence to quote is looked for.
    public static func make(subject: String, sender: String, senderEmail: String?, whole: String, cleaned: String,
                            blocks: String? = nil, html: String?, kind: MailDigest.Kind, isBulk: Bool = false,
                            isPromotion: Bool = false, isFromReader: Bool = false,
                            receivedAt: Date, now: Date = .now) -> InShort {
        let blocks = blocks ?? cleaned
        let glance = MailDigest.glance(text: cleaned, subject: subject, kind: kind, html: html)
        var step = isFromReader ? nil : MailDigest.nextStep(text: whole, html: html, kind: kind)
        // A step that doesn't fit the email: "Track package" on lab results
        // ("track your health"), "Sign" once everyone has signed.
        if step?.label == "Track package", kind != .shipping, kind != .receipt { step = nil }
        if step?.label == "Sign", (subject + "\n" + cleaned.prefix(600)).patternRange(#"(?i)^(completed|signed)\b|\b(all parties have signed|has been signed|was signed)\b"#) != nil {
            step = nil
        }
        let ask = kind == .personal && !isFromReader ? MailDigest.buriedAsk(text: cleaned) : nil
        var card = InShort(topic: kind == .personal ? .personal : .notification, glance: glance, ask: ask, nextStep: step)
        // Your own message needs no gist: you wrote it.
        guard !isFromReader else { return card }
        let arrivedToday = Calendar.current.isDate(receivedAt, inSameDayAs: now)
        let details = glance == nil ? Gist.details(in: blocks) : []
        let automated = kind != .personal

        if kind == .code, let code = MailDigest.verificationCode(in: subject + "\n" + cleaned.prefix(600)) {
            card.topic = .code
            card.headline = Gist.codeLine(code: code, text: cleaned)
            return card
        }
        if kind == .invite {
            card.topic = .invitation
            return card
        }
        if let offer = Gist.jobOffer(subject: subject, text: blocks, sender: sender, kind: kind) {
            card.topic = .jobOffer
            card.headline = offer.headline
            card.details = offer.details
            return card
        }
        if Gist.isJobAlert(senderEmail: senderEmail, subject: subject) {
            card.topic = .jobAlert
            card.headline = Gist.jobAlertLine(senderEmail: senderEmail, sender: sender)
            card.details = Gist.jobAlertDetails(subject: subject, text: cleaned)
            // Its links are listings, never one step of yours ("Book").
            card.nextStep = nil
            return card
        }
        if kind == .shipping || kind == .receipt {
            card.topic = kind == .shipping ? .delivery : .receipt
            if glance == nil {
                card.quote = Gist.keySentence(in: blocks, subject: subject, automated: automated)
                card.details = details
            }
            return card
        }
        // A sale says its offer; mail sent to many people says nothing else
        // of its own (the old complaint: quoting it picked up sales lines).
        if isPromotion || kind == .newsletter || isBulk,
           let offer = Gist.offer(subject: subject, text: cleaned, html: html, arrivedToday: arrivedToday, now: now) {
            card.topic = .sale
            card.headline = offer
            return card
        }
        if isPromotion {
            card.topic = kind == .newsletter && Gist.isDigest(senderEmail: senderEmail, sender: sender, subject: subject) ? .newsletter : .promotion
            if card.topic == .newsletter { card.headline = Gist.readingTime(blocks) }
            return card
        }
        if kind == .newsletter || (isBulk && Gist.isDigest(senderEmail: senderEmail, sender: sender, subject: subject)) {
            card.topic = .newsletter
            card.headline = Gist.readingTime(blocks)
            return card
        }
        if Gist.isSecurityAlert(subject: subject, text: cleaned) {
            card.topic = .securityAlert
            card.quote = Gist.keySentence(in: blocks, subject: subject, automated: true, allowConditional: true)
            card.details = details
            return card
        }
        if let appointment = Gist.appointment(subject: subject, text: cleaned, receivedAt: receivedAt, now: now) {
            card.topic = .appointment
            card.headline = appointment.headline
            card.details = Gist.merged(appointment.details, details)
            return card
        }
        card.details = details
        // A person's email reads in full right below; only a sentence the
        // opening doesn't already show is worth lifting out.
        if kind == .personal {
            if ask == nil { card.quote = Gist.keySentence(in: blocks, subject: subject, automated: false, skippingOpeningWords: 40) }
            return card
        }
        card.quote = Gist.keySentence(in: blocks, subject: subject, automated: true)
        return card
    }
    /// Where the email is sorted and why, under the card. Handled says
    /// where it went rather than the reason it once needed you; quiet mail
    /// says what it is, rather than only that nothing's needed.
    public static func statusLine(for thread: Correspondence, topic: Topic?, now: Date = .now) -> String {
        if thread.isPastEvent(at: now), let due = thread.dueAt {
            return String(localized: "Was on \(due.formatted(.dateTime.weekday(.wide).month(.wide).day())), so it's out of Needs You. It stays in Mail.")
        }
        switch thread.attention {
        case .handled: return String(localized: "Handled. It's off your lists and stays in Mail and in Mailboxes \u{2192} Handled.")
        case .quiet:
            // The reason often ends by saying so itself ("Marketing
            // newsletter, no action needed"); say it once.
            // "Kept out of Needs You" says the same again; once is enough.
            var reason = thread.reason.replacingPattern(#"(?i)[\s,;.—–-]*no action (is )?needed[.!]?"#, with: "")
                .replacingPattern(#"(?i)\s*kept out of needs you\.?"#, with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            // "Automated update" and "Bulk mail" say how it was sent, not
            // what it is; the card knows that better.
            if let noun = topic?.noun, genericReasons.contains(reason) { return String(localized: "No action needed: \(noun)") }
            reason = InboxClassifier.displayReason(reason)
            return reason.isEmpty ? String(localized: "No action needed.") : String(localized: "No action needed: \(reason)")
        default:
            return thread.reason.isEmpty ? thread.attention.title : "\(thread.attention.title): \(thread.displayReason)"
        }
    }

    /// Stored reasons, as the status line has them once trimmed, that only
    /// say the mail was sent in bulk.
    static let genericReasons: Set<String> = ["Automated update.", "Bulk mail.", "Promotion.", "Mailing list.", "Social notification.",
                                              "Already read.", "Already read in Gmail."]
}

/// The extractors behind `InShort`, each tested on its own
/// (`InShortTests`). Each returns nil rather than a guess.
enum Gist {

    // MARK: Codes

    /// "Code 482913. Expires in 10 minutes.": the expiry the email states,
    /// in the reader's language.
    static func codeLine(code: String, text: String) -> String {
        let line = String(localized: "Code \(code).")
        guard let groups = captures(#"(?i)\b(?:expires?|expiring|valid|good)\b[^.\n]{0,25}?\b(\d{1,3})\s?(minutes?|mins?|hours?|hrs?)\b"#, in: text),
              groups.count == 2, let amount = Double(groups[0]) else { return line }
        let seconds = amount * (groups[1].lowercased().hasPrefix("h") ? 3_600 : 60)
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.allowedUnits = seconds >= 3_600 ? [.hour, .minute] : [.minute]
        guard let span = formatter.string(from: seconds) else { return line }
        return line + " " + String(localized: "Expires in \(span).")
    }

    // MARK: Job offers

    /// An offer of a job, from the employer: "we are thrilled to extend you
    /// an offer", "pleased to offer you the position". Never a job alert's
    /// listing ("offers a competitive salary") or a newsletter's.
    static func jobOffer(subject: String, text: String, sender: String, kind: MailDigest.Kind) -> (headline: String, details: [Glance.Fact])? {
        guard kind == .personal || kind == .notification else { return nil }
        let top = subject + "\n" + text.prefix(1_500)
        guard top.patternRange(#"(?i)\b(extend(ing)? (to )?you (a|an|the) (job |formal |conditional |official )?offer|(pleased|happy|delighted|thrilled|excited) to offer you|offer to join|offer of employment|offer letter|you got the job|job offer)\b"#) != nil,
              top.patternRange(#"(?i)\b(job alert|jobs? (for|like|matching) you|recommended jobs|apply now|is hiring|new jobs)\b"#) == nil else { return nil }
        // "…to join Amazon as an Area Manager", "…the position of Senior
        // Designer at Brightpath": the role in capitals, as offers write it.
        let role = capture(#"(?:\boffer[^.\n]{0,60}?\b(?:join\s+[^\n.]{1,40}?\s+)?as\s+(?:an?\s+|the\s+|our\s+)?|\b(?:the |our )?(?:position|role) of\s+|\boffer (?:you )?(?:for )?the\s+)((?:[A-Z][\w&/+-]*\s?){1,6}?)(?=\s*(?:position|role)?\s*(?:[,.!;:\n]|at\b|with\b|in\b|on\b|starting\b|$))"#, in: top)
            .flatMap(nonEmpty)
        let company = (capture(#"(?i:offer to join|join)\s+((?:[A-Z][\w&.'-]*\s?){1,4}?)(?=\s+(?i:as|in|at|on)\b|[,.!])"#, in: top)
            ?? capture(#"(?i:position|role) of [^.\n]{1,60}? at ((?:[A-Z][\w&.'-]*\s?){1,4}?)(?=[,.!\n]|\s+(?i:starting|on|in|as)\b|$)"#, in: top))
            .flatMap(nonEmpty)
        var found = details(in: text)
        let start = found.first { $0.label.lowercased().hasPrefix("start") }?.value
            ?? capture(#"(?i:\bstart(?:ing)?(?: date)?(?: is| on| of)?\s*[:：]?\s*)("# + datePhrase + ")", in: text)
        found.removeAll { $0.value == start }
        let headline: String
        switch (role, company) {
        case let (role?, company?): headline = String(localized: "\(role) at \(company).")
        case let (role?, nil): headline = String(localized: "\(role).")
        case let (nil, company?): headline = String(localized: "An offer to join \(company).")
        default: headline = String(localized: "An offer from \(sender).")
        }
        let startLine = start.map { " " + String(localized: "Starts \($0).") } ?? ""
        return (headline + startLine, Array(found.prefix(3)))
    }

    // MARK: Job alerts

    /// A job board's alert or match: a listing, not a reply about a job
    /// you applied for, which is what its subject reads like.
    static func isJobAlert(senderEmail: String?, subject: String) -> Bool {
        let address = (senderEmail ?? "").lowercased()
        let board = address.patternRange(#"(jobalert|jobs-noreply@linkedin|jobalerts-noreply@linkedin|match\.indeed|@indeed|ziprecruiter|glassdoor|@(.*\.)?monster\.|@dice\.com|wellfound|joinhandshake|simplyhired|careerbuilder|naukri|bdjobs|seek\.com)"#) != nil
        return board && subject.patternRange(#"(?i)(\bhiring\b|\bjobs?\b|\brole\b|\bposition\b|@|\sat\s)"#) != nil
    }

    static func jobAlertLine(senderEmail: String?, sender: String) -> String {
        let address = (senderEmail ?? "").lowercased()
        let board = address.contains("linkedin") ? "LinkedIn" : address.contains("indeed") ? "Indeed"
            : address.contains("ziprecruiter") ? "ZipRecruiter" : address.contains("glassdoor") ? "Glassdoor" : sender
        return String(localized: "Listings from \(board), not a reply from an employer.")
    }

    /// The pay a listing states ("$98,329 - $153,911 a year", "From $250
    /// a day"), and how many more jobs it has. Not the search's own pay
    /// filter ("29 more $5000 A Month jobs").
    static func jobAlertDetails(subject: String, text: String) -> [Glance.Fact] {
        var facts: [Glance.Fact] = []
        if let pay = text.patternRange(#"(?i)(from |up to )?\$\s?\d[\d,]*(\.\d+)?[kK]?(\s?[-–]\s?\$\s?\d[\d,]*(\.\d+)?[kK]?)?\s(a|an|per|/)\s?(year|yr|hour|hr|day|week|month)\b(?!\s+jobs)"#) {
            facts.append(Glance.Fact(label: "Listed pay", value: String(text[pay])))
        }
        if let more = capture(#"(?i)\b(\d{1,3}) more\b[^.]{0,60}\bjobs?\b"#, in: subject) {
            facts.append(Glance.Fact(label: "More jobs", value: more))
        }
        return facts
    }

    // MARK: Sales

    /// A sale's offer, its code and when it ends, from what the sender
    /// embedded for Gmail's Promotions tab (schema.org `DiscountOffer`)
    /// or its own words, the subject's first: "20% off sitewide. Code
    /// FALLFEELS. Ends Mon, Oct 12."
    static func offer(subject: String, text: String, html: String?, arrivedToday: Bool, now: Date) -> String? {
        let structured = html.flatMap(discountOffer(in:))
        let top = subject + "\n" + text.prefix(1_500)
        var discount = structured?.description.flatMap { $0.patternRange(discountPattern) != nil ? $0 : nil }
        if discount == nil {
            if let range = subject.patternRange(discountPattern) {
                discount = String(subject[range])
            } else if let range = text.prefix(1_500).patternRange(discountPattern),
                      // "Refer a friend and earn 10% off" is a referral, not a sale.
                      text[text.index(range.lowerBound, offsetBy: -min(60, text.distance(from: text.startIndex, to: range.lowerBound)))..<range.lowerBound]
                        .patternRange(#"(?i)\b(earn|refer|referral|friends?|invite)\b"#) == nil {
                discount = String(text[range])
            }
        }
        // "Free shipping on orders $100+" is a store's standing banner,
        // said in every email; an offer only when the subject says it.
        if let found = discount, found.patternRange(#"(?i)^free shipping"#) != nil, subject.patternRange(#"(?i)free shipping"#) == nil {
            discount = nil
        }
        guard let discount else { return nil }
        // "35% OFF* Select Styles" as "35% off select styles": an offer's
        // words are plain ones, written in capitals to shout.
        var parts = [sentenceCase(discount.replacingOccurrences(of: "*", with: "")
            .replacingPattern(#"\s+"#, with: " ").trimmingCharacters(in: .whitespacesAndNewlines).lowercased())]
        let code = structured?.code ?? capture(#"(?i:\b(?:use|with|enter|promo|coupon|discount|offer)\s+code\s*[:：]?\s*)["“']?((?=[A-Z0-9]*[A-Z])[A-Z0-9]{4,15}|\d{4,8})\b"#, in: top)
        if let code { parts.append(String(localized: "Code \(code).")) }
        if let ends = structured?.ends {
            let day = ends.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
            parts.append(ends < now ? String(localized: "Ended \(day).") : String(localized: "Ends \(day)."))
        } else if let ends = top.patternRange(#"(?i)\b(ends?|ending|expires?|valid (through|thru|until)|offer ends|sale ends)\s+(on\s+)?(\d{1,2}/\d{1,2}(/\d{2,4})?|(mon|tues|wednes|thurs|fri|satur|sun)day|(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?\s+\d{1,2}(st|nd|rd|th)?)\b"#) {
            // "OFFER ENDS ON OCT 6" as "Offer ends on Oct 6": months and
            // days keep their capital.
            let words = String(top[ends]).lowercased().split(separator: " ").map { word in
                word.patternRange(#"^(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec|mon|tue|wed|thu|fri|sat|sun)"#) != nil
                    ? sentenceCase(String(word)) : String(word)
            }
            parts.append(sentenceCase(words.joined(separator: " ")) + ".")
        } else if arrivedToday, let ends = top.patternRange(#"(?i)\b(ends? (tonight|today|at midnight)|today only|last day|final hours)\b"#) {
            // "Tonight" is the night it arrived, so only said that day.
            parts.append(sentenceCase(String(top[ends]).lowercased()) + ".")
        }
        return parts.map { $0.hasSuffix(".") ? $0 : $0 + "." }.joined(separator: " ")
    }

    /// "20% off", "up to 72% off sitewide", "35% off* select styles",
    /// "$10 off $50", "buy 2, get 1 free", "BOGO", "free shipping on
    /// orders $59+".
    static let discountPattern = #"(?i)\b((up to|extra|an extra|take|save|get)\s+)?(\d{1,2}\s?%|\$\d{1,4})\s?off\b\*?(\s(sitewide|everything|all \w+|your (first |next )?(order|purchase)|select \w+|orders? (of |over )?\$\d+\+?|\$\d+\+?))?|\bbuy \d+,? get \d+( free)?\b|\bbogo\b|\bfree shipping on (all )?orders( (of |over )?\$\d+\+?)?"#

    /// schema.org `DiscountOffer` as JSON-LD or microdata: the offer's
    /// description, code and end.
    static func discountOffer(in html: String) -> (description: String?, code: String?, ends: Date?)? {
        func date(_ value: String?) -> Date? {
            guard let value, !value.isEmpty else { return nil }
            if let date = ISO8601DateFormatter().date(from: value) { return date }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            for format in ["yyyy-MM-dd'T'HH:mm:ssZ", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd"] {
                formatter.dateFormat = format
                if let date = formatter.date(from: value) { return date }
            }
            return nil
        }
        func nonBlank(_ value: Any?) -> String? { (value as? String).flatMap(nonEmpty) }
        if let item = EventFinder.structuredItems(in: html).first(where: { ($0["@type"] as? String) == "DiscountOffer" }) {
            let description = nonBlank(item["description"]), code = nonBlank(item["discountCode"])
            guard description != nil || code != nil else { return nil }
            return (description, code, date(nonBlank(item["availabilityEnds"])))
        }
        guard let start = html.range(of: "schema.org/DiscountOffer") else { return nil }
        let block = String(html[start.lowerBound...].prefix(3_000))
        func property(_ name: String) -> String? {
            captures(#"itemprop=["']"# + name + #"["'][^>]*?content=["']([^"']*)["']|content=["']([^"']*)["'][^>]*?itemprop=["']"# + name + #"["']"#, in: block)?
                .lazy.compactMap(nonEmpty).first
        }
        let description = property("description"), code = property("discountCode")
        guard description != nil || code != nil else { return nil }
        return (description, code, date(property("availabilityEnds")))
    }

    // MARK: Newsletters

    /// A digest or newsletter by how it's sent or titled ("news@",
    /// "Your Morning Digest", "The Verge Daily"), whatever Gmail filed it
    /// under: its sentences are stories, never the email's gist.
    static func isDigest(senderEmail: String?, sender: String, subject: String) -> Bool {
        let from = ((senderEmail ?? "") + " " + sender).lowercased()
        return from.patternRange(#"(news|newsletter|digest|daily|weekly|brief|editors?|subscriptions|substack|beehiiv|redditmail|crew@|community|sailthru|e\.smartnews)"#) != nil
            || subject.patternRange(#"(?i)\b(digest|newsletter|edition|roundup|issue #?\d+)\b|[▽☕]"#) != nil
    }

    /// "About 6 minutes to read.", at 230 words a minute; nothing for one
    /// that reads in a minute or two.
    static func readingTime(_ text: String) -> String? {
        let minutes = Int((Double(MailDigest.wordCount(text)) / 230).rounded())
        guard minutes >= 3 else { return nil }
        return String(localized: "About \(minutes) minutes to read.")
    }

    // MARK: Security alerts

    static func isSecurityAlert(subject: String, text: String) -> Bool {
        let top = subject + "\n" + text.prefix(400)
        return top.patternRange(#"(?i)\b(security (alert|notice|update)|new (sign[- ]?in|log[- ]?in|device)|password (was |has been )?(changed|reset)|sign[- ]?in attempt|unusual (activity|sign[- ]?in)|(third-party|oauth) application|allowed [^.\n]{1,40} access|two-factor|2-step verification)\b"#) != nil
    }

    // MARK: Appointments

    /// An appointment, interview or reservation an email confirms or
    /// reminds you of, with its day and time as Apple's date detector
    /// reads them (`EventFinder.fromWording`).
    static func appointment(subject: String, text: String, receivedAt: Date, now: Date) -> (headline: String, details: [Glance.Fact])? {
        let top = subject + "\n" + text.prefix(500)
        guard top.patternRange(#"(?i)\b(appointment|interview|reservation|consultation|visit|check-in|class|session)\b"#) != nil,
              top.patternRange(#"(?i)\b(your|upcoming|scheduled|confirm(ed|ation)?|reminder|booked|is on|starts)\b"#) != nil,
              let event = EventFinder.fromWording(text, subject: subject, receivedAt: receivedAt, now: now) else { return nil }
        let headline = event.start.formatted(.dateTime.weekday(.wide).month(.abbreviated).day().hour().minute()) + "."
        var details: [Glance.Fact] = []
        if let place = event.location, place.count <= 90 { details.append(Glance.Fact(label: "Where", value: place)) }
        if let confirmation = event.confirmation { details.append(Glance.Fact(label: "Confirmation", value: confirmation)) }
        return (headline, details)
    }

    /// `first`, then those of `more` that say something new: another
    /// value, under a label that isn't a synonym already shown.
    static func merged(_ first: [Glance.Fact], _ more: [Glance.Fact]) -> [Glance.Fact] {
        var result = first
        for fact in more where !result.contains(where: { $0.value == fact.value || sameLabel($0.label, fact.label) }) {
            result.append(fact)
        }
        return Array(result.prefix(4))
    }

    private static func sameLabel(_ a: String, _ b: String) -> Bool {
        let groups: [Set<String>] = [["where", "location", "address", "site", "work location", "venue"],
                                     ["confirmation", "confirmation number", "booking reference", "reference number"]]
        let x = a.lowercased(), y = b.lowercased()
        return x == y || groups.contains { $0.contains(x) && $0.contains(y) }
    }

    // MARK: Labeled details

    /// "Start Date: Monday, January 11, 2027", "Site PSP1", "Location
    /// Remote": the label and value pairs designed mail lays out, for the
    /// labels worth seeing at a glance. A value is copied as written, on
    /// its label's line or alone on the next.
    static func details(in text: String) -> [Glance.Fact] {
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var facts: [Glance.Fact] = []
        func add(_ label: String, _ value: String) {
            let value = value.trimmingCharacters(in: .whitespaces.union(.init(charactersIn: ",;*")))
            // A value is a value: not a sentence, a fragment, or a button.
            guard let first = value.first, first.isUppercase || first.isNumber || first == "$" || first == "#",
                  MailDigest.wordCount(value) <= 12, !value.hasSuffix("?"),
                  value.patternRange(#"(?i)^(click|tap|view|see|learn|here|n/a|none|tbd|tba)\b|https?://"#) == nil,
                  !facts.contains(where: { sameLabel($0.label, label) || $0.value == value }) else { return }
            let tidy = label.prefix(1).uppercased() + label.dropFirst().lowercased()
            facts.append(Glance.Fact(label: tidy, value: value))
        }
        var index = 0
        while index < lines.count, facts.count < 4 {
            let line = lines[index]
            index += 1
            guard line.count <= 90 else { continue }
            if let groups = captures("(?i)^(" + detailLabels + #")(?:\s*[:：]\s*|\s+(?=[A-Z0-9$#]))(.{2,70})$"#, in: line),
               groups.count == 2 {
                add(groups[0], groups[1])
            } else if index < lines.count, let label = capture("(?i)^(" + detailLabels + #")\s*[:：]?$"#, in: line) {
                let value = lines[index]
                if value.count <= 70, value.patternRange("(?i)^(" + detailLabels + #")\b"#) == nil {
                    add(label, value)
                    index += 1
                }
            }
        }
        return facts
    }

    /// Labels worth lifting out, as senders write them. Not "Date" or
    /// "Time" alone: those are as often a newsletter's issue date.
    static let detailLabels = #"start date|start time|end date|first day|site|work location|location|address|building|position|job title|role|department|shift|schedule|salary|pay rate|hourly rate|compensation|reporting to|manager|provider|doctor|venue|room|gate|seat|terminal|flight|departure|arrival|check-in date|check-out date|check-in|check-out|pickup|pick-up|drop-off|return date|due date|deadline|respond by|reply by|expiration date|renewal date|policy number|account number|case number|reference number|confirmation number|booking reference"#

    // MARK: Key sentence

    /// The one sentence of the email's own that says what it's about: the
    /// first real sentence (the strongest guide to an email's gist, ahead
    /// of TextRank on email in EmailSum), weighted toward one that talks to
    /// you, says what happened or names a date or amount. Never a greeting,
    /// a pleasantry, a sales line, a button, a heading, a footer, a news
    /// story, or one that only repeats the subject. Nil when none is clear.
    ///
    /// In mail a company sends, a sentence has to say what happened or
    /// when (`cuePattern`, or a date): that one rule keeps out the slogans
    /// and stories that read like sentences ("Stay connected to the music
    /// you love").
    static func keySentence(in text: String, subject: String, automated: Bool,
                            skippingOpeningWords: Int = 0, allowConditional: Bool = false) -> String? {
        let subjectWords = Set(contentWords(MailSubject.base(subject)))
        let source = reflowed(String(text.prefix(5_000)))
        var best: (sentence: String, score: Double)?
        var position = 0
        for sentence in MailDigest.sentences(in: source).flatMap(pieces) {
            guard isCandidate(sentence) else { continue }
            if skippingOpeningWords > 0, let range = source.range(of: sentence),
               MailDigest.wordCount(source[..<range.lowerBound]) < skippingOpeningWords { continue }
            let words = contentWords(sentence)
            guard words.count >= 3 else { continue }
            let shared = words.filter(subjectWords.contains).count
            defer { position += 1 }
            // Only the subject again, right under it.
            if Double(shared) / Double(words.count) >= 0.75 { continue }
            let addressed = sentence.patternRange(#"(?i)\b(you|your|you're|you've|you'll)\b"#) != nil
            let happened = sentence.patternRange(cuePattern) != nil || (addressed && sentence.patternRange(weakCuePattern) != nil)
            let dated = sentence.patternRange("(?i)" + datePhrase) != nil || sentence.patternRange(#"(?i)\bby (mon|tues|wednes|thurs|fri|satur|sun)day\b"#) != nil
            if automated, !happened, !dated { continue }
            if automated, sentence.hasSuffix("?") { continue }
            var score = max(0, 3 - Double(position))
            if sentence.patternRange(#"(?i)\b(you|your|you're|you've|you'll)\b"#) != nil { score += 2 }
            if happened { score += 2 }
            if sentence.contains(where: \.isNumber) { score += 1.5 }
            if shared > 0 { score += 1 }
            // "If the tickets become available, you will receive…" isn't
            // what happened; only a security alert's "if this wasn't you"
            // is worth reading first.
            if sentence.patternRange(#"(?i)^if\b"#) != nil {
                guard allowConditional else { continue }
                score -= 1
            }
            if sentence.hasSuffix("?") { score -= 1 }
            if score >= 3, score > (best?.score ?? 0) { best = (sentence, score) }
            if position >= 8 { break }
        }
        return best.map(\.sentence)
    }

    /// Plain text hard-wrapped at 60 or 70 characters, put back into its
    /// sentences: a line that stops mid-sentence ("…a temporary access
    /// code from the") is joined to the next one that carries on in
    /// lowercase.
    static func reflowed(_ text: String) -> String {
        var lines: [String] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let last = lines.last, !last.isEmpty, let first = trimmed.first,
               first.isLowercase || first.isNumber, let end = last.last, !".!?:;".contains(end) {
                lines[lines.count - 1] = last + " " + trimmed
            } else {
                lines.append(trimmed)
            }
        }
        return lines.joined(separator: "\n")
    }

    /// A sentence as it can be quoted: designed mail runs a heading, a
    /// greeting and the first line together when the HTML has no break
    /// between them ("…from a new IP address We've noticed a new login Hi
    /// Sam, We're notifying you…"), so they're cut apart where a new
    /// sentence plainly starts. Bold markers and a label run on after a
    /// colon go too.
    static func pieces(_ sentence: String) -> [String] {
        var text = sentence.replacingPattern(#"\*{1,2}([^*]{1,80})\*{1,2}"#, with: "$1")
            .replacingPattern(#"^\*\*.{0,60}?\*\*\s*"#, with: "")
        // A greeting inside: everything after it.
        text = text.replacingPattern(#"(?:^|(?<=\s))(?:Hi|Hello|Hey|Dear|Greetings)\b[^,.!?\n]{0,40}[,!]\s*"#, with: "\n")
        // A new sentence after a lowercase word with no full stop.
        text = text.replacingPattern(#"(?<=[a-z\d)])\s+(?=(?:We|We're|We've|You|Your|You're|You've|Our|This|Please|Thank|Thanks|If)\b)"#, with: "\n")
        text = text.replacingPattern(#"(?<=[a-z])\s+(?=The [a-z])"#, with: "\n")
        return text.split(separator: "\n").map { piece in
            var piece = piece.trimmingCharacters(in: .whitespaces)
            // "…on your policy 1234567: Download or print…": the clause.
            if let colon = piece.range(of: ": "), MailDigest.wordCount(piece[..<colon.lowerBound]) >= 6 {
                piece = String(piece[..<colon.lowerBound])
            }
            while let last = piece.last, ":;,–-".contains(last) { piece.removeLast() }
            // A space left before a full stop where a link was ("…2026 .").
            return piece.replacingPattern(#"\s+([.,!?])"#, with: "$1").trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }
    }

    /// What happened, in the words notices use for it.
    /// Asks too: "we're asking you to install", "please confirm".
    static let cuePattern = #"(?i)\b(is (now )?(ready|due|available|scheduled|confirmed|approved|active|paused|on|going to)|are (now )?(ready|due|available)|will (expire|renew|start|end|close|change|move|receive|need)|due|expires?|expired|expiring|confirmed|scheduled|approved|declined|denied|paused|changed|updated|received|requested|added|removed|signed|completed|processed|provided|charged|sent|cancel+ed|renew(s|ed)?|deadline|accepted|rejected|ready|verified|enrolled|created|published|installed|authori[sz]ed|allowed|accessed|granted|(asking|ask|need|needs) you to|please (update|confirm|install|complete|review|verify|sign|pay|respond|reply|call|bring|arrive))\b"#
    /// "Was", "has been", "will be": what happened only in a sentence
    /// about you ("$45.00 was charged to your account"); otherwise as
    /// often a product's story ("solutions that were handpicked").
    static let weakCuePattern = #"(?i)\b(has been|have been|had been|was|were|is now|are now|will be)\b"#

    /// Not a sentence worth quoting: too short or long, a heading in
    /// capitals or Title Case, navigation, a sales line, a pleasantry, an
    /// instruction to click, a footer, or a sentence that leans on the one
    /// before it ("You'll then be charged…").
    static func isCandidate(_ sentence: String) -> Bool {
        let words = MailDigest.wordCount(sentence)
        guard (6...45).contains(words), !MailDigest.isBoilerplate(sentence), !MailDigest.isPromptQuestion(sentence),
              sentence.patternRange(#"[|•►▶→»<>]|https?://|www\.|\.com/|&[a-z]+;"#) == nil else { return false }
        let letters = sentence.filter(\.isLetter)
        if !letters.isEmpty, Double(letters.filter(\.isUppercase).count) / Double(letters.count) > 0.4 { return false }
        let ended = sentence.last.map { ".!?。！？".contains($0) } ?? false
        if !ended {
            // A heading, or a line cut short.
            let tokens = sentence.split(separator: " ").filter { $0.first?.isLetter == true }
            if tokens.count >= 3, Double(tokens.filter { $0.first!.isUppercase }.count) / Double(tokens.count) > 0.5 { return false }
            if sentence.patternRange(#"(?i)\b(the|a|an|as|and|or|to|of|for|from|with|by|in|on|at|any|that|your|our|this|add)$"#) != nil { return false }
            // A long line without a full stop ran into the next cell.
            if words > 14 { return false }
        }
        for pattern in [salesPattern, pleasantryPattern, instructionPattern, leaningPattern] where sentence.patternRange(pattern) != nil {
            return false
        }
        return true
    }

    static let salesPattern = #"(?i)(\d+\s?% off|\bsale\b|\bshop\b|\bshopping\b|\bdeals?\b|free shipping|\bbuy\b|\bdiscount|\bcoupon|\bpromo\b|limited[- ]time|don'?t miss|\border now\b|\bexclusive\b|\bnew arrivals?\b|\bbestsellers?\b|\bsubscribe\b|\bupgrade\b|\bsponsored\b|\bpremium\b|\brefer\b|\bearn\b|\bwin\b|\bbonus\b|\brewards?\b|\bpoints\b)"#
    static let pleasantryPattern = #"(?i)^(thank(s| you)\b|we('re| are) (so )?(excited|thrilled|happy|glad|pleased|delighted)|welcome\b|we hope|i hope|hope you|it'?s (been )?a pleasure|happy \w+day|good news|congratulations|great (job|news|work)|nice work)"#
    static let instructionPattern = #"(?i)^(please )?(click|tap|view|shop|download|learn|see|read|visit|follow|sign in|log ?in|go to|check out|explore|discover|find out|get started|start|join|try|manage|enjoy|stay|boost|dive|deploy|unlock|connect|meet|introducing|to (make changes|change|update|unsubscribe|stop|manage|view|learn|access)|you can (also |now )?(view|see|manage|change|update|unsubscribe|reply|contact|find|learn|always|pay|access|download|log|sign)|you may (also )?(view|see|access|contact|download|reply)|if you (have|need|would like|wish|want) (any )?(questions|help|assistance|more)|feel free|do not hesitate|don'?t hesitate|for (more )?(information|details|help|questions))\b"#
    /// Opens by pointing at what came before, so it can't stand alone.
    /// A footnote's marker ("3 Free trial is for 7 days…") too.
    /// And a forwarded copy's note about itself ("This is a copy of a
    /// security alert sent to…"): the alert follows it.
    static let leaningPattern = #"(?i)^(then|also|however|so|but|and|or|it|they|these|those|that)\b|^\S+(\s\S+)?\s+then\b|^(?-i:\d{1,2}\s+[A-Z][a-z])|^this is a copy of\b"#

    // MARK: Text

    static let datePhrase = #"(?:(?:mon|tues|wednes|thurs|fri|satur|sun)day,?\s+)?(?:(?:jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?\s+\d{1,2}(?:st|nd|rd|th)?(?:,?\s+\d{4})?|\d{1,2}(?:st|nd|rd|th)?\s+(?:jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?(?:,?\s+\d{4})?|\d{1,2}/\d{1,2}/\d{2,4})"#

    /// Lowercased words of four letters or more, without a trailing "s":
    /// enough to tell whether a sentence only repeats the subject.
    static func contentWords(_ text: String) -> [String] {
        let skip: Set<String> = ["your", "with", "from", "that", "this", "have", "will", "been", "about", "they", "their", "there", "here",
                                 "what", "when", "which", "into", "more", "just", "also", "were", "them", "then", "than", "only"]
        return text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
            .filter { $0.count >= 4 && !skip.contains($0) }
            .map { $0.hasSuffix("s") ? String($0.dropLast()) : $0 }
    }

    static func sentenceCase(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }

    /// "20% OFF SITEWIDE" as "20% off sitewide"; mixed case stays.
    static func lowercasedIfShouting(_ text: String) -> String {
        let letters = text.filter(\.isLetter)
        let shouting = !letters.isEmpty && Double(letters.filter(\.isUppercase).count) / Double(letters.count) > 0.6
        return shouting ? text.lowercased() : text
    }

    static func nonEmpty(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The first capture group that matched, of the first match.
    static func capture(_ pattern: String, in text: String) -> String? {
        captures(pattern, in: text)?.first
    }

    /// Every capture group that matched, of the first match, in order.
    static func captures(_ pattern: String, in text: String) -> [String]? {
        guard let regex = PatternCache.shared.regex(pattern, caseInsensitive: false),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        let groups = (1..<max(1, match.numberOfRanges)).compactMap { index -> String? in
            Range(match.range(at: index), in: text).map { String(text[$0]) }
        }
        return groups.isEmpty ? nil : groups
    }
}
