import Foundation
import NaturalLanguage

/// How you write, learned from the email you've sent, on this device: the
/// way you open ("Hi Maya,"), the way you close ("Thanks,"), how long you
/// usually go on, and a few of your own short replies. Drafted replies use
/// it so they sound like you, as Smart Reply does in Mail and Gmail. It is
/// worked out from the words alone, with no model, so it holds the same
/// with or without Apple Intelligence, and nothing leaves the device.
public struct WritingStyle: Codable, Sendable, Equatable {
    /// "Hi {name},", with `{name}` where their first name goes. Empty: you
    /// usually start straight in. Nil: no clear habit.
    public var greeting: String?
    /// "Thanks,", the line before your name. Nil: no clear habit.
    public var signOff: String?
    /// The middle of how long your replies run, in words.
    public var typicalWords: Int
    public var usesExclamations: Bool
    /// Most of your sentences start in lower case.
    public var writesLowercase: Bool
    /// The language most of them are in ("en").
    public var language: String?
    /// Up to three of your own short replies, newest first, for tone.
    public var examples: [String]
    public var sampleCount: Int

    /// One email you wrote, and who it was to.
    public struct Sample: Sendable {
        public var text: String
        public var recipientName: String
        public var date: Date
        public init(text: String, recipientName: String, date: Date) {
            self.text = text
            self.recipientName = recipientName
            self.date = date
        }
    }

    /// Fewer than this, and a habit is only a coincidence.
    public static let minimumSamples = 5

    public static func learn(from samples: [Sample], ownNames: [String], signature: String? = nil) -> WritingStyle? {
        var seen = Set<String>()
        let parsed = samples.compactMap { sample -> (sample: Sample, reply: Parsed)? in
            let words = ownWords(in: sample.text, signature: signature)
            guard isPersonal(words), seen.insert(words).inserted else { return nil }
            return (sample, parse(words, recipient: sample.recipientName, ownNames: ownNames))
        }
        guard parsed.count >= minimumSamples else { return nil }

        var greetings: [String: Int] = [:]
        var noGreeting = 0
        var signOffs: [String: Int] = [:]
        var lengths: [Int] = []
        var exclaiming = 0
        var lowercase = 0
        var languages: [String: Int] = [:]
        for (_, reply) in parsed {
            if let greeting = reply.greeting { greetings[greeting, default: 0] += 1 } else { noGreeting += 1 }
            if let closing = reply.signOff { signOffs[closing, default: 0] += 1 }
            lengths.append(wordCount(reply.body))
            if reply.body.contains("!") || reply.body.contains("！") { exclaiming += 1 }
            if let letter = reply.body.first(where: \.isLetter), letter.isLowercase { lowercase += 1 }
            if let code = NLLanguageRecognizer.dominantLanguage(for: reply.body)?.rawValue { languages[code, default: 0] += 1 }
        }
        let count = parsed.count
        // A habit is the word you open or close with ("Hi", "Best regards"),
        // however you punctuate it; its commonest form is what's used.
        let greeting: String? = noGreeting * 2 > count ? "" : habit(greetings, of: count) { $0.split(separator: " ").first.map { $0.lowercased().trimmingCharacters(in: .punctuationCharacters) } ?? "" }
        let signOff = habit(signOffs, of: count) { $0.lowercased().trimmingCharacters(in: .punctuationCharacters) }
        // Greeting, words and sign-off only: never the signature under them.
        let examples = parsed.sorted { $0.sample.date > $1.sample.date }
            .map(\.reply)
            .filter { (8...80).contains(wordCount($0.body)) }
            .prefix(3)
            .map { [$0.greetingLine, $0.body, $0.signOff].compactMap { $0 }.joined(separator: "\n\n") }
        return WritingStyle(greeting: greeting, signOff: signOff,
                            typicalWords: lengths.sorted()[lengths.count / 2],
                            usesExclamations: exclaiming * 10 >= count * 4,
                            writesLowercase: lowercase * 2 > count,
                            language: languages.max { $0.value < $1.value }?.key,
                            examples: Array(examples), sampleCount: count)
    }

