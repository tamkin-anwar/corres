import Foundation

/// What the Share extension needs to write an email the way Compose does,
/// written by the app into the shared App Group: your accounts and the
/// addresses each can send as, your signatures, and who you write to (the
/// same ranking Compose suggests from). Tokens are not in here; they stay
/// in the Keychain.
struct ShareSnapshot: Codable {
    struct Address: Codable, Hashable {
        let email: String
        let name: String
        let isDefault: Bool
        let isPrimary: Bool
    }

    struct Account: Codable, Hashable {
        let email: String
        var name: String?
        /// Its send-as addresses, its own first.
        var addresses: [Address]
        var signature: String
    }

    var accounts: [Account]
    /// Settings → Composing → Send New Mail From.
    var defaultAccount: String?
    var people: PeopleIndex
    /// Your Contacts, ranked a little higher, as in Compose.
    var favored: Set<String>
    /// Your own names, so another address of yours isn't suggested.
    var ownNames: Set<String>
    var updatedAt: Date

    static let appGroup = "group.studio.anwarcreative.corres"

    private static var fileURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appending(path: "share-snapshot.json")
    }

    static func load() -> ShareSnapshot? {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(ShareSnapshot.self, from: data)
    }

    func save() {
        guard let url = Self.fileURL, let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

/// Emails written in the Share sheet that couldn't go (no connection):
/// handed to the app, which sends them the next time it runs, in the
/// foreground or the background, like anything scheduled.
enum ShareOutbox {
    private static var folder: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: ShareSnapshot.appGroup)?
            .appending(path: "share-outbox", directoryHint: .isDirectory)
    }

    static func add(_ draft: Draft) throws {
        guard let folder else { throw CocoaError(.fileNoSuchFile) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder().encode(draft).write(to: folder.appending(path: "\(draft.id.uuidString).json"),
                                              options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// Everything waiting, removed from the queue as it's handed over.
    /// Only what was read: a file that can't be read yet (the device still
    /// locked) stays for next time, and one that reads but doesn't decode
    /// is set aside as ".unreadable" instead of deleted, so an email you
    /// wrote is never thrown away unseen.
    static func takeAll() -> [Draft] {
        guard let folder,
              let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return [] }
        return files.filter { $0.pathExtension == "json" }.compactMap { file in
            guard let data = try? Data(contentsOf: file) else { return nil }
            guard let draft = try? JSONDecoder().decode(Draft.self, from: data) else {
                try? FileManager.default.moveItem(at: file, to: file.deletingPathExtension().appendingPathExtension("unreadable"))
                return nil
            }
            try? FileManager.default.removeItem(at: file)
            return draft
        }
    }
}
