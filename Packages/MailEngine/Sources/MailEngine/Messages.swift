import Foundation

/// One message as a list needs it: who, what, when and how it relates to
/// others. Bodies load separately, when the message is opened.
public struct MessageSummary: Sendable, Equatable, Hashable {
    public let uid: UInt32
    public let folder: String
    public var flags: Set<String>
    public let subject: String
    public let from: Address?
    public let to: [Address]
    public let cc: [Address]
    public let date: Date?
    /// Without angle brackets ("abc@example.com").
    public let messageID: String?
    public let inReplyTo: String?
    public let references: [String]
    public let size: Int?

    public init(uid: UInt32, folder: String, flags: Set<String>, subject: String, from: Address?, to: [Address],
                cc: [Address] = [], date: Date?, messageID: String?, inReplyTo: String?, references: [String] = [],
                size: Int? = nil) {
        self.uid = uid; self.folder = folder; self.flags = flags; self.subject = subject; self.from = from
        self.to = to; self.cc = cc; self.date = date; self.messageID = messageID; self.inReplyTo = inReplyTo
        self.references = references; self.size = size
    }

    public var isSeen: Bool { flags.contains("\\seen") }
    public var isFlagged: Bool { flags.contains("\\flagged") }
}

public struct Address: Sendable, Equatable, Hashable {
    public let name: String?
    public let email: String
    public init(name: String?, email: String) { self.name = name; self.email = email }
}

/// Strips angle brackets and spaces from a Message-ID-style header value.
func cleanMessageID(_ raw: String) -> String {
    raw.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
}

/// Every message id in a References or In-Reply-To header, in order.
func messageIDs(in header: String) -> [String] {
    var ids: [String] = []
    var current: String?
    for ch in header {
        if ch == "<" { current = "" } else if ch == ">" {
            if let id = current, !id.isEmpty { ids.append(id) }
            current = nil
        } else if current != nil { current!.append(ch) }
    }
    return ids
}
