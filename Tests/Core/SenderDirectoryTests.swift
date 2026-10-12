import Foundation
import Testing
@testable import CorresCore

struct SenderDirectoryTests {
    private let now = Date(timeIntervalSince1970: 1_791_800_000)

    private func mail(_ id: String, from email: String, name: String, daysAgo: Double, unread: Bool = false,
                      decision: SenderDecision = .approved, list: Bool = false) -> Correspondence {
        var thread = Correspondence(id: ThreadID(account: "me@x.test", providerID: id), sender: name, senderEmail: email,
                                    organization: "", subject: id, excerpt: "", body: "",
                                    receivedAt: now.addingTimeInterval(-daysAgo * 86_400), dueAt: nil, reason: "",
                                    attention: .quiet, isUnread: unread,
                                    listUnsubscribeURL: list ? "https://x.test/u" : nil)
        thread.senderDecision = decision
        return thread
    }

    @Test func oneRowPerSenderWithTheNewestDecision() {
        let threads = [
            mail("1", from: "News@Medium.com", name: "Medium", daysAgo: 5, unread: true, list: true),
            mail("2", from: "news@medium.com", name: "Medium Daily", daysAgo: 1, unread: true, decision: .blocked, list: true),
            mail("3", from: "sara@x.test", name: "Sara", daysAgo: 2),
        ]
        let senders = SenderDirectory.summaries(threads)
        #expect(senders.count == 2)
        let medium = senders.first { $0.email == "news@medium.com" }!
        #expect(medium.count == 2 && medium.unread == 2 && medium.isList)
        #expect(medium.decision == .blocked && medium.name == "Medium Daily")
        #expect(SenderDirectory.filtered(senders, .blocked).map(\.email) == ["news@medium.com"])
        #expect(SenderDirectory.filtered(senders, .subscriptions).isEmpty) // blocked ones aren't listed twice
        #expect(SenderDirectory.filtered(senders, .allowed, search: "sar").map(\.name) == ["Sara"])
        #expect(SenderDirectory.filtered(senders, .all, order: .most).first?.email == "news@medium.com")
    }
}