    /// The commonest form of the commonest family, if at least three in ten
    /// of your emails have it.
    private static func habit(_ counts: [String: Int], of total: Int, family: (String) -> String) -> String? {
        let families = Dictionary(grouping: counts, by: { family($0.key) })
        guard let top = families.max(by: { a, b in
            let x = a.value.reduce(0) { $0 + $1.value }, y = b.value.reduce(0) { $0 + $1.value }
            return x < y || (x == y && a.key > b.key)
        }), top.value.reduce(0, { $0 + $1.value }) * 10 >= total * 3 else { return nil }
        return top.value.max { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }?.key
    }

    /// One email of yours, taken apart.
    struct Parsed {
        /// "Hi {name},", or nil when it starts straight in.
        var greeting: String?
        var greetingLine: String?
        var signOff: String?
        /// What's between them.
        var body: String
    }

    static func parse(_ words: String, recipient: String, ownNames: [String]) -> Parsed {
        var lines = words.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var result = Parsed(body: "")
        // The greeting: a short first line, or the start of a first line
        // that runs on ("Hi Maya, thanks for…", where the lines were lost).
        if let first = lines.first {
            if let greeting = greeting(in: first, recipient: recipient) {
                result.greeting = greeting
                result.greetingLine = first
                lines.removeFirst()
            } else if let stop = first.firstIndex(where: { $0 == "," || $0 == "!" }),
                      case let opening = String(first[...stop]), opening.split(separator: " ").count <= 4,
                      let greeting = greeting(in: opening, recipient: recipient) {
                result.greeting = greeting
                result.greetingLine = opening
                lines[0] = String(first[first.index(after: stop)...]).trimmingCharacters(in: .whitespaces)
            }
        }
        // The sign-off: a closing line near the end, with only your name and
        // a signature (phone, address) below it.
        if let index = lines.indices.reversed().prefix(8).first(where: { isClosing(lines[$0]) }), index > 0 || lines.count == 1 {
            result.signOff = lines[index]
            lines.removeSubrange(index...)
        } else if let last = lines.last, let (closing, before) = inlineSignOff(last, ownNames: ownNames) {
            // "…see you then. Thanks, Tamkin" on one line.
            result.signOff = closing
            lines[lines.count - 1] = before
        } else if let last = lines.last, isOwnName(last, ownNames: ownNames) {
            lines.removeLast()
        }
        result.body = lines.filter { !$0.isEmpty }.joined(separator: "\n")
        return result
    }

    /// Mail you wrote to a person, not a forward, a code or a message an
    /// app sent from your address.
    /// Counted in words, not spaces: Chinese and Japanese replies have
    /// none ("好的，我周五前发给你。"), and were all left out. A run over 40
    /// characters is a link or a code, except in those languages, where
    /// it's a sentence.
    static func isPersonal(_ words: String) -> Bool {
        let tokens = words.split(whereSeparator: \.isWhitespace)
        guard wordCount(words) >= 3, !words.hasPrefix("-"),
              !tokens.contains(where: { $0.count > 40 && !$0.contains(where: MailDigest.isUnspaced) }) else { return false }
        let lower = words.lowercased()
        return !["forwarded message", "begin forwarded", "do_not_delete", "unsubscribe"].contains { lower.contains($0) }
    }

    /// The greeting for someone, with their first name in place.
    public func greeting(for name: String) -> String? {
        guard let greeting else { return nil }
        // "Md. Rahim Uddin" is "Rahim"; "王伟" stays whole (`Person.firstName`).
        let first = Person.firstName(of: name)
        if greeting.contains("{name}") {
            guard !first.isEmpty else { return greeting.replacingOccurrences(of: " {name}", with: "") }
            return greeting.replacingOccurrences(of: "{name}", with: first)
        }
        return greeting
    }

