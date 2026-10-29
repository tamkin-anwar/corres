import Foundation

/// How Corres's own state merges between your devices (`CloudSync`).
/// Pure, so it can be tested.
public enum SyncMerge {
    /// iCloud's list, plus what this device has that iCloud doesn't (added
    /// here meanwhile), without anything deleted on either. An item on both
    /// is iCloud's, as before. Nil when either isn't a list of items with
    /// an `id`.
    public static func list(local: Data?, remote: Data, removed: Set<String>) -> Data? {
        guard let remoteItems = try? JSONSerialization.jsonObject(with: remote) as? [[String: Any]] else { return nil }
        let localItems = local.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [[String: Any]] } ?? []
        func id(_ item: [String: Any]) -> String? { item["id"] as? String }
        guard remoteItems.allSatisfy({ id($0) != nil }), localItems.allSatisfy({ id($0) != nil }) else { return nil }
        let remoteIDs = Set(remoteItems.compactMap(id))
        let merged = remoteItems.filter { !removed.contains(id($0) ?? "") }
            + localItems.filter { !remoteIDs.contains(id($0) ?? "") && !removed.contains(id($0) ?? "") }
        // Nothing to add or take out: iCloud's own bytes, so the two stay equal.
        if merged.count == remoteItems.count, !remoteItems.contains(where: { removed.contains(id($0) ?? "") }) { return remote }
        return try? JSONSerialization.data(withJSONObject: merged, options: [.sortedKeys])
    }

    /// A set of plain values (VIP addresses): both devices' together, less
    /// any removed after it was last added. `token` names a value in the
    /// added and removed notes.
    public static func strings(local: [String], remote: [String], added: [String: Date], removed: [String: Date],
                               token: (String) -> String) -> [String] {
        Set(local + remote).filter { value in
            guard let gone = removed[token(value)] else { return true }
            return (added[token(value)] ?? .distantPast) > gone
        }.sorted()
    }

    /// Values with the date they were set (muted conversations): both
    /// devices' together, the later date kept, less any removed after it
    /// was set.
    public static func dated(local: [String: Date], remote: [String: Date], removed: [String: Date],
                             token: (String) -> String) -> [String: Date] {
        local.merging(remote) { max($0, $1) }.filter { key, at in
            guard let gone = removed[token(key)] else { return true }
            return at > gone
        }
    }

    /// Whether a move made on another device (Needs You, Waiting, Handled)
    /// applies to a conversation here: only while it still ends with the
    /// message the move was made on. A reply puts it back in play, and a
    /// move kept without its message applied to every reply after it.
    public static func moveApplies(madeOn messageID: String?, latest: String?) -> Bool {
        messageID == latest
    }

    /// A sender decision's key: the account it was made in and the sender,
    /// so allowing someone in one account doesn't block them in another.
    public static func decisionKey(account: String, sender: String) -> String {
        account.lowercased() + "|" + sender.lowercased()
    }

    /// The sender a decision's key names.
    public static func decisionSender(key: String, account: String) -> String {
        let prefix = account.lowercased() + "|"
        return key.hasPrefix(prefix) ? String(key.dropFirst(prefix.count)) : key
    }

    /// Sender decisions keyed by account and sender (`decisionKey`). They
    /// were once keyed by the sender alone, and other devices may still
    /// write them that way: each is moved under its account, the later
    /// decision winning where both are there.
    public static func accountKeyed<Value>(_ entries: [String: Value], account: (Value) -> String,
                                           at: (Value) -> Date) -> [String: Value] {
        var result: [String: Value] = [:]
        for (key, value) in entries {
            let owner = account(value)
            let normalized = decisionKey(account: owner, sender: decisionSender(key: key, account: owner))
            if let kept = result[normalized], at(kept) >= at(value) { continue }
            result[normalized] = value
        }
        return result
    }
}
