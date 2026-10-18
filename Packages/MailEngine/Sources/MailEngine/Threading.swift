import Foundation

/// Groups messages into conversations the way Apple Mail and Gmail do on
/// IMAP, which has no thread ids: by Message-ID, In-Reply-To and
/// References, across folders, so your reply in Sent joins the email it
/// answers in the Inbox. Messages with no links stay on their own; subjects
/// alone never join two messages (two unrelated "Hello" emails aren't a
/// conversation).
public enum Threader {
    public struct Thread: Sendable, Equatable {
        /// Stable across syncs: the Message-ID of the oldest message known
        /// to start it, or the first message's own key.
        public let id: String
        /// Oldest first.
        public let messages: [MessageSummary]
        public var latest: MessageSummary { messages.last! }
    }

    public static func threads(_ messages: [MessageSummary]) -> [Thread] {
        // Union-find over message ids.
        var parent: [String: String] = [:]
        func find(_ x: String) -> String {
            var root = x
            while let p = parent[root], p != root { root = p }
            var node = x
            while let p = parent[node], p != root { parent[node] = root; node = p }
            return root
        }
        func union(_ a: String, _ b: String) {
            let ra = find(a), rb = find(b)
            if ra != rb { parent[rb] = ra }
        }
        func key(_ m: MessageSummary) -> String { m.messageID.map(cleanMessageID) ?? "uid:\(m.folder)/\(m.uid)" }

        for m in messages {
            let k = key(m)
            if parent[k] == nil { parent[k] = k }
            for linked in m.references + [m.inReplyTo].compactMap({ $0 }) {
                let id = cleanMessageID(linked)
                guard !id.isEmpty else { continue }
                if parent[id] == nil { parent[id] = id }
                union(id, k)
            }
        }
        var groups: [String: [MessageSummary]] = [:]
        var seen = Set<String>()
        for m in messages {
            // The same message in two folders (Gmail-style All Mail) counts once.
            let dedupe = m.messageID.map(cleanMessageID) ?? "uid:\(m.folder)/\(m.uid)"
            guard seen.insert(dedupe).inserted else { continue }
            groups[find(key(m)), default: []].append(m)
        }
        return groups.map { root, list in
            let sorted = list.sorted { ($0.date ?? .distantPast, $0.uid) < ($1.date ?? .distantPast, $1.uid) }
            return Thread(id: root, messages: sorted)
        }.sorted { ($0.latest.date ?? .distantPast) > ($1.latest.date ?? .distantPast) }
    }
}