    /// What a drafted reply needs to know, in the words a writing model
    /// follows. The greeting and sign-off only when the reply is in the
    /// language they're in, and the examples likewise.
    public func instructions(recipientName: String, replyLanguage: String?) -> String {
        var lines: [String] = []
        let sameLanguage = language == nil || replyLanguage == nil || language == replyLanguage
        if sameLanguage, let greeting = greeting(for: recipientName) {
            lines.append(greeting.isEmpty ? "Start straight in, with no greeting line." : "Open with: \(greeting)")
        }
        if sameLanguage, let signOff { lines.append("Close with \"\(signOff)\" on its own line.") }
        lines.append("Keep it to about \(max(typicalWords, 10)) words, as I usually do.")
        if !usesExclamations { lines.append("I rarely use exclamation marks.") }
        if writesLowercase { lines.append("I write casually, mostly in lower case.") }
        // In another language, examples would pull the reply into theirs.
        if sameLanguage, !examples.isEmpty {
            lines.append("Replies I wrote before, for my tone only. Do not reuse what they say:")
            lines.append(contentsOf: examples.map { "---\n\($0)" })
            lines.append("---")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Reading your own words

    /// What you wrote yourself: the quoted email below it, your saved
    /// signature and "Sent from my iPhone" taken off.
    public static func ownWords(in text: String, signature: String? = nil) -> String {
        var words = text.replacingOccurrences(of: "\r\n", with: "\n")
        // "On … wrote:" and its forms in every language, an Outlook header
        // block, "-----Original Message-----" (`QuoteDetector`).
        if let start = QuoteDetector.quoteStart(in: words) { words = String(words[..<start]) }
        for pattern in quoteStarts {
            if let range = words.patternRange(pattern, caseInsensitive: true) { words = String(words[..<range.lowerBound]) }
        }
        if let signature = signature?.trimmingCharacters(in: .whitespacesAndNewlines), !signature.isEmpty,
           let range = words.range(of: signature, options: .backwards) {
            words.removeSubrange(range)
        }
        if let range = words.patternRange(#"\n\s*(Sent from my (iPhone|iPad|Mac)|Get Outlook for \w+|Sent with Corres)[^\n]*"#, caseInsensitive: true) {
            words = String(words[..<range.lowerBound])
        }
        return words.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Where a reply's quoted email starts, in the forms mail apps write.
    private static let quoteStarts = [
        // "On Tue, … Maya <maya@x.com> wrote:", which may wrap onto a second line.
        #"\n\s*(On|Le|Am|El|Em|Il|Op) [^\n]{0,200}(\n[^\n]{0,120})?\b(wrote|a écrit|schrieb|escribió|escreveu|scritto|schreef)\s*:"#,
        #"\n[^\n]{0,200}\b(wrote|a écrit|schrieb|escribió|escreveu|scritto|schreef)\s*:\s*(\n|$)"#,
        #"\n[^\n]*(写道|のメッセージ|작성)[^\n]{0,20}[:：]\s*(\n|$)"#,
        #"\n-{2,}\s*(Original Message|Forwarded message)"#,
        #"\n_{8,}"#,
        #"\nFrom:[^\n]+\n(Sent|Date):"#,
        #"\n>"#,
    ]

    private static let greetingWords: Set<String> = [
        "hi", "hey", "hello", "dear", "hiya", "heya", "yo", "morning", "afternoon", "evening", "greetings", "howdy",
        "good", "hallo", "liebe", "lieber", "bonjour", "salut", "hola", "buenos", "buenas", "olá", "oi", "ciao",
        "こんにちは", "안녕하세요", "您好", "你好",
    ]

    /// Words that greet a group, kept as they are ("Hi all,").
    private static let groupWords: Set<String> = ["all", "everyone", "team", "both", "guys", "folks", "there", "y'all", "zusammen", "à tous", "todos"]

    /// "Hi Maya," → "Hi {name},". Only a short first line that a greeting
    /// starts, or that's their name and a comma. Whoever it names becomes
    /// `{name}`, so "Hi Jackie," and "Hi Sam," are the same habit.
    static func greeting(in line: String, recipient: String) -> String? {
        let words = line.split(separator: " ").map(String.init)
        guard !words.isEmpty, words.count <= 5 else { return nil }
        let bare = words.map { $0.lowercased().trimmingCharacters(in: .punctuationCharacters) }
        let names = recipient.split(separator: " ").map { String($0).lowercased().trimmingCharacters(in: .punctuationCharacters) }.filter { $0.count > 1 }
        let endsLikeGreeting = line.hasSuffix(",") || line.hasSuffix("!") || line.hasSuffix("،")
        let greets = bare.prefix { greetingWords.contains($0) }.count
        guard greets > 0 || (endsLikeGreeting && words.count <= 2 && names.contains(bare[0])) else { return nil }
        let rest = bare[greets...].joined(separator: " ")
        let ending = String(line.reversed().prefix { $0.isPunctuation }.reversed())
        let opening = words.prefix(greets).joined(separator: " ").trimmingCharacters(in: .punctuationCharacters)
        if rest.isEmpty { return opening + ending }
        if groupWords.contains(rest) { return line }
        return (opening.isEmpty ? "{name}" : opening + " {name}") + ending
    }

    private static let closingWords: Set<String> = [
        "thanks", "thank you", "thanks so much", "thanks again", "many thanks", "best", "best regards", "all the best",
        "regards", "kind regards", "warm regards", "warmly", "cheers", "talk soon", "speak soon", "see you", "love",
        "sincerely", "take care", "thx", "ty", "best wishes", "with thanks",
        "danke", "viele grüße", "liebe grüße", "merci", "cordialement", "gracias", "saludos", "obrigado", "obrigada", "abraços",
        "mit freundlichen grüßen", "freundliche grüße", "beste grüße", "grüße", "bien à vous", "bien cordialement",
        "atentamente", "un saludo", "un abrazo", "atenciosamente", "att", "abs",
        "よろしくお願いします", "よろしくお願いいたします", "よろしくお願い致します", "감사합니다", "고맙습니다",
        "谢谢", "謝謝", "此致", "祝好", "ধন্যবাদ", "শুভেচ্ছান্তে",
    ]

    static func isClosing(_ line: String) -> Bool {
        let bare = line.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ",.!-– ，。！、"))
        return closingWords.contains(bare) && line.split(separator: " ").count <= 4
    }

    /// "…see you then. Thanks, Tamkin": the closing, and what came before.
    static func inlineSignOff(_ line: String, ownNames: [String]) -> (closing: String, before: String)? {
        let firstNames = ownNames.compactMap { $0.split(separator: " ").first.map { String($0).lowercased() } }
        let words = line.split(separator: " ").map(String.init)
        guard words.count >= 3, let name = words.last?.trimmingCharacters(in: .punctuationCharacters).lowercased(),
              firstNames.contains(name) else { return nil }
        for length in (1...3).reversed() where words.count > length + 1 {
            let phrase = words[(words.count - 1 - length)..<(words.count - 1)].joined(separator: " ")
            if isClosing(phrase) {
                return (phrase, words[..<(words.count - 1 - length)].joined(separator: " "))
            }
        }
        return nil
    }

    private static func isOwnName(_ line: String, ownNames: [String]) -> Bool {
        let bare = line.trimmingCharacters(in: CharacterSet(charactersIn: "-–— ")).lowercased()
        guard !bare.isEmpty, bare.split(separator: " ").count <= 3 else { return false }
        return ownNames.contains { name in
            let name = name.lowercased()
            return !name.isEmpty && (bare == name || name.split(separator: " ").first.map { bare == String($0) } == true)
        }
    }

    private static func wordCount(_ text: String) -> Int {
        var count = 0
        text.enumerateSubstrings(in: text.startIndex..., options: [.byWords, .substringNotRequired]) { _, _, _, _ in count += 1 }
        return count
    }
}
