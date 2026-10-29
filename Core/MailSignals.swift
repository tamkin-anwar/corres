import Foundation

/// What a message itself says, read with plain rules so it works the same
/// on every device, with or without Apple Intelligence. These are the
/// content and thread signals Gmail's Priority Inbox leans on (does it ask
/// something of you, did you reply, is there a date attached), not a score.
public enum MailSignals {
    /// The writer's own words, without the quoted history below them.
    public static func ownText(_ body: String) -> String {
        var kept: [String] = []
        let lines = oneBengaliSpelling(body).components(separatedBy: "\n")
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(">") { continue }
            // The signature delimiter ("-- "): a "Want to book a call?" in
            // a signature asks nothing of this email's reader.
            if trimmed == "--" { break }
            // "On … wrote:", "Am … schrieb:", "…写道：", an Outlook "From: /
            // Sent:" block, "-----Original Message-----" (`QuoteDetector`).
            if QuoteDetector.startsQuote(lines, at: index) { break }
            // A legal notice ("If you have received this email in error,
            // please reply…") asks nothing of the reader.
            if trimmed.patternRange(legalNoticePattern) != nil { break }
            if trimmed.patternRange(protectiveMarkingLine) != nil { continue }
            kept.append(line)
        }
        return withoutSurveys(kept.joined(separator: "\n"))
    }

    /// "We would like to know how you found our customer service. Please
    /// click the link to take part": a feedback survey, most often in a
    /// signature or footer. Asks nothing of you that needs doing (tester
    /// feedback: a council's signature survey put mail in Needs You).
    private static let surveyPattern = #"(?i)\b(how (did we do|was (your|the) (experience|visit|stay|service|call|appointment)|would you rate|likely (are you|is it that you would) (to )?recommend|you found (our|the) (customer )?service)|rate (us|our service|your (experience|visit|interaction|call))|(take|complete|fill (in|out)|answer) (part in )?(our|a|this|the) (short |quick |brief |\d+[- ]minute )?(customer )?(survey|questionnaire|feedback form)|(customer|client) (satisfaction|experience|feedback) (survey|questionnaire)|feedback (survey|form|link)|we('d| would) (love|like) (to (hear|know|get) )?your (feedback|thoughts|views|opinion)s?|we('d| would) (love|like) to (hear|know) (how|what) you (found|thought)|tell us (how we did|what you think|about your experience)|share your (feedback|experience)|leave (us )?a review|click (on )?(the|this) link( below)? to (take part|participate|give (us )?(your )?feedback)|research\.net|surveymonkey|qualtrics|typeform|medallia|smartsurvey|surveygizmo|alchemer|forms\.office\.com|forms\.gle|feedbackify|trustpilot)\b"#

    /// Bengali's য়, ড় and ঢ় are written two ways: one character (U+09DF,
    /// U+09DC, U+09DD), or the letter with a dot below. The rules here are
    /// written the second way, Unicode's normal form, so mail typed the
    /// first way ("দয়া করে", "অ্যাপয়েন্টমেন্ট", "৫ জানুয়ারি") matched none
    /// of them. Text without those characters is returned as it is.
    static func oneBengaliSpelling(_ text: String) -> String {
        guard text.unicodeScalars.contains(where: { (0x09DC...0x09DF).contains($0.value) }) else { return text }
        return text.precomposedStringWithCanonicalMapping
    }

    /// The text without its survey and feedback requests: each sentence (or
    /// line) that carries one goes.
    static func withoutSurveys(_ text: String) -> String {
        guard text.patternRange(surveyPattern) != nil else { return text }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let line = String(line)
            guard line.patternRange(surveyPattern) != nil else { return line }
            // Sentence by sentence, so a real request on the same line stays.
            var kept: [String] = []
            line.enumerateSubstrings(in: line.startIndex..., options: .bySentences) { sentence, _, _, _ in
                guard let sentence, sentence.patternRange(surveyPattern) == nil else { return }
                kept.append(sentence)
            }
            return kept.joined()
        }
        return lines.joined(separator: "\n")
    }

    /// Where an organization's legal notice starts: everything from there
    /// down is boilerplate.
    public static let legalNoticePattern = #"(?i)^(confidentiality notice|(privacy|legal|email) (notice|disclaimer|statement)|disclaimer:|this (e-?mail|message|communication)( and any (attachments?|files)( transmitted with it)?)? (is|are|may be|contains?|may contain) (for the (intended|named|exclusive|sole)|intended|confidential|private|privileged|strictly|monitored|recorded)|if you (have )?received this (e-?mail|message|communication)( in error| by mistake| due to)?|if you are not the (intended|named|addressee)|the (information|contents?) (in|of) this (e-?mail|message) (is|are|may be) (confidential|privileged|intended))"#

    /// A UK government (or company) protective marking on its own line:
    /// "- Official -", "OFFICIAL-SENSITIVE", "Classification: Internal".
    public static let protectiveMarkingLine = #"(?i)^[\[\-–— ]*(official(-sensitive)?|unclassified|(classification|sensitivity): ?(official|public|internal|general|confidential)( use)?)[\]\-–— ]*$"#

    /// Phrases that ask the reader for something even without a question
    /// mark ("Let me know", "Please confirm"), in English and the app's
    /// other languages: "bitte bestätigen", "merci de confirmer", "por favor
    /// confirme", "me avise", "ご確認ください", "확인 부탁드립니다", "请确认",
    /// "জানাবেন". Japanese and Korean often ask without a question mark
    /// ("…でしょうか", "…주시겠어요"). "Please find attached" in any language
    /// ("veuillez trouver ci-joint", "请查收") asks nothing.
    ///
    /// One pattern per language: as one long alternation, the regular
    /// expression engine tried every phrase at every letter and took
    /// thirty times as long.
    static let requestPatterns: [String] = [
        #"(?i)\b(can|could|would|will) you\b|\blet me know\b|\bplease (confirm|advise|review|send|reply|respond|approve|sign|share|rsvp|let)\b|\bwhat do you think\b|\byour thoughts\b|\bany (update|news)\b|\bare you (free|available|around)\b|\bwhen (works|would work|are you)\b|\bget back to me\b|\blooking forward to (hearing|your reply)\b|\brsvp\b"#,
        // German
        #"(?i)\b(bitte (um )?(bestätig|rückmeld|antwort|melde|prüf|schick|send|unterschreib|teil)\w*|(können|könnten|würden) sie|(kannst|könntest|würdest) du|(lass(t)?|lassen sie) (es )?(mich|uns) wissen|geben sie (mir|uns) bescheid|gib (mir|uns) bescheid|ich bitte um|was meinst du|was meinen sie)\b"#,
        // French
        #"(?i)\b(merci de (confirmer|me |nous |valider|vérifier|signer|répondre|revenir)|(pouvez|pourriez)-vous|(peux|pourrais)-tu|veuillez (confirmer|me |nous |répondre|signer|valider)|(tenez|tiens)-moi au courant|(faites|fais)-moi savoir|(dites|dis)-moi|qu'en (penses-tu|pensez-vous)|dans l'attente de (votre|ta) réponse)\b"#,
        // Spanish
        #"(?i)\b(por favor,? (confirm|respond|revis|env[ií]|firm|avís|avis|indic)\w*|(puede|puedes|podría|podrías) (confirmar|enviar|revisar|decirme|avisarme|indicarme)|me (avisas|confirmas|dices)|avísame|avíseme|confírmame|confírmeme|quedo (atento|atenta|a la espera) (a|de) (su|tu) respuesta|qué (te|le) parece)\b"#,
        // Portuguese
        #"(?i)\b(por favor,? (confirm|respond|revis|envi|assin|avis|me (avise|diga|informe))\w*|(pode|poderia|podes|você pode) (confirmar|enviar|revisar|me)|me (avise|avisa|confirme|diga|informe)|aguardo (o |a )?(seu|sua) (retorno|resposta|confirmação)|fico no aguardo|o que (acha|você acha))\b"#,
    ]

    /// Bengali, Japanese, Korean and Chinese, read only when the text has
    /// those scripts in it.
    static let requestPatternsOtherScripts: [String] = [
        // Bengali
        #"\b(জানাবেন|জানান|জানাও|জানাবে|নিশ্চিত করুন|অনুগ্রহ করে|দয়া করে|পাঠাবেন|পারবেন কি|পারবে কি|উত্তর দিন|কী মনে করেন)"#,
        // Japanese, Korean and Chinese
        #"ご確認(ください|下さい|お願い|の上|いただけ)|ご(返信|連絡|回答|検討|対応)(ください|下さい|お願い|いただけ)|お知らせ(ください|下さい)|教えて(ください|下さい|いただけ)|いただけ(ます|ません)か|でしょうか|お返事(ください|お待ち)|확인 ?부탁|확인해 ?주(세요|시겠|실)|(회신|답장|검토|연락) ?부탁|알려 ?주(세요|시겠|실)|연락 ?주(세요|십시오)|주시겠어요|주실 수 있(나요|을까요|으신가요)|가능할까요|어떠세요|어떻습니까|请(确认|回复|告知|尽快|提供|您确认|您回复)|請(確認|回覆|告知|盡快|提供)|麻(烦|煩)(你|您)|能否|可否|可以吗|可以嗎|盼复|盼覆|期待(你|您)的(回复|回覆)|你觉得呢|您觉得|您覺得"#,
        // Asked to send, submit or sign something: "資料を送ってください",
        // "보내 주시기 바랍니다", "请提交". Not "ご覧ください", "참고 바랍니다" or
        // "请查收" (please see), which ask nothing.
        #"(送って|送付して|提出して|返送して|記入して|署名して|共有して|返信して)(ください|下さい|もらえ|いただけ|頂け)|ご(提出|送付|記入|署名|返送|共有)(ください|下さい|をお願い|いただけ)|(보내|제출해|작성해|서명해|검토해|회신해|답장해|공유해|송부해) ?주(세요|십시오|시기 ?바랍니다)|(확인|회신|답장|검토|제출|작성|서명|송부) ?(해 ?주시기 ?)?바랍니다|[请請](发送|發送|提交|签字|簽字|签署|簽署|审核|審核|审阅|審閱|填写|填寫|答复|答覆|核对|核對)"#,
    ]

    /// A polite closing that offers help rather than asking for anything,
    /// in English and the app's other languages: "Let me know if you have
    /// any questions", "Feel free to reach out", "Bei Fragen stehe ich
    /// Ihnen gerne zur Verfügung", "N'hésitez pas à me contacter", "No
    /// dudes en contactarme", "Qualquer dúvida, estou à disposição",
    /// "কোনো প্রশ্ন থাকলে জানাবেন", "ご不明な点がございましたら、お気軽にお問い合わせ
    /// ください", "궁금한 점이 있으시면 연락 주세요", "如有任何问题，请随时与我联系".
    /// Only the closing goes, so a request in the same sentence ("…, and
    /// please confirm the date") still counts. "Let me know" alone, or
    /// with anything but an offer ("if you can make it"), is a request.
    static let courtesyClosings: [String] = [
        // "Let me know if you have any questions", "Feel free to reach out
        // if you need anything else", "Let us know if there's anything
        // else we can help with".
        #"(?i)\b(?:(?:please|just|do)\s+)*(?:let (?:me|us) know|(?:feel free|do not hesitate|don'?t hesitate|never hesitate) to (?:reach out|contact (?:me|us)|get in touch|ask|let (?:me|us) know|email (?:me|us)|call (?:me|us))(?: to (?:me|us))?|reach out(?: to (?:me|us))?|get in touch|contact (?:me|us))\s+(?:if|should|in case)\s+(?:you\s+)?(?:have|need|want|require|there is|there are|there's|anything)\s*[^.!?\n]{0,40}?\b(?:questions?|concerns?|anything(?: else)?|help|assistance|clarification|issues?|problems?|information|comments?|feedback)\b(?:\s+(?:or|and)\s+(?:questions?|concerns?|comments?|feedback|need anything(?: else)?))?(?:\s+(?:else\s+)?(?:(?:i|we) can (?:do|help(?: you)?(?: with)?)|you need))?\s*[.!]?"#,
        // "Feel free to reach out.", "Don't hesitate to contact me."
        #"(?i)\b(?:please\s+)?(?:feel free|do not hesitate|don'?t hesitate|never hesitate) to (?:reach out|contact (?:me|us)|get in touch|ask)(?: (?:to )?(?:me|us))?(?: (?:anytime|any time|at any time))?\s*[.!]?"#,
        // "If you have any questions, please don't hesitate to reach out",
        // "Any questions, just let me know".
        #"(?i)\b(?:(?:if|should) you (?:have|need) (?:any|anything)[^.!?\n]{0,30}?\b(?:questions?|concerns?|help|assistance|else|information)\b|any (?:questions?|concerns?))[^.!?\n]{0,15}?,?\s*(?:(?:please|just|do)\s+)*(?:let (?:me|us) know|(?:feel free|do not hesitate|don'?t hesitate) to (?:reach out|contact (?:me|us)|get in touch|ask)(?: (?:me|us))?|reach out|get in touch|contact (?:me|us)|give (?:me|us) a (?:call|shout))\s*[.!]?"#,
        // German: "Bei Fragen stehe ich Ihnen gerne zur Verfügung", "Lassen
        // Sie mich wissen, wenn Sie Fragen haben", "Zögern Sie nicht, mich
        // zu kontaktieren".
        #"(?i)\b(?:bei|für) (?:weiteren |sonstigen |eventuellen |allen )?(?:rück)?fragen\b[^.!?\n,]*[.!]?"#,
        #"(?i)\b(?:(?:lassen sie|lass|lasst) (?:es )?(?:mich|uns) wissen|(?:geben sie|gib) (?:mir|uns) (?:gerne |einfach )?bescheid|melden sie sich (?:gerne|einfach)|meld(?:e)? dich (?:gerne|einfach)),? (?:wenn|falls|sollten) (?:sie|du|ihr|es) (?:noch )?(?:weitere |irgendwelche )?(?:fragen|anmerkungen|unklarheiten)[^.!?\n,]*[.!]?"#,
        #"(?i)\bzögern sie nicht,? (?:mich|uns) (?:zu kontaktieren|anzusprechen|anzurufen)[^.!?\n,]*[.!]?"#,
        // French: "N'hésitez pas à me contacter", "Dites-moi si vous avez
        // des questions", "Je reste à votre disposition".
        #"(?i)\bn['’]h[ée]sit(?:ez|e) pas (?:à|a) (?:me|nous) (?:contacter|recontacter|joindre|écrire|solliciter|faire signe|revenir vers (?:moi|nous))[^.!?\n,]*[.!]?"#,
        #"(?i)\b(?:dites|dis|faites|fais)-(?:moi|nous)(?: savoir)? si (?:vous avez|tu as) (?:des|d'autres|la moindre|quelques) (?:questions?|interrogations?|remarques?)[^.!?\n,]*[.!]?"#,
        #"(?i)\bje reste (?:à|a) (?:votre|ta) (?:entière )?disposition[^.!?\n,]*[.!]?"#,
        // Spanish: "Avísame si tienes alguna pregunta", "No dudes en
        // contactarme", "Quedo a su disposición".
        #"(?i)\b(?:av[íi]same|av[íi]seme|d[íi]me|d[íi]game|me avisas|h[áa]zmelo saber|h[áa]gamelo saber) si (?:tienes|tiene|tuvieras|tuviera) (?:alguna|cualquier|m[áa]s) (?:pregunta|duda|consulta)s?[^.!?\n,]*[.!]?"#,
        #"(?i)\bno (?:dudes|dude|duden) en (?:contactarme|contactarnos|escribirme|escribirnos|preguntar(?:me)?|consultarme|llamarme|avisarme)[^.!?\n,]*[.!]?"#,
        #"(?i)\bsi (?:tienes|tiene) (?:alguna|cualquier) (?:pregunta|duda|consulta)s?,? (?:av[íi]same|av[íi]seme)[^.!?\n,]*[.!]?|\bquedo a (?:tu|su) (?:entera )?disposici[óo]n[^.!?\n,]*[.!]?"#,
        // Portuguese: "Me avise se tiver alguma dúvida", "Qualquer dúvida,
        // estou à disposição", "Não hesite em entrar em contato".
        #"(?i)\b(?:me avise|me avisa|me diga|me informe|me fala) (?:se|caso) (?:tiver|tenha|houver|tenham) (?:alguma|qualquer|mais) (?:d[úu]vida|pergunta|quest[ãa]o)s?[^.!?\n,]*[.!]?"#,
        #"(?i)\bqualquer (?:d[úu]vida|pergunta|coisa|quest[ãa]o),? (?:(?:[ée] s[óo] )?(?:me )?(?:avise|avisa|avisar|chamar|falar|chame|fale)|(?:estou|fico) [àa] disposi[çc][ãa]o)[^.!?\n,]*[.!]?"#,
        #"(?i)\bn[ãa]o hesite em (?:entrar em contato|me contatar|nos contatar|perguntar|me procurar)[^.!?\n,]*[.!]?|(?:\bfico|\bestou) [àa] (?:sua |inteira )?disposi[çc][ãa]o[^.!?\n,]*[.!]?"#,
        // Bengali: "কোনো প্রশ্ন থাকলে জানাবেন".
        #"(?:কোনো|কোন|যেকোনো|যে কোনো)\s?(?:প্রশ্ন|জিজ্ঞাসা|সমস্যা|কিছু)\s?(?:থাকলে|হলে)[^।.!?\n]{0,20}?(?:জানাবেন|জানান|জানাও|জানাবে|যোগাযোগ করবেন|যোগাযোগ করুন)[।.!]?"#,
        // Japanese, Korean and Chinese.
        #"(?:ご不明(?:な)?点|ご質問|何か|ご要望|ご意見)(?:等|など)?(?:が|は)?(?:ございましたら|ございます場合は|ありましたら|あれば)[、,]?\s?(?:お気軽に|遠慮なく|いつでも|何なりと)?\s?(?:お問い合わせ|お問合せ|ご連絡|お知らせ|お申し付け)(?:ください|下さい|くださいませ)[。.!！]?"#,
        #"(?:궁금한\s?(?:점|사항|것)|문의\s?사항|질문|문의)(?:이|가)?\s?(?:있으시면|있으면|있으실 경우)[,\s]*(?:언제든(?:지)?|편하게|부담 없이)?\s?(?:연락|말씀|알려|문의)\s?(?:해\s?)?(?:주세요|주십시오|주시기 바랍니다|부탁드립니다)[.!]?"#,
        #"(?:如有|如果有|若有|有)(?:任何|其他|什么|什麼)?(?:问题|問題|疑问|疑問|需要)[，,]?\s?(?:请|請)?(?:随时|隨時)?(?:与|與|和|跟)?(?:我|我们|我們)?(?:联系|聯繫|聯絡|联络|告知|告诉|告訴)(?:我|我们|我們)?[。.!！]?"#,
    ]

    /// A link with or without "https://" ("www.example.com/page?x=1",
    /// "example.com/reset?token=abc"), whose query string carries a
    /// question mark. Punctuation after it ends the sentence, not the link.
    static let linkPattern = #"(?i)(?:https?://|www\.)\S*[^\s.,;:!?)\]'"’」』]|\b[\w-]+(?:\.[\w-]+)+/\S*[^\s.,;:!?)\]'"’」』]"#

    /// Whether the writer asks the reader something: a real question or a
    /// request. Links are removed first, since their query strings carry
    /// question marks, and courtesy closings (`courtesyClosings`), which
    /// offer help without asking. A question mark in any script counts:
    /// full-width "？" (Chinese, Japanese) and Arabic-script "؟" too.
    ///
    /// A reply's or forward's subject ("Re: Are you free Thursday?") is the
    /// first message's question, not this one's: answered with "Yes,
    /// Thursday works", it read as asking you something.
    public static func asksSomething(_ text: String) -> Bool {
        let own = courtesyClosings.reduce(ownText(withoutReplySubject(text)).replacingPattern(linkPattern, with: "")) {
            $0.replacingPattern($1, with: " ")
        }
        if own.patternRange(#"[\p{L}\p{N})"'’」』]\s?[?？؟]"#) != nil { return true }
        if own.matchesAny(requestPatterns) { return true }
        return own.unicodeScalars.contains { $0.value >= 0x0980 } && own.matchesAny(requestPatternsOtherScripts)
    }

    /// An out-of-office or other automatic reply, by its subject (the first
    /// line of `text`) as mail servers write it in each language:
    /// "Automatic reply:", "Out of Office:", "Abwesenheitsnotiz", "Réponse
    /// automatique", "Respuesta automática", "自動応答", "자동 회신", "自动回复".
    public static func isAutoReply(_ text: String) -> Bool {
        let subject = oneBengaliSpelling(String(text.prefix { $0 != "\n" }))
        return subject.patternRange(autoReplyPattern, caseInsensitive: true) != nil
    }

    /// With the colon that follows it, as servers write it: "Out of office
    /// next week" is a person telling you, and stays theirs.
    static let autoReplyPattern = #"^\s*((automatic|auto)[- ]?(reply|response)|autoreply|out of (the )?office( auto ?reply)?|automatische antwort|abwesenheitsnotiz|réponse automatique|absence du bureau|respuesta automática|fuera de la oficina|resposta automática|ausência temporária|fora do escritório|自動応答|自動返信|자동 ?(회신|응답)|自动回复|自動回覆|স্বয়ংক্রিয় উত্তর)\s?[:：]"#

    /// `text` (a subject, then the message) without its first line when
    /// that is a reply's or forward's subject, in any language (`MailSubject`).
    static func withoutReplySubject(_ text: String) -> String {
        guard let end = text.firstIndex(of: "\n"),
              text[..<end].patternRange(MailSubject.prefixPattern) != nil else { return text }
        return String(text[text.index(after: end)...])
    }

    /// Words that make a date a deadline when they come right before it:
    /// "due Friday", "by Oct 3", "RSVP by the 12th", "Due: 12 Nov", and the
    /// same in the app's other languages: "bis zum", "fällig am", "avant
    /// le", "au plus tard", "antes del", "vence el", "até", "prazo". Chinese,
    /// Japanese, Korean and Bengali deadlines are read with their dates
    /// (`LocalDates`). Deliberately tight; a date on its own ("Posted Sep
    /// 3") is not a deadline. Business English puts words between "by"
    /// and the day ("by end of day Friday", "EOD tomorrow", "COB
    /// Thursday"), which count too: they once set no deadline at all.
    static let leadInWords = #"due|by|before|until|no later than|(the )?(end of (the )?(business )?day|end of business|close of business|eod|cob)|deadline(\s+is)?|expires?|expiring|rsvp(\s+by)?|respond by|reply by|closes?|bis( zum| spätestens)?|spätestens( am| bis)?|fällig( am| bis)?|frist( bis)?|zahlbar bis|avant( le)?|d'ici( le)?|au plus tard( le)?|jusqu'au|date limite|échéance|dû le|antes del?|hasta el|a más tardar( el)?|fecha límite|vence( el| em)?|vencimento|até( o dia| dia)?|prazo( até)?|data limite"#
    private static let deadlineLeadIn = #"(?i)\b("# + leadInWords + #")\s*:?\s*(on\s+|the\s+|le\s+|el\s+|am\s+|dem\s+|o\s+)?$"#
    /// The same words at the start of what the date detector found: it
    /// takes them into the date ("due November 5, 2026" came back as today,
    /// lasting until the 5th), so the commonest bill wording never set a
    /// deadline.
    private static let leadInAtStart = #"(?i)^(("# + leadInWords + #")\s*:?\s*)+(on\s+|the\s+|le\s+|el\s+|am\s+|dem\s+|o\s+)?(?=\S)"#
    /// A deadline in Chinese, Japanese, Korean or Bengali is said before
    /// the date ("期限：", "截止日期：", "마감", "শেষ তারিখ") or after it
    /// ("11月12日まで", "11월 12일까지", "11月12日前", "১২ নভেম্বরের মধ্যে",
    /// "রাত ১২টার মধ্যে").
    static let localLeadIn = #"(期限|締め?切り?日?|締切日?|支払期限|お支払い期限|期日|마감(일)?|기한|납부 ?기한|截止(日期|时间|時間)?|最晚|最迟|最遲|请于|請於|于|於|শেষ তারিখ)\s?[:：は은는이]?\s?$"#
    /// The same words before a numeric date, without "于"/"於" ("on"),
    /// which as often says when a meeting is as when something is due.
    static let numericLocalLeadIn = #"(期限|締め?切り?日?|締切日?|支払期限|お支払い期限|期日|마감(일)?|기한|납부 ?기한|截止(日期|时间|時間)?|最晚|最迟|最遲|请于|請於|শেষ তারিখ)\s?[:：は은는이]?\s?$"#
    static let localLeadOut = #"^\s?(\([^)]{1,4}\)|（[^）]{1,4}）)?\s?(ের|এর|র|\x{09DF}ের|\x{09AF}\x{09BC}ের)?\s?(まで|迄|까지|前|之前|以前|মধ্যে)"#

    /// The earliest upcoming deadline the message names, within `horizon`.
    /// Relative dates ("by Friday", "tomorrow") resolve against today's
    /// clock, so they count only in mail that arrived today: given
    /// `receivedAt` on an earlier day, "reply by Friday" from last week
    /// became next Friday. `senderEmail` says how the sender writes a date
    /// like 03/11/2026 (`numericDateOrder`).
    ///
    /// A reply's or forward's subject is the first message's deadline, as
    /// it is its question (`asksSomething`): "Paid, thanks" under "Re:
    /// Payment due Friday" set Friday as due.
    public static func deadline(in text: String, now: Date = .now, horizon: TimeInterval = 45 * 86_400,
                                senderEmail: String? = nil, receivedAt: Date? = nil) -> Date? {
        let own = String(ownText(withoutReplySubject(text)).prefix(4_000))
        guard !own.isEmpty else { return nil }
        return dates(in: own, senderEmail: senderEmail, now: now, relativeToday: readsRelativeDates(receivedAt))
            .filter { $0.isDeadline && $0.date > now.addingTimeInterval(-3_600) && $0.date < now.addingTimeInterval(horizon) }
            .map(\.date).min()
    }

    /// Whether "Friday" in mail received at `receivedAt` still means the
    /// Friday the date detector reads it as (the next one by the clock).
    static func readsRelativeDates(_ receivedAt: Date?) -> Bool {
        receivedAt.map { Calendar.current.isDateInToday($0) } ?? true
    }

    /// For automated mail about an appointment, bill or signature, any date
    /// in the next few days is the one that matters, however it's worded:
    /// "Your appointment is tomorrow at 9:00 AM" has no "by" or "due" in
    /// it. Promotions never get here (see `InboxClassifier`).
    public static func timeSensitiveDate(in text: String, now: Date = .now, within: TimeInterval = 3 * 86_400,
                                         senderEmail: String? = nil, receivedAt: Date? = nil) -> Date? {
        if let due = deadline(in: text, now: now, horizon: within, senderEmail: senderEmail, receivedAt: receivedAt) { return due }
        let text = withoutReplySubject(text)
        guard isObligation(text) else { return nil }
        let own = String(ownText(text).prefix(4_000))
        return dates(in: own, senderEmail: senderEmail, now: now, relativeToday: readsRelativeDates(receivedAt)).map(\.date)
            .filter { $0 > now.addingTimeInterval(-3_600) && $0 < now.addingTimeInterval(within) }
            .min()
    }

    struct FoundDate { let date: Date; let isDeadline: Bool }

    /// "14:00〜15:00", "14:00～", "14:00~15:00": Japanese and Chinese write a
    /// time's range with a wave dash (U+301C) or a tilde, full-width
    /// (U+FF5E) or plain. The date detector reads "14:00-15:00" but no time
    /// at all in these, so for it the mark becomes "-" when another time
    /// follows, and a space when none does ("14:00〜", from 14:00). Only
    /// after a clock time: "約3〜5日" (about 3 to 5 days) stays. One
    /// character for one, so a range in the result is one in `text`.
    static func withTimeRangesForDetector(_ text: String) -> String {
        guard text.contains(where: { "〜～~".contains($0) }),
              let regex = PatternCache.shared.regex(#"(?<=\d[:：]\d\d)\s?([〜～~])\s?(\d{1,2}[:：]\d\d)?"#, caseInsensitive: false)
        else { return text }
        let result = NSMutableString(string: text)
        for match in regex.matches(in: text, range: NSRange(location: 0, length: result.length)) {
            result.replaceCharacters(in: match.range(at: 1), with: match.range(at: 2).location != NSNotFound ? "-" : " ")
        }
        return result as String
    }

    /// Every date the text names, each read once: Apple's date detector
    /// for the languages it reads, with its two slips put right (a lead-in
    /// word taken into the date, and a numeric date read the reader's way
    /// rather than the writer's), and `LocalDates` for Chinese, Japanese,
    /// Korean and Bengali dates, which it doesn't read at all.
    /// `relativeToday`: whether a date the text gives only relative to
    /// the day it was written ("Friday", "tomorrow", "5pm") is read at all.
    static func dates(in own: String, senderEmail: String?, now: Date, relativeToday: Bool = true) -> [FoundDate] {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else { return [] }
        // Bengali and Arabic-Indic digits ("৩১/১২/২০২৬") as 0-9, which is
        // all the date detector reads (`asciiDigits` keeps the length), and
        // a range's "〜" as it reads one (`withTimeRangesForDetector`).
        let source = withTimeRangesForDetector(MailDigest.asciiDigits(own))
        let ns = source as NSString
        let order = numericDateOrder(senderEmail: senderEmail, text: source, now: now)
        var found: [FoundDate] = []
        for match in detector.matches(in: source, range: NSRange(location: 0, length: ns.length)) {
            var range = match.range
            var date = match.date
            var leadIn = false
            // "due November 5, 2026": read the date again without "due".
            for _ in 0..<2 {
                let phrase = ns.substring(with: range)
                guard let lead = phrase.patternRange(leadInAtStart) else { break }
                let skip = phrase[..<lead.upperBound].utf16.count
                let rest = NSRange(location: range.location + skip, length: range.length - skip)
                guard rest.length > 0, let again = detector.firstMatch(in: source, range: rest) else { date = nil; break }
                range = again.range
                date = again.date
                leadIn = true
            }
            guard var date else { continue }
            if !relativeToday, ns.substring(with: range).patternRange(explicitDatePattern) == nil { continue }
            switch numericReading(of: ns.substring(with: range), detected: date, order: order, now: now) {
            case .notNumeric: break
            case .date(let written): date = written
            // 03/11/2026 from someone whose way of writing dates is unknown:
            // the 3rd of November or March the 11th. Better no deadline
            // than the wrong one.
            case .ambiguous: continue
            }
            let start = max(0, range.location - 32)
            let before = ns.substring(with: NSRange(location: start, length: range.location - start))
            // A numeric date in Japanese, Korean, Chinese or Bengali mail
            // says it's a deadline the same way: "締切：11/12", "11/12(木)
            // まで", "৩১/১২/২০২৬ এর মধ্যে".
            let afterStart = NSMaxRange(range)
            let after = ns.substring(with: NSRange(location: afterStart, length: min(14, ns.length - afterStart)))
            let local = before.patternRange(numericLocalLeadIn) != nil || after.patternRange(localLeadOut) != nil
            found.append(FoundDate(date: date, isDeadline: leadIn || local || before.patternRange(deadlineLeadIn) != nil))
        }
        let digits = ns
        for local in LocalDates.find(in: own, now: now) where local.hasDay {
            let start = max(0, local.range.location - 12)
            let before = digits.substring(with: NSRange(location: start, length: local.range.location - start))
            let afterStart = local.range.location + local.range.length
            let after = digits.substring(with: NSRange(location: afterStart, length: min(14, digits.length - afterStart)))
            let isDeadline = before.patternRange(localLeadIn) != nil || after.patternRange(localLeadOut) != nil
                || before.patternRange(deadlineLeadIn) != nil
            // Due at midnight ("11월 12일 자정까지") is due on the 12th: its
            // last minute, which shows as that day, not 0:00 on the 13th.
            let clock = Calendar.current.dateComponents([.hour, .minute], from: local.date)
            let midnight = local.hasTime && clock.hour == 0 && clock.minute == 0
            found.append(FoundDate(date: midnight ? local.date.addingTimeInterval(-60) : local.date, isDeadline: isDeadline))
        }
        // "金曜日までに", "내일까지", "周五前": by a day relative to today,
        // which the date detector reads in English and Europe's languages
        // only.
        if relativeToday {
            found += LocalDates.relativeDeadlines(in: own, now: now).map { FoundDate(date: $0, isDeadline: true) }
        }
        return found
    }

    /// A date that says which day it is whenever it's read: a month name
    /// (in the languages the date detector reads), a numeric date (not a
    /// time, "7.15pm"), a year or a day of the month ("the 12th"). Anything
    /// else ("Friday", "tomorrow", "at 5pm") is relative to the day it was
    /// written.
    static let explicitDatePattern = #"(?i)\b(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\.?\b|\d{1,2}/\d{1,2}|\d{1,2}[.\-]\d{1,2}[.\-]\d{2,4}|\b\d{4}\b|\d(st|nd|rd|th)\b|\b(januar|februar|märz|mai|juni|juli|oktober|dezember|janvier|février|mars|avril|juin|juillet|août|septembre|octobre|novembre|décembre|enero|febrero|marzo|abril|mayo|junio|julio|agosto|septiembre|octubre|noviembre|diciembre|janeiro|fevereiro|março|maio|junho|julho|setembro|outubro|novembro|dezembro)\b"#

    // MARK: Numeric dates

    /// How a sender writes a numeric date like 03/11/2026.
    public enum DateOrder: Sendable, Equatable { case dayFirst, monthFirst }

    /// A numeric date: "03/11/2026", "3/11", "12.11.2026", "12-11-2026".
    /// Dots and dashes count only with a year, so a time ("7.15pm") or a
    /// range ("12-15 Nov") is never read as one.
    private static let numericDatePattern = #"(?<![\d/.\-])(\d{1,2})(?:/(\d{1,2})(?:/(\d{4}|\d{2}))?|([.\-])(\d{1,2})\4(\d{4}|\d{2}))(?![\d/])"#

    /// Where people write the day first (most of the world: the UK,
    /// Ireland, Bangladesh, India, Australia, New Zealand, South Africa,
    /// Europe, Latin America) and where the month comes first (the US, its
    /// government and universities, the Philippines, and the year-first
    /// countries, whose dates without a year read month/day: Japan's
    /// "11/3" is the 3rd of November). Generic endings (.com) say nothing.
    static let dayFirstEndings: Set<String> = [
        "uk", "ie", "bd", "in", "pk", "lk", "np", "au", "nz", "za", "sg", "my", "hk", "ae", "sa", "qa", "eg", "ng",
        "ke", "gh", "de", "fr", "es", "it", "pt", "br", "nl", "be", "at", "ch", "se", "no", "dk", "fi", "pl", "cz",
        "ru", "tr", "gr", "mx", "ar", "cl", "pe", "id", "vn", "th", "il", "ro", "hu", "ua",
    ]
    static let monthFirstEndings: Set<String> = ["us", "gov", "edu", "mil", "ph", "jp", "cn", "kr", "tw"]

    /// How this email writes numeric dates: settled by another date in it
    /// that can only be read one way ("13/11/2026" is day first), else by
    /// where the sender writes from. Nil when neither says.
    static func numericDateOrder(senderEmail: String?, text: String, now: Date = .now,
                                 calendar: Calendar = .current) -> DateOrder? {
        let ns = text as NSString
        if let regex = PatternCache.shared.regex(numericDatePattern, caseInsensitive: false) {
            for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                let first = Int(ns.substring(with: match.range(at: 1))) ?? 0
                let secondRange = match.range(at: 2).location != NSNotFound ? match.range(at: 2) : match.range(at: 5)
                let second = Int(ns.substring(with: secondRange)) ?? 0
                let yearRange = match.range(at: 3).location != NSNotFound ? match.range(at: 3) : match.range(at: 6)
                let year = yearRange.location != NSNotFound ? Int(ns.substring(with: yearRange)) : nil
                let afterStart = NSMaxRange(match.range)
                let after = ns.substring(with: NSRange(location: afterStart, length: min(10, ns.length - afterStart)))
                if let order = orderByWeekday(first, second, year: year, after: after, now: now, calendar: calendar) { return order }
                // Only full dates: "24/7" and "50/50" are not dates.
                guard year != nil else { continue }
                if first > 12, (1...12).contains(second) { return .dayFirst }
                if second > 12, (1...12).contains(first), second <= 31 { return .monthFirst }
            }
        }
        if let host = senderEmail?.split(separator: "@").last?.lowercased(),
           let ending = host.split(separator: ".").last.map(String.init) {
            if dayFirstEndings.contains(ending) { return .dayFirst }
            if monthFirstEndings.contains(ending) { return .monthFirst }
        }
        return numericDateOrder(byScript: text)
    }

    /// "12/3(木)", "12/3（周四）", "12/3 (목)": Japanese, Chinese and Korean
    /// mail writes the weekday in brackets after a numeric date, and the
    /// weekday says which way round the date is: the reading that falls
    /// on it. A short email has too little kana to say so by its script
    /// (`numericDateOrder(byScript:)`). Nil without a weekday, or when
    /// both readings or neither fall on it. A date without a year is the
    /// next one, as `LocalDates` reads it.
    static func orderByWeekday(_ first: Int, _ second: Int, year: Int?, after: String,
                               now: Date, calendar: Calendar = .current) -> DateOrder? {
        guard first != second, let match = after.patternRange(bracketedWeekday) else { return nil }
        // The day's own character: "木" of "木曜日", "四" of "星期四".
        let name = after[match].filter { !"()（） ".contains($0) }
            .replacingOccurrences(of: "曜日", with: "").replacingOccurrences(of: "曜", with: "").replacingOccurrences(of: "요일", with: "")
        let days: [String: Int] = ["日": 1, "天": 1, "月": 2, "一": 2, "火": 3, "二": 3, "水": 4, "三": 4, "木": 5, "四": 5,
                                   "金": 6, "五": 6, "土": 7, "六": 7, "일": 1, "월": 2, "화": 3, "수": 4, "목": 5, "금": 6, "토": 7,
                                   "1": 2, "2": 3, "3": 4, "4": 5, "5": 6, "6": 7, "7": 1]
        guard let weekday = name.last.flatMap({ days[String($0)] }) else { return nil }
        func falls(day: Int, month: Int) -> Bool {
            var parts = DateComponents(year: year.map { $0 < 100 ? 2000 + $0 : $0 } ?? calendar.component(.year, from: now),
                                       month: month, day: day, hour: 12)
            guard (1...12).contains(month), let date = calendar.date(from: parts),
                  calendar.component(.day, from: date) == day else { return false }
            var found = date
            if year == nil, date < now.addingTimeInterval(-60 * 86_400) {
                parts.year = (parts.year ?? 0) + 1
                found = calendar.date(from: parts) ?? date
            }
            return calendar.component(.weekday, from: found) == weekday
        }
        switch (falls(day: first, month: second), falls(day: second, month: first)) {
        case (true, false): return .dayFirst
        case (false, true): return .monthFirst
        default: return nil
        }
    }

    /// A weekday in brackets: "(木)", "（木曜）", "(周四)", "(星期四)", "(목)",
    /// and "(周4)" as `asciiDigits` leaves it.
    static let bracketedWeekday = #"^\s?[(（]\s?(?:(?:周|週|星期|礼拜|禮拜)[日天一二三四五六1-7]|[日月火水木金土](?:曜日?)?|[일월화수목금토](?:요일)?)\s?[)）]"#

    /// The order the email's own language writes dates in, when that
    /// language uses one order everywhere: Japanese and Korean month
    /// first ("11/12" is the 12th of November), Bengali day first.
    /// Chinese says nothing (Hong Kong and Singapore write the day first).
    static func numericDateOrder(byScript text: String) -> DateOrder? {
        var kanaOrHangul = 0, bengali = 0, latin = 0
        for scalar in text.unicodeScalars.prefix(4_000) {
            switch scalar.value {
            case 0x3040...0x30FF, 0xAC00...0xD7A3: kanaOrHangul += 1
            case 0x0980...0x09FF: bengali += 1
            case 0x41...0x5A, 0x61...0x7A: latin += 1
            default: break
            }
        }
        if kanaOrHangul >= 5, kanaOrHangul * 2 > latin { return .monthFirst }
        if bengali >= 10, bengali > latin { return .dayFirst }
        return nil
    }

    enum NumericReading: Equatable { case notNumeric, ambiguous, date(Date) }

    /// A detected date that is numbers only, read the writer's way. Dots
    /// are always day first (no one writes 11.12.2026 for November 12th).
    /// Ambiguous when both numbers could be the month and `order` is nil.
    /// Without a year, a date read the other way round from the
    /// detector's is the next one after `now`, as `LocalDates` reads one:
    /// the detector's year was for its own reading ("3/12" as March 12th,
    /// 2027 made the 3rd of December a year away).
    static func numericReading(of phrase: String, detected: Date, order: DateOrder?, now: Date? = nil,
                               calendar: Calendar = .current) -> NumericReading {
        let ns = phrase as NSString
        guard let regex = PatternCache.shared.regex(numericDatePattern, caseInsensitive: false),
              let match = regex.firstMatch(in: phrase, range: NSRange(location: 0, length: ns.length)) else { return .notNumeric }
        let slashed = match.range(at: 2).location != NSNotFound
        let first = Int(ns.substring(with: match.range(at: 1))) ?? 0
        let second = Int(ns.substring(with: match.range(at: slashed ? 2 : 5))) ?? 0
        let yearRange = match.range(at: slashed ? 3 : 6)
        let dayFirst: Bool
        if !slashed { dayFirst = true }
        else if first == second { dayFirst = true }
        else if first > 12 { dayFirst = true }
        else if second > 12 { dayFirst = false }
        else if let order { dayFirst = order == .dayFirst }
        else { return .ambiguous }
        let (day, month) = dayFirst ? (first, second) : (second, first)
        guard (1...12).contains(month), (1...31).contains(day) else { return .notNumeric }
        var parts = calendar.dateComponents([.year, .hour, .minute], from: detected)
        if yearRange.location != NSNotFound, let written = Int(ns.substring(with: yearRange)) {
            parts.year = written < 100 ? 2000 + written : written
        }
        let swapped = calendar.component(.month, from: detected) != month || calendar.component(.day, from: detected) != day
        if yearRange.location == NSNotFound, swapped, let now { parts.year = calendar.component(.year, from: now) }
        parts.month = month
        parts.day = day
        guard var date = calendar.date(from: parts), calendar.component(.day, from: date) == day else { return .notNumeric }
        if yearRange.location == NSNotFound, swapped, let now, date < now.addingTimeInterval(-60 * 86_400) {
            parts.year = (parts.year ?? 0) + 1
            date = calendar.date(from: parts) ?? date
        }
        return .date(date)
    }

    /// Automated mail that carries a real obligation for this person: a
    /// bill, a signature, a renewal, an appointment. Only ever combined
    /// with a detected deadline, and never applied to promotions.
    /// Something the reader has to do, not just something that will
    /// happen: "payment due", "sign by", "your appointment", "verify".
    /// A welcome, receipt or autopay notice ("will be charged
    /// automatically", "thanks for your payment") is information, never an
    /// obligation, however many dates it names.
    ///
    /// Only the opening counts: a real reminder says what's due up top,
    /// while "pay by the due date each month" in a sale's fine print or
    /// "updates due on job numbers" in a news story said nothing to the
    /// reader, yet brought both into Needs You.
    public static func isObligation(_ text: String) -> Bool {
        let lower = oneBengaliSpelling(String(text.prefix(obligationOpening))).lowercased()
        guard lower.matchesAny(obligationAction) else { return false }
        // An appointment or reservation reminder stays even if it thanks you.
        return lower.patternRange(reminderWords) != nil || !lower.matchesAny(marketingNotice)
    }

    /// What the reader has to do, in English and the app's other
    /// languages: "Zahlung fällig", "à régler avant", "fecha de
    /// vencimiento", "boleto vence", "お支払い期限", "납부 기한", "缴费截止",
    /// "পরিশোধের শেষ তারিখ".
    static let obligationAction: [String] = [
        #"\b(payment (is )?(due|failed|declined|overdue)|past due|amount due|due (date|on|by)|pay (by|now|your)|bill (is )?(due|ready)|balance (is )?due|invoice (is )?due|sign (by|the|your|here)|signature (requested|required|needed)|please sign|verify (your|by)|action (is )?required|expires? (on|in|soon|today|tomorrow)|expiring|renew (by|before|now)|appointment|check-in|reservation|rsvp|deadline)\b"#,
        #"\b(zahlung (ist )?fällig|fällig (am|bis)|zahlbar bis|bitte (bezahlen|überweisen|unterschreiben)|zahlungserinnerung|mahnung|unterschrift erforderlich|ihr termin|terminerinnerung|handlungsbedarf|läuft (am|bald) ab)\b"#,
        #"\b(paiement (dû|en retard|refusé)|à (payer|régler) avant|date d'échéance|facture (due|à payer)|veuillez (payer|régler|signer)|signature requise|votre rendez-vous|votre réservation|action requise|expire (le|bientôt))\b"#,
        #"\b(pago (pendiente|vencido|rechazado)|fecha de vencimiento|vence el|por favor (pague|firme)|firma requerida|(su|tu) cita|(su|tu) reserva|acción requerida|caduca (el|pronto))\b"#,
        #"\b(pagamento (pendente|vencido|recusado)|data de vencimento|vence em|boleto|por favor,? (pague|assine)|assinatura (necessária|pendente)|sua consulta|seu agendamento|sua reserva|ação necessária|expira (em|hoje|amanhã))\b"#,
        #"\b(পরিশোধের শেষ তারিখ|বিল পরিশোধ|বকেয়া|স্বাক্ষর করুন|অ্যাপয়েন্টমেন্ট|মেয়াদ শেষ)\b"#,
        #"お支払い期限|支払期限|お支払いのお願い|ご請求|請求書|署名(をお願い|が必要)|ご予約|ご来院|受診|要対応|有効期限|납부 ?기한|결제 ?기한|청구서|미납|연체|서명(이 필요|을 요청| 요청)|예약|진료|조치(가)? 필요|만료|付款截止|缴费|繳費|到期|逾期|账单|帳單|请签署|請簽署|预约|預約|就诊|就診|需要(处理|處理)"#,
    ]

    /// A reminder of something booked, which stays even when it thanks you.
    static let reminderWords = #"\b(appointment|reservation|check-in|rsvp|termin|rendez-vous|réservation|cita|reserva|consulta|agendamento|অ্যাপয়েন্টমেন্ট)\b|ご予約|ご来院|예약|진료|预约|預約|就诊|就診"#

    /// Marketing urgency is a sale, not an obligation: "LAST CHANCE, your
    /// rewards points expire tomorrow", "Letzte Chance", "期間限定". Nor is
    /// a receipt, a welcome or an autopay notice.
    static let marketingNotice: [String] = [
        #"\b(last chance|don.?t miss|limited time|(points|rewards?) (expire|are expiring)|ends (today|tonight|soon)|\d+% off|will be (charged|billed|renewed) (automatically|monthly|annually)|(automatically|auto-?) ?(charged|billed|renews?)|thank(s| you) for (your )?(payment|order|purchase)|payment (received|confirmed|successful)|receipt|welcome to|auto-?pay (is )?(on|scheduled|set up|enabled|active)|(you're |you are )?enrolled in auto-?pay|automatic payment (is |has been )?scheduled|(will|is set to) be paid automatically)\b"#,
        #"\b(letzte chance|nur heute|\d+ ?% rabatt|wird automatisch (abgebucht|verlängert)|(vielen )?dank für ihre (zahlung|bestellung)|zahlung (erhalten|bestätigt)|quittung|willkommen (bei|zu))\b"#,
        #"\b(dernière chance|offre limitée|sera (prélevé|renouvelé) automatiquement|merci pour votre (paiement|commande|achat)|paiement (reçu|confirmé)|bienvenue (chez|sur|à))\b"#,
        #"\b(última (oportunidad|chance)|tiempo limitado|por tempo limitado|se (cobrará|renovará) automáticamente|gracias por (su|tu) (pago|compra|pedido)|pago (recibido|confirmado)|será (cobrado|renovado) automaticamente|obrigad[oa] pel[oa] (seu |sua )?(pagamento|compra|pedido)|pagamento (recebido|confirmado)|recibo|bienvenid[oa] a|bem-vind[oa] (a|ao|à))\b"#,
        #"\b(শেষ সুযোগ|সীমিত সময়|স্বয়ংক্রিয়ভাবে|(পেমেন্টের|কেনাকাটার|অর্ডারের) জন্য ধন্যবাদ|পেমেন্ট সফল|রসিদ|স্বাগতম)\b"#,
        #"最後のチャンス|期間限定|自動(更新|引き落とし)|ご(購入|注文|入金)ありがとう|お支払いありがとう|領収書|へようこそ|ポイント.{0,6}失効|마지막 기회|기간 한정|자동 ?(결제|갱신)|(결제|구매|주문)해 주셔서 감사|영수증|오신 것을 환영|포인트.{0,6}소멸|最后机会|最後機會|限时|限時|自动(续费|扣款)|自動(續費|扣款)|感谢您的(付款|购买|订单|支付)|感謝您的(付款|購買|訂單|支付)|(付款|支付)成功|收据|收據|欢迎(加入|使用|来到)|歡迎(加入|使用|來到)|积分.{0,6}过期"#,
    ]

    /// About something that happens on a day (an appointment, a class, a
    /// flight), not something to get done by one (a bill, a signature).
    /// Once that day is over there's nothing left to do: the email leaves
    /// Needs You by itself, the way Gmail's "Happening soon" cards drop off
    /// after the event. A missed payment is different, and stays overdue.
    /// Kept per text: a Needs You row with a date asks this on every redraw.
    public static func isEvent(_ text: String) -> Bool {
        eventMemo.value(text) { isEventUncached(text) }
    }
    private static let eventMemo = Memo<String, Bool>()

    private static func isEventUncached(_ text: String) -> Bool {
        let lower = oneBengaliSpelling(text).lowercased()
        let event = [#"\b(appointments?|reservations?|check-?in|meeting|class(es)?|session|visit|interview|webinar|flight|booking|lesson|tour|consultation|exam|screening|event|concert|show(time)?|game|ceremony|termin|besprechung|sitzung|flug|reservierung|buchung|veranstaltung|rendez-vous|réunion|réservation|entretien|cita|reunión|vuelo|reserva|entrevista|consulta|reunião|voo|agendamento|evento|événement|অ্যাপয়েন্টমেন্ট|মিটিং|সভা|ফ্লাইট|বুকিং|সাক্ষাৎকার)\b"#, #"予約|会議|打ち合わせ|面接|フライト|搭乗|診察|예약|회의|미팅|면접|항공편|진료|预约|預約|会议|會議|面试|面試|航班|就诊|就診"#]
        let task = [#"\b(payment|pay (by|now|your)|bill|invoice|balance|amount due|past due|sign(ature)?|renew|expir|submit|application|form|zahlung|rechnung|bezahlen|unterschr\w*|paiement|facture|signer|pago|factura|firma|pagamento|fatura|boleto|assinatura|পেমেন্ট|বিল|স্বাক্ষর)\b"#, #"支払|請求|署名|결제|납부|청구|서명|付款|缴费|繳費|账单|帳單|签署|簽署"#]
        return lower.matchesAny(event) && !lower.matchesAny(task)
    }

    /// Something has gone wrong that only you can fix, date or not: a
    /// payment that failed, a card declined, an account on hold. Said up
    /// top, like any obligation, in any of the app's languages.
    public static func isFailure(_ text: String) -> Bool {
        let lower = oneBengaliSpelling(String(text.prefix(obligationOpening))).lowercased()
        return lower.matchesAny(failurePattern)
    }

    static let failurePattern: [String] = [

        #"\b(payment (has |was )?(failed|declined|unsuccessful)|unable to process your (recent )?(\w+ )?payment|card (was |has been )?declined|(account|subscription|service) (is |has been )?(suspended|on hold|locked|past due))\b"#,

        #"\b(zahlung (ist |wurde )?(fehlgeschlagen|abgelehnt)|(karte|kreditkarte) (wurde )?abgelehnt|(konto|abonnement) (wurde |ist )?gesperrt|abbuchung (ist )?fehlgeschlagen|lastschrift [^.]{0,20}(zurückgegeben|fehlgeschlagen))\b"#,

        #"\b((le )?paiement (a )?échoué|échec (du|de votre) paiement|paiement (a été )?refusé|carte (a été )?refusée|compte (est |a été )?(suspendu|bloqué))\b"#,

        #"\b((el )?pago (ha )?(fallado|sido rechazado)|pago rechazado|no (hemos podido|pudimos) procesar (su|tu) pago|tarjeta rechazada|cuenta (suspendida|bloqueada))\b"#,

        #"\b(pagamento (falhou|foi recusado|recusado|não aprovado)|não (foi possível|conseguimos) processar (o )?seu pagamento|cartão recusado|conta (suspensa|bloqueada))\b"#,

        #"\b(পেমেন্ট ব্যর্থ|লেনদেন ব্যর্থ|কার্ড প্রত্যাখ্যাত|অ্যাকাউন্ট স্থগিত)\b"#,

        #"お支払いに失敗|決済(に失敗|エラー|できませんでした)|カード.{0,10}(拒否|ご利用いただけません)|アカウント.{0,6}(停止|ロック)|결제(에)? ?실패|결제가 거절|카드.{0,6}거절|계정.{0,6}(정지|잠김|잠금)|(付款|支付|扣款)失(败|敗)|卡.{0,6}被拒|(账户|帳戶).{0,6}(冻结|凍結|停用|锁定|鎖定)"#,

    ]

    /// A payment asked of you, with its amount, date or not: "payment in
    /// the amount of $188.00 is required to complete your application",
    /// "offener Betrag", "montant à payer", "ご請求金額", "청구 금액",
    /// "应付金额". Said up top. Not a receipt, an autopay notice, or a
    /// reminder that thanks you if you've already paid.
    public static func isPaymentRequest(_ text: String) -> Bool {
        let opening = oneBengaliSpelling(String(text.prefix(obligationOpening)))
        let lower = opening.lowercased()
        // The amount as written: currency codes are capitals ("BDT 2,500",
        // "Tk 1,250", "Rs 500"), and lowercased they were never found.
        guard lower.matchesAny(paymentRequestPattern),
              opening.patternRange(MailDigest.amountPattern) != nil
        else { return false }
        return !lower.matchesAny(alreadyPaidPattern)
    }

    static let paymentRequestPattern: [String] = [

        #"\b(payment (request(ed)?|(in the amount of [^.]{1,40} )?(is )?required)|please (make|submit) (a |your )?payment|(amount|balance) (is )?(now )?due)\b"#,

        #"\b(zahlungsaufforderung|bitte (bezahlen|überweisen) sie|(offener|ausstehender|fälliger) betrag|betrag (ist )?fällig)\b"#,

        #"\b(demande de paiement|montant (dû|à payer)|solde (dû|à payer)|veuillez (effectuer|procéder au) (le |votre )?paiement)\b"#,

        #"\b(solicitud de pago|(importe|monto) (pendiente|a pagar)|saldo pendiente|por favor realice (el|su) pago)\b"#,

        #"\b(solicitação de pagamento|valor (em aberto|a pagar|devido)|saldo devedor|por favor,? (efetue|realize) o pagamento)\b"#,

        #"\b(পরিশোধ করুন|বকেয়া পরিমাণ|প্রদেয় পরিমাণ|পেমেন্ট অনুরোধ)\b"#,

        #"お支払いのお願い|ご請求金額|お支払い金額|請求金額|お振込み?のお願い|결제 요청|납부 요청|청구 금액|납부하실 금액|결제하실 금액|付款(请求|請求)|请付款|請付款|(应付|應付)金额|應付金額|待(付款|支付)|请缴纳|請繳納"#,

    ]

    static let alreadyPaidPattern: [String] = [

        #"\b(if you('ve| have) already paid|thank(s| you) for your payment|payment (received|confirmed|successful)|autopay|automatic payment)\b"#,

        #"\b(bereits (bezahlt|überwiesen)|dank für ihre zahlung|lastschrift|déjà (payé|réglé)|merci pour votre paiement|prélèvement automatique|ya (ha|has) pagado|gracias por (su|tu) pago|domiciliación|já (pagou|efetuou|foi pago)|débito automático|ইতিমধ্যে পরিশোধ)\b"#,

        #"お支払い済み|支払い済み|自動引き落とし|口座振替|이미 (결제|납부)|자동이체|已(付款|支付|繳費|缴费)|自动扣款|自動扣款"#,

    ]

    /// How much of an email's start states its obligation, in characters:
    /// the subject and the first few sentences.
    static let obligationOpening = 600

    /// Whether anyone you wrote to is a person rather than a no-reply
    /// system address: waiting on `noreply@` makes no sense.
    /// Recipients are read for their addresses: Outlook and IMAP keep the
    /// name too ("Support <noreply@shop.com>"), which hid the no-reply.
    public static func hasPersonRecipient(_ recipients: [String], account: String) -> Bool {
        recipients.contains { address in
            let bare = Correspondence.bareAddress(address)
            return !bare.isEmpty && bare != account.lowercased()
                && bare.patternRange(Correspondence.automatedLocalPart) == nil
        }
    }
}

/// Dates as Chinese, Japanese, Korean and Bengali mail writes them, which
/// Apple's date detector doesn't read: "2026年11月12日", "11月12日(木)
/// 15時", "11월 12일 오후 3시", "11月12日下午3点半", "১২ নভেম্বর ২০২৬
/// সকাল ১০টায়". Times alone ("15時", "오후 3시") too, for an event whose day
/// is said elsewhere.
enum LocalDates {
    struct Found: Equatable {
        let date: Date
        let hasDay: Bool
        let hasTime: Bool
        /// In the text with its digits made ASCII (same length).
        let range: NSRange
    }

    static let datePattern = #"(?:(\d{4})\s?[年년]\s?)?(\d{1,2})\s?[月월]\s?(\d{1,2})\s?[日일号號]"#
    static let bengaliMonths = ["জানুয়ারি", "ফেব্রুয়ারি", "মার্চ", "এপ্রিল", "মে", "জুন", "জুলাই", "আগস্ট", "সেপ্টেম্বর",
                                "অক্টোবর", "নভেম্বর", "ডিসেম্বর"]
    /// "মে" (May) never as the start of a longer word ("মেইল"), but with
    /// its "of" ending: "৫ জানুয়ারির মধ্যে", "জুলাইয়ের", "মের" (by the 5th
    /// of January), which a month ending in a vowel takes as a letter.
    static let bengaliPattern = #"(\d{1,2})\s?("# + bengaliMonths.joined(separator: "|") + #")(?=(?:র|\x{09DF}ের|\x{09AF}\x{09BC}ের)?(?!\p{L}))(?:,?\s?(\d{4}))?"#
    /// A clock time: "15:30", "15時", "午後3時半", "下午3点", "오후 3시 30분",
    /// "সকাল ১০টায়", "রাতে ১২টার". Not "3時間" or "2시간" (hours, not a
    /// time). Midnight and noon as words too: "자정", "정오", "মধ্যরাত".
    static let timePattern = #"(?:(午前|午後|上午|下午|中午|晚上|早上|凌晨|오전|오후|낮|밤|저녁|아침|새벽|সকাল|দুপুর|বিকাল|বিকেল|সন্ধ্যা|রাত)(?:\x{09C7}|\x{09DF}|\x{09AF}\x{09BC})?)?\s?(\d{1,2})\s?(?:[:：]\s?(\d{2})|([時时點点](?!間|间)|시(?!간)|টা)\s?(?:(\d{1,2})\s?[分분]|(半))?)|(자정|정오|মধ্যরাত|মাঝরাত)"#

    /// Han numerals reach here half read: `asciiDigits` turns "一" to "九"
    /// into digits but leaves "十", so "十一月五日" (November 5th) was "十1月5日",
    /// January 5th, and "十一点" one o'clock. A number right after one of
    /// them is part of a bigger one, and not read at all.
    static func followsHanNumeral(_ range: NSRange, in ns: NSString) -> Bool {
        guard range.location != NSNotFound, range.location > 0 else { return false }
        return "十百千拾".contains(ns.substring(with: NSRange(location: range.location - 1, length: 1)))
    }

    /// `nextDay`: midnight, which ends the day it's said with ("12일
    /// 자정" is when the 12th turns into the 13th).
    /// `original`: the text before `asciiDigits`, to tell a Han numeral.
    static func clock(_ match: NSTextCheckingResult, in ns: NSString,
                      original: NSString? = nil) -> (hour: Int, minute: Int, nextDay: Bool)? {
        func number(_ group: Int) -> Int? {
            let range = match.range(at: group)
            return range.location == NSNotFound ? nil : Int(ns.substring(with: range))
        }
        func text(_ group: Int) -> String {
            match.range(at: group).location == NSNotFound ? "" : ns.substring(with: match.range(at: group))
        }
        switch text(7) {
        case "": break
        case "정오": return (12, 0, false)
        default: return (0, 0, true)
        }
        guard var hour = number(2), !followsHanNumeral(match.range(at: 2), in: ns) else { return nil }
        let minute = number(3) ?? number(5) ?? (match.range(at: 6).location != NSNotFound ? 30 : 0)
        let marker = text(1)
        // "一時的に" (for a while) and "一时" are not one o'clock: an hour
        // in Han numerals is a time only with a time of day ("午後三時") or
        // minutes ("三時半").
        let hourRange = match.range(at: 2)
        if marker.isEmpty, match.range(at: 5).location == NSNotFound, match.range(at: 6).location == NSNotFound,
           let original, NSMaxRange(hourRange) <= original.length,
           original.substring(with: hourRange).unicodeScalars.contains(where: { (0x4E00...0x9FFF).contains($0.value) }) {
            return nil
        }
        // "৫টা বই" is five books: a Bengali টা is a time with a time of
        // day ("রাত ১২টার"), or alone as "৫টায়" or "৫টা বাজে".
        if text(4) == "টা", marker.isEmpty {
            let start = NSMaxRange(match.range(at: 4))
            let after = ns.substring(with: NSRange(location: start, length: min(6, ns.length - start)))
            let first = after.unicodeScalars.first
            guard first == "\u{09AF}" || first == "\u{09DF}" || after.drop(while: { $0 == " " }).hasPrefix("বাজে") else { return nil }
        }
        // 12 at night is midnight ("밤 12시", "রাত ১২টা", "晚上12点"), and
        // so is "24시"; 12 by day stays noon ("낮 12시", "오후 12시",
        // "দুপুর ১২টা").
        if ["밤", "রাত", "晚上"].contains(marker) && hour == 12 || hour == 24 && minute == 0 { return (0, minute, true) }
        if marker == "새벽", hour == 12 { hour = 0 }
        if ["午後", "下午", "晚上", "오후", "밤", "저녁", "বিকাল", "বিকেল", "সন্ধ্যা", "রাত"].contains(marker), hour < 12 { hour += 12 }
        // "3시", "3点" with no morning or afternoon word: a meeting at
        // three is in the afternoon.
        if marker.isEmpty || marker == "দুপুর" || marker == "낮", !text(4).isEmpty, (1...6).contains(hour) { hour += 12 }
        guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        return (hour, minute, false)
    }

    static func find(in source: String, now: Date, calendar: Calendar = .current) -> [Found] {
        let digits = MailDigest.asciiDigits(source)
        let ns = digits as NSString
        guard digits.contains(where: { !$0.isASCII }),
              let dates = PatternCache.shared.regex(datePattern + "|" + bengaliPattern, caseInsensitive: false),
              let times = PatternCache.shared.regex(timePattern, caseInsensitive: false) else { return [] }
        func number(_ match: NSTextCheckingResult, _ group: Int) -> Int? {
            let range = match.range(at: group)
            return range.location == NSNotFound ? nil : Int(ns.substring(with: range))
        }
        func text(_ match: NSTextCheckingResult, _ group: Int) -> String {
            match.range(at: group).location == NSNotFound ? "" : ns.substring(with: match.range(at: group))
        }
        func clock(_ match: NSTextCheckingResult) -> (hour: Int, minute: Int, nextDay: Bool)? { Self.clock(match, in: ns, original: source as NSString) }
        var found: [Found] = []
        var used: [NSRange] = []
        for match in dates.matches(in: digits, range: NSRange(location: 0, length: ns.length)) {
            let month: Int, day: Int, year: Int?
            if followsHanNumeral(match.range(at: 2), in: ns) { continue }
            if match.range(at: 2).location != NSNotFound {
                (month, day, year) = (number(match, 2) ?? 0, number(match, 3) ?? 0, number(match, 1))
            } else {
                let name = ns.substring(with: match.range(at: 5))
                (month, day, year) = ((bengaliMonths.firstIndex(of: name) ?? -1) + 1, number(match, 4) ?? 0, number(match, 6))
            }
            guard (1...12).contains(month), (1...31).contains(day) else { continue }
            // A time just after it: "11月12日(木) 15時", "11월 12일 오후 3시".
            var range = match.range
            var time: (hour: Int, minute: Int, nextDay: Bool)?
            let tail = NSRange(location: NSMaxRange(match.range), length: min(16, ns.length - NSMaxRange(match.range)))
            if let next = times.firstMatch(in: digits, range: tail),
               ns.substring(with: NSRange(location: tail.location, length: next.range.location - tail.location))
                .allSatisfy({ !$0.isNumber && !$0.isNewline }),
               let parsed = clock(next) {
                time = parsed
                range = NSUnionRange(range, next.range)
            }
            var parts = DateComponents(year: year ?? calendar.component(.year, from: now), month: month, day: day,
                                       hour: time?.hour ?? 12, minute: time?.minute ?? 0)
            guard var date = calendar.date(from: parts), calendar.component(.day, from: date) == day else { continue }
            // No year: the next one, once this year's has long passed.
            if year == nil, date < now.addingTimeInterval(-60 * 86_400) {
                parts.year = (parts.year ?? 0) + 1
                date = calendar.date(from: parts) ?? date
            }
            if time?.nextDay == true { date = calendar.date(byAdding: .day, value: 1, to: date) ?? date }
            found.append(Found(date: date, hasDay: true, hasTime: time != nil, range: range))
            used.append(range)
        }
        for match in times.matches(in: digits, range: NSRange(location: 0, length: ns.length)) {
            // CJK and Bengali clock words only; "15:30" alone is the
            // detector's.
            guard match.range(at: 3).location == NSNotFound,
                  !used.contains(where: { NSIntersectionRange($0, match.range).length > 0 }),
                  // "以下3点" is three points: a Chinese 点 alone is a time
                  // only with 上午/下午 or minutes ("下午3点", "3点半").
                  !(["点", "點"].contains(text(match, 4)) && text(match, 1).isEmpty && match.range(at: 5).location == NSNotFound
                    && match.range(at: 6).location == NSNotFound),
                  let time = clock(match),
                  var date = calendar.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: now) else { continue }
            if time.nextDay { date = calendar.date(byAdding: .day, value: 1, to: date) ?? date }
            found.append(Found(date: date, hasDay: false, hasTime: true, range: match.range))
        }
        return found
    }

    // MARK: Relative deadlines

    /// A day said relative to today in Japanese, Korean, Chinese or
    /// Bengali: today, tomorrow, the day after, a weekday ("金曜日", "금요일",
    /// "周五", "শুক্রবার"), or a weekday next week ("来週の月曜日", "다음 주
    /// 월요일", "下周一").
    static let relativeDayPattern = #"(来週の?\s?|다음\s?주\s?|下\s?(?:个|個)?\s?(?:周|週|星期|礼拜|禮拜))?(?:(本日|今日|明後日|明日|あさって|あした|あす|오늘|내일|모레|今天|后天|後天|明天)|([月火水木金土日])曜日?|([일월화수목금토])요일|(?:周|週|星期|礼拜|禮拜)([日天一二三四五六1-6]))|(?<![\p{L}\p{M}])(আজ(?:কের)?|আগামীকাল|পরশু|(রবি|সোম|মঙ্গল|বুধ|বৃহস্পতি|শুক্র|শনি)বার)"#

    /// What makes it a deadline when it follows: "までに" (by; "まで" alone
    /// is until: "金曜日まで休みます"), "中に" ("本日中に", by the end of
    /// today), "까지", "之前", "前" (not "前往", to go to), "এর মধ্যে".
    static let relativeLeadOut = #"^\s?(?:ের|এর|র)?\s?(?:までに|迄に|中に|까지|之前|以前|前(?![往进進来來去])|মধ্যে)"#

    /// Deadlines a Japanese, Korean, Chinese or Bengali email gives by a
    /// day relative to when it was written: "金曜日までにご返信ください",
    /// "내일 오후 5시까지", "请于周五前回复", "শুক্রবারের মধ্যে", "期限：明日".
    /// Only for mail written today, as with "by Friday" in English. A day
    /// without a time is due at noon (as the date detector reads one),
    /// and today's at its last minute.
    static func relativeDeadlines(in source: String, now: Date, calendar: Calendar = .current) -> [Date] {
        let digits = MailDigest.asciiDigits(source)
        let ns = digits as NSString
        guard digits.contains(where: { !$0.isASCII }),
              let days = PatternCache.shared.regex(relativeDayPattern, caseInsensitive: false),
              let times = PatternCache.shared.regex(timePattern, caseInsensitive: false) else { return [] }
        let today = calendar.startOfDay(for: now)
        let weekdays: [String: Int] = ["日": 1, "天": 1, "일": 1, "রবি": 1, "月": 2, "一": 2, "월": 2, "সোম": 2,
                                       "火": 3, "二": 3, "화": 3, "মঙ্গল": 3, "水": 4, "三": 4, "수": 4, "বুধ": 4,
                                       "木": 5, "四": 5, "목": 5, "বৃহস্পতি": 5, "金": 6, "五": 6, "금": 6, "শুক্র": 6,
                                       "土": 7, "六": 7, "토": 7, "শনি": 7,
                                       // "周五" reaches here as "周5" (`asciiDigits` reads Chinese numerals).
                                       "1": 2, "2": 3, "3": 4, "4": 5, "5": 6, "6": 7]
        func text(_ match: NSTextCheckingResult, _ group: Int) -> String {
            match.range(at: group).location == NSNotFound ? "" : ns.substring(with: match.range(at: group))
        }
        var found: [Date] = []
        for match in days.matches(in: digits, range: NSRange(location: 0, length: ns.length)) {
            var day: Date?
            switch text(match, 2) + text(match, 6) {
            case "本日", "今日", "오늘", "今天", "আজ", "আজকের": day = today
            case "明日", "あした", "あす", "내일", "明天", "আগামীকাল": day = calendar.date(byAdding: .day, value: 1, to: today)
            case "明後日", "あさって", "모레", "后天", "後天", "পরশু": day = calendar.date(byAdding: .day, value: 2, to: today)
            default:
                guard let weekday = weekdays[text(match, 3) + text(match, 4) + text(match, 5) + text(match, 7)] else { continue }
                // The coming one (today's, said on that day), or the one in
                // the week after this.
                var start = today
                if !text(match, 1).isEmpty, let following = calendar.dateInterval(of: .weekOfYear, for: today)?.end {
                    start = calendar.startOfDay(for: following)
                }
                let delta = (weekday - calendar.component(.weekday, from: start) + 7) % 7
                day = calendar.date(byAdding: .day, value: delta, to: start)
            }
            guard let day else { continue }
            // A time just after it: "明日の17時までに", "내일 오후 5시까지".
            var end = NSMaxRange(match.range)
            var time: (hour: Int, minute: Int, nextDay: Bool)?
            let tail = NSRange(location: end, length: min(16, ns.length - end))
            if let next = times.firstMatch(in: digits, range: tail),
               ns.substring(with: NSRange(location: end, length: next.range.location - end))
                .allSatisfy({ !$0.isNumber && !$0.isNewline && $0 != "。" && $0 != "." }),
               let parsed = clock(next, in: ns, original: source as NSString) {
                time = parsed
                end = NSMaxRange(next.range)
            }
            let after = ns.substring(with: NSRange(location: end, length: min(10, ns.length - end)))
            let start = max(0, match.range.location - 12)
            let before = ns.substring(with: NSRange(location: start, length: match.range.location - start))
            guard after.patternRange(relativeLeadOut) != nil || before.patternRange(MailSignals.numericLocalLeadIn) != nil else { continue }
            let date: Date?
            switch time {
            // Midnight ends the day: due at its last minute.
            case let time? where time.nextDay:
                date = calendar.date(byAdding: .day, value: 1, to: day).map { $0.addingTimeInterval(-60) }
            case let time?:
                date = calendar.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: day)
            case nil:
                date = day == today ? calendar.date(bySettingHour: 23, minute: 59, second: 0, of: day)
                    : calendar.date(bySettingHour: 12, minute: 0, second: 0, of: day)
            }
            if let date { found.append(date) }
        }
        return found
    }
}

