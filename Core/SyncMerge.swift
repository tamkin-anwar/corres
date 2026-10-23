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
}
