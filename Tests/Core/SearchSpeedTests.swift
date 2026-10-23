import Foundation
import Testing
@testable import CorresCore

/// Times Search over a synthetic mailbox of 10,000 conversations. Set
/// CORRES_SEARCH_PERF to run it; skipped in a normal pass.
struct SearchSpeedTests {
    private static let enabled = ProcessInfo.processInfo.environment["CORRES_SEARCH_PERF"] != nil

    static func mailbox(_ count: Int, seed: UInt64 = 7) -> [Correspondence] {
        var random = SeededRandom(seed)
        let words = ["invoice", "March", "café", "Résumé", "meeting", "Lisbon", "delta", "Straße", "naïve", "project",
                     "update", "hello", "thanks", "schedule", "payment", "receipt", "শুভ", "কিছু", "বাংলা", "München",
                     "José", "ÉCOLE", "Zoë", "order", "shipped", "Ångström", "report", "quarterly", "dinner", "tickets"]
        let names = ["Ana Souza", "José Álvarez", "Zoë Smith", "Mahmud Hasan", "Delta Air Lines", "Acme Billing", "Lena Müller"]
        func text(_ n: Int) -> String { (0..<n).map { _ in words[random.next(words.count)] }.joined(separator: " ") }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        return (0..<count).map { n in
            let name = names[random.next(names.count)]
            let address = name.lowercased().replacingOccurrences(of: " ", with: ".") + "@example.com"
            return Correspondence(id: ThreadID(account: "me@example.com", providerID: "t\(n)"), sender: name,
                                  senderEmail: address, organization: random.next(3) == 0 ? "Acme" : "",
                                  subject: text(5), excerpt: text(12), body: text(250 + random.next(250)),
                                  latestMessageID: "m\(n)", receivedAt: now.addingTimeInterval(-Double(n) * 3_600),
                                  dueAt: nil, reason: "", attention: [.needsYou, .waiting, .quiet, .handled][random.next(4)],
                                  isUnread: random.next(2) == 0,
                                  toRecipients: ["me@example.com", names[random.next(names.count)].lowercased() + "@example.org"],
                                  ccRecipients: random.next(4) == 0 ? ["lena@example.de"] : [])
        }
    }

    @Test(.enabled(if: enabled)) func tenThousandConversations() {
        let threads = Self.mailbox(10_000)
        let clock = ContinuousClock()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let first = clock.measure { _ = MailQuery.filter(threads, search: "invoice", now: now) }
        print("SEARCH first search \(first)")
        for query in ["i", "in", "inv", "invoice", "invoice march", "cafe", "xyz", "from:jose", "to:lena", "\"thanks hello\"", "কি"] {
            var matches: [Correspondence] = []
            let filter = clock.measure { matches = MailQuery.filter(threads, search: query, now: now) }
            let top = clock.measure { _ = MailQuery.topResults(matches, search: query, now: now) }
            print("SEARCH \(query): \(matches.count) matches, filter \(filter), top results \(top)")
        }
    }
}

/// The same "random" mailbox every run.
struct SeededRandom {
    private var state: UInt64
    init(_ seed: UInt64) { state = seed }
    mutating func next(_ bound: Int) -> Int {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Int((state >> 33) % UInt64(bound))
    }
}
