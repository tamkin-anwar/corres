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
        // In English and the app's other languages. Chinese, Japanese and
        // Korean words are found wherever they are, with no spaces around
        // them ("今月の領収書").
        if take(#" ((this|current) month|diesen monat|ce mois(-ci)?|este mes|este mês|neste mês|এই মাসে?) |今月|本月|这个月|這個月|이번 ?달"#) != nil {
            range = interval(.month)
        } else if take(#" (last month|letzten monat|(le )?mois dernier|el mes pasado|(no )?mês passado|গত মাসে?) |先月|上个月|上個月|지난 ?달"#) != nil {
            range = interval(.month, offset: -1)
        } else if take(#" ((this|current) week|diese woche|cette semaine|esta semana|nesta semana|এই সপ্তাহে?) |今週|本周|本週|这周|這週|이번 ?주"#) != nil {
            range = interval(.weekOfYear)
        } else if take(#" (last week|letzte woche|la semaine dernière|la semana pasada|(na )?semana passada|গত সপ্তাহে?) |先週|上周|上週|지난 ?주"#) != nil {
            range = interval(.weekOfYear, offset: -1)
        } else if take(#" (today|heute|aujourd'hui|hoy|hoje|আজ) |今日|今天|오늘"#) != nil {
            range = DateInterval(start: startOfToday, duration: 86_400)
        } else if take(#" (yesterday|gestern|hier|ayer|ontem|গতকাল) |昨日|昨天|어제"#) != nil {
            range = DateInterval(start: startOfToday.addingTimeInterval(-86_400), duration: 86_400)
        } else if let days = take(#" (last|past) (\d{1,3}) days "#), let count = Int(days[2]) {
            range = DateInterval(start: startOfToday.addingTimeInterval(Double(-count) * 86_400), end: now)
        }

        // Attachments and kinds of mail.
        if take(#" (attachments?|attached|files?|pdfs?|documents?|docs|photos|pictures|images|anhang|anhänge|anhängen|dateien|pièces? jointes?|fichiers|adjuntos?|archivos|anexos?|arquivos|সংযুক্তি|ফাইল) |添付(ファイル)?|附件|첨부(파일)?"#) != nil {
            wantsAttachments = true
        }
        if take(#" (receipts?|orders?|invoices?|purchases?|bills?|charges?|payments?|spent|spend|quittungen?|rechnungen?|bestellungen?|zahlungen?|reçus|factures?|commandes?|paiements?|recibos?|facturas?|pedidos?|pagos?|faturas?|compras|pagamentos?|রসিদ|অর্ডার|বিল|পেমেন্ট) |領収書|レシート|請求書|注文|購入|영수증|주문|결제|청구서|收据|收據|发票|發票|订单|訂單|账单|帳單"#) != nil {
            topic = .receipts
        } else if take(#" (packages?|parcels?|deliver(y|ies)|shipments?|shipping|tracking|pakete?|lieferungen?|sendungen?|colis|livraisons?|paquetes?|envíos?|entregas?|pacotes?|encomendas?|পার্সেল|ডেলিভারি) |荷物|配達|配送|택배|배송|包裹|快递|快遞|物流"#) != nil {
            topic = .packages
        } else if text.patternRange(#" (flights?|trips?|travel|itinerar(y|ies)|boarding|hotel|reservations?|check-?in|flüge?|reise|buchung|vols?|voyage|réservations?|vuelos?|viajes?|reservas?|voos?|viagem|ফ্লাইট|হোটেল|ভ্রমণ) |フライト|航空券|ホテル|予約|旅行|항공권|비행기|호텔|예약|여행|航班|机票|機票|酒店|飯店|预订|預訂"#) != nil {
            topic = .travel
        }

        // A person: "from X" ("von", "de", "desde"), or "did X ask/say/send/
        // want", in any script; "田中さんから", "김민준에게서", "来自王伟",
        // "রহিমের থেকে".
        let name = #"[\p{L}\p{M}\p{N}@.'-]+"#
        // "de"/"da" is also "of" ("facturas de luz"): a person only when the
        // question gives the name a capital ("recibos de Maya").
        let written = question.split(whereSeparator: { $0.isWhitespace || $0.isPunctuation && $0 != "'" && $0 != "-" })
        func capitalized(_ name: String) -> Bool {
            written.contains { $0.lowercased() == name && $0.first?.isUppercase == true }
        }
        if let from = take(#" (from|von) ("# + name + ") ") {
            person = from[2]
        } else if let regex = try? NSRegularExpression(pattern: #" (?:de|da|desde) ("# + name + ") "),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let range = Range(match.range(at: 1), in: text), capitalized(String(text[range])),
                  let from = take(#" (de|da|desde) ("# + name + ") ") {
            person = from[2]
        } else if let did = take(#" (did|has|have) ("# + name + #") (ask|asked|say|said|send|sent|want|wanted|need|needed|mention|write|wrote) "#) {
            person = did[2]
        } else if let cjk = take(#"(?:^| )([\p{L}\p{N}]{1,12}?)(?:さん|様|氏|先生)?(?:から|님이 보낸|님한테서|에게서|한테서|로부터|发来|發來|寄来|寄來)"#) {
            person = cjk[1]
        } else if let cjk = take(#"来自([\p{L}\p{N}]{1,12}?)(?:的|$| )|來自([\p{L}\p{N}]{1,12}?)(?:的|$| )"#) {
            person = cjk[1].isEmpty ? cjk[2] : cjk[1]
        } else if let bengali = take(#" ([\p{L}\p{M}\p{N}]+?)(?:ের|এর|র)? (?:কাছ )?থেকে "#) {
            person = bengali[1]
        }
        if let name = person, Self.notPeople.contains(name) { person = nil }

        keywords = text.split(separator: " ").map(String.init)
            .map(Self.withoutParticles)
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
                                   looksAutomated: thread.looksAutomated, hasEvent: false, labelIds: thread.labelIds) == .receipt
        case .packages?:
            return MailDigest.kind(subject: thread.subject, text: thread.excerpt + "\n" + thread.body,
                                   senderEmail: thread.senderEmail, isBulk: true,
                                   looksAutomated: thread.looksAutomated, hasEvent: false, labelIds: thread.labelIds) == .shipping
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

    /// A heading for a list answer: "3 emails with attachments from
    /// Oliver", in the reader's language.
    public func title(count: Int) -> String {
        let what: String
        if wantsAttachments {
            what = count == 1 ? String(localized: "1 email with attachments") : String(localized: "\(count) emails with attachments")
        } else if topic == .receipts {
            what = count == 1 ? String(localized: "1 receipt") : String(localized: "\(count) receipts")
        } else if topic == .packages {
            what = count == 1 ? String(localized: "1 package") : String(localized: "\(count) packages")
        } else {
            what = count == 1 ? String(localized: "1 email") : String(localized: "\(count) emails")
        }
        guard let person else { return what }
        let name = person.prefix(1).uppercased() + person.dropFirst()
        return String(localized: "\(what) from \(name)")
    }

    /// What's left of a Chinese, Japanese or Korean question once its
    /// parts are read: the grammar ("の", "を見せて", "보여줘", "的") isn't a
    /// word to search for.
    static func withoutParticles(_ word: String) -> String {
        guard word.contains(where: { !$0.isASCII }) else { return word }
        var word = word
        for phrase in ["を見せて", "見せて", "を教えて", "教えて", "ください", "보여줘", "알려줘", "给我看", "显示", "顯示",
                       "দেখাও", "দেখান"] {
            word = word.replacingOccurrences(of: phrase, with: "")
        }
        if word.hasPrefix("我的") { word.removeFirst(2) }
        // A particle at the end only: "은행" (bank) keeps its "은".
        for _ in 0..<2 {
            for particle in ["の", "を", "は", "が", "에서", "을", "를", "은", "는", "的"] where word.hasSuffix(particle) && word.count > particle.count {
                word.removeLast(particle.count)
                break
            }
        }
        return word
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
        // The same small words in German, French, Spanish and Portuguese.
        "zeig", "zeige", "mir", "die", "der", "das", "den", "dem", "ein", "eine", "meine", "mein", "alle", "was",
        "wann", "wer", "hat", "ist", "mit", "für", "und", "oder", "im", "le", "la", "les", "des", "du", "un", "une",
        "mes", "mon", "ma", "montre", "moi", "quoi", "qui", "quand", "est", "et", "ou", "pour", "avec", "el", "los",
        "las", "una", "mis", "mi", "muéstrame", "muestra", "qué", "quién", "cuándo", "para", "con", "os", "as",
        "uma", "meus", "minhas", "mostre", "mostra", "quem", "quando", "com", "todos", "todas",
    ]
}
