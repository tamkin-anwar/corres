import Foundation

/// A rule you set: when an email matches, Corres does what you chose, on
/// every account. The condition is one field and some words, as Mail's and
/// Gmail's simplest rules are; what happens can be several things at once
/// (into Promotions and marked read), but never two that fight (Needs You
/// and archived).
public struct MailRule: Codable, Hashable, Identifiable, Sendable {
    public enum Field: String, Codable, CaseIterable, Sendable {
        /// The sender's name, address or company ("amazon.com" matches
        /// everyone there).
        case from
        /// Who it was sent to, Cc included: an alias, a list.
        case to
        case subject
        /// Anywhere: sender, subject, preview and body.
        case anywhere
    }

    public var id: UUID
    public var field: Field
    /// Matched as written, ignoring case and accents; several words must
    /// all appear, as in search.
    public var text: String
    public var isEnabled: Bool
    /// Needs You, or no action needed. Nil leaves it to Corres.
    public var attention: Attention?
    public var category: InboxCategory?
    public var markRead: Bool
    public var archive: Bool
    public var flag: Bool
    public var createdAt: Date
    /// Also kept as a filter in Gmail and a rule in Outlook, so it works
    /// with Corres closed and on their websites. Optional so older rules
    /// decode; nil is off.
    public var inAccounts: Bool?

    public init(id: UUID = UUID(), field: Field = .from, text: String = "", isEnabled: Bool = true,
                attention: Attention? = nil, category: InboxCategory? = nil,
                markRead: Bool = false, archive: Bool = false, flag: Bool = false, createdAt: Date = .now,
                inAccounts: Bool? = nil) {
        self.id = id; self.field = field; self.text = text; self.isEnabled = isEnabled
        self.attention = attention; self.category = category
        self.markRead = markRead; self.archive = archive; self.flag = flag; self.createdAt = createdAt
        self.inAccounts = inAccounts
    }

    /// Something to do, and something to look for.
    public var isUsable: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (attention != nil || category != nil || markRead || archive || flag)
    }

    public func matches(_ thread: Correspondence) -> Bool {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard isEnabled, !words.isEmpty else { return false }
        let fields: [String] = switch field {
        case .from: [thread.sender, thread.senderEmail ?? "", thread.organization]
        case .to: thread.toRecipients + thread.ccRecipients
        case .subject: [thread.subject]
        case .anywhere: [thread.sender, thread.senderEmail ?? "", thread.organization, thread.subject, thread.excerpt, thread.body]
        }
        return words.allSatisfy { word in fields.contains { $0.localizedStandardContains(word) } }
    }
}

/// Text you send often, ready to drop into an email. `{first name}` and
/// `{name}` become the first recipient's, filled in as it's inserted.
public struct MailTemplate: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    /// Used only when the email has no subject yet.
    public var subject: String
    public var body: String

    public static let firstNameToken = "{first name}"
    public static let nameToken = "{name}"

    public init(id: UUID = UUID(), name: String = "", subject: String = "", body: String = "") {
        self.id = id; self.name = name; self.subject = subject; self.body = body
    }

    /// The body with the recipient's name put in. With no name to use, the
    /// placeholder goes and so does the space before it ("Hi {first name},"
    /// becomes "Hi,"), rather than leaving a gap or the braces.
    public func filled(recipientName: String?) -> (subject: String, body: String) {
        (Self.fill(subject, name: recipientName), Self.fill(body, name: recipientName))
    }

    static func fill(_ text: String, name: String?) -> String {
        let full = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let first = full.split(separator: " ").first.map(String.init) ?? ""
        var result = text
        for (token, value) in [(firstNameToken, first), (nameToken, full)] {
            if value.isEmpty {
                // "Hi {first name}," → "Hi,"; "Thanks, {name}." → "Thanks."
                let escaped = NSRegularExpression.escapedPattern(for: token)
                result = result.replacingOccurrences(of: ",?[ \\t]*" + escaped, with: "", options: .regularExpression)
            } else {
                result = result.replacingOccurrences(of: token, with: value)
            }
        }
        return result
    }
}

/// A search kept as a mailbox: the words and filters as typed
/// ("from:sam has:attachment"), run again each time it's opened.
public struct SavedSearch: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var query: String

    public init(id: UUID = UUID(), name: String, query: String) {
        self.id = id; self.name = name; self.query = query
    }
}

public enum MuteRule {
    /// Whether a new email in a muted conversation should bring it back, as
    /// Gmail does: when it's written to you and you alone, or you've been
    /// added as a recipient. Everything else stays quiet and out of the
    /// lists.
    public static func breaksMute(_ thread: Correspondence, accountAddresses: Set<String>) -> Bool {
        let to = thread.toRecipients.map { $0.lowercased() }
        let mine = to.filter { address in accountAddresses.contains { address.contains($0) } }
        return !mine.isEmpty && mine.count == to.count && thread.ccRecipients.isEmpty
    }
}

/// Where a receipt or delivery stands, for Purchases.
public enum PurchaseStage: Int, Comparable, Sendable {
    case problem, onTheWay, delivered, ordered

    public static func < (lhs: PurchaseStage, rhs: PurchaseStage) -> Bool { lhs.rawValue < rhs.rawValue }

    /// From the status Corres reads out of the email.
    public static func from(status: String?, isAlert: Bool) -> PurchaseStage {
        if isAlert { return .problem }
        switch status {
        case "Out for delivery", "On its way": return .onTheWay
        case "Delivered": return .delivered
        default: return .ordered
        }
    }
}