/// Something the reader could put on their calendar: an appointment, a
/// reservation, a meeting, a flight, an interview.
public struct EventSuggestion: Equatable, Sendable {
    public let title: String
    public let start: Date
    /// When the email says (a range, the booking data or an invite);
    /// otherwise an hour after `start`.
    public let end: Date?
    public let location: String?
    /// The confirmation or reservation number, when the email gives one.
    public let confirmation: String?

    public init(title: String, start: Date, end: Date? = nil, location: String?, confirmation: String? = nil) {
        self.title = title
        self.start = start
        self.end = end
        self.location = location
        self.confirmation = confirmation
    }
}

/// Finds the event an email is about, most reliable source first, the
/// order Mail and Gmail use:
/// 1. booking data the sender embedded for mail apps (schema.org JSON-LD:
///    Event, EventReservation, FlightReservation, LodgingReservation,
///    FoodEstablishmentReservation), exact to the minute;
/// 2. a calendar invite (.ics);
/// 3. the wording, with Apple's date and address detectors.
public enum EventFinder {
    public static func event(text: String, html: String?, subject: String, receivedAt: Date,
                             now: Date = .now) -> EventSuggestion? {
        if let html, let structured = fromStructuredData(html, now: now) { return structured }
        return fromWording(text, subject: subject, receivedAt: receivedAt, now: now)
    }

