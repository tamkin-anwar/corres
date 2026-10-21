import Foundation
import Testing
@testable import CorresCore

struct TopResultsTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func mail(_ n: Int, sender: String, subject: String, body: String, daysAgo: Double) -> Correspondence {
        Correspondence(id: ThreadID(account: "me@example.com", providerID: "t\(n)"), sender: sender,
                       senderEmail: "\(sender.lowercased().replacingOccurrences(of: " ", with: "."))@example.com",
                       organization: "", subject: subject, excerpt: "", body: body,
                       receivedAt: now.addingTimeInterval(-daysAgo * 86_400), dueAt: nil, reason: "", attention: .quiet)
    }

    @Test func whoItsFromOutranksAMention() {
        // Newest first, the one from Delta is buried under mentions.
        let mentions = (0..<8).map { mail($0, sender: "Newsletter \($0)", subject: "Weekly", body: "Deals on Delta flights", daysAgo: Double($0)) }
        let delta = mail(99, sender: "Delta", subject: "Your trip to Lisbon", body: "Confirmation", daysAgo: 40)
        let matches = MailQuery.filter(mentions + [delta], search: "delta", now: now)
        #expect(matches.last?.id == delta.id)
        let top = MailQuery.topResults(matches, search: "delta", now: now)
        #expect(top.first?.id == delta.id)
        #expect(top.count == 5)
    }

    @Test func aShortListHasNoTopResults() {
        let few = (0..<4).map { mail($0, sender: "Ana", subject: "Plans", body: "", daysAgo: Double($0)) }
        #expect(MailQuery.topResults(few, search: "ana", now: now).isEmpty)
    }
}
