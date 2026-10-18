import Foundation

/// What a folder is for, so Corres knows where Sent, Trash and Archive are
/// on any server.
public enum FolderRole: String, Sendable, CaseIterable {
    case inbox, sent, drafts, trash, junk, archive, all, flagged
}

public struct Folder: Sendable, Equatable, Hashable {
    /// The server's name for it, as it must be sent back ("Sent Messages").
    public let path: String
    /// The separator between levels ("/" on iCloud, "." on some servers).
    public let delimiter: Character?
    /// The server's own flags for it, lowercased without the backslash
    /// ("sent", "noselect").
    public let attributes: Set<String>
    public let role: FolderRole?

    public init(path: String, delimiter: Character?, attributes: Set<String>) {
        self.path = path
        self.delimiter = delimiter
        let attrs = Set(attributes.map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "\\")) })
        self.attributes = attrs
        self.role = Folder.role(path: path, delimiter: delimiter, attributes: attrs)
    }

    /// Folders that hold no mail themselves (a parent in some servers).
    public var isSelectable: Bool { !attributes.contains("noselect") && !attributes.contains("nonexistent") }

    /// The last level of the path, for display ("Receipts" from
    /// "Archive/Receipts").
    public var name: String {
        guard let delimiter, let last = path.split(separator: delimiter).last else { return path }
        return String(last)
    }

    /// The server's SPECIAL-USE flag when it has one; otherwise the names
    /// servers use in practice: iCloud's "Sent Messages" and "Deleted
    /// Messages", Gmail-style "[Gmail]/Sent Mail", Outlook's "Deleted
    /// Items", Yahoo's "Bulk".
    static func role(path: String, delimiter: Character?, attributes: Set<String>) -> FolderRole? {
        if path.uppercased() == "INBOX" { return .inbox }
        let flagged: [(String, FolderRole)] = [("sent", .sent), ("drafts", .drafts), ("trash", .trash),
                                               ("junk", .junk), ("archive", .archive), ("all", .all),
                                               ("flagged", .flagged)]
        for (flag, role) in flagged where attributes.contains(flag) { return role }
        let leaf = (delimiter.flatMap { path.split(separator: $0).last.map(String.init) } ?? path).lowercased()
        let names: [FolderRole: Set<String>] = [
            .sent: ["sent", "sent messages", "sent mail", "sent items"],
            .drafts: ["drafts", "draft"],
            .trash: ["trash", "deleted messages", "deleted items", "deleted", "bin"],
            .junk: ["junk", "spam", "bulk", "bulk mail", "junk e-mail", "junk email"],
            .archive: ["archive", "archives", "all mail"],
        ]
        for (role, set) in names where set.contains(leaf) { return role }
        return nil
    }
}

extension Array where Element == Folder {
    /// The folder for a role, preferring one the server labelled itself.
    public func folder(for role: FolderRole) -> Folder? {
        first { $0.role == role && $0.attributes.contains(role.rawValue) } ?? first { $0.role == role }
    }
}