    // MARK: Structured data

    public static func fromStructuredData(_ html: String, now: Date = .now) -> EventSuggestion? {
        structuredItems(in: html).compactMap(suggestion(from:))
            .filter { $0.start > now.addingTimeInterval(-3_600) }
            .min { $0.start < $1.start }
    }

    /// Every schema.org item the sender embedded for mail apps (JSON-LD),
    /// `@graph` lists opened up.
    static func structuredItems(in html: String) -> [[String: Any]] {
        guard html.range(of: "application/ld+json", options: .caseInsensitive) != nil else { return [] }
        let pattern = #"(?is)<script[^>]*type\s*=\s*["']application/ld\+json["'][^>]*>(.*?)</script>"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let ns = html as NSString
        var items: [[String: Any]] = []
        for match in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let json = ns.substring(with: match.range(at: 1))
            guard let data = json.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) else { continue }
            let found = (object as? [[String: Any]]) ?? [(object as? [String: Any])].compactMap { $0 }
            items += found.flatMap(flattenGraph)
        }
        return items
    }

    private static func flattenGraph(_ item: [String: Any]) -> [[String: Any]] {
        if let graph = item["@graph"] as? [[String: Any]] { return graph }
        return [item]
    }

    private static func suggestion(from item: [String: Any]) -> EventSuggestion? {
        let type = (item["@type"] as? String) ?? ""
        let reservationFor = item["reservationFor"] as? [String: Any]
        let subject = reservationFor ?? item
        let confirmation = item["reservationNumber"] as? String ?? item["confirmationNumber"] as? String
        switch type {
        case "FlightReservation":
            guard let flight = reservationFor,
                  let departs = date(flight["departureTime"]) else { return nil }
            let airline = (flight["airline"] as? [String: Any])?["name"] as? String
                ?? (flight["airline"] as? [String: Any])?["iataCode"] as? String ?? ""
            let number = flight["flightNumber"] as? String ?? ""
            let from = (flight["departureAirport"] as? [String: Any])?["iataCode"] as? String
            let to = (flight["arrivalAirport"] as? [String: Any])?["iataCode"] as? String
            let route = [from, to].compactMap { $0 }.joined(separator: " → ")
            let title = [String(localized: "Flight"), [airline, number].filter { !$0.isEmpty }.joined(separator: " "), route]
                .filter { !$0.isEmpty }.joined(separator: " ")
            let airport = (flight["departureAirport"] as? [String: Any])?["name"] as? String
            return EventSuggestion(title: title, start: departs, end: date(flight["arrivalTime"]),
                                   location: airport, confirmation: confirmation)
        case "LodgingReservation":
            guard let checkin = date(item["checkinTime"] ?? item["checkinDate"]) else { return nil }
            let name = (reservationFor?["name"] as? String) ?? String(localized: "Hotel")
            return EventSuggestion(title: String(localized: "Stay at \(name)"), start: checkin, end: date(item["checkoutTime"] ?? item["checkoutDate"]),
                                   location: place(reservationFor?["address"]) ?? place(reservationFor),
                                   confirmation: confirmation)
        case "FoodEstablishmentReservation":
            guard let time = date(item["startTime"] ?? item["startDate"]) else { return nil }
            let name = (reservationFor?["name"] as? String) ?? String(localized: "Reservation")
            return EventSuggestion(title: name, start: time, end: date(item["endTime"]),
                                   location: place(reservationFor?["address"]) ?? place(reservationFor),
                                   confirmation: confirmation)
        default:
            // Event, EventReservation and other reservations with a start.
            guard type.hasSuffix("Event") || type.hasSuffix("Reservation"),
                  let start = date(subject["startDate"] ?? item["startTime"] ?? item["startDate"]) else { return nil }
            let name = subject["name"] as? String ?? String(localized: "Event")
            return EventSuggestion(title: name, start: start, end: date(subject["endDate"] ?? item["endTime"]),
                                   location: place(subject["location"]), confirmation: confirmation)
        }
    }

    private static func date(_ value: Any?) -> Date? {
        guard let string = value as? String else { return nil }
        let full = ISO8601DateFormatter()
        full.formatOptions = [.withInternetDateTime]
        if let date = full.date(from: string) { return date }
        full.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = full.date(from: string) { return date }
        // "2026-09-28T14:45:00" with no offset: the reader's own time zone.
        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd"] {
            local.dateFormat = format
            if let date = local.date(from: string) { return date }
        }
        return nil
    }

    private static func place(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        guard let object = value as? [String: Any] else { return nil }
        if let address = object["address"] { return place(address) ?? object["name"] as? String }
        let parts = ["name", "streetAddress", "addressLocality", "addressRegion", "postalCode"]
            .compactMap { object[$0] as? String }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    // MARK: Calendar invites

    /// The first event in an .ics invite, times in their stated zone.
    public static func fromInvite(_ ics: String, now: Date = .now) -> EventSuggestion? {
        let unfolded = ics.replacingOccurrences(of: "\r\n ", with: "").replacingOccurrences(of: "\n ", with: "")
        guard let block = unfolded.range(of: "BEGIN:VEVENT") else { return nil }
        var fields: [String: (value: String, params: String)] = [:]
        for line in unfolded[block.upperBound...].split(whereSeparator: \.isNewline) {
            if line.hasPrefix("END:VEVENT") { break }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon]
            let name = String(key.split(separator: ";").first ?? "")
            if fields[name] == nil { fields[name] = (String(line[line.index(after: colon)...]), String(key)) }
        }
        func icsDate(_ field: (value: String, params: String)?) -> Date? {
            field.flatMap { ICalendar.date($0.value, params: $0.params)?.date }
        }
        guard let start = icsDate(fields["DTSTART"]), start > now.addingTimeInterval(-3_600) else { return nil }
        func text(_ key: String) -> String? {
            fields[key]?.value.replacingOccurrences(of: "\\,", with: ",").replacingOccurrences(of: "\\n", with: " ")
        }
        return EventSuggestion(title: text("SUMMARY") ?? String(localized: "Event"), start: start, end: icsDate(fields["DTEND"]),
                               location: text("LOCATION").flatMap { $0.isEmpty ? nil : $0 })
    }

    // MARK: Wording

    /// What an event is called, in English and the app's other languages
    /// ("Termin", "rendez-vous", "cita", "reunião", "মিটিং"); with word
    /// boundaries.
    private static let eventWords = #"appointment|reservation|booking|meeting|interview|flight|check-in|event|dinner|lunch|call|webinar|session|visit|consultation|class|concert|show|termin|besprechung|sitzung|treffen|veranstaltung|flug|reservierung|buchung|vorstellungsgespräch|rendez-vous|réunion|vol|réservation|entretien|dîner|déjeuner|événement|webinaire|cita|reunión|vuelo|reserva|entrevista|cena|almuerzo|evento|reunião|voo|consulta|jantar|almoço|agendamento|অ্যাপয়েন্টমেন্ট|মিটিং|সভা|ফ্লাইট|বুকিং|সাক্ষাৎকার|অনুষ্ঠান"#
    /// The same in Chinese, Japanese and Korean, which have no spaces to
    /// mark a word's edge.
    private static let cjkEventWords = #"予約|会議|打ち合わせ|ミーティング|面接|フライト|搭乗|診察|イベント|説明会|예약|회의|미팅|면접|항공편|진료|행사|약속|预约|預約|会议|會議|面试|面試|航班|活动|活動|聚餐|晚宴|见面|見面"#

    /// A clock time in what the date detector found: "3:30", "3pm",
    /// "noon", and the European ways, "15 Uhr", "15h30", "15h".
    private static let clockPattern = #"\d:\d\d|\d[.:]\d\d\s?(am|pm)\b|\d\s?(am|pm)\b|noon|\d\s?uhr\b|\d{1,2}\s?h(\d\d)?\b|mittag|midi\b|mediodía|meio-dia"#
    /// A day in it: a weekday or month name in the app's Latin-script
    /// languages, a numeric date (not "7.15pm", nor the "00-15" of a time
    /// range, "14:00-15:00"), or today/tomorrow.
    private static let dayPattern = #"\b(mon|tue|wed|thu|fri|sat|sun)[a-z]*\b|\b(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\b|(?<![:\d])\b\d{1,4}[/-]\d{1,2}\b(?!:)|\b\d{1,2}\.\d{1,2}\.\d{2,4}\b|\b(montag|dienstag|mittwoch|donnerstag|freitag|samstag|sonntag|lundi|mardi|mercredi|jeudi|vendredi|samedi|dimanche|lunes|martes|miércoles|jueves|viernes|sábado|domingo|segunda|terça|quarta|quinta|sexta)\b|\b(januar|februar|märz|mai|juni|juli|oktober|dezember|janvier|février|mars|avril|juin|juillet|août|septembre|octobre|novembre|décembre|enero|febrero|marzo|abril|mayo|junio|julio|agosto|septiembre|octubre|noviembre|diciembre|janeiro|fevereiro|março|maio|junho|julho|setembro|outubro|novembro|dezembro)\b|"# + relativeDayPattern
    private static let relativeDayPattern = #"\b(today|tonight|tomorrow|heute|morgen|aujourd'hui|demain|hoy|mañana|hoje|amanhã)\b"#

    /// The earliest upcoming date with a clock time in the next three
    /// months. Relative days ("tomorrow", "Friday") resolve against today,
    /// so they only count in mail that arrived today; explicit dates
    /// always do. A range ("2:45–3:30 PM") sets the end. Dates in Chinese,
    /// Japanese, Korean and Bengali ("11月12日 15時", "11월 12일 오후 3시")
    /// are read by `LocalDates`.
    public static func fromWording(_ text: String, subject: String, receivedAt: Date, now: Date = .now) -> EventSuggestion? {
        let own = String(MailSignals.ownText(text).prefix(6_000))
        let all = subject + "\n" + own
        guard all.patternRange("(?i)\\b(" + eventWords + ")\\b|" + cjkEventWords) != nil,
              let dates = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else { return nil }
        let arrivedToday = Calendar.current.isDate(receivedAt, inSameDayAs: now)
        let ns = own as NSString
        let calendar = Calendar.current
        // Each date the detector finds is a day, a time, or both. A time on
        // its own ("doors open 19:15", "7.15pm") comes back as today at that
        // time, so a meeting on Thursday the 15th showed as today at 19:15.
        struct Found { let date: Date; let duration: TimeInterval; let hasTime: Bool; let hasDay: Bool }
        let order = MailSignals.numericDateOrder(senderEmail: nil, text: own, now: now)
        // "14:00～15:00" as the detector reads a range (same length as `own`).
        let detectable = MailSignals.withTimeRangesForDetector(own)
        var found = dates.matches(in: detectable, range: NSRange(location: 0, length: ns.length)).compactMap { match -> Found? in
            guard var date = match.date else { return nil }
            let phrase = (detectable as NSString).substring(with: match.range).lowercased()
            let hasTime = phrase.patternRange(clockPattern) != nil
            // 03/11 read the writer's way, or not at all.
            switch MailSignals.numericReading(of: phrase, detected: date, order: order, now: now) {
            case .notNumeric: break
            case .date(let written): date = written
            case .ambiguous: return nil
            }
            // A day: a weekday or month name, a numeric date (not "7.15pm"),
            // or today/tomorrow.
            // In any language: a time alone comes back as today (or
            // tomorrow, once it's passed), so a date on any other day means
            // the phrase named one.
            // Against the real clock, not `now`: the detector reads a time
            // alone as today by the clock, whatever `now` is.
            let dayOffset = calendar.dateComponents([.day], from: calendar.startOfDay(for: Date()),
                                                    to: calendar.startOfDay(for: date)).day ?? 0
            let hasDay = dayOffset > 1 || dayOffset < 0 || phrase.patternRange(dayPattern) != nil
            // "Tomorrow" in an email from days ago isn't tomorrow now.
            let isRelative = phrase.patternRange(relativeDayPattern) != nil
            if isRelative, !arrivedToday { return nil }
            return Found(date: date, duration: match.duration, hasTime: hasTime, hasDay: hasDay)
        }
        found += LocalDates.find(in: own, now: now).map {
            Found(date: $0.date, duration: 0, hasTime: $0.hasTime, hasDay: $0.hasDay)
        }
        let window = { (date: Date) in date > now && date < now.addingTimeInterval(92 * 86_400) }
        // Day and time together.
        var timed = found.filter { $0.hasTime && $0.hasDay && window($0.date) }.map { ($0.date, $0.duration) }
        // Day in one place, time in another ("Thursday 15 October … from
        // 19:15"): put together, as Mail does.
        if timed.isEmpty, let day = found.filter({ $0.hasDay && !$0.hasTime }).map(\.date)
            .filter({ calendar.startOfDay(for: $0) >= calendar.startOfDay(for: now) && $0 < now.addingTimeInterval(92 * 86_400) })
            .min(), let time = found.first(where: { $0.hasTime && !$0.hasDay }) {
            let clock = calendar.dateComponents([.hour, .minute], from: time.date)
            if let combined = calendar.date(bySettingHour: clock.hour ?? 0, minute: clock.minute ?? 0, second: 0, of: day),
               window(combined) {
                timed = [(combined, time.duration)]
            }
        }
        // A time alone means today only in mail that came today.
        if timed.isEmpty, arrivedToday {
            timed = found.filter { $0.hasTime && !$0.hasDay && window($0.date) }.map { ($0.date, $0.duration) }
        }
        guard let (start, duration) = timed.min(by: { $0.0 < $1.0 }) else { return nil }

        var location: String?
        if let addresses = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.address.rawValue),
           let match = addresses.firstMatch(in: own, range: NSRange(location: 0, length: ns.length)) {
            location = ns.substring(with: match.range)
                .replacingPattern(#"\s*\n\s*"#, with: ", ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // The subject without "Re:" or "Fwd:" in any language: a calendar
        // event isn't called "Re: Fwd: Dinner".
        var title = MailSubject.base(subject.trimmingCharacters(in: .whitespacesAndNewlines))
        // A capitalised name right before the event word ("Labcorp
        // appointment", "Delta flight"); the event word in any case. On
        // the same line: a subject "Meeting" above "Meeting on Friday" made
        // "Meeting Meeting".
        let named = try? NSRegularExpression(pattern: "\\b([A-Z][\\w&'.-]*)[ \\t]+(?i:(" + eventWords + "))\\b")
        let skip: Set<String> = ["your", "the", "our", "this", "an", "a", "upcoming", "next", "for", "of", "my", "new"]
        let isEventWord = { (word: String) in word.patternRange("(?i)^(" + eventWords + ")$") != nil }
        for match in named?.matches(in: all, range: NSRange(location: 0, length: (all as NSString).length)) ?? [] {
            let name = (all as NSString).substring(with: match.range(at: 1))
            guard !skip.contains(name.lowercased()), !isEventWord(name) else { continue }
            let kind = (all as NSString).substring(with: match.range(at: 2))
            title = name + " " + kind.prefix(1).uppercased() + kind.dropFirst().lowercased()
            break
        }
        // A real code has a digit and is in capitals: "Confirmation email
        // was sent" and "Confirmation: pending" have none.
        let confirmation = all.patternRange(#"(?i:confirmation(?:\s+(?:number|code|#))?)\s*[:#]?\s*(?=[A-Z0-9-]*\d)[A-Z0-9][A-Z0-9-]{4,}\b"#)
            .flatMap { found in all[found].patternRange(#"(?=[A-Z0-9-]*\d)[A-Z0-9][A-Z0-9-]{4,}$"#).map { String(all[found][$0]) } }
        return EventSuggestion(title: title, start: start, end: duration > 0 ? start.addingTimeInterval(duration) : nil,
                               location: location, confirmation: confirmation)
    }
}
