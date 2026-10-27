import Foundation
import Testing
@testable import CorresCore

/// Corres's plain rules read mail from everywhere it's used: the US,
/// Canada, the UK, Bangladesh, Japan, Korea, China, India, Australia and
/// Europe, with or without Apple Intelligence. Real wording from each.
struct WorldRulesTests {
    private var calendar: Calendar { .current }
    /// Sunday, October 25, 2026, noon.
    private var now: Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: 25, hour: 12))! }

    private func day(_ date: Date?) -> DateComponents? {
        date.map { calendar.dateComponents([.year, .month, .day], from: $0) }
    }
    private func ymd(_ year: Int, _ month: Int, _ day: Int) -> DateComponents {
        DateComponents(year: year, month: month, day: day)
    }

    // MARK: Words in scripts without spaces

    @Test func chineseAndJapaneseWordsAreCounted() {
        #expect(MailDigest.wordCount("Corres is a mail app") == 5)
        // 20 Han characters, about 12 words, not one.
        #expect(MailDigest.wordCount("王总，附件是报价单，请查收。如有问题请随时联系我。") >= 10)
        let long = String(repeating: "我们已经根据您上周提出的意见修改了合同条款，请您在周五之前确认。", count: 6)
        #expect(MailDigest.isWorthSummarizing(long))
        #expect(MailDigest.wordCount("ご確認のほどよろしくお願いいたします。") >= 8)
        #expect(MailDigest.wordCount("ขอบคุณสำหรับอีเมลของคุณ") >= 4)
        // Korean spaces its words.
        #expect(MailDigest.wordCount("회의 자료를 보내 드립니다") == 4)
    }

    @Test func aChineseNoteWithASignatureLogoIsNotAFlyer() {
        let logo = #"<p>王总，附件是报价单，请查收。</p><img src="https://cdn.example.cn/logo.png">"#
        #expect(!Correspondence.isRemoteImageOnly(body: "王总，附件是报价单，请查收。谢谢！", html: logo))
        // A flyer is still a flyer.
        #expect(Correspondence.isRemoteImageOnly(body: "View online", html: #"<img src="https://x.example/sale.jpg">"#))
    }

    @Test func sentencesEndAtEveryScriptsFullStop() {
        let chinese = MailDigest.sentences(in: "我们已经修改了合同条款。请您在周五之前确认最终版本。谢谢！")
        #expect(chinese.count == 2)
        #expect(chinese.first == "我们已经修改了合同条款。")
        let bengali = MailDigest.sentences(in: "আমরা চুক্তির শর্তগুলো পরিবর্তন করেছি। অনুগ্রহ করে শুক্রবারের মধ্যে চূড়ান্ত সংস্করণ নিশ্চিত করুন।")
        #expect(bengali.count == 2)
    }

    @Test func chineseRepliesTeachYourStyle() {
        #expect(WritingStyle.isPersonal("好的，我周五前把报价单发给你。"))
        #expect(WritingStyle.isPersonal("承知しました。金曜日までに資料をお送りします。"))
        #expect(!WritingStyle.isPersonal("https://example.com/aVeryLongTrackingLinkThatGoesOnAndOnForeverAndEver"))
    }

    // MARK: Deadlines

    @Test func theCommonestBillWordingSetsADeadline() {
        let nov5 = ymd(2026, 11, 5)
        for phrase in ["Your payment is due 5 November 2026", "Payment due November 5, 2026",
                       "Amount due on 5 Nov 2026"] {
            #expect(day(MailSignals.deadline(in: phrase, now: now)) == nov5, "\(phrase)")
        }
        #expect(day(MailSignals.deadline(in: "Due: 12 Nov 2026", now: now)) == ymd(2026, 11, 12))
        // Without a year, the next November 5th by the real clock (which is
        // how the date detector reads it), checked eleven days before it.
        let real = Date()
        var next = calendar.date(from: DateComponents(year: calendar.component(.year, from: real), month: 11, day: 5, hour: 12))!
        if next < real { next = calendar.date(byAdding: .year, value: 1, to: next)! }
        let before = next.addingTimeInterval(-11 * 86_400)
        for phrase in ["Due by Nov 5", "pay by November 5"] {
            #expect(day(MailSignals.deadline(in: phrase, now: before)) == day(next), "\(phrase)")
        }
        // "By end of day", "EOD", "COB" before the day.
        for phrase in ["Please send the deck by end of day Nov 5", "Need this EOD Nov 5", "Sign and return by COB on November 5",
                       "Due by the end of the business day on November 5"] {
            #expect(day(MailSignals.deadline(in: phrase, now: before)) == day(next), "\(phrase)")
        }
        #expect(calendar.isDateInTomorrow(MailSignals.deadline(in: "Can you review this by EOD tomorrow?") ?? .distantPast))
    }

    @Test func deadlinesInOtherLanguages() {
        let nov12 = ymd(2026, 11, 12)
        for phrase in ["Bitte bis zum 12.11.2026 überweisen.", "Zahlung fällig am 12.11.2026",
                       "Merci de régler avant le 12 novembre 2026.", "Por favor pague antes del 12 de noviembre de 2026.",
                       "O boleto vence em 12/11/2026.", "11月12日までにお支払いください。", "お支払い期限：2026年11月12日",
                       "11월 12일까지 납부해 주세요.", "请于11月12日前付款。", "截止日期：2026年11月12日",
                       "১২ নভেম্বরের মধ্যে বিল পরিশোধ করুন।"] {
            #expect(day(MailSignals.deadline(in: phrase, now: now, senderEmail: "billing@example.de")) == nov12, "\(phrase)")
        }
        // A date alone is still not a deadline, in any language.
        #expect(MailSignals.deadline(in: "Wir haben uns am 12. November 2026 getroffen.", now: now) == nil)
        #expect(MailSignals.deadline(in: "2026年11月12日に会いました。", now: now) == nil)
    }

    @Test func aNumericDateIsReadTheWayItsWriterMeantIt() {
        let january = calendar.date(from: DateComponents(year: 2026, month: 1, day: 10, hour: 12))!
        let year: TimeInterval = 360 * 86_400
        let text = "Please pay by 03/11/2026."
        // A UK council means the 3rd of November.
        #expect(day(MailSignals.deadline(in: text, now: january, horizon: year, senderEmail: "rates@council.gov.uk")) == ymd(2026, 11, 3))
        #expect(day(MailSignals.deadline(in: text, now: january, horizon: year, senderEmail: "billing@bkash.com.bd")) == ymd(2026, 11, 3))
        // A US agency means March 11th.
        #expect(day(MailSignals.deadline(in: text, now: january, horizon: year, senderEmail: "notices@irs.gov")) == ymd(2026, 3, 11))
        // From a .com, nothing says which: no deadline rather than a wrong one.
        #expect(MailSignals.deadline(in: text, now: january, horizon: year, senderEmail: "billing@example.com") == nil)
        // Unless another date in the same email does.
        let settled = "Invoice date 15/10/2025. Please pay by 03/11/2026."
        #expect(day(MailSignals.deadline(in: settled, now: january, horizon: year, senderEmail: "billing@example.com")) == ymd(2026, 11, 3))
        #expect(MailSignals.numericDateOrder(senderEmail: "x@example.com", text: "Open 24/7, 50/50 split") == nil)
        #expect(MailSignals.numericDateOrder(senderEmail: "x@shop.com.au", text: "") == .dayFirst)
        #expect(MailSignals.numericDateOrder(senderEmail: "x@city.ca.us", text: "") == .monthFirst)
    }

    /// Bengali and Arabic-Indic digits, and the way Japanese, Korean and
    /// Bengali mail says a numeric date is a deadline.
    @Test func numericDatesInOtherScripts() {
        let january = calendar.date(from: DateComponents(year: 2026, month: 1, day: 10, hour: 12))!
        let year: TimeInterval = 360 * 86_400
        #expect(day(MailSignals.deadline(in: "Please pay by ৩১/১২/২০২৬.", now: january, horizon: year,
                                         senderEmail: "bill@desco.org.bd")) == ymd(2026, 12, 31))
        #expect(day(MailSignals.deadline(in: "Please pay by ٣١/١٢/٢٠٢٦.", now: january, horizon: year,
                                         senderEmail: "bill@example.ae")) == ymd(2026, 12, 31))
        // Japanese from a .com: the language says month first, まで says due.
        // With no year the detector reads the next 3/11 by the real clock.
        func monthDay(_ date: Date?) -> [Int]? { date.map { [calendar.component(.month, from: $0), calendar.component(.day, from: $0)] } }
        #expect(monthDay(MailSignals.deadline(in: "書類は3/11(水)までにご提出ください。", now: Date(), horizon: 400 * 86_400,
                                              senderEmail: "info@example.com")) == [3, 11])
        #expect(monthDay(MailSignals.deadline(in: "서류는 3/11까지 제출해 주세요. 감사합니다.", now: Date(), horizon: 400 * 86_400,
                                              senderEmail: "info@example.com")) == [3, 11])
        #expect(day(MailSignals.deadline(in: "অনুগ্রহ করে ০৩/১১/২০২৬ এর মধ্যে বিল পরিশোধ করুন।", now: january, horizon: year,
                                         senderEmail: "info@example.com")) == ymd(2026, 11, 3))
        // Chinese alone doesn't say which (Hong Kong writes the day first).
        #expect(MailSignals.numericDateOrder(byScript: "请在3/11之前提交文件，谢谢。") == nil)
        // A date that only says when something happens is no deadline.
        #expect(MailSignals.deadline(in: "会議は3/11(水)に行います。よろしくお願いします。", now: Date(), horizon: 400 * 86_400,
                                     senderEmail: "info@example.com") == nil)
    }

    // MARK: Needs You

    @Test func asksInEveryLanguage() {
        for text in ["Bitte bestätigen Sie den Termin.", "Kannst du mir die Unterlagen schicken", "Merci de confirmer votre présence.",
                     "Pourriez-vous m'envoyer le contrat", "Por favor, confirme su asistencia.", "Avísame cuando puedas.",
                     "Me avise quando puder.", "Aguardo o seu retorno.", "ご確認ください。", "ご都合はいかがでしょうか",
                     "확인 부탁드립니다.", "회의 시간을 알려 주세요.", "请确认一下合同。", "麻烦您看一下报价。",
                     "অনুগ্রহ করে জানাবেন।", "明天下午可以吗？", "هل يمكنك الحضور؟"] {
            #expect(MailSignals.asksSomething(text), "\(text)")
        }
        // "Please find attached" asks nothing, in any language.
        for text in ["Veuillez trouver ci-joint la facture.", "附件是报价单，请查收。", "Danke, das passt.", "ありがとうございました。"] {
            #expect(!MailSignals.asksSomething(text), "\(text)")
        }
        // Asked to send, submit or sign, as Japanese, Korean and Chinese
        // write it; "please see" and "please note" still ask nothing.
        for text in ["資料を送ってください。", "申請書をご提出ください。", "계약서를 보내 주시기 바랍니다.", "서류 제출 바랍니다.",
                     "请提交报告。", "請簽署合約。"] {
            #expect(MailSignals.asksSomething(text), "\(text)")
        }
        for text in ["詳細は添付をご覧ください。", "참고 바랍니다.", "请查收附件。"] {
            #expect(!MailSignals.asksSomething(text), "\(text)")
        }
    }

    @Test func obligationsFailuresAndPaymentRequestsInEveryLanguage() {
        #expect(MailSignals.isObligation("Ihre Rechnung\nZahlung fällig am 12.11.2026"))
        #expect(MailSignals.isObligation("お支払い期限：2026年11月12日"))
        #expect(MailSignals.isObligation("납부 기한: 11월 12일"))
        #expect(MailSignals.isObligation("缴费通知：请于11月12日前付款"))
        #expect(MailSignals.isObligation("পরিশোধের শেষ তারিখ ১২ নভেম্বর"))
        // A thank-you for a payment is not one.
        #expect(!MailSignals.isObligation("Vielen Dank für Ihre Zahlung. Nächste Zahlung fällig am 12.11.2026"))
        #expect(!MailSignals.isObligation("お支払いありがとうございます。次回のお支払い期限は12月12日です。"))

        for text in ["Ihre Zahlung ist fehlgeschlagen", "Le paiement a échoué", "No pudimos procesar tu pago",
                     "Não foi possível processar o seu pagamento", "お支払いに失敗しました", "결제에 실패했습니다",
                     "您的支付失败", "আপনার পেমেন্ট ব্যর্থ হয়েছে"] {
            #expect(MailSignals.isFailure(text), "\(text)")
        }

        #expect(MailSignals.isPaymentRequest("Offener Betrag: 49,90 €"))
        #expect(MailSignals.isPaymentRequest("今月のご請求金額：5,000円"))
        #expect(MailSignals.isPaymentRequest("应付金额：¥300"))
        #expect(MailSignals.isPaymentRequest("বকেয়া পরিমাণ ৳১,২৫০"))
        // A currency code, as bills in Bangladesh, India and elsewhere write it.
        #expect(MailSignals.isPaymentRequest("Your bill\nAmount due: BDT 2,500. Please make your payment."))
        #expect(MailSignals.isPaymentRequest("Payment requested: Tk 1,250 for your connection"))
        #expect(MailSignals.isPaymentRequest("Amount due: INR 2,499"))
        #expect(!MailSignals.isPaymentRequest("Offener Betrag: 49,90 €. Der Betrag wird per Lastschrift eingezogen."))
    }

    @Test func eventsAreKnownInEveryLanguage() {
        #expect(MailSignals.isEvent("Erinnerung an Ihren Termin"))
        #expect(MailSignals.isEvent("ご予約の確認"))
        #expect(MailSignals.isEvent("진료 예약 안내"))
        #expect(!MailSignals.isEvent("Ihre Rechnung zum Termin"))
    }

    // MARK: Subjects

    @Test func replyAndForwardPrefixesInEveryLanguage() {
        #expect(MailSubject.base("AW: WG: Angebot") == "Angebot")
        #expect(MailSubject.reply("AW: Angebot") == "Re: Angebot")
        #expect(MailSubject.reply("RE: Re[2]: 回复：报价") == "Re: 报价")
        #expect(MailSubject.reply("Re: Re: Lunch") == "Re: Lunch")
        #expect(MailSubject.forward("TR: Réunion") == "Fwd: Réunion")
        #expect(MailSubject.forward("RV: Factura") == "Fwd: Factura")
        #expect(MailSubject.forward("Re: Plans") == "Fwd: Re: Plans")
        #expect(MailSubject.forward("WG: AW: Angebot") == "Fwd: AW: Angebot")
        #expect(MailSubject.reply("返信: 会議の件") == "Re: 会議の件")
        #expect(MailSubject.reply("답장: 회의") == "Re: 회의")
        #expect(MailSubject.reply("Odp: Spotkanie") == "Re: Spotkanie")
        // Outlook in Brazil, Korea and China.
        #expect(MailSubject.reply("RES: Proposta") == "Re: Proposta")
        #expect(MailSubject.reply("회신: 회의") == "Re: 회의")
        #expect(MailSubject.reply("转发：会议纪要") == "Re: 会议纪要")
        #expect(MailSubject.forward("转寄：會議") == "Fwd: 會議")
        #expect(MailSubject.sameConversation("Re: 转发: 会议", "会议"))
        // Words that only start like a prefix stay.
        #expect(MailSubject.reply("Answer: yes") == "Re: Answer: yes")
        #expect(MailSubject.reply("Reunion plans") == "Re: Reunion plans")
        #expect(MailSubject.sameConversation("Fwd: AW: Angebot", "angebot"))
    }

    // MARK: Quoted history

    @Test func quotedHistoryInEveryLanguage() {
        let replies = [
            "Am Mo., 12. Okt. 2026 um 10:00 Uhr schrieb Maya Weber <maya@example.de>:",
            "Le lun. 12 oct. 2026 à 10:00, Maya Weber <maya@example.fr> a écrit :",
            "El lun, 12 oct 2026 a las 10:00, Maya (<maya@example.es>) escribió:",
            "Em seg., 12 de out. de 2026 às 10:00, Maya <maya@example.com.br> escreveu:",
            "Il giorno lun 12 ott 2026 alle ore 10:00 Maya <maya@example.it> ha scritto:",
            "Op ma 12 okt. 2026 om 10:00 schreef Maya <maya@example.nl>:",
            "W dniu 12.10.2026 o 10:00 Maya <maya@example.pl> napisał(a):",
            "Maya <maya@example.cn> 于2026年10月12日周一 10:00写道：",
            "2026年10月12日(月) 10:00 Maya <maya@example.jp>:",
            "2026년 10월 12일 (월) 오전 10:00, Maya <maya@example.kr>님이 작성:",
            "সোম, ১২ অক্টো, ২০২৬ এ ১০:০০ AM এ Maya <maya@example.com.bd> লিখেছেন:",
        ]
        for attribution in replies {
            let body = "Danke, passt.\n\n\(attribution)\n> Kannst du am Freitag?\n> Could you confirm?"
            #expect(MailSignals.ownText(body) == "Danke, passt.\n", "\(attribution)")
            #expect(!MailSignals.asksSomething(body), "\(attribution)")
        }
        // Outlook's header block, in German, Chinese and Japanese, with no ">" lines.
        let blocks = [
            "Von: Maya Weber <maya@example.de>\nGesendet: Montag, 12. Oktober 2026 10:00\nAn: Tamkin\nBetreff: Angebot",
            "发件人: Maya <maya@example.cn>\n发送时间: 2026年10月12日 10:00\n收件人: Tamkin\n主题: 报价",
            "差出人: Maya <maya@example.jp>\n送信日時: 2026年10月12日 10:00\n宛先: Tamkin\n件名: 見積もり",
            "-----Ursprüngliche Nachricht-----\nVon: Maya",
            "-----原始邮件-----\n发件人: Maya",
            "-----Message d'origine-----\nDe : Maya",
        ]
        for block in blocks {
            let body = "Erledigt.\n\n\(block)\n\nKönnen Sie das Angebot bestätigen?"
            #expect(!MailSignals.asksSomething(body), "\(block)")
        }
    }

    @Test func quotesAreFoundInMailWithCRLFLineEnds() {
        let body = "Danke.\r\n\r\nAm Mo., 12. Okt. 2026 um 10:00 Uhr schrieb Maya <maya@example.de>:\r\n> Kannst du kommen?"
        #expect(!MailSignals.asksSomething(body))
    }

    @Test func anEventsDetailsAreNotAQuotedEmail() {
        let details = "Bitte bestätigen Sie die Teilnahme.\nVon: 9 Uhr\nBis: 17 Uhr\nDatum: Montag, 12. November"
        #expect(MailSignals.ownText(details) == details)
    }

    @Test func onlyRealAttributionsStartAQuote() {
        // A sentence, not an attribution.
        #expect(!QuoteDetector.isAttribution("Here's what she wrote:"))
        #expect(!QuoteDetector.isAttribution("他写道："))
        // The writer's own last line stays above a wrapped attribution.
        let body = "谢谢。\nMaya <maya@example.cn> 于2026年10月12日\n周一 10:00写道：\n> 可以吗？"
        #expect(QuoteDetector.ownPart(of: body) == "谢谢。")
    }

    @Test func draftsFindTheirQuoteInAnyLanguage() {
        let draft = "Sounds good.\n\nAm Mo., 12. Okt. 2026 um 10:00 Uhr schrieb Maya <maya@example.de>:\n> Termin?"
        let start = QuoteDetector.quoteStart(in: draft)
        #expect(start.map { String(draft[..<$0]) } == "Sounds good.")
        #expect(QuoteDetector.quoteStart(in: "Just my own words.") == nil)
        let corres = "Hi\n\nOn Tue, Oct 13, 2026 at 9:00 AM, Maya <maya@example.com> wrote:\n> Hello"
        #expect(QuoteDetector.quoteStart(in: corres).map { String(corres[..<$0]) } == "Hi")
    }

    @Test func aKoreanQuoteFoldsInPlainText() {
        let html = PlainTextEmail.html(from: "네, 좋습니다.\n\n2026년 10월 12일 (월) 오전 10:00, Maya <maya@example.kr>님이 작성:\n> 내일 가능하세요?")
        #expect(html.contains(#"<div class="corres-quote">"#))
    }

    @Test func attachmentsMentionedInEveryLanguage() {
        #expect(MailDigest.mentionsAttachment("Anbei das Angebot."))
        #expect(MailDigest.mentionsAttachment("Veuillez trouver la facture en pièce jointe."))
        #expect(MailDigest.mentionsAttachment("请见附件。"))
        #expect(MailDigest.mentionsAttachment("資料を添付します。"))
        // Only the quoted email mentions one.
        #expect(!MailDigest.mentionsAttachment("好的。\n\nMaya <maya@example.cn> 于2026年10月12日周一 10:00写道：\n> 请见附件。"))
    }

    // MARK: Receipts, deliveries, Purchases

    @Test func receiptsAndDeliveriesInEveryLanguage() {
        func kind(_ subject: String) -> MailDigest.Kind {
            MailDigest.kind(subject: subject, text: "", senderEmail: "shop@example.com", isBulk: true, looksAutomated: true, hasEvent: false)
        }
        for subject in ["Ihre Bestellung wurde versandt", "Votre colis a été expédié", "Tu pedido ha sido enviado",
                        "Seu pedido saiu para entrega", "ご注文の商品を発送しました", "배송이 시작되었습니다", "您的订单已发货",
                        "আপনার পার্সেল পাঠানো হয়েছে"] {
            #expect(kind(subject) == .shipping, "\(subject)")
        }
        for subject in ["Ihre Rechnung", "Confirmation de commande", "Confirmación de pedido", "Nota fiscal eletrônica",
                        "領収書", "주문 확인", "订单确认", "আপনার রসিদ"] {
            #expect(kind(subject) == .receipt, "\(subject)")
        }
        // "Enviado desde mi iPhone" says nothing was shipped.
        #expect(kind("Enviado desde mi iPhone") != .shipping)
    }

    @Test func glanceStatusesInEveryLanguage() {
        let cases: [(String, String)] = [
            ("Ihr Paket wurde zugestellt.\nSendungsnummer: 00340434", "Delivered"),
            ("お荷物は配達中です。\n追跡番号：1234-5678-9012", "Out for delivery"),
            ("Seu pedido saiu para entrega.\nNúmero do pedido: 778812", "Out for delivery"),
            ("您的订单已发货。\n运单号：SF1234567890", "On its way"),
            ("Ihre Zahlung ist fehlgeschlagen.\nBetrag: 49,90 €", "Payment failed"),
            ("결제가 완료되었습니다.\n결제 금액: 15,000원", "Paid"),
        ]
        for (text, status) in cases {
            #expect(MailDigest.glance(text: text, kind: .shipping)?.status == status, "\(text)")
        }
    }

    @Test func receiptFiguresInEveryLanguage() {
        let japanese = MailDigest.glance(text: "ご注文ありがとうございます。\n合計：1,250円\n注文番号：A123-4567", kind: .receipt)
        #expect(japanese?.facts.contains { $0.value == "1,250円" } == true)
        #expect(japanese?.facts.contains { $0.value == "A123-4567" } == true)
        let german = MailDigest.glance(text: "Bestellbestätigung\nGesamtbetrag: 49,90 €\nBestellnummer: 302-1234567", kind: .receipt)
        #expect(german?.status == "Order confirmed")
        #expect(german?.facts.first?.value == "49,90 €")
        let delivery = MailDigest.glance(text: "発送しました\nお届け予定日：2026年11月12日", kind: .shipping)
        #expect(delivery?.facts.contains { $0.value == "2026年11月12日" } == true)
    }

    @Test func orderDataTheSenderEmbeddedIsRead() {
        let html = """
        <script type="application/ld+json">{"@context":"http://schema.org","@type":"ParcelDelivery",
        "deliveryStatus":"http://schema.org/OrderInTransit","trackingNumber":"1Z999",
        "partOfOrder":{"@type":"Order","orderNumber":"112-4471"}}</script>
        """
        let glance = MailDigest.glance(text: "Merci pour votre achat.", kind: .shipping, html: html)
        #expect(glance?.status == "On its way")
        #expect(glance?.facts.contains { $0.value == "112-4471" } == true)
    }

    @Test func nextStepsInOtherLanguages() {
        let dhl = #"<p>Ihr Paket ist unterwegs.</p><a href="https://www.dhl.de/sendung?id=1">Sendung verfolgen</a>"#
        #expect(MailDigest.nextStep(text: "Ihr Paket ist unterwegs.", html: dhl, kind: .shipping)?.label == "Sendung verfolgen")
        let japanese = #"<p>ご請求金額のお知らせ</p><a href="https://pay.example.jp/p">お支払い手続きへ</a>"#
        #expect(MailDigest.nextStep(text: "ご請求金額のお知らせ", html: japanese, kind: .receipt)?.label == "お支払い手続きへ")
        // A plain letter's link, by the sentence before it.
        let plain = "Hallo Herr Rahman,\nbitte bestätigen Sie Ihren Termin unter https://praxis.example.de/termin/77"
        #expect(MailDigest.nextStep(text: plain, html: nil, kind: .personal)?.label == "Confirm")
        // A sales button is never a step: "Jetzt kaufen", "今すぐ購入".
        let sale = #"<a href="https://shop.example.de/x">Jetzt kaufen</a><a href="https://shop.example.jp/y">今すぐ購入</a>"#
        #expect(MailDigest.nextStep(text: "", html: sale, kind: .notification) == nil)
    }

    @Test func calendarInvitationsInOtherLanguages() {
        for subject in ["Einladung: Projekt-Meeting @ Do. 12. Nov. 2026", "Invitation : Réunion d'équipe", "Convite: Reunião",
                        "招待: 定例会議", "초대: 주간 회의", "邀请：项目会议", "Angenommen: Projekt-Meeting"] {
            #expect(MailDigest.kind(subject: subject, text: "", senderEmail: "calendar-notification@google.com", isBulk: false,
                                    looksAutomated: true, hasEvent: false) == .invite, "\(subject)")
        }
    }

    // MARK: Calendar suggestions

    @Test func eventsAndTimesInEveryLanguage() {
        let cases: [(String, Int, Int)] = [
            ("Ihr Termin am 12. November 2026 um 15 Uhr.", 15, 0),
            ("Rendez-vous le 12 novembre 2026 à 15h30.", 15, 30),
            ("会議は2026年11月12日(木) 15時からです。", 15, 0),
            ("회의: 2026년 11월 12일 오후 3시", 15, 0),
            ("会议时间：2026年11月12日下午3点半", 15, 30),
            ("মিটিং ১২ নভেম্বর ২০২৬ বিকেল ৪টায়", 16, 0),
        ]
        for (text, hour, minute) in cases {
            let event = EventFinder.fromWording(text, subject: "", receivedAt: now, now: now)
            #expect(day(event?.start) == ymd(2026, 11, 12), "\(text)")
            #expect(event.map { calendar.component(.hour, from: $0.start) } == hour, "\(text)")
            #expect(event.map { calendar.component(.minute, from: $0.start) } == minute, "\(text)")
        }
        // "以下3点" is three points, not three o'clock; "৫টা বই" is five books.
        #expect(LocalDates.find(in: "会议要讨论以下3点", now: now).isEmpty)
        #expect(LocalDates.find(in: "মিটিংয়ে ৫টা বই আনবেন", now: now).isEmpty)
    }

    /// 12 at night is midnight, the end of the day it's said with; 12 by
    /// day is noon. Korean: 밤 12시, 자정 / 낮 12시, 오후 12시, 정오.
    /// Bengali: রাত ১২টা, মধ্যরাত / দুপুর ১২টা.
    @Test func midnightAndNoonInKoreanAndBengali() {
        func start(_ text: String) -> [Int]? {
            EventFinder.fromWording(text, subject: "", receivedAt: now, now: now)
                .map { calendar.dateComponents([.month, .day, .hour, .minute], from: $0.start) }
                .map { [$0.month!, $0.day!, $0.hour!, $0.minute!] }
        }
        for text in ["회의: 2026년 11월 12일 밤 12시", "회의: 2026년 11월 12일 자정", "회의: 2026년 11월 12일 24시",
                     "মিটিং ১২ নভেম্বর ২০২৬ রাত ১২টায়", "মিটিং ১২ নভেম্বর ২০২৬ রাতে ১২টায়", "মিটিং ১২ নভেম্বর ২০২৬ মধ্যরাতে"] {
            #expect(start(text) == [11, 13, 0, 0], "\(text)")
        }
        #expect(start("회의: 2026년 11월 12일 밤 12시 30분") == [11, 13, 0, 30])
        for text in ["회의: 2026년 11월 12일 낮 12시", "회의: 2026년 11월 12일 오후 12시", "회의: 2026년 11월 12일 정오",
                     "মিটিং ১২ নভেম্বর ২০২৬ দুপুর ১২টায়", "মিটিং ১২ নভেম্বর ২০২৬ দুপুরে ১২টায়"] {
            #expect(start(text) == [11, 12, 12, 0], "\(text)")
        }
        // The other hours keep their time of day.
        #expect(start("회의: 2026년 11월 12일 밤 9시") == [11, 12, 21, 0])
        #expect(start("회의: 2026년 11월 12일 낮 2시") == [11, 12, 14, 0])
        #expect(start("মিটিং ১২ নভেম্বর ২০২৬ রাত ৯টায়") == [11, 12, 21, 0])

        // Due at midnight is due that day, at its last minute.
        for text in ["11월 12일 자정까지 납부해 주세요.", "11월 12일 밤 12시까지 납부해 주세요.",
                     "১২ নভেম্বর রাত ১২টার মধ্যে বিল পরিশোধ করুন।"] {
            let due = MailSignals.deadline(in: text, now: now)
            #expect(due.map { calendar.dateComponents([.month, .day, .hour, .minute], from: $0) }
                .map { [$0.month!, $0.day!, $0.hour!, $0.minute!] } == [11, 12, 23, 59], "\(text)")
            #expect(due.map { TodayBrief.hasTime($0, calendar: calendar) } == false, "\(text)")
        }
        for text in ["11월 12일 낮 12시까지 납부해 주세요.", "১২ নভেম্বর দুপুর ১২টার মধ্যে বিল পরিশোধ করুন।"] {
            #expect(MailSignals.deadline(in: text, now: now).map { calendar.component(.hour, from: $0) } == 12, "\(text)")
        }

        // A time alone: tonight's midnight, not today's noon.
        let tonight = calendar.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: 0))!
        for text in ["오늘 자정까지", "오늘 밤 12시까지", "আজ রাত ১২টার মধ্যে"] {
            #expect(LocalDates.find(in: text, now: now).map(\.date) == [tonight], "\(text)")
        }
    }

    /// "By Friday" and "by tomorrow" in Japanese, Korean, Chinese and
    /// Bengali set a deadline, as they do in English and Europe's
    /// languages; the date detector reads none of them.
    @Test func relativeDeadlinesInEveryScript() {
        func due(_ text: String, receivedAt: Date? = nil) -> [Int]? {
            MailSignals.deadline(in: text, now: now, receivedAt: receivedAt)
                .map { calendar.dateComponents([.month, .day, .hour, .minute], from: $0) }
                .map { [$0.month!, $0.day!, $0.hour!, $0.minute!] }
        }
        // Sunday the 25th: Friday is the 30th.
        #expect(due("金曜日までにご返信ください。") == [10, 30, 12, 0])
        #expect(due("请于周五前回复。") == [10, 30, 12, 0])
        #expect(due("星期五之前请提交报告。") == [10, 30, 12, 0])
        #expect(due("금요일까지 회신 부탁드립니다.") == [10, 30, 12, 0])
        #expect(due("শুক্রবারের মধ্যে জানাবেন।") == [10, 30, 12, 0])
        #expect(due("明日の17時までにご確認ください。") == [10, 26, 17, 0])
        #expect(due("내일 오후 5시까지 보내 주세요.") == [10, 26, 17, 0])
        #expect(due("明天下午3点前回复我。") == [10, 26, 15, 0])
        #expect(due("期限：明日") == [10, 26, 12, 0])
        // By the end of today: its last minute.
        #expect(due("本日中にご対応ください。") == [10, 25, 23, 59])
        // "Until" and "go to" are not "by".
        #expect(due("金曜日まで休みます。") == nil)
        #expect(due("明天前往北京。") == nil)
        // Mail from an earlier day: its "tomorrow" isn't tomorrow now.
        #expect(due("明日までにご確認ください。", receivedAt: now.addingTimeInterval(-3 * 86_400)) == nil)
    }

    /// Dates and times in Han numerals are read whole or not at all:
    /// "十一月五日" (November 5th) was January 5th, "十一時" one o'clock, and
    /// "一時的に" (for a while) a time today.
    @Test func hanNumeralsAreNeverHalfRead() {
        #expect(LocalDates.find(in: "十一月五日下午三点开会", now: now).filter(\.hasDay).isEmpty)
        #expect(LocalDates.find(in: "十二月三日までにご提出ください", now: now).filter(\.hasDay).isEmpty)
        #expect(LocalDates.find(in: "十一時に集合してください", now: now).isEmpty)
        #expect(EventFinder.fromWording("会議室は一時的に使えません。", subject: "会議室のお知らせ", receivedAt: now, now: now) == nil)
        // A Han numeral with a time of day, and Arabic digits, still count.
        #expect(LocalDates.find(in: "下午三点开会", now: now).map { calendar.component(.hour, from: $0.date) } == [15])
        #expect(day(LocalDates.find(in: "三月五日", now: now).first?.date) == ymd(2027, 3, 5))
        #expect(LocalDates.find(in: "11時に集合", now: now).map { calendar.component(.hour, from: $0.date) } == [11])
    }

    /// Bengali's য় (and ড়, ঢ়) is typed as one character or as two; mail
    /// with the one-character spelling matched no Bengali rule. And a month
    /// that ends in a vowel takes its "of" as a letter: "জানুয়ারির".
    @Test func bengaliReadsEitherSpellingAndTheMonthsOf() {
        let ya = "\u{09DF}"
        #expect(MailSignals.asksSomething("রিপোর্টটি দ\(ya)া করে পাঠান।"))
        #expect(MailSignals.isObligation("আপনার অ্যাপ\(ya)েন্টমেন্ট আগামীকাল"))
        #expect(MailSignals.isAutoReply("স্ব\(ya)ংক্রি\(ya) উত্তর: বাজেট\nআমি অফিসের বাইরে।"))
        for text in ["৫ জানুয়ারির মধ্যে বিল পরিশোধ করুন।", "৫ জানু\(ya)ারির মধ্যে বিল পরিশোধ করুন।"] {
            #expect(day(MailSignals.deadline(in: text, now: now, horizon: 120 * 86_400)) == ymd(2027, 1, 5), "\(text)")
        }
        #expect(day(LocalDates.find(in: "১০ জুলাইয়ের মধ্যে", now: now).first?.date) == ymd(2027, 7, 10))
        // Still never the start of a longer word: "মেইল" is not May.
        #expect(LocalDates.find(in: "৫ মেইল পাঠানো হয়েছে", now: now).isEmpty)
    }

    // MARK: One-time codes and money

    @Test func oneTimeCodesInEveryLanguage() {
        let cases: [(String, String)] = [
            ("Your OTP is 482913. Do not share it.", "482913"),
            ("482913 is your OTP for transaction of INR 5,000 at Amazon.", "482913"),
            ("OTP for your transaction is 739102", "739102"),
            ("Use one time password 552310 to log in.", "552310"),
            ("Ihr Bestätigungscode lautet 123456", "123456"),
            ("Votre code de vérification : 654321", "654321"),
            ("Seu código de verificação é 112233", "112233"),
            ("認証コード：482913", "482913"),
            ("[Web발신] 인증번호 [482913]를 입력해주세요", "482913"),
            ("【微信】验证码482913，5分钟内有效。", "482913"),
            ("আপনার যাচাইকরণ কোড ৪৮২৯১৩", "৪৮২৯১৩"),
            // The year of a date between the words and the code is not it.
            ("Your verification code expires on Oct 25, 2026. Code: 482913", "482913"),
            ("Security code valid until 25 October 2026: 7731", "7731"),
            ("Your login code (sent 25/10/2026) is 5521", "5521"),
        ]
        for (text, code) in cases {
            #expect(MailDigest.verificationCode(in: text) == code, "\(text)")
        }
    }

    /// A code named after its service, a code in French typography, and
    /// never a shop's discount code, which put a sale in Primary for its
    /// first hour as if it were a sign-in.
    @Test func codesNamedForTheirServiceButNotShopCodes() {
        let cases: [(String, String)] = [
            ("123456 is your Instagram code", "123456"),
            ("G-482913 is your Google verification code.", "482913"),
            ("48291345 is your Facebook confirmation code", "48291345"),
            ("Votre code : 482913", "482913"),
            ("Tu código es 552310", "552310"),
        ]
        for (text, code) in cases {
            #expect(MailDigest.verificationCode(in: text) == code, "\(text)")
        }
        for text in ["Promo code: FALL25 for 20% off", "Use discount code: SAVE20 today", "Your gift card code: ABCD-1234",
                     "Coupon code: TAKE10 at checkout", "Ship to: 1 Main St. ZIP code: 94105"] {
            #expect(MailDigest.verificationCode(in: text) == nil, "\(text)")
            #expect(MailDigest.kind(subject: "Fall sale", text: text, senderEmail: "deals@shop.test", isBulk: true,
                                    looksAutomated: true, hasEvent: false) != .code, "\(text)")
        }
        let sale = Correspondence(id: ThreadID(account: "me@x.test", providerID: "sale"), sender: "Shop", senderEmail: "deals@shop.test",
                                  organization: "", subject: "Fall sale starts now", excerpt: "Promo code: FALL25 for 20% off everything",
                                  body: "", receivedAt: .now, dueAt: nil, reason: "", attention: .quiet, labelIds: ["CATEGORY_PROMOTIONS"])
        #expect(InboxCategory.of(sale) == .promotions)
    }

    /// Whose dollar it is stays with the amount, and thousands grouped
    /// with a space stay whole: "R$ 1.250,00" was handed on as "$ 1.250,00",
    /// and "1 250,00 €" as "250,00 €".
    @Test func amountsKeepTheirCurrencyAndThousands() {
        for amount in ["R$ 1.250,00", "C$45.00", "A$120", "US$ 99", "HK$300", "1 250,00 €", "€ 12 500", "1\u{202F}250,00 €"] {
            #expect(MailDigest.facts(in: "Total: \(amount) today").first == amount, "\(amount)")
        }
        let brazil = MailDigest.glance(text: "Pedido confirmado\nTotal: R$ 1.250,00\nNúmero do pedido: 4521-889", kind: .receipt)
        #expect(brazil?.facts.first?.value == "R$ 1.250,00")
        let france = MailDigest.glance(text: "Votre commande\nTotal : 1 250,00 €\nNuméro de commande : 4521-889", kind: .receipt)
        #expect(france?.facts.first?.value == "1 250,00 €")
        // Numbers beside each other are not one amount.
        #expect(MailDigest.facts(in: "Seats 2 and 3 cost $45 each") == ["$45"])
        #expect(!MailDigest.isAmount("PAID 12 items"))
    }

    /// In capitals, words are currency codes too: "TOP 10" is Tonga's
    /// pa'anga and "ALL 3" Albania's lek. A code in capital text counts
    /// only with a money label before it or cents after.
    @Test func capitalWordsAreNotAmounts() {
        #expect(MailDigest.facts(in: "OUR TOP 10 PICKS FOR THIS WEEK").isEmpty)
        #expect(MailDigest.facts(in: "PLEASE PAY ALL 3 INSTALMENTS ON TIME").isEmpty)
        #expect(MailDigest.facts(in: "TOP 10\nShop the list").isEmpty)
        // Real amounts in capitals stay.
        #expect(MailDigest.facts(in: "ORDER TOTAL USD 300 PAID") == ["USD 300"])
        #expect(MailDigest.facts(in: "ORDER TOTAL:\nEUR 45") == ["EUR 45"])
        #expect(MailDigest.facts(in: "BALANCE ALL 3,500.00 THANK YOU") == ["ALL 3,500.00"])
        #expect(MailDigest.facts(in: "YOU PAID $45, THANK YOU") == ["$45"])
        // In ordinary text, codes read as before.
        #expect(MailDigest.facts(in: "Also AED 120 on file.") == ["AED 120"])
    }

    @Test func amountsWrittenWithWords() {
        for amount in ["1,250円", "5,000원", "88元", "20块", "1,250 টাকা", "৳1,250", "Rs. 1,500/-", "RMB 300", "₹2,499"] {
            #expect(MailDigest.isAmount(amount), "\(amount)")
            // The "/-" mark goes, as other trailing punctuation does.
            #expect(MailDigest.facts(in: "Total \(amount) today").contains(amount.replacingOccurrences(of: "/-", with: "")), "\(amount)")
        }
        #expect(!MailDigest.isAmount("12 November"))
    }

    // MARK: Domains, categories, search

    @Test func freeMailAroundTheWorldIsNoCompany() {
        for address in ["li@qq.com", "kim@naver.com", "kim@hanmail.net", "sato@yahoo.co.jp", "sato@docomo.ne.jp",
                        "raj@rediffmail.com", "anna@web.de", "anna@t-online.de", "marie@orange.fr", "luca@libero.it",
                        "jack@bigpond.com", "sam@shaw.ca", "ivan@yandex.ru", "maya@outlook.de", "maya@hotmail.fr",
                        "maya@yahoo.co.in", "maya@outlook.com.au"] {
            #expect(InboxClassifier.companyDomain(of: address) == nil, "\(address)")
        }
        #expect(InboxClassifier.companyDomain(of: "info@mail.sony.co.jp") == "sony.co.jp")
        #expect(InboxClassifier.companyDomain(of: "news@www.mext.go.jp") == "mext.go.jp")
        #expect(InboxClassifier.companyDomain(of: "noreply@mail.example.ne.jp") == "example.ne.jp")
    }

    @Test func socialNetworksAcrossAsia() {
        for address in ["no-reply@line.me", "notice@kakaocorp.com", "noreply@band.us", "service@weibo.com",
                        "no-reply@xiaohongshu.com", "info@mixi.jp", "noreply@imo.im", "hello@sharechat.com"] {
            #expect(InboxCategory.isSocialNetwork(address), "\(address)")
        }
    }

    @Test func salesAroundTheWorld() {
        for subject in ["Eid Sale is live", "Diwali Dhamaka offers inside", "Pohela Boishakh collection is here",
                        "EOFY savings end Sunday", "Click Frenzy starts now", "Get Tk 500 off your first order",
                        "Save ₹500 on headphones", "20% Rabatt auf alles", "Les soldes d'hiver commencent",
                        "Oferta especial para ti", "冬のセール開催中", "최대 50% 할인", "双11狂欢节", "ঈদে ৩০% ছাড়"] {
            #expect(InboxCategory.looksPromotional(subject), "\(subject)")
        }
        #expect(!InboxCategory.looksPromotional("Your order has shipped"))
        #expect(!InboxCategory.looksPromotional("Termin am 11.11."))
    }

    @Test func searchFoldsWidthButKeepsOtherScriptsMarks() {
        #expect(SearchText("Café").contains(SearchText("cafe")))
        #expect(SearchText("ｶﾀｶﾅ").contains(SearchText("カタカナ")))
        #expect(SearchText("ＡＢＣ").contains(SearchText("abc")))
        // "が" is not "か"; a Bengali vowel sign changes the word.
        #expect(!SearchText("がっこう").contains(SearchText("かっこう")))
        #expect(!SearchText("কাল").contains(SearchText("কল")))
        #expect(SearchText("Renée কাল").contains(SearchText("renee")))
    }

    // MARK: Ask

    @Test func askInOtherLanguages() {
        var la = Calendar(identifier: .gregorian)
        la.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let german = AskQuery("Rechnungen diesen Monat", now: now, calendar: la)
        #expect(german.topic == .receipts && german.range != nil && german.keywords.isEmpty)
        let japanese = AskQuery("今月の領収書", now: now, calendar: la)
        #expect(japanese.topic == .receipts && japanese.range != nil && japanese.keywords.isEmpty)
        let fromTanaka = AskQuery("田中さんからの添付ファイル", now: now, calendar: la)
        #expect(fromTanaka.wantsAttachments && fromTanaka.person == "田中")
        let french = AskQuery("pièces jointes de Marie", now: now, calendar: la)
        #expect(french.wantsAttachments && french.person == "marie")
        // "de" as "of" names no one.
        #expect(AskQuery("facturas de luz", now: now, calendar: la).person == nil)
        let korean = AskQuery("지난주 영수증", now: now, calendar: la)
        #expect(korean.topic == .receipts && korean.range != nil)
        let bengali = AskQuery("রহিমের থেকে সংযুক্তি", now: now, calendar: la)
        #expect(bengali.wantsAttachments && bengali.person == "রহিম")
        #expect(AskQuery("Attachments from Oliver", now: now, calendar: la).title(count: 3) == "3 emails with attachments from Oliver")
    }

    // MARK: Faithfulness

    @Test func faithfulnessChecksReadEveryScript() {
        // German capitalizes every noun: "Rückmeldung" is not a made-up name.
        let german = MailDigest.unsupportedClaims(in: "Maya bittet um Rückmeldung zum Angebot.",
                                                   source: "Hallo, kannst du mir sagen, was du vom Angebot hältst? Maya")
        #expect(!german.contains("Rückmeldung"))
        // Chinese claims are judged by their words.
        let source = "你好，请在周五前确认合同。王伟"
        #expect(MailDigest.ungroundedClaims(in: "王伟请你周五前确认合同。", source: source).isEmpty)
        #expect(!MailDigest.ungroundedClaims(in: "航班已经取消，退款已经到账。", source: source).isEmpty)
    }

    // MARK: Names

    @Test func theNameSomeoneGoesBy() {
        #expect(Person.firstName(of: "Md. Rahim Uddin") == "Rahim")
        #expect(Person.firstName(of: "Mohammad Ali Khan") == "Ali")
        #expect(Person.firstName(of: "Mst. Fatema Begum") == "Fatema")
        #expect(Person.firstName(of: "Dr. Maya Patel") == "Maya")
        #expect(Person.firstName(of: "Engr. Kamal Hossain") == "Kamal")
        #expect(Person.firstName(of: "Patel, Maya") == "Maya")
        #expect(Person.firstName(of: "Mohammad") == "Mohammad")
        #expect(Person.firstName(of: "王伟") == "王伟")
        #expect(Person.firstName(of: "田中 太郎") == "田中 太郎")
        #expect(Person.firstName(of: "김민준") == "김민준")
        let style = WritingStyle(greeting: "Hi {name},", signOff: nil, typicalWords: 40, usesExclamations: false,
                                 writesLowercase: false, language: "en", examples: [], sampleCount: 5)
        #expect(style.greeting(for: "Md. Karim Ahmed") == "Hi Karim,")
    }
}
