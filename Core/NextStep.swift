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
        let host = (url.host ?? "").lowercased().replacingPattern(#"^www\."#, with: "")
        if host.patternRange(#"^(click|clicks|track|tracking|links?|email|e|l|t|r|go|trk|mail|em|url\d*|ablink|ct)\.|^(track|click|trk|link)[a-z0-9]{0,4}\.|pstmrk|sendgrid|awstrack|sailthru|list-manage|mailchimp|hubspotlinks|mandrillapp|mcsv\.net|exacttarget|rs6\.net|cmail\d*\.com"#) != nil { return "" }
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
            if isDesigned, anchor.patternRange(salesButton) != nil { continue }
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

    private static let salesButton = #"(?i)\b(now|today|sign ?up|subscribe|shop|buy|deals?|offer|save|earn|join|explore|discover|learn more|get started|download|upgrade|jetzt|heute|kaufen|shoppen|entdecken|maintenant|acheter|découvrir|ahora|comprar|descubrir|agora|এখনই|কিনুন)\b|今すぐ|購入|지금|구매|立即购买|马上|購買"#

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
                    .replacingPattern(#"<[^>]+>"#, with: " "))
                    .replacingPattern(#"\s+"#, with: " ")
                let start = html.index(hrefRange.lowerBound, offsetBy: -min(600, html.distance(from: html.startIndex, to: hrefRange.lowerBound)))
                let before = decodeEntities(String(html[start..<hrefRange.lowerBound])
                    .replacingPattern(#"<[^>]*>?"#, with: " "))
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
        if whole.patternRange(#"\.(png|jpe?g|gif|svg|webp)(\?|$)"#) != nil { return false }
        return true
    }

    /// The action a sentence or link names: "book", "pay", "track".
    static func actionVerb(in text: String) -> String? {
        let lower = text.lowercased()
        for (pattern, verb) in actionPatterns where lower.patternRange(pattern) != nil {
            return verb
        }
        return nil
    }

    /// Each step in English and the app's other languages: "Termin
    /// buchen", "payer", "rastrear", "予約する", "배송 조회", "查看物流",
    /// "পরিশোধ করুন".
    private static let actionPatterns: [(String, String)] = [
        (#"\b(book|booking|schedule|reschedule|buchen|termin vereinbaren|réserver|prendre rendez-vous|reservar|agendar|marcar consulta|বুক করুন)\b|予約|예약|预约|預約"#, "book"),
        (#"\b(update|fix|change) (your )?(payment|card|billing)( (method|info(rmation)?|details))?\b|\b(zahlungsmethode (aktualisieren|ändern)|mettre à jour (votre )?(moyen de paiement|carte)|actualizar (el )?(método de pago|tarjeta)|atualizar (a )?(forma de pagamento|cartão))\b|お支払い方法(を)?(更新|変更)|결제 ?수단 ?(변경|업데이트)|更新(付款|支付)方式"#, "update"),
        (#"\b(pay|payment due|make a payment|bezahlen|jetzt zahlen|payer|régler|pagar|pague|পরিশোধ করুন|পেমেন্ট করুন)\b|お支払い(手続き|はこちら)|支払う|결제하기|납부하기|立即(支付|付款)|去支付|去付款"#, "pay"),
        (#"\b(track|tracking|sendung verfolgen|verfolgen|suivre (mon|votre|le) colis|suivi|rastrear|rastreio|seguimiento|seguir (mi|el) pedido|ট্র্যাক করুন)\b|追跡|配送状況|배송 ?조회|查看物流|物流(详情|詳情)|追踪"#, "track"),
        (#"\b(confirm|confirmation required|bestätigen|confirmer|confirmar|নিশ্চিত করুন)\b|確認する|확인하기|确认|確認"#, "confirm"),
        (#"\b(verify|verification|verifizieren|vérifier|verificar|যাচাই করুন)\b|認証|인증하기|验证|驗證"#, "verify"),
        (#"\b(sign the|e-?sign|docusign|signature|unterschreiben|signer|firmar|assinar|স্বাক্ষর করুন)\b|署名|서명하기|签署|簽署"#, "sign"),
        (#"\b(rsvp|respond to (the )?invitation|zusagen|répondre à l'invitation|confirmar asistencia|confirmar presença)\b|出欠|참석 ?여부|回复邀请"#, "rsvp"),
        (#"\b(register|sign up|enrol|enroll|registrieren|anmelden|s'inscrire|inscribirse|registrarse|inscrever-se|cadastrar|নিবন্ধন করুন)\b|登録|등록하기|가입하기|注册|註冊|报名|報名"#, "register"),
        (#"\b(reset (your )?password|passwort zurücksetzen|réinitialiser (le |votre )?mot de passe|restablecer (la |tu )?contraseña|redefinir (a )?senha|পাসওয়ার্ড রিসেট)\b|パスワード(を)?(再設定|リセット)|비밀번호 ?재설정|重置密码|重設密碼"#, "reset"),
        (#"\b(complete (your|the)|fill (in|out)|ausfüllen|remplir|completar|preencher|পূরণ করুন)\b|入力する|작성하기|填写|填寫"#, "complete"),
        (#"\b(check[- ]?in|einchecken|s'enregistrer|hacer check-in|fazer check-in|চেক-ইন)\b|チェックイン|체크인|值机|辦理登機|办理登机"#, "checkin"),
        (#"\b(view|see) (your )?(order|receipt|invoice|statement|bill|results?|booking|reservation|appointment)\b|\b(bestellung ansehen|rechnung ansehen|voir (la |votre )?(commande|facture)|ver (el |tu |su |o |seu )?(pedido|factura|fatura|recibo))\b|注文(内容)?を確認|주문 ?(내역|확인)|查看订单|查看訂單|查看账单"#, "view"),
        (#"\b(review|approve|prüfen|genehmigen|approuver|revisar|aprobar|aprovar|অনুমোদন করুন)\b|承認|승인하기|审批|審批|批准"#, "review"),
        (#"\b(join (the )?(meeting|call|zoom|webinar)|meeting beitreten|rejoindre la réunion|unirse a la reunión|participar da reunião|মিটিংয়ে যোগ দিন)\b|会議に参加|회의 ?참가|회의 ?참여|加入会议|加入會議"#, "join"),
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
              anchor.patternRange(#"https?://|www\.|\.com\b"#, caseInsensitive: true) == nil else { return false }
        return !["here", "click here", "link", "this link", "tap here", "more", "hier", "hier klicken", "ici", "cliquez ici",
                 "aquí", "haga clic aquí", "aqui", "clique aqui", "こちら", "ここ", "여기", "这里", "這裡", "এখানে"].contains(anchor.lowercased())
    }

    private static func anchorLabel(_ anchor: String) -> String {
        let trimmed = anchor.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "›»→>")))
        // "BOOK NOW" reads as "Book now".
        let cased = trimmed == trimmed.uppercased() ? trimmed.lowercased() : trimmed
        return cased.prefix(1).uppercased() + cased.dropFirst()
    }

    private static func lastSentence(of text: String) -> String {
        let cleaned = text.replacingPattern(#"\s+"#, with: " ")
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
    public static func glance(text: String, subject: String = "", kind: Kind, html: String? = nil) -> Glance? {
        guard [.receipt, .shipping, .notification].contains(kind) else { return nil }
        let lines = text.split(separator: "\n").map {
            String($0).replacingPattern(#"\s+"#, with: " ").trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }
        // A short label alone on its line, its amount on the next, joined.
        var merged: [String] = []
        for line in lines {
            if let last = merged.last, wordCount(last) <= 6, !last.contains(where: \.isNumber) || last.count < 40,
               line.patternRange("^(" + amountPattern + #")(\s+[A-Z]{3})?$"#) != nil {
                merged[merged.count - 1] = last + " " + line
            } else {
                merged.append(line)
            }
        }
        let body = String(merged.joined(separator: "\n").prefix(8_000))

        // What happened, in the same few words whoever sent it.
        let top = subject + "\n" + merged.prefix(25).joined(separator: "\n")
        var status = statusRules.first { top.matchesAny($0.patterns) }
        // A receipt, by its own subject, is for something paid.
        if status == nil, subject.patternRange(#"(?i)\breceipt\b|領収書|영수증|收据|收據|রসিদ"#) != nil {
            status = StatusRule(patterns: [], label: "Paid", isAlert: false)
        }
        // The order data the sender embedded for mail apps says it
        // exactly, in any language (schema.org ParcelDelivery and Order).
        let structured = html.flatMap(structuredOrder(in:))
        if let label = structured?.status {
            status = StatusRule(patterns: [], label: label, isAlert: label == "Delivery problem")
        }

        var facts: [Glance.Fact] = []
        if let amount = firstFact(in: body, labels: paidLabels) ?? firstFact(in: body, labels: dueLabels)
            ?? firstFact(in: body, labels: totalLabels) ?? cardCharge(in: body) ?? proseAmount(in: body)
            // Last resort: a bare "Amount: Tk 1,250" (bKash, Nagad, bank
            // alerts), then "paid Tk 1,250", when nothing names it better.
            ?? firstFact(in: body, labels: "amount|betrag|montant|importe|valor|金額|금액|金额|পরিমাণ")
            ?? firstFact(in: body, labels: "paid") {
            facts.append(amount)
        }
        if let date = firstFact(in: body, labels: dateLabels, value: datePattern) { facts.append(date) }
        if let reference = firstFact(in: body, labels: referenceLabels, value: #"#?\s*((?=[A-Z0-9-]*\d)[A-Z0-9][A-Z0-9-]{3,})\b"#) {
            facts.append(reference)
        } else if let number = structured?.orderNumber {
            facts.append(Glance.Fact(label: "Order", value: number))
        }
        // A status alone, or a single figure without one, isn't a card.
        guard facts.count >= (status == nil ? 2 : 1) else { return nil }
        return Glance(status: status?.label, isAlert: status?.isAlert ?? false, facts: Array(facts.prefix(3)))
    }

    /// A delivery's or order's status and number from its schema.org data
    /// (`ParcelDelivery`, `Order`), the way Gmail reads it.
    static func structuredOrder(in html: String) -> (status: String?, orderNumber: String?)? {
        for item in EventFinder.structuredItems(in: html) {
            let type = (item["@type"] as? String) ?? ""
            guard type == "ParcelDelivery" || type == "Order" else { continue }
            let order = (item["partOfOrder"] as? [String: Any]) ?? item
            let statusURL = (item["deliveryStatus"] as? String) ?? (item["orderStatus"] as? String)
                ?? (order["orderStatus"] as? String) ?? ((item["deliveryStatus"] as? [String: Any])?["@id"] as? String) ?? ""
            let status: String? = switch statusURL.split(separator: "/").last.map(String.init) ?? "" {
            case "OrderDelivered": "Delivered"
            case "OrderInTransit": "On its way"
            case "OrderProblem": "Delivery problem"
            case "OrderPaymentDue": "Payment due"
            case "OrderProcessing": "Order confirmed"
            default: nil
            }
            let number = (order["orderNumber"] as? String) ?? (item["trackingNumber"] as? String)
            if status != nil || number != nil { return (status, number) }
        }
        return nil
    }

    /// "Amount paid $18.50", "Total: £14.62": the label as written, the
    /// value after it.
    private static func firstFact(in text: String, labels: String, value: String? = nil) -> Glance.Fact? {
        // Not inside a longer Latin word ("Subtotal"); Chinese and Japanese
        // labels follow other characters directly ("今回のご請求金額：").
        let pattern = #"(?i)(?<!\p{Latin})("# + labels + #")\s*[:：\-–—]?\s*"# + (value ?? "(" + amountPattern + ")")
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
        guard let range = text.patternRange(pattern),
              let amount = text[range].patternRange(amountPattern) else { return nil }
        return Glance.Fact(label: "Charged", value: String(text[range][amount]))
    }

    /// "your recent payment of $9.99", "a charge of €40".
    private static func proseAmount(in text: String) -> Glance.Fact? {
        let pattern = #"(?i)\b(payment|charge|bill|balance|refund) of ("# + amountPattern + ")"
        guard let range = text.patternRange(pattern),
              let amount = text[range].patternRange(amountPattern) else { return nil }
        let noun = text[range].split(separator: " ").first.map { $0.lowercased() } ?? "amount"
        return Glance.Fact(label: noun == "refund" ? "Refund" : "Amount", value: String(text[range][amount]))
    }

    private struct StatusRule { let patterns: [String]; let label: String; let isAlert: Bool }

    /// Problems first: a failed payment's email also says "receipt". Each
    /// status in English and the app's other languages ("Zahlung
    /// fehlgeschlagen", "a été livré", "en reparto", "saiu para entrega",
    /// "発送しました", "배송 완료", "已签收", "ডেলিভারি করা হয়েছে"), so a
    /// delivery from Japan or a bill from Germany gets the same card.
    private static let statusRules: [StatusRule] = [
        .init(patterns: [#"(?i)\b(payment|charge|card|transaction)\b[^\n.]{0,40}\b(failed|declined|unsuccessful|did ?n[o']t go through)\b|\b(unable|couldn'?t|could not|were not able) (to )?(process|charge|complete)\b[^\n.]{0,30}\b(payment|card|charge)|\bfailed payment\b|\bpayment failure\b"#,
                         #"(?i)\b(zahlung (ist |wurde )?(fehlgeschlagen|abgelehnt)|abbuchung fehlgeschlagen|paiement (a )?(échoué|été refusé|refusé)|échec (du|de votre) paiement|pago (rechazado|fallido|ha fallado)|no (hemos podido|pudimos) procesar (su|tu) pago|pagamento (recusado|não aprovado|falhou)|পেমেন্ট ব্যর্থ|লেনদেন ব্যর্থ)\b"#,
                         #"お支払いに失敗|決済(に失敗|エラー)|결제(에)? ?실패|결제가 거절|(支付|付款|扣款)失(败|敗)"#],
              label: "Payment failed", isAlert: true),
        .init(patterns: [#"(?i)\b(delivery|package|parcel|shipment)\b[^\n.]{0,30}\b(failed|delayed|exception|attempted)\b|\bunable to deliver\b|\bmissed (your )?delivery\b|\breturned to sender\b"#,
                         #"(?i)\b(zustellung (fehlgeschlagen|nicht möglich)|zustellversuch|konnte nicht zugestellt|échec de (la )?livraison|livraison (a échoué|impossible)|entrega (fallida|fracasada)|no (hemos podido|pudimos) entregar|tentativa de entrega|não foi possível entregar|ডেলিভারি ব্যর্থ)\b"#,
                         #"配達できませんでした|ご不在|배송 ?(실패|지연)|배달 ?실패|派送失(败|敗)|配送(异常|異常)"#],
              label: "Delivery problem", isAlert: true),
        .init(patterns: [#"(?i)\b(overdue|past due|late fee|überfällig|zahlungsverzug|mahnung|impayé|en retard de paiement|pago vencido|pagamento (em atraso|atrasado)|fatura vencida)\b"#, #"延滞|연체|逾期"#],
              label: "Overdue", isAlert: true),
        .init(patterns: [#"(?i)\b(was|been|has been|is) delivered\b|^delivered\b"#,
                         #"(?i)\b((wurde|ist) (erfolgreich )?zugestellt|zugestellt am|wurde geliefert|(a été|est) livrée?s?|livrée? le|(ha sido|fue) entregado|pedido entregado|foi entregue|pedido entregue|ডেলিভারি করা হয়েছে|পৌঁছে গেছে)\b"#,
                         #"配達(が)?完了|お届け(が)?完了|配達しました|배송 ?완료|배달 ?완료|已(签收|簽收|送达|送達)"#],
              label: "Delivered", isAlert: false),
        .init(patterns: [#"(?i)\bout for delivery\b"#,
                         #"(?i)\b(in zustellung|wird heute zugestellt|heute zugestellt|en cours de livraison|en reparto|saiu para entrega|ডেলিভারির পথে|আজ ডেলিভারি)\b"#,
                         #"配達中|本日お届け|배송 ?출발|배달 ?중|派送中|派件中"#],
              label: "Out for delivery", isAlert: false),
        .init(patterns: [#"(?i)\b(has|have|was|been) (shipped|dispatched|picked up)\b|\bon (its|the) way\b"#,
                         #"(?i)\b((wurde|ist) (versandt|verschickt|versendet)|ist unterwegs|(a été|est) expédiée?s?|colis expédié|en route|en camino|(ha sido|fue) enviado|pedido enviado|(foi|já foi) (enviado|despachado)|pedido (foi )?enviado|a caminho|পাঠানো হয়েছে)\b"#,
                         #"発送(しました|済み|完了)|出荷(しました|完了)|配送中|배송(이)? ?(시작|중)|발송(되었|완료)|已(发货|發貨)|(运输|運輸)中"#],
              label: "On its way", isAlert: false),
        .init(patterns: [#"(?i)\brefund(ed| (has been |was )?(issued|processed))\b"#,
                         #"(?i)\b(rückerstattung (wurde |ist )?(veranlasst|erfolgt|bearbeitet)|wurde erstattet|remboursement (effectué|émis|traité)|a été remboursée?|reembolso (procesado|emitido|realizado|processado|efetuado)|reembolsado|টাকা ফেরত দেওয়া হয়েছে)\b"#,
                         #"返金(しました|完了|処理)|환불 ?(완료|처리)|退款(成功|完成)|已退款"#],
              label: "Refunded", isAlert: false),
        .init(patterns: [#"(?i)\b(payment (request|reminder|due)|amount due|bill is ready|statement is ready|rent (is )?due)\b"#,
                         #"(?i)\b(zahlungserinnerung|zahlung fällig|fälliger betrag|ihre rechnung ist (da|verfügbar)|paiement dû|montant dû|facture disponible|pago pendiente|importe a pagar|factura disponible|pagamento pendente|fatura disponível|boleto disponível|বিল পরিশোধ|বকেয়া পরিমাণ)\b"#,
                         #"お支払い期限|ご請求金額|請求書(発行|のお知らせ)|납부 ?(기한|요청|안내)|청구서|(应付|應付)金额|待付款|(账单|帳單)已出"#],
              label: "Payment due", isAlert: false),
        .init(patterns: [#"(?i)\b(payment (received|confirmed|successful|processed)|successfully (processed|paid)|thank you for your payment|receipt from)\b"#,
                         #"(?i)\b(zahlung (erhalten|bestätigt|erfolgreich|eingegangen)|dank für ihre zahlung|paiement (reçu|confirmé|accepté)|merci pour votre paiement|pago (recibido|confirmado|realizado)|gracias por (su|tu) pago|pagamento (recebido|confirmado|aprovado)|obrigad[oa] pelo (seu )?pagamento|পেমেন্ট সফল|পরিশোধ সম্পন্ন)\b"#,
                         #"お支払い(完了|ありがとう)|決済完了|ご入金(確認|ありがとう)|결제(가)? ?완료|납부(가)? ?완료|(支付|付款)成功|已付款"#],
              label: "Paid", isAlert: false),
        .init(patterns: [#"(?i)\b(order (confirmed|received|placed)|we got your order|thanks? (you )?for your order)\b"#,
                         #"(?i)\b(bestellbestätigung|bestellung (eingegangen|bestätigt)|dank für ihre bestellung|confirmation de commande|commande (confirmée|reçue)|merci pour votre commande|confirmación de pedido|pedido confirmado|gracias por (su|tu) (pedido|compra)|confirmação (do|de) pedido|obrigad[oa] pel[oa] (sua |seu )?(pedido|compra)|অর্ডার নিশ্চিত)\b"#,
                         #"ご注文(ありがとう|確認|を承りました)|注文確定|주문 ?(완료|확인)|주문해 주셔서 감사|(订单|訂單)已(确认|確認)|下(单|單)成功|感谢您的订单"#],
              label: "Order confirmed", isAlert: false),
    ]

    private static let paidLabels = #"amount paid|total paid|amount charged|total charged|you paid|charged|initial charge|bezahlter betrag|gezahlt|montant payé|importe pagado|valor pago|お支払い金額|결제 ?금액|(?:支付|实付|實付)金额|實付金額|পরিশোধিত"#
    private static let dueLabels = #"amount due|total due|balance due|minimum (?:payment )?due|payment due|amount owed|balance|fälliger betrag|offener betrag|montant dû|importe a pagar|valor a pagar|ご請求金額|請求金額|청구 ?금액|납부 ?금액|(?:应付|應付)金额|應付金額|বকেয়া"#
    private static let totalLabels = #"grand total|order total|trip total|total|gesamtbetrag|gesamtsumme|summe|montant total|importe total|valor total|合計(?:金額)?|합계|총 ?금액|总计|總計|合计|মোট"#
    private static let dateLabels = #"due date|due on|due by|pay by|payment due(?: date)?|estimated delivery(?: date)?|expected delivery|delivery date|arriving(?: on| by)?|arrives(?: on| by)?|renews on|expires on|fällig am|zahlbar bis|lieferdatum|voraussichtliche (?:lieferung|zustellung)|date d'échéance|livraison prévue|fecha de vencimiento|entrega estimada|vencimento|previsão de entrega|お支払い期限|お届け予定日?|납부 ?기한|도착 ?예정일?|截止日期|(?:预计|預計)送达|預計送達|শেষ তারিখ"#
    private static let referenceLabels = #"order(?: number| no\.?| #| id)?|confirmation(?: number| code)?|booking(?: reference| number)?|reservation(?: number)?|invoice(?: number| no\.?| id)?|receipt(?: number| #)?|tracking(?: number| #)?|case(?: number| #)?|bestellnummer|rechnungsnummer|sendungsnummer|numéro de (?:commande|suivi|facture)|número de (?:pedido|seguimiento|factura)|número do pedido|código de rastreio|注文番号|追跡番号|주문 ?번호|운송장 ?번호|(?:订单|訂單)(?:号|號|编号|編號)|(?:运单|運單)(?:号|號)|অর্ডার নম্বর|ট্র্যাকিং নম্বর"#
    /// "Thu, 15 Oct", "October 20, 2026", "20 October 2026", "10/20/2026",
    /// and the app's other languages: "12. November 2026", "12 novembre",
    /// "12 de noviembre de 2026", "15.10.2026", "2026年11月12日", "11월 12일",
    /// "১২ নভেম্বর".
    private static let datePattern = #"((?:(?:mon|tue|wed|thu|fri|sat|sun)[a-z]*\.?,?\s+)?(?:\d{1,2}(?:st|nd|rd|th)?\s+(?:jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?|(?:jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?\s+\d{1,2}(?:st|nd|rd|th)?)(?:,?\s+\d{4})?|\d{1,2}\.?\s+(?:de\s+)?(?:januar|februar|märz|mai|juni|juli|oktober|dezember|janvier|février|mars|avril|juin|juillet|août|septembre|octobre|novembre|décembre|enero|febrero|marzo|abril|mayo|junio|julio|agosto|septiembre|octubre|noviembre|diciembre|janeiro|fevereiro|março|maio|junho|julho|setembro|outubro|novembro|dezembro)(?:\s+(?:de\s+)?\d{4})?|\d{1,2}\.\d{1,2}\.\d{2,4}|\d{4}-\d{2}-\d{2}|(?:\d{4}\s?年\s?)?\d{1,2}\s?月\s?\d{1,2}\s?日|(?:\d{4}\s?년\s?)?\d{1,2}\s?월\s?\d{1,2}\s?일|\d{1,2}\s?(?:জানুয়ারি|ফেব্রুয়ারি|মার্চ|এপ্রিল|মে|জুন|জুলাই|আগস্ট|সেপ্টেম্বর|অক্টোবর|নভেম্বর|ডিসেম্বর)(?:,?\s?\d{4})?|\d{1,2}/\d{1,2}(?:/\d{2,4})?)"#
}

extension Glance {
    /// A status, figure or step label Corres wrote, in the reader's
    /// language. Kept in English underneath (Purchases sorts by it); a
    /// label copied from the email itself passes through as written.
    public static func display(_ label: String) -> String { displayLabels[label] ?? label }

    private static let displayLabels: [String: String] = [
        "Payment failed": String(localized: "Payment failed"),
        "Delivery problem": String(localized: "Delivery problem"),
        "Overdue": String(localized: "Overdue"),
        "Delivered": String(localized: "Delivered"),
        "Out for delivery": String(localized: "Out for delivery"),
        "On its way": String(localized: "On its way"),
        "Refunded": String(localized: "Refunded"),
        "Payment due": String(localized: "Payment due"),
        "Paid": String(localized: "Paid"),
        "Order confirmed": String(localized: "Order confirmed"),
        "Charged": String(localized: "Charged"),
        "Refund": String(localized: "Refund"),
        "Amount": String(localized: "Amount"),
        "Order": String(localized: "Order"),
        "Book": String(localized: "Book"),
        "Pay": String(localized: "Pay"),
        "Update payment": String(localized: "Update payment"),
        "Track package": String(localized: "Track package"),
        "Confirm": String(localized: "Confirm"),
        "Verify": String(localized: "Verify"),
        "Sign": String(localized: "Sign"),
        "RSVP": String(localized: "RSVP"),
        "Register": String(localized: "Register"),
        "Reset password": String(localized: "Reset password"),
        "Complete it": String(localized: "Complete it"),
        "Check in": String(localized: "Check in"),
        "View": String(localized: "View"),
        "Review": String(localized: "Review"),
        "Join": String(localized: "Join"),
    ]
}
