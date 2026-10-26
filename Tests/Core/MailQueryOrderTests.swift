import Foundation
import Testing
@testable import CorresCore

/// Needs You and Waiting are sorted by keys read once per conversation; the
/// order must be exactly what sorting the conversations themselves gave,
/// ties included.
extension NewSenderModeSuites {
struct MailQueryOrderTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// A mailbox with plenty of ties: shared dates, pins, dues inside and
    /// outside the three-day horizon, snoozed and screened mail.
    private func mailbox(_ count: Int, seed: UInt64) -> [Correspondence] {
        var random = SeededRandom(seed)
        let attentions: [Attention] = [.needsYou, .waiting, .quiet, .handled]
        return (0..<count).map { n in
            let received = now.addingTimeInterval(-Double(random.next(40)) * 3_600)
            let due: Date? = switch random.next(4) {
            case 0: now.addingTimeInterval(Double(random.next(10)) * 86_400 / 2)
            case 1: now.addingTimeInterval(Double(random.next(3)) * 3_600)
            default: nil
            }
            return Correspondence(id: ThreadID(account: "me@example.com", providerID: "t\(n)"), sender: "Person \(random.next(9))",
                                        organization: "", subject: "Subject \(n)", excerpt: "", body: "",
                                        receivedAt: received, dueAt: due, reason: "", attention: attentions[random.next(4)],
                                        isPinned: random.next(6) == 0,
                                        snoozedUntil: random.next(10) == 0 ? now.addingTimeInterval(86_400) : nil,
                                        senderDecision: random.next(12) == 0 ? .pending : .approved,
                                        isUnread: random.next(2) == 0,
                                        waitingSince: random.next(3) == 0 ? received.addingTimeInterval(-Double(random.next(5)) * 86_400) : nil)
        }
    }

    /// How Needs You and Waiting were sorted before: the conversations
    /// themselves, by the same rules.
    private func reference(_ threads: [Correspondence], attention: Attention) -> [Correspondence] {
        let base = MailQuery.filter(threads, attention: attention, now: now)
        switch attention {
        case .needsYou:
            let horizon = now.addingTimeInterval(3 * 86_400)
            return base.sorted {
                if $0.isPinned != $1.isPinned { return $0.isPinned }
                let a = $0.dueAt.flatMap { $0 <= horizon ? $0 : nil }
                let b = $1.dueAt.flatMap { $0 <= horizon ? $0 : nil }
                switch (a, b) {
                case let (a?, b?) where a != b: return a < b
                case (.some, nil): return true
                case (nil, .some): return false
                default: return $0.receivedAt > $1.receivedAt
                }
            }
        case .waiting:
            return base.sorted {
                if $0.isPinned != $1.isPinned { return $0.isPinned }
                return $0.waitingReference < $1.waitingReference
            }
        default:
            return base
        }
    }

    @Test func sameOrderAsSortingTheConversations() {
        for seed in 1...20 as ClosedRange<UInt64> {
            let threads = mailbox(400, seed: seed)
            for attention in [Attention.needsYou, .waiting, .quiet] {
                #expect(MailQuery.prioritized(threads, attention: attention, now: now).map(\.id)
                        == reference(threads, attention: attention).map(\.id), "seed \(seed), \(attention)")
            }
        }
    }

    @Test func newestFirstMatchesSortingTheConversations() {
        for seed in 1...10 as ClosedRange<UInt64> {
            let threads = mailbox(600, seed: seed)
            let expected = threads.sorted {
                if $0.isPinned != $1.isPinned { return $0.isPinned }
                if $0.receivedAt == $1.receivedAt { return $0.id.providerID < $1.id.providerID }
                return $0.receivedAt > $1.receivedAt
            }
            #expect(MailQuery.sortedNewestFirst(threads).map(\.id) == expected.map(\.id), "seed \(seed)")
            // Already in order: handed back as it is.
            #expect(MailQuery.sortedNewestFirst(expected).map(\.id) == expected.map(\.id))
        }
    }

    @Test func unorderedHoldsWhatFilterLists() {
        let threads = mailbox(500, seed: 7)
        for attention in [nil, Attention.needsYou, .waiting] as [Attention?] {
            let unordered = MailQuery.unordered(threads, attention: attention, now: now)
            let filtered = MailQuery.filter(threads, attention: attention, now: now)
            #expect(unordered.count == filtered.count)
            #expect(Set(unordered.map(\.id)) == Set(filtered.map(\.id)))
        }
    }
}
}
