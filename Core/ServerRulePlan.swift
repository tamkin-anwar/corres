import Foundation

/// What to change in one account so its filters (Gmail) or inbox rules
/// (Outlook) match the Corres rules that should run there: decided here,
/// done by `ServerRules`. Pure, so every case can be tested.
public enum ServerRulePlan {
    /// The filter or rule kept for a Corres rule in one account.
    public struct Entry: Codable, Equatable, Sendable {
        public var id: String
        public var signature: String
        public init(id: String, signature: String) { self.id = id; self.signature = signature }
    }

    /// A Corres rule that should run in the account: what it should be
    /// (`signature`), and how to recognize a copy already there (`keys`).
    public struct Wanted: Equatable, Sendable {
        public var ruleID: String
        public var signature: String
        public var keys: [String]
        public init(ruleID: String, signature: String, keys: [String]) {
            self.ruleID = ruleID; self.signature = signature; self.keys = keys
        }
    }

    /// A filter or rule already in the account.
    public struct Existing: Equatable, Sendable {
        public var id: String
        public var key: String
        public init(id: String, key: String) { self.id = id; self.key = key }
    }

    public enum Step: Equatable, Sendable {
        /// Out of date, or its Corres rule is gone or off.
        case remove(ruleID: String, id: String)
        /// Out of date, but another rule still uses the same one: kept
        /// in the account, dropped from this rule.
        case forget(ruleID: String)
        /// Made already, by another device: kept, not made twice.
        case adopt(ruleID: String, id: String, signature: String)
        case create(ruleID: String, signature: String)
    }

    /// What's kept but no longer matches what's wanted.
    public static func removals(wanted: [Wanted], kept: [String: Entry]) -> [Step] {
        let current = Dictionary(wanted.map { ($0.ruleID, $0.signature) }, uniquingKeysWith: { first, _ in first })
        let outdated = kept.filter { current[$0.key] != $0.value.signature }
        // One still in use by a rule that stays is only forgotten, not
        // deleted: deleting it would stop that rule too.
        let stillUsed = Set(kept.filter { current[$0.key] == $0.value.signature }.map(\.value.id))
        return outdated.sorted { $0.key < $1.key }.map { ruleID, entry in
            stillUsed.contains(entry.id) ? .forget(ruleID: ruleID) : .remove(ruleID: ruleID, id: entry.id)
        }
    }

    /// Wanted and not kept (after removals): adopted when an identical one
    /// is already in the account, each existing one adopted at most once,
    /// and made otherwise.
    public static func additions(wanted: [Wanted], kept: [String: Entry], existing: [Existing]) -> [Step] {
        // One already kept for another rule is never taken over as well.
        let keptIDs = Set(kept.values.map(\.id))
        var available = existing.filter { !keptIDs.contains($0.id) }
        var steps: [Step] = []
        for want in wanted where kept[want.ruleID]?.signature != want.signature {
            if let index = available.firstIndex(where: { want.keys.contains($0.key) }) {
                steps.append(.adopt(ruleID: want.ruleID, id: available[index].id, signature: want.signature))
                available.remove(at: index)
            } else {
                steps.append(.create(ruleID: want.ruleID, signature: want.signature))
            }
        }
        return steps
    }

    /// How a Gmail filter is recognized: its search and label changes.
    public static func gmailKey(query: String, add: [String], remove: [String]) -> String {
        query + "|" + add.sorted().joined(separator: ",") + "|" + remove.sorted().joined(separator: ",")
    }
}
