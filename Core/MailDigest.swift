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
        let isPlaceholder = plain.patternRange(#"(?i)(not support|unable to (display|view)|can'?t (display|see)|view (it|this( email)?) (online|in (a|your) browser)|html (formatted )?(e-?mail|version))"#) != nil && wordCount(plain) < 400
        if wordCount(plain) >= 60 && !isPlaceholder { return plain }
        let converted = text(fromHTML: html)
        if isPlaceholder, !converted.isEmpty { return converted }
        return wordCount(converted) > wordCount(plain) ? converted : plain
    }

    /// The list preview, from the email itself once its body is here: the
    /// writer's own words, without image captions ("Remitly logo Account
    /// Arrow"), hidden preheaders, quoted history or signatures, and with
    /// words from separate blocks kept apart ("Role" "The", not "RoleThe").
    /// Providers' snippets are cut from raw HTML and keep all of that. Nil
    /// when the email has too little of its own to say.
    public static func preview(body: String, html: String?) -> String? {
        let words = clean(readableText(body: body, html: html))
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .replacingPattern(#"\s{2,}"#, with: " ")
        guard words.count >= 20 else { return nil }
        guard words.count > 240 else { return words }
        // Chinese and Japanese have no spaces to cut at: without one, the
        // whole email became its preview.
        guard let cut = words.prefix(240).lastIndex(of: " "), words.distance(from: words.startIndex, to: cut) >= 120 else {
            return String(words.prefix(240))
        }
        return String(words[..<cut])
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
        for pattern in removals { text = text.replacingPattern(pattern, with: " ") }
        text = text.replacingPattern(#"(?i)<br\s*/?>"#, with: "\n")
        text = text.replacingPattern(#"(?i)</(p|div|tr|li|h[1-6]|table|blockquote|section|article)>"#, with: "\n")
        text = text.replacingPattern(#"(?i)<li\b[^>]*>"#, with: "\n• ")
        text = text.replacingPattern(#"(?i)</t[dh]>"#, with: " ")
        // A quoted attribute can hold a ">" (an image's alt text with "<br>"
        // in it); a plain <[^>]+> stopped there and left CSS in the text.
        text = text.replacingPattern(#"<(?:[^>"']|"[^"]*"|'[^']*')*>"#, with: " ")
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
            if line.patternRange(cutFromPattern) != nil
                || line.patternRange(MailSignals.legalNoticePattern) != nil { break }
            if line.patternRange(MailSignals.protectiveMarkingLine) != nil { index += 1; continue }
            if line.patternRange(dropLinePattern) != nil { index += 1; continue }
            kept.append(lines[index])
            index += 1
        }
        var result = kept.joined(separator: "\n")
        // Links carry no meaning for a summary; "(https://…)" and "<https://…>"
        // wrappers go with them.
        result = result.replacingPattern(#"[(<\[]\s*https?://[^\s)>\]]+\s*[)>\]]"#, with: "")
        result = result.replacingPattern(#"https?://\S+"#, with: "")
        return tidy(result)
    }

    /// "On Mon, Sep 28 … wrote:" (often wrapped over two or three lines by
    /// Gmail), Outlook's "From: / Sent:" block, its underscore rule, and
    /// forwarded or original-message markers, in every language mail apps
    /// write them (`QuoteDetector`).
    private static func startsQuotedHistory(_ lines: [String], at index: Int) -> Bool {
        QuoteDetector.startsQuote(lines, at: index)
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
        cleaned = cleaned.replacingPattern(#"[ \t]+"#, with: " ")
        let lines = cleaned.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        var result: [String] = []
        for line in lines where !(line.isEmpty && (result.last?.isEmpty ?? true)) { result.append(line) }
        return result.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Words as a reader counts them, in any script. Chinese, Japanese and
    /// Thai put no spaces between words, so by spaces a whole paragraph was
    /// one "word": a long Chinese email never got a summary, and a short
    /// one with a signature logo read as an image-only flyer. There each
    /// character counts for part of a word: about 1.7 Han or kana
    /// characters, or 3.5 Thai letters, to a word, the averages for those
    /// languages. Korean spaces its words, so it counts as written.
    public static func wordCount(_ text: some StringProtocol) -> Int {
        var words = 0
        var inWord = false, wordHasContent = false
        var unspaced = 0.0
        for character in text {
            if character.isWhitespace {
                if inWord, wordHasContent { words += 1 }
                inWord = false; wordHasContent = false
                continue
            }
            if let weight = unspacedWeight(character) {
                unspaced += weight
                continue
            }
            inWord = true
            if character.isLetter || character.isNumber { wordHasContent = true }
        }
        if inWord, wordHasContent { words += 1 }
        return words + Int(unspaced.rounded())
    }

    /// How much of a word one character of a language written without
    /// spaces is, or nil for every other script.
    static func unspacedWeight(_ character: Character) -> Double? {
        guard let scalar = character.unicodeScalars.first, scalar.value >= 0x0E00 else { return nil }
        switch scalar.value {
        case 0x3040...0x30FF, 0x31F0...0x31FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0xFF66...0xFF9F,
             0x20000...0x2FA1F:
            return 0.6
        case 0x0E00...0x0EFF, 0x1000...0x109F, 0x1780...0x17FF:
            // Thai, Lao, Myanmar, Khmer.
            return 0.3
        default:
            return nil
        }
    }

    /// Whether `character` is in a script written without spaces between
    /// words (Chinese, Japanese, Thai).
    static func isUnspaced(_ character: Character) -> Bool { unspacedWeight(character) != nil }

    public static func isWorthSummarizing(_ cleanedText: String) -> Bool {
        wordCount(cleanedText) >= minimumWords
    }

    /// Whether a summary only says what the email's opening already says,
    /// so it would repeat the first lines shown right below it. Judged by
    /// meaning words (word roots, so "booking" matches "book"), against the
    /// opening of the email.
    public static func restatesOpening(_ summary: String, of text: String, openingWords: Int = 70) -> Bool {
        // Chinese and Japanese have no spaces to count by: about 1.7
        // characters a word (`wordCount`).
        let opening = text.contains(where: isUnspaced) ? String(text.prefix(openingWords * 2))
            : text.split(whereSeparator: \.isWhitespace).prefix(openingWords).joined(separator: " ")
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
        // A code email is short and says so up top; a newsletter with
        // "code:" somewhere in a story is not one. Counted only to 301.
        // Counted over the start only: enough for 300 words in any script.
        let words = wordCount(text.prefix(4_000))
        if words <= 300, verificationCode(in: subject + "\n" + text.prefix(400)) != nil { return .code }
        if labelIds.contains("CATEGORY_PROMOTIONS") { return .newsletter }
        // The subject says what an email is; its body only does near the
        // top of a short one. A newsletter's article about deliveries or
        // "your order" isn't a receipt (Morning Brew, TLDR, LinkedIn were).
        let opening = MailSignals.oneBengaliSpelling(subject + "\n" + (wordCount(text) <= 300 ? String(text.prefix(400)) : ""))
        if opening.matchesAny(shippingCue) { return .shipping }
        if opening.matchesAny(receiptCue) { return .receipt }
        // Calendar invitations and replies, as Google Calendar and Outlook
        // title them in each language.
        if hasEvent || subject.patternRange(#"(?i)^(invitation|updated invitation|accepted|declined|einladung|aktualisierte einladung|angenommen|abgelehnt|invitation mise à jour|accepté|refusé|invitación|invitación actualizada|aceptado|rechazado|convite|convite atualizado|aceito|recusado|招待|更新された招待|承諾|辞退|초대|업데이트된 초대|수락|거절|邀请|更新的邀请|已接受|已拒绝|আমন্ত্রণ)\s?[:：]"#) != nil {
            return .invite
        }
        if !isBulk && !looksAutomated { return .personal }
        // Updates are notices unless they read like an issue of something.
        // In real mail, notices and receipts run under ~450 words; Morning
        // Brew, TLDR and LinkedIn's newsletters run 850 to 3,300.
        if labelIds.contains("CATEGORY_UPDATES") { return wordCount(text) > 600 ? .newsletter : .notification }
        return isBulk && wordCount(text) > 120 ? .newsletter : .notification
    }

    /// A delivery, in English and the app's other languages: "wurde
    /// versandt", "en cours de livraison", "ha sido enviado", "saiu para
    /// entrega", "発送しました", "배송 중", "已发货", "ডেলিভারি করা হয়েছে".
    /// Never a bare "enviado", which is also "sent" ("Enviado desde mi
    /// iPhone").
    static let shippingCue: [String] = [
        #"(?i)\b(has shipped|have shipped|out for delivery|was delivered|been delivered|tracking (number|#)|on (its|the) way|estimated delivery|arriving (today|tomorrow|on)|picked up)\b"#,
        #"(?i)\b((wurde|ist|wird) (versandt|verschickt|versendet|zugestellt)|ist unterwegs|in zustellung|zustellung (heute|morgen)|sendungsverfolgung|sendungsnummer|voraussichtliche (lieferung|zustellung))\b"#,
        #"(?i)\b((a été|est) (expédiée?s?|livrée?s?)|en cours de (livraison|acheminement)|numéro de suivi|livraison prévue|colis (expédié|livré|en route))\b"#,
        #"(?i)\b((ha sido|fue) (enviado|entregado)|pedido (enviado|entregado)|en camino|en reparto|número de seguimiento|entrega (estimada|prevista))\b"#,
        #"(?i)\b((foi|já foi) (enviado|entregue|despachado)|pedido (enviado|entregue)|a caminho|saiu para entrega|(código|número) de rastreamento|código de rastreio|previsão de entrega)\b"#,
        #"(?i)\b(পাঠানো হয়েছে|ডেলিভারি করা হয়েছে|ডেলিভারির পথে|পৌঁছে গেছে|ট্র্যাকিং নম্বর)\b"#,
        #"(?i)発送(しました|済み|のお知らせ|完了)|出荷(しました|完了|のお知らせ)|配達(完了|中|予定)|お届け(予定|しました|完了)|追跡番号|お問い合わせ伝票番号|배송(이)? ?(시작|중|완료|출발)|배달 ?완료|발송(되었|완료)|운송장 ?번호|송장 ?번호|도착 ?예정|已(发货|發貨|签收|簽收|送达|送達)|派送中|派件中|(运单|運單|快递单|快遞單)号|预计送达|預計送達"#,
    ]

    /// A receipt, an order or a bill, in English and the app's other
    /// languages: "Rechnung", "Bestellbestätigung", "votre commande",
    /// "confirmación de pedido", "nota fiscal", "領収書", "주문 확인",
    /// "订单确认", "রসিদ".
    static let receiptCue: [String] = [
        #"(?i)\b(receipt|order (confirmation|confirmed|number|#|summary)|your order|invoice|payment (received|confirmation|confirmed|of|failed|declined|request|reminder)|payment (has|was) (failed|declined)|you paid|amount (paid|charged|due)|total charged|has been charged|billing statement|transaction|your (ride|trip) (with|to|on)|rent payment|statement is (ready|available)|bill is ready)\b"#,
        #"(?i)\b(rechnung|quittung|bestellbestätigung|ihre bestellung|bestellnummer|zahlungsbestätigung|zahlung (erhalten|eingegangen|fehlgeschlagen)|zahlungserinnerung|kontoauszug)\b"#,
        #"(?i)\b(votre reçu|reçu de paiement|facture|confirmation de (commande|paiement)|votre commande|numéro de commande|paiement (reçu|confirmé|refusé)|relevé)\b"#,
        #"(?i)\b(recibo|factura|confirmación de (pedido|pago|compra)|(tu|su) pedido|número de pedido|pago (recibido|confirmado|rechazado)|estado de cuenta)\b"#,
        #"(?i)\b(fatura|nota fiscal|confirmação (do|de) (pedido|pagamento|compra)|seu pedido|número do pedido|pagamento (recebido|confirmado|aprovado|recusado)|comprovante|extrato)\b"#,
        #"(?i)\b(রসিদ|অর্ডার নিশ্চিত|অর্ডার নম্বর|পেমেন্ট সফল|পেমেন্ট ব্যর্থ|লেনদেন|বিল)\b"#,
        #"(?i)領収書|請求書|ご注文(確認|内容|ありがとう)|注文番号|お支払い(完了|確認|金額)|決済完了|ご請求|ご利用明細|영수증|주문 ?(확인|번호|내역)|결제(가|에)? ?(완료|금액|내역|실패)|청구서|이용 ?내역|收据|收據|发票|發票|(订单|訂單)(确认|確認|号|號|编号|編號)|(支付|付款)(成功|失败|失敗)|账单|帳單|交易"#,
    ]

    // MARK: - Facts

    /// A one-time code: 4 to 8 digits (or a short letter/digit mix) close
    /// to words that say it's a code.
    /// A one-time code's words, in English (with India's "OTP" and "one
    /// time password") and the app's other languages: "Bestätigungscode",
    /// "code de vérification", "código de verificación", "código de
    /// verificação", "認証コード", "인증번호", "验证码", "যাচাইকরণ কোড".
    static let codeCue: [String] = [
        // A bare "Code:" (French writes "code :"), but never a shop's
        // "Promo code: FALL25", which put a sale in Primary as a sign-in.
        #"(?i)\b(verification|security|login|log-in|sign[- ]?in|one[- ]time|2fa|two-factor|access|authentication|otp)\s+(code|pin|passcode)\b|\byour (code|passcode|pin|otp) is\b|"#
            + notASignInCode + #"\bcode\s?[:：]\s|\botp\b|\bone[- ]time[- ]pass(word|code)\b"#,
        #"(?i)\b((tu|su|seu|sua|ihr|dein|votre|ton) (código|code) (es|é|lautet|ist|est)|bestätigungscode|sicherheitscode|verifizierungscode|anmeldecode|einmalcode|code de (vérification|confirmation|sécurité|connexion)|código de (verificación|verificação|seguridad|segurança|acceso|acesso|confirmación|confirmação)|codice di verifica|verificatiecode|যাচাইকরণ কোড|যাচাই কোড|ওটিপি)\b"#,
        #"(?i)認証コード|確認コード|ワンタイムパスワード|セキュリティコード|인증 ?번호|인증 ?코드|확인 ?코드|보안 ?코드|验证码|驗證碼|校验码|校驗碼|动态密码|動態密碼"#,
    ]

    /// Codes that are no sign-in: a shop's discount, and the codes of an
    /// address, a parcel or a booking ("ZIP code: 94105").
    private static let notASignInCode = #"(?<!promo |promotional |promotion |discount |coupon |voucher |gift |card |referral |offer |reward |rewards |redemption |sale |bonus |zip |postal |post |area |country |tracking |booking |reservation |product |item |style )"#

    public static func verificationCode(in text: String) -> String? {
        // "482913 is your OTP for…", as Indian and Bangladeshi banks write
        // it, and "123456 is your Instagram code", "G-482913 is your Google
        // verification code", with the service's name in between.
        if let before = text.patternRange(#"(?i)(?<![\d.,])\d{4,8}(?=\s+is\s+(your|the)\s+([\p{L}\p{N}&'.-]+\s+){0,2}(otp|one[- ]time|verification|security|login|sign[- ]?in|confirmation|code|passcode)\b)"#) {
            return String(text[before])
        }
        guard let cue = text.firstPatternRange(codeCue) else { return nil }
        let window = String(text[cue.lowerBound..<(text.index(cue.upperBound, offsetBy: 120, limitedBy: text.endIndex) ?? text.endIndex)])
        // Digits right after a CJK word have no word boundary ("验证码
        // 482913"), so the digits are bounded by what isn't a digit.
        guard let regex = PatternCache.shared.regex(#"\b(?=[A-Z0-9-]*\d)[A-Z0-9]{3,4}-?[A-Z0-9]{2,4}\b|(?<![\d.,])\d{4,8}(?![\d.,]?\d)"#,
                                                    caseInsensitive: false) else { return nil }
        let ns = window as NSString
        for match in regex.matches(in: window, range: NSRange(location: 0, length: ns.length)) {
            // "Your verification code expires on Oct 25, 2026. Code:
            // 482913": the year of a date is never the code.
            let before = ns.substring(to: match.range.location)
            if ns.substring(with: match.range).patternRange(#"^(19|20)\d\d$"#) != nil,
               before.patternRange(yearOfDateLeadIn, caseInsensitive: true) != nil { continue }
            return ns.substring(with: match.range)
        }
        return nil
    }

    /// What comes before the year of a written date: "Oct 25, ", "25
    /// October ", "25/10/".
    private static let yearOfDateLeadIn = #"((jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?\s+\d{1,2}(st|nd|rd|th)?,?|\d{1,2}(st|nd|rd|th)?\s+(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?,?|\d{1,2}[/.\-]\d{1,2}[/.\-])\s*$"#

    /// Facts already in the email, exactly as written, for the model to
    /// quote rather than retype: amounts, codes, order/booking numbers and
    /// dates. At most eight, in the order they appear.
    /// An amount of money in any currency, written any way: a currency
    /// symbol (Unicode's whole currency category: $ € £ ¥ ৳ ₹ ₦ ₱ ₩ …) or
    /// ISO code (every one iOS knows, plus "Tk" and "Rs"), before or after
    /// a number in any grouping style.
    /// The currency written as a word after the number counts too: "500円",
    /// "5,000원", "88元", "20块", "1,250 টাকা", "৳1,250", "Rs. 1,500/-" (the
    /// Indian and Bangladeshi "only" mark), "RMB 300".
    /// A dollar sign keeps the letters that say whose dollar it is: "R$"
    /// (Brazil), "C$", "A$", "US$", "HK$". Without them, "R$ 1.250,00"
    /// was handed on as "$ 1.250,00", in US dollars.
    /// Thousands grouped with a space count whole: "1 250,00 €" (France,
    /// and any amount once HTML's non-breaking space is a plain one) was
    /// "250,00 €".
    static let amountPattern: String = {
        let codes = (Locale.Currency.isoCurrencies.map(\.identifier) + ["Tk", "Rs", "Tsh", "Ksh", "RMB"]).joined(separator: "|")
        let number = #"(?:\d{1,3}(?:[ \u00A0\u202F]\d{3})+(?:[.,]\d{1,2})?(?!\d)|\d(?:[\d.,'\u00A0\u202F]*\d)?)"#
        let words = #"円|원|元|块|塊|人民币|人民幣|টাকা|রুপি|/-"#
        return #"(?:(?<![\p{L}\p{N}])[A-Z]{1,3})?\p{Sc}\s?"# + number + #"(?:/-)?|\b(?:"# + codes + #")\.?\s?"# + number + #"(?:/-)?"#
            + #"|"# + number + #"\s?(?:\p{Sc}|\b(?:"# + codes + #")\b|"# + words + #")"#
    }()

    /// Whether `text` is an amount of money, in any currency and form.
    public static func isAmount(_ text: String) -> Bool { text.patternRange(amountPattern) != nil }

    /// Which currencies an amount can be in, by the sign, code or word
    /// written with it: "R$" is only Brazil's real, "$" any dollar or
    /// peso, "¥" the yen or the yuan, "Tk" and "৳" the taka. Nil when it
    /// names none ("1,500/-").
    static func currencies(ofAmount amount: some StringProtocol) -> Set<String>? {
        let marker = currencyMarker(String(amount).filter { !$0.isNumber })
        guard !marker.isEmpty else { return nil }
        return currencyMarkers[marker] ?? localeCurrencySigns[marker] ?? [marker]
    }

    /// A currency sign or code as `currencyMarkers` keys it: without
    /// spaces, dots and the "/-" mark, full-width signs as plain ones.
    private static func currencyMarker(_ text: some StringProtocol) -> String {
        String(text.filter { !$0.isWhitespace && !".,'/-".contains($0) })
            .replacingOccurrences(of: "＄", with: "$").replacingOccurrences(of: "￥", with: "¥")
    }

    /// Every currency code iOS knows, and the signs and words mail writes
    /// most, with the currencies each can mean ("$" is a dollar or a
    /// peso in the locales that write it so; "US$", "Tk", "円" and "RMB"
    /// are written in mail but no locale's sign). Rarer signs are read
    /// from the locales (`localeCurrencySigns`).
    static let currencyMarkers: [String: Set<String>] = {
        var markers: [String: Set<String>] = [:]
        for code in Locale.Currency.isoCurrencies.map(\.identifier) { markers[code, default: []].insert(code) }
        let written: [String: [String]] = [
            "$": ["USD", "CAD", "AUD", "NZD", "HKD", "SGD", "TWD", "MXN", "ARS", "CLP", "COP", "UYU", "CUP", "BBD", "BMD",
                  "BND", "BSD", "BZD", "FJD", "GYD", "JMD", "KYD", "LRD", "NAD", "SBD", "SRD", "TTD", "XCD"],
            "€": ["EUR"], "£": ["GBP", "GIP", "FKP", "SHP", "SSP"],
            "US$": ["USD"], "C$": ["CAD"], "CA$": ["CAD"], "A$": ["AUD"], "AU$": ["AUD"], "NZ$": ["NZD"], "HK$": ["HKD"],
            "S$": ["SGD"], "NT$": ["TWD"], "MX$": ["MXN"], "R$": ["BRL"], "Tk": ["BDT"], "টাকা": ["BDT"], "৳": ["BDT"],
            "Rs": ["INR", "PKR", "LKR", "NPR", "MUR", "SCR"], "রুপি": ["INR", "PKR", "LKR", "NPR"], "₹": ["INR"],
            "Tsh": ["TZS"], "Ksh": ["KES"], "RMB": ["CNY"], "人民币": ["CNY"], "人民幣": ["CNY"], "元": ["CNY"], "块": ["CNY"],
            "塊": ["CNY"], "円": ["JPY"], "원": ["KRW"], "₩": ["KRW"], "¥": ["JPY", "CNY"],
        ]
        for (marker, codes) in written { markers[marker, default: []].formUnion(codes) }
        return markers
    }()

    /// Each locale's own currency sign ("₦" in Nigeria, "₱" in the
    /// Philippines, "kr" in Sweden and Norway), read only when an amount
    /// carries a sign `currencyMarkers` doesn't have: reading every
    /// locale takes a quarter of a second.
    private static let localeCurrencySigns: [String: Set<String>] = {
        var signs: [String: Set<String>] = [:]
        for identifier in Locale.availableIdentifiers {
            let locale = Locale(identifier: identifier)
            guard let code = locale.currency?.identifier, let symbol = locale.currencySymbol else { continue }
            let marker = currencyMarker(symbol)
            if !marker.isEmpty { signs[marker, default: []].insert(code) }
        }
        return signs
    }()

    /// Where `text` names an amount (`amountPattern`). In capital text a
    /// currency written only as its code needs a money label before it or
    /// cents after: there "TOP 10" (Tonga's pa'anga) and "ALL 3" (Albania's
    /// lek) are words. The glance card reads codes with their case for
    /// the same reason (`caseSensitiveAmount`), which capitals get past.
    static func amountRanges(in text: String) -> [Range<String.Index>] {
        text.regexRanges(of: amountPattern).filter { range in
            let marker = currencyMarker(text[range].filter { !$0.isNumber })
            guard !marker.isEmpty, marker.allSatisfy({ $0.isASCII && $0.isLetter }) else { return true }
            let lineStart = text[..<range.lowerBound].lastIndex(of: "\n").map { text.index(after: $0) } ?? text.startIndex
            let lineEnd = text[range.upperBound...].firstIndex(of: "\n") ?? text.endIndex
            let around = text[lineStart..<range.lowerBound] + text[range.upperBound..<lineEnd]
            if around.contains(where: \.isLowercase) { return true }
            if text[range].patternRange(#"\d[.,]\d{2}(/-)?$"#) != nil { return true }
            let before = text[text.index(range.lowerBound, offsetBy: -min(40, text.distance(from: text.startIndex, to: range.lowerBound)))..<range.lowerBound]
            return before.patternRange(#"(?i)\b(total|subtotal|amount|balance|price|fee|cost|charged?|due|sum|betrag|summe|gesamt|montant|prix|importe|monto|precio|valor|preço)\s*[:：\-–—]?\s*$"#) != nil
        }
    }

    /// Each amount in `text`, with its value (`canonicalNumber`) and the
    /// currencies it can be in.
    private static func amounts(in text: String) -> [(text: String, value: String, currencies: Set<String>?)] {
        amountRanges(in: text).compactMap { range in
            let written = String(text[range])
            // Thousands grouped with a space count whole ("1 250,00 €").
            guard let value = numberTokens(in: written.replacingOccurrences(of: " ", with: "\u{00A0}")).first else { return nil }
            return (written, value, currencies(ofAmount: written))
        }
    }

    public static func facts(in text: String) -> [String] {
        let source = String(text.prefix(8_000))
        var found: [(Int, String)] = []
        func add(_ range: Range<String.Index>) {
            let value = String(source[range]).trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters.subtracting(.init(charactersIn: "#"))))
            guard !value.isEmpty, !found.contains(where: { $0.1 == value }) else { return }
            found.append((source.distance(from: source.startIndex, to: range.lowerBound), value))
        }
        for range in amountRanges(in: source) { add(range) }
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
        let own = QuoteDetector.ownPart(of: body)
        // "Anbei", "ci-joint", "adjunto", "em anexo", "添付", "첨부", "附件",
        // "সংযুক্ত" in the app's other languages.
        return own.patternRange(#"(?i)\b(attached|attaching|attachments?|enclosed|pfa|please find (the )?(attached|enclosed)|anbei|angehängt|im anhang|ci-joint|pièces? jointes?|en pièce jointe|adjunto|adjunta|en el adjunto|em anexo|segue anexo|anexado|সংযুক্ত)\b|添付|첨부|附件"#) != nil
            && own.patternRange(#"(?i)\b(no|without( an?)?|forgot (the|to)) attach"#) == nil
    }

    /// An alert confirming something you just did ("You allowed Corres
    /// access", "New sign-in on iPhone") whose only ask is conditional: act
    /// if it wasn't you. Worth seeing, never a to-do on its own; an
    /// on-device model once promoted one as "unauthorized access claim
    /// requires verification".
    /// Kept per text: asked of every conversation the model brought into
    /// Needs You, on every pass.
    public static func isConfirmationAlert(_ text: String) -> Bool {
        confirmationMemo.value(text) {
            text.patternRange(#"(?i)\b(if (you|this) (didn\S{0,5}t|did not|wasn\S{0,5}t|was not|don\S{0,5}t recogni[sz]e)|if this was you|wasn\S{0,5}t you\?)"#) != nil
        }
    }
    private static let confirmationMemo = Memo<String, Bool>()

    public static func unsupportedClaims(in summary: String, source: String) -> [String] {
        let lowerSource = source.lowercased()
        var unsupported: [String] = []

        // Numbers match whole, never inside a longer one: "28" isn't
        // supported by "$1,284.63". Compared as values, in any locale:
        // "1,250.00", "1.250,00", "1,25,000"-style grouping and Bengali or
        // Arabic digits all read the same (`canonicalNumber`).
        let sourceAmounts = amounts(in: source)
        let sourceNumbers = Set(numberTokens(in: lowerSource)).union(sourceAmounts.map(\.value))
        for token in numberTokens(in: summary) where !sourceNumbers.contains(token) {
            // "3:00" is supported by a bare "3" ("3pm").
            if token.hasSuffix(":00"), sourceNumbers.contains(String(token.dropLast(3))) { continue }
            unsupported.append(token)
        }
        // An amount needs the email's currency too: "$1,250" is not
        // supported by "R$ 1.250,00", which is Brazilian reais. A figure
        // the email gives without a currency stays supported.
        for amount in amounts(in: summary) {
            guard let currencies = amount.currencies else { continue }
            let same = sourceAmounts.filter { $0.value == amount.value }
            if !same.isEmpty, !same.contains(where: { $0.currencies.map { !$0.isDisjoint(with: currencies) } ?? true }) {
                unsupported.append(amount.text)
            }
        }
        let words = summary.split(whereSeparator: { !$0.isLetter && $0 != "'" && $0 != "’" })
        for word in words {
            let lower = word.lowercased()
            if let stem = calendarStems[lower], !lowerSource.contains(stem) { unsupported.append(String(word)) }
            if relativeDays.contains(lower), !containsWord(lower, in: lowerSource) { unsupported.append(String(word)) }
        }
        // Names: capitalized words not starting a sentence. Not in German,
        // where every noun is capitalized ("Rechnung", "Termin").
        let sentences = NLLanguageRecognizer.dominantLanguage(for: summary) == .german ? []
            : summary.split(whereSeparator: { ".!?;:\n".contains($0) })
        for sentence in sentences {
            let tokens = sentence.split(separator: " ").map { $0.trimmingCharacters(in: .punctuationCharacters) }
            for token in tokens.dropFirst() where token.count >= 3 {
                guard let first = token.first, first.isUppercase else { continue }
                // "Ultra's" is supported by "Ultra".
                var lower = token.lowercased()
                for suffix in ["'s", "’s"] where lower.hasSuffix(suffix) { lower = String(lower.dropLast(2)) }
                if commonCapitalized.contains(lower) || calendarStems[lower] != nil { continue }
                // A currency ("BRL", "R$1,250") is checked with its amount above.
                if currencyMarkers[token] != nil || token.patternRange("^(?:" + amountPattern + ")$") != nil { continue }
                if !lowerSource.contains(lower) { unsupported.append(token) }
            }
        }
        // Alarm words only when the email says them: "your debit card was
        // used" is not a "fraud alert", and a reminder isn't "overdue".
        let lowerSummary = summary.lowercased()
        // Likewise outcomes: a job alert is not "you're offered", and a
        // shipping notice is not "refunded".
        for stem in alarmStems + outcomeStems where lowerSummary.contains(stem) && !lowerSource.contains(stem) {
            unsupported.append(stem)
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
    /// Words that raise the alarm, as stems ("unauthori" covers
    /// unauthorized and unauthorised).
    static let alarmStems = ["fraud", "scam", "suspicious", "unauthori", "misuse", "compromis", "hacked", "breach",
                             "stolen", "phishing", "urgent", "overdue", "past due", "declined", "suspend", "locked out",
                             "terminat", "penalt", "legal action", "warrant", "arrest"]

    /// Words that say something happened to the reader.
    static let outcomeStems = ["offer", "approv", "accepted", "hired", "award", "you won", "winner", "selected",
                               "rejected", "denied", "refund", "cancel", "expired"]

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
        text.components(separatedBy: CharacterSet(charactersIn: ".!?;\n•。！？；।"))
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
            guard [.noun, .verb, .adjective].contains(tag), word.count >= minimumLength(of: word),
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

    /// The shortest word worth judging: two characters in Chinese,
    /// Japanese and Korean, where a word is one to three characters
    /// ("合同", "确认"); three elsewhere.
    static func minimumLength(of word: String) -> Int {
        word.contains(where: { isUnspaced($0) || $0.unicodeScalars.first.map { (0xAC00...0xD7A3).contains($0.value) } == true }) ? 2 : 3
    }

    /// What a summary says about an email rather than from it: the act of
    /// writing ("asks", "reminds"), the reader, and the email itself, in
    /// English and the app's other languages.
    private static let describingWords: Set<String> = [
        // German, French, Spanish, Portuguese
        "bittet", "fragt", "erinnert", "schreibt", "teilt", "mitteilung", "möchte", "sagt", "informiert", "schickt",
        "sendet", "e-mail", "nachricht", "demande", "rappelle", "écrit", "indique", "informe", "souhaite", "envoie",
        "partage", "propose", "courriel", "pide", "pregunta", "recuerda", "escribe", "dice", "informa", "quiere",
        "envía", "comparte", "correo", "mensaje", "pede", "pergunta", "lembra", "escreve", "diz", "quer", "envia",
        "compartilha", "mensagem",
        // Chinese and Bengali
        "请求", "询问", "詢問", "提醒", "告知", "表示", "希望", "发送", "發送", "邮件", "郵件", "信息", "消息",
        "অনুরোধ", "জানিয়েছেন", "বলেছেন", "পাঠিয়েছেন", "ইমেইল",
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
            repaired = repaired.replacingPattern(pattern, with: "")
        }
        repaired = repaired.replacingPattern(#"\s+([.,;!?])"#, with: "$1")
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
            if result.patternRange(#"\b"# + escaped + #"\b"#, caseInsensitive: true) != nil { return nil }
        }
        return result
    }

    /// Whether a summary slipped into the sender's voice ("I'd meet at…",
    /// "we'll ship…"); a summary talks to the reader about the email.
    public static func speaksAsSender(_ summary: String) -> Bool {
        summary.patternRange(#"(^|[\s(“"])(I|I'd|I'll|I'm|I've|I’d|I’ll|I’m|I’ve)\b"#) != nil
            || summary.patternRange(#"(?i)\b(we|we'd|we'll|we're|we've|we’d|we’ll|we’re|we’ve|our|ours)\b"#) != nil
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
            || summary.patternRange(#"(?i)\b(a |the )?charge of\b"#) != nil
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
        // Chinese or Japanese runs on without spaces: counted by `wordCount`.
        let letterWords = words.reduce(0) { total, word in
            if word.contains(where: isUnspaced) { return total + wordCount(word) }
            return total + (word.count >= 3 && word.allSatisfy(\.isLetter) ? 1 : 0)
        }
        let hasFigure = point.contains(where: \.isNumber)
        // A real word with a figure ("Tax $0.87 on Sep 27"), else three.
        guard letterWords >= (hasFigure ? 1 : 3) else { return false }
        // A cut-off fragment from the model's notes ("Window. The team…").
        if point.patternRange(#"^\p{L}+\.\s"#) != nil { return false }
        // A bare link or domain says nothing on its own.
        if point.patternRange(#"^\S+\.[a-z]{2,}(/\S*)?$"#, caseInsensitive: true) != nil { return false }
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

    /// Any script's digits as 0–9: "১২৫০" (Bengali) reads as "1250", and
    /// a Han numeral ("三月五日", "周五") too, but only where it stands for
    /// one digit. Not inside a bigger number: "十一" is eleven and "三十"
    /// thirty, which digit by digit were "十1" (November read as January,
    /// and "十二/三" as February 3rd) and "3十". Nor as an hour without a
    /// time of day or minutes: "一時的に" is "for a while", not one o'clock;
    /// "午後三時" and "三時半" are times (`LocalDates.clock` reads the same
    /// way). Keeps the length, so a range in the result is one in `text`.
    static func asciiDigits(_ text: String) -> String {
        guard text.contains(where: { $0.isNumber && !$0.isASCII }) else { return text }
        let characters = Array(text)
        return String(characters.indices.map { index -> Character in
            let character = characters[index]
            guard !character.isASCII, let value = character.wholeNumberValue, (0...9).contains(value),
                  !isHanDigit(character) || readsAsDigit(hanAt: index, in: characters) else { return character }
            return Character(String(value))
        })
    }

    private static func isHanDigit(_ character: Character) -> Bool {
        character.unicodeScalars.first.map { $0.value == 0x3007 || (0x4E00...0x9FFF).contains($0.value) } ?? false
    }

    /// Whether the Han numeral at `index` is a digit on its own (see `asciiDigits`).
    private static func readsAsDigit(hanAt index: Int, in characters: [Character]) -> Bool {
        var start = index, end = index
        while start > 0, isHanDigit(characters[start - 1]), characters[start - 1].wholeNumberValue.map({ $0 < 10 }) == true { start -= 1 }
        while end + 1 < characters.count, isHanDigit(characters[end + 1]), characters[end + 1].wholeNumberValue.map({ $0 < 10 }) == true { end += 1 }
        let bigger: Set<Character> = ["十", "百", "千", "万", "萬", "拾", "佰", "仟", "億", "亿"]
        if start > 0, bigger.contains(characters[start - 1]) { return false }
        guard end + 1 < characters.count else { return true }
        if bigger.contains(characters[end + 1]) { return false }
        // An hour ("三時", "三点"), not hours ("三時間", "三小时").
        guard "時时點点".contains(characters[end + 1]), end + 2 >= characters.count || !"間间".contains(characters[end + 2]) else { return true }
        let before = String(characters[max(0, start - 4)..<start]).trimmingCharacters(in: .whitespaces)
        if ["午前", "午後", "上午", "下午", "中午", "晚上", "早上", "凌晨"].contains(where: before.hasSuffix) { return true }
        let after = String(characters[(end + 2)..<min(characters.count, end + 6)]).trimmingCharacters(in: .whitespaces)
        return after.hasPrefix("半") || after.patternRange(#"^[\d〇一二三四五六七八九十]{1,3}\s?分"#) != nil
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
        text.patternRange(#"\b"# + NSRegularExpression.escapedPattern(for: word) + #"\b"#) != nil
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
        let pressing = asks.first { $0.patternRange(#"\p{Sc}\s?\d|\b\d{1,2}(:\d{2})?\s?(am|pm)\b|\b(due|by|before|deadline|until|tomorrow|today|tonight|monday|tuesday|wednesday|thursday|friday|saturday|sunday)\b"#, caseInsensitive: true) != nil }
        guard let ask = pressing ?? asks.first, let range = text.range(of: ask) else { return nil }
        guard wordCount(String(text[..<range.lowerBound])) >= 40 else { return nil }
        return clipped(ask)
    }

    /// The parts of an email that are about the email or the app, never
    /// what it says: footers, legal lines, app and download prompts.
    static func isBoilerplate(_ sentence: String) -> Bool {
        sentence.patternRange(boilerplatePattern) != nil
    }

    private static let boilerplatePattern = #"(?i)\b(do not reply|don'?t reply|no-?reply|unsubscribe|you('re| are) receiving this|(this|the) (e-?mail|message) (was|is) (sent|intended)|sent to you because|all rights reserved|privacy (policy|notice|statement)|terms (of (use|service)|and conditions)|in (your|a) (web )?browser|having trouble (viewing|seeing)|address book|(email|notification|communication) preferences|download (the|our|your) (app|receipt|invoice|statement|pdf)|pdf format|get the app|app store|google play|follow us|registered (office|in)|company (no|number)|customer service is available)\b|©"#

    /// Questions an email asks to sell or help, not ones it needs answered:
    /// "Want to…?", "Need help?", "Questions?", "Not you?".
    static func isPromptQuestion(_ sentence: String) -> Bool {
        sentence.patternRange(#"(?i)^(want|wanna|need|needing|looking|ready|interested|curious|tired|enjoying|love|loving|did you know|why not|have (any )?questions|got (a )?questions|questions|not you|didn'?t (request|ask|make)|wasn'?t (this )?you|forgot|having (issues|problems|trouble)|can'?t find)\b[^?]{0,90}\?"#) != nil
    }

    /// Real sentences: greetings, pleasantries, sign-offs, bare link labels
    /// and fragments dropped. A sentence ends at ". ! ?" before a space, and
    /// at the full stops of other scripts wherever they are: Chinese and
    /// Japanese "。！？" (no space follows them), Bengali and Hindi "।",
    /// Arabic-script "؟".
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
                } else if "。！？।؟".contains(character) {
                    result.append(current); current = ""
                }
            }
            if !current.isEmpty { result.append(current) }
            return result
        }
        return pieces.map { $0.trimmingCharacters(in: .whitespaces) }.filter { sentence in
            guard wordCount(sentence) >= 4 else { return false }
            return sentence.patternRange(skipSentencePattern) == nil
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
