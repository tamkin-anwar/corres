import Foundation

/// A plain-text email, made into a page the reading view shows like any
/// other: the same typography, Dark mode, tappable links, addresses and
/// phone numbers, pinch to zoom, and the quoted history folded away.
/// Shown as bare text before, its links did nothing and every reply
/// repeated the whole conversation in `>` lines.
public enum PlainTextEmail {
    /// The class on the quoted history (attribution line and quote), which
    /// the reading view folds like a Gmail or Mail quote.
    public static let quoteClass = "corres-quote"

    public static func html(from text: String) -> String {
        let lines = unwrapped(text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init))
        let trimmed = Array(lines.drop { $0.trimmingCharacters(in: .whitespaces).isEmpty }
            .reversed().drop { $0.trimmingCharacters(in: .whitespaces).isEmpty }.reversed())
        return #"<div class="corres-plain-text" style="white-space: pre-wrap">"# + render(trimmed) + "</div>"
    }

    /// Lines as HTML, `>` quotes as nested `<blockquote type="cite">` (the
    /// form Mail itself sends), with the "On … wrote:" line that
    /// introduces a quote kept with it.
    static func render(_ lines: [String]) -> String {
        var output: [String] = []
        var index = 0
        while index < lines.count {
            guard isQuoted(lines[index]) else {
                // The attribution line(s) right before a quote go with it.
                if let span = attributionSpan(at: index, in: lines) {
                    let attribution = lines[index..<index + span].map(escape).joined(separator: "\n")
                    index += span
                    let quoted = takeQuote(from: &index, in: lines)
                    output.append(#"<div class="\#(quoteClass)">"# + attribution + "\n"
                                  + #"<blockquote type="cite">"# + render(quoted) + "</blockquote></div>")
                    continue
                }
                output.append(escape(lines[index]))
                index += 1
                continue
            }
            let quoted = takeQuote(from: &index, in: lines)
            output.append(#"<blockquote type="cite">"# + render(quoted) + "</blockquote>")
        }
        // Block elements end their own line.
        return output.joined(separator: "\n").replacingOccurrences(of: "</blockquote>\n", with: "</blockquote>")
            .replacingOccurrences(of: "</div>\n", with: "</div>")
    }

    private static func isQuoted(_ line: String) -> Bool { line.hasPrefix(">") }

    /// Consecutive quoted lines, one level of `>` removed. Blank lines
    /// between two quoted lines belong to the quote.
    private static func takeQuote(from index: inout Int, in lines: [String]) -> [String] {
        var quoted: [String] = []
        while index < lines.count {
            let line = lines[index]
            if isQuoted(line) {
                var rest = line.dropFirst()
                if rest.hasPrefix(" ") { rest = rest.dropFirst() }
                quoted.append(String(rest))
                index += 1
            } else if line.trimmingCharacters(in: .whitespaces).isEmpty,
                      index + 1 < lines.count, isQuoted(lines[index + 1]), !quoted.isEmpty {
                quoted.append("")
                index += 1
            } else {
                break
            }
        }
        return quoted
    }

    /// "On Tue, Oct 7, 2026 at 3:12 PM Maya <maya@example.com> wrote:",
    /// which Gmail often breaks over two lines, directly followed by `>`
    /// lines (blank lines between allowed).
    private static func attributionSpan(at index: Int, in lines: [String]) -> Int? {
        for span in 1...2 where index + span <= lines.count {
            let text = lines[index..<index + span].joined(separator: " ").trimmingCharacters(in: .whitespaces)
            guard QuoteDetector.isAttribution(text) else { continue }
            var next = index + span
            while next < lines.count, lines[next].trimmingCharacters(in: .whitespaces).isEmpty { next += 1 }
            return next < lines.count && isQuoted(lines[next]) ? next - index : nil
        }
        return nil
    }

    /// Text hard-wrapped at about 72 characters (most plain-text mail
    /// software, and format=flowed) read as ragged half-lines on a phone.
    /// Its paragraphs are joined back up; lists, quotes and short lines
    /// keep their breaks.
    static func unwrapped(_ lines: [String]) -> [String] {
        let body = lines.filter { !isQuoted($0) && $0.count > 40 }
        let nearWrap = body.filter { (60...80).contains($0.count) }
        let flowed = lines.contains { $0.hasSuffix(" ") && $0 != "-- " && !isQuoted($0) }
        let hardWrapped = body.count >= 3 && nearWrap.count * 2 >= body.count && body.allSatisfy { $0.count <= 80 }
        guard hardWrapped || flowed else { return lines }
        var result: [String] = []
        for line in lines {
            if let last = result.last, joins(last, line, flowedOnly: !hardWrapped) {
                let left = last.hasSuffix(" ") ? last : last + " "
                result[result.count - 1] = left + line
            } else {
                result.append(line)
            }
        }
        return result.map { $0 == "-- " ? $0 : $0.replacingPattern(#" +$"#, with: "") }
    }

    private static func joins(_ previous: String, _ line: String, flowedOnly: Bool) -> Bool {
        guard !isQuoted(previous), !isQuoted(line), previous != "-- ",
              let first = line.first, !first.isWhitespace else { return false }
        if line.patternRange(#"^([-*•+]\s|\d{1,2}[.)]\s|--\s?$)"#) != nil { return false }
        if previous.hasSuffix(" ") { return true }
        return !flowedOnly && previous.count >= 50 && !previous.hasSuffix(":")
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

/// Where the quoted history starts in a plain-text email, in the forms
/// mail apps write it around the world. One reading for every place that
/// needs it (Needs You, summaries, earlier messages, drafts), so an email
/// from Berlin or Dhaka is read the same way as one from Boston: before,
/// only "On … wrote:" in English counted, and a question in a quoted
/// German or Chinese email put the reply in Needs You.
public enum QuoteDetector {
    /// "On Tue, Oct 7, 2026 at 3:12 PM Maya <maya@example.com> wrote:" and
    /// its forms in other languages: "Le … a écrit :", "Am … schrieb Maya
    /// <…>:", "El … escribió:", "Em … escreveu:", "Il giorno … ha scritto:",
    /// "Op … schreef …:", "W dniu … napisał(a):".
    static let leadInAttribution = #"^(On|Le|Am|El|Em|Il( giorno)?|Op|W dniu|Den|På|Dne)\s.{4,}?\s(wrote|a écrit|schrieb|escribió|escreveu|ha scritto|scritto|schreef|napisał(\(a\))?|skrev|kirjoitti)\b[^\n]{0,160}?\s?[:：]\s*$"#

    /// Attributions that end with the verb, with the date or address
    /// before it: Gmail's Chinese "Maya <maya@…> 于2026年10月12日周一
    /// 10:00写道：", Korean "…, Maya <maya@…>님이 작성:", Japanese "…が書き
    /// ました:" or Mail's "…のメール:", Bengali "… লিখেছেন:", and an English
    /// "Maya Smith <maya@example.com> wrote:".
    static let verbLastAttribution = #"^.{0,250}?(写道|寫道|が書きました|のメッセージ|のメール|작성|লিখেছেন|wrote|a écrit|schrieb|escribió|escreveu|ha scritto|schreef)\s?[:：]\s*$"#

    /// Gmail's Japanese attribution has no verb at all: "2026年10月12日(月)
    /// 10:00 Maya <maya@example.com>:".
    static let dateAddressAttribution = #"^\d{4}\s?[年/.\-]\s?\d{1,2}\s?[月/.\-]\s?\d{1,2}.{0,200}@[^\s>]+>?\s?[:：]\s*$"#

    /// "-----Original Message-----" and "---------- Forwarded message
    /// ---------" as Outlook, Gmail and Mail write them in each language,
    /// Apple Mail's "Begin forwarded message:", and Outlook's underscore
    /// rule.
    static let separatorPattern = #"(?i)^(-{2,}\s*(original message|ursprüngliche nachricht|message d'origine|mensaje original|mensagem original|messaggio originale|oorspronkelijk bericht|originalmeddelande|原始邮件|原始郵件|元のメッセージ|원본 메시지|forwarded message|weitergeleitete nachricht|message transféré|mensaje reenviado|mensagem encaminhada|messaggio inoltrato|doorgestuurd bericht|转发的邮件|轉寄的郵件|転送されたメッセージ|전달된 메일|전달된 메시지|ফরওয়ার্ড করা মেসেজ)|(begin forwarded message|anfang der weitergeleiteten nachricht|début du message (réexpédié|transféré)|inicio del mensaje reenviado|início da mensagem (encaminhada|reencaminhada)|转发的邮件|以下是转发的邮件|転送されたメッセージ|전달된 메시지 시작)\s?[:：]|_{10,}$)"#

    /// The first line of a header block quoting an earlier email: "From:",
    /// "Von:", "De :", "Da:", "Van:", "差出人:", "发件人：", "보낸 사람:".
    static let headerFrom = #"^\*?(From|Von|De|Da|Van|Od|Från|Fra|Lähettäjä|差出人|发件人|發件人|寄件者|寄件人|보낸 사람|보낸사람|প্রেরক)\s?\*?\s?[:：]"#

    /// The lines that follow it: "Sent:", "Gesendet:", "Envoyé :",
    /// "Enviado:", "送信日時:", "发送时间：", "날짜:", "Subject:", "件名:".
    static let headerField = #"^\s*\*?(Sent|Date|To|Cc|Subject|Gesendet|Datum|An|Betreff|Envoyé|À|Objet|Enviado|Enviada|Fecha|Para|Asunto|Assunto|Inviato|Data|A|Oggetto|Verzonden|Aan|Onderwerp|Skickat|Ämne|送信日時|日時|宛先|件名|发送时间|發送時間|时间|日期|收件人|收件者|主题|主旨|날짜|보낸 날짜|받는 사람|제목|তারিখ|প্রাপক|বিষয়)\s?\*?\s?[:：]"#

    /// Whether `text` (one line, or a wrapped one joined with spaces) is
    /// the line that introduces a quote.
    public static func isAttribution(_ text: String) -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count <= 400, text.last == ":" || text.last == "：" else { return false }
        if text.patternRange(leadInAttribution) != nil { return true }
        if text.patternRange(dateAddressAttribution) != nil { return true }
        // Without a lead-in word, only with the date or address that mail
        // apps put there: "Here's what she wrote:" is not a quote.
        return text.patternRange(verbLastAttribution) != nil && text.contains(where: { $0.isNumber || $0 == "@" })
    }

    /// Whether the quoted history starts at `lines[index]`: an attribution
    /// (which Gmail may wrap over two or three lines), a header block, or
    /// a separator.
    public static func startsQuote(_ lines: [String], at index: Int) -> Bool {
        // Lines may end in "\r" (mail sent with CRLF line ends).
        let line = lines[index].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return false }
        if line.patternRange(separatorPattern) != nil { return true }
        // A wrapped attribution's first line starts like one (a lead-in
        // word, the date, the address) and runs straight on: never "Hi"
        // above a blank line, or "谢谢。" ending a sentence.
        let wraps = line.last.map({ !".!?。！？".contains($0) }) == true
            && (line.contains(where: { $0.isNumber || $0 == "@" || $0 == "<" }) || line.patternRange(#"^(On|Le|Am|El|Em|Il|Op|W dniu|Den|På|Dne)\s"#) != nil)
        for span in 1...3 where index + span <= lines.count {
            let window = lines[index..<index + span].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            if span > 1, !wraps || window.contains(where: \.isEmpty) { break }
            if isAttribution(window.joined(separator: " ")) { return true }
        }
        // Two of its fields below, as every mail app writes: "Von: 9 Uhr /
        // Bis: 17 Uhr / Datum: Montag" in an event's details is not one.
        if line.patternRange(headerFrom) != nil {
            let fields = lines[(index + 1)..<min(lines.count, index + 5)].filter { $0.patternRange(headerField) != nil }
            if fields.count >= 2 { return true }
        }
        return false
    }

    /// The writer's own words: everything above the quoted history, and
    /// no `>` lines.
    public static func ownPart(of text: String) -> String {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var kept: [String] = []
        for index in lines.indices {
            if lines[index].trimmingCharacters(in: .whitespaces).hasPrefix(">") { continue }
            if startsQuote(lines, at: index) { break }
            kept.append(lines[index])
        }
        return kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Where the quoted history starts in a draft or a sent email,
    /// including the blank lines above it, so what comes before is exactly
    /// the writer's own part. Nil when nothing is quoted.
    public static func quoteStart(in text: String) -> String.Index? {
        var lineStart = text.startIndex
        var lines: [String] = []
        var starts: [String.Index] = []
        while lineStart <= text.endIndex {
            let lineEnd = text[lineStart...].firstIndex(of: "\n") ?? text.endIndex
            lines.append(String(text[lineStart..<lineEnd]))
            starts.append(lineStart)
            guard lineEnd < text.endIndex else { break }
            lineStart = text.index(after: lineEnd)
        }
        guard let found = lines.indices.first(where: { startsQuote(lines, at: $0) }) else { return nil }
        // Back over the blank lines above it.
        var start = starts[found]
        while start > text.startIndex, text[text.index(before: start)].isWhitespace {
            start = text.index(before: start)
        }
        return start
    }
}

/// Subject lines without the "Re:" and "Fwd:" that replies and forwards
/// pile up, in every language's form: German "AW:" and "WG:", French
/// "TR:", Spanish "RV:", Italian "R:" and "Rif:", Polish "Odp:", Chinese
/// "回复：", Japanese "返信:", Korean "답장:", and Outlook's "RE[2]:".
/// Before, a German reply's subject became "Re: AW: Angebot".
public enum MailSubject {
    static let prefixPattern = #"(?i)^\s*((re|aw|antw|sv|vs|r|rif|tr|wg|fw|fwd|enc|rv|odp|回复|答复|回覆|転送|返信|전달|답장)\s*(\[\d+\])?\s*[:：]\s*)+"#

    /// "AW: WG: Angebot" → "Angebot".
    public static func base(_ subject: String) -> String {
        subject.replacingPattern(prefixPattern, with: "").trimmingCharacters(in: .whitespaces)
    }

    /// The subject for a reply: one "Re: " in front of the base subject.
    public static func reply(_ subject: String) -> String { "Re: " + base(subject) }

    static let forwardPrefixPattern = #"(?i)^\s*((tr|wg|fw|fwd|enc|rv|転送|转发|轉寄|전달)\s*(\[\d+\])?\s*[:：]\s*)+"#

    /// The subject for a forward: one "Fwd: " in front, any forward prefix
    /// ("WG:", "TR :", "転送:") folded into it. A reply's "Re:" stays, as
    /// Gmail and Mail keep it: "Fwd: Re: Plans" says it was a conversation.
    public static func forward(_ subject: String) -> String {
        "Fwd: " + subject.replacingPattern(forwardPrefixPattern, with: "").trimmingCharacters(in: .whitespaces)
    }

    /// Whether two subjects are the same conversation's, prefixes aside.
    public static func sameConversation(_ a: String, _ b: String) -> Bool {
        base(a).caseInsensitiveCompare(base(b)) == .orderedSame
    }
}
