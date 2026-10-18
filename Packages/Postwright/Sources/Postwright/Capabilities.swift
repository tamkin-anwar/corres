import Foundation

/// What an IMAP server says it can do, asked for after login (iCloud
/// advertises almost nothing before it). Corres uses each feature only when
/// it's here and falls back when it isn't: iCloud, Fastmail and Yahoo all
/// differ.
public struct Capabilities: Sendable, Equatable {
    public let names: Set<String>

    public init<S: Sequence>(_ names: S) where S.Element == String {
        self.names = Set(names.map { $0.uppercased() })
    }

    public func has(_ name: String) -> Bool { names.contains(name.uppercased()) }

    /// The server can tell an open connection about new mail.
    public var idle: Bool { has("IDLE") }
    /// One command moves a message; otherwise copy, mark deleted, expunge.
    public var move: Bool { has("MOVE") }
    /// Per-message change counters, so a sync asks only for what changed.
    public var condstore: Bool { has("CONDSTORE") || qresync }
    /// Also reports deleted messages on reconnect.
    public var qresync: Bool { has("QRESYNC") }
    /// The server returns the new UID of an appended or copied message.
    public var uidplus: Bool { has("UIDPLUS") }
    /// Folders are labelled with their role (Sent, Trash, Archive…).
    public var specialUse: Bool { has("SPECIAL-USE") }
    /// Plain password login is allowed.
    public var authPlain: Bool { has("AUTH=PLAIN") || !has("LOGINDISABLED") }
    public var xoauth2: Bool { has("AUTH=XOAUTH2") }
}
