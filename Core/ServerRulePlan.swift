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
        /// Made already, by another device: kept, not made twice.
        case adopt(ruleID: String, id: String, signature: String)
        case create(ruleID: String, signature: String)
    }

    /// What's kept but no longer matches what's wanted.
    public static func removals(wanted: [Wanted], kept: [String: Entry]) -> [Step] {
        let current = Dictionary(wanted.map { ($0.ruleID, $0.signature) }, uniquingKeysWith: { first, _ in first })
        return kept.sorted { $0.key < $1.key }.compactMap { ruleID, entry in
            current[ruleID] == entry.signature ? nil : .remove(ruleID: ruleID, id: entry.id)
        }
    }

    /// Wanted and not kept (after removals): adopted when an identical one
    /// is already in the account, each existing one adopted at most once,
    /// and made otherwise.
    public static func additions(wanted: [Wanted], kept: [String: Entry], existing: [Existing]) -> [Step] {
        var available = existing
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
