import Foundation

/// A Corres rule as Gmail and Outlook can run it themselves: a filter in
/// Gmail, an inbox rule in Outlook. Only what each can do goes over.
/// Needs You is Corres's own and stays in Corres. Outlook has no flag
/// action, and its Focused and Other aren't something a rule can set.
/// When the server can't match a rule exactly it matches less, never
/// more: Corres still applies the whole rule to what it sees.
public enum ServerRuleSpec {
    /// A Gmail filter: a search, and labels to add or take off.
    public struct Gmail: Codable, Equatable, Sendable {
        public var query: String
        public var addLabelIds: [String]
        public var removeLabelIds: [String]

        /// The same filter without the tab, for when Gmail won't take it.
        public var withoutCategory: Gmail {
            Gmail(query: query, addLabelIds: addLabelIds.filter { !$0.hasPrefix("CATEGORY_") }, removeLabelIds: removeLabelIds)
        }

        public var hasAction: Bool { !addLabelIds.isEmpty || !removeLabelIds.isEmpty }
    }

    /// An Outlook inbox rule: one condition holding the whole phrase, and
    /// what to do.
    public struct Outlook: Codable, Equatable, Sendable {
        /// The Graph condition: senderContains, recipientContains,
        /// subjectContains or bodyOrSubjectContains.
        public var condition: String
        public var phrase: String
        public var markAsRead: Bool
        public var archive: Bool

        /// Shown in Outlook's rules list, and how Corres knows its own.
        /// The same in every language, so every device recognizes it.
        public var displayName: String { "Corres · \(condition.replacingOccurrences(of: "Contains", with: "")) \(phrase)" }

        /// How a copy already in Outlook is recognized: the name says what
        /// it looks for, the actions what it does.
        public var key: String { Self.key(displayName: displayName, markAsRead: markAsRead, archive: archive) }

        public static func key(displayName: String, markAsRead: Bool, archive: Bool) -> String {
            "\(displayName)|\(markAsRead)|\(archive)"
        }
    }

    public static func words(_ rule: MailRule) -> [String] {
        rule.text.split(whereSeparator: \.isWhitespace).map(String.init)
    }

    /// Nil when there's nothing Gmail can do for this rule.
    public static func gmail(for rule: MailRule) -> Gmail? {
        let words = words(rule)
        guard rule.isEnabled, rule.isUsable, !words.isEmpty else { return nil }
        var add: [String] = []
        var remove: [String] = []
        if rule.markRead { remove.append("UNREAD") }
        if rule.archive { remove.append("INBOX") }
        if rule.flag { add.append("STARRED") }
        if let category = rule.category { add.append(category.gmailLabel) }
        let spec = Gmail(query: gmailQuery(field: rule.field, words: words), addLabelIds: add, removeLabelIds: remove)
        return spec.hasAction ? spec : nil
    }

    /// Every word must appear, as in Corres: one search term per word.
    static func gmailQuery(field: MailRule.Field, words: [String]) -> String {
        words.map { word in
            let term = quoted(word)
            return switch field {
            case .from: "from:\(term)"
            // Corres's To includes Cc.
            case .to: "{to:\(term) cc:\(term)}"
            case .subject: "subject:\(term)"
            // A bare word in Gmail also matches To and Cc, which Corres's
            // Anywhere doesn't look at: "acme" would catch everything sent
            // to you@acme.com. Sender and subject only; Corres itself still
            // checks the body.
            case .anywhere: "{from:\(term) subject:\(term)}"
            }
        }.joined(separator: " ")
    }

    /// Plain words and addresses as they are; anything else in quotes, so
    /// Gmail reads it as text, not as search syntax.
    static func quoted(_ word: String) -> String {
        let plain = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: ".@_-+'"))
        // A leading - or + and the words OR, AND and AROUND are search
        // syntax even when every character is plain.
        let isSyntax = word.hasPrefix("-") || word.hasPrefix("+") || ["OR", "AND", "AROUND"].contains(word)
        if !isSyntax, word.unicodeScalars.allSatisfy(plain.contains) { return word }
        return "\"" + word.replacingOccurrences(of: "\"", with: "") + "\""
    }

    /// Nil when there's nothing Outlook can do for this rule.
    public static func outlook(for rule: MailRule) -> Outlook? {
        let words = words(rule)
        guard rule.isEnabled, rule.isUsable, !words.isEmpty, rule.markRead || rule.archive else { return nil }
        let condition = switch rule.field {
        case .from: "senderContains"
        case .to: "recipientContains"
        case .subject: "subjectContains"
        case .anywhere: "bodyOrSubjectContains"
        }
        return Outlook(condition: condition, phrase: words.joined(separator: " "), markAsRead: rule.markRead, archive: rule.archive)
    }

    /// What changed, compared: a rule edited in Corres replaces its copy.
    public static func signature<T: Encodable>(_ spec: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(spec)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }
}
