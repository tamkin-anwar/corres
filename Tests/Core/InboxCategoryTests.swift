import Foundation
import Testing
@testable import CorresCore

struct InboxCategoryTests {
    private func mail(_ labels: [String], automated: Bool = false, attention: Attention = .quiet) -> Correspondence {
        Correspondence(id: ThreadID(account: "me@x.test", providerID: UUID().uuidString), sender: "S",
                       senderEmail: automated ? "no-reply@shop.test" : "sara@x.test", organization: "", subject: "Hi",
                       excerpt: "", body: "", receivedAt: .now, dueAt: nil, reason: "", attention: attention, labelIds: labels)
    }

    @Test func placesMailLikeTabsButSmarter() {
        #expect(InboxCategory.of(mail(["CATEGORY_PERSONAL"])) == .primary)
        #expect(InboxCategory.of(mail(["CATEGORY_PROMOTIONS"], automated: true)) == .promotions)
        #expect(InboxCategory.of(mail(["CATEGORY_SOCIAL"], automated: true)) == .social)
        #expect(InboxCategory.of(mail(["CATEGORY_FORUMS"], automated: true)) == .updates)
        // Gmail's Primary often holds automated mail; Corres puts it in Updates…
        #expect(InboxCategory.of(mail(["CATEGORY_PERSONAL"], automated: true)) == .updates)
        // …unless it needs you, like a failed payment.
        #expect(InboxCategory.of(mail(["CATEGORY_UPDATES"], automated: true, attention: .needsYou)) == .primary)
        // What you've said wins.
        #expect(InboxCategory.of(mail(["CATEGORY_PROMOTIONS"], automated: true), override: .primary) == .primary)
    }
}
