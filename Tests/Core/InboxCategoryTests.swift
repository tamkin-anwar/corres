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

    private func bulk(_ subject: String, from email: String, labels: [String] = ["CATEGORY_UPDATES"], age: TimeInterval = 0) -> Correspondence {
        Correspondence(id: ThreadID(account: "me@x.test", providerID: UUID().uuidString), sender: "S", senderEmail: email,
                       organization: "", subject: subject, excerpt: "", body: "", receivedAt: .now.addingTimeInterval(-age),
                       dueAt: nil, reason: "", attention: .quiet, labelIds: labels)
    }

    @Test func socialNetworksAreSocial() {
        #expect(InboxCategory.of(bulk("Stripe is hiring", from: "jobalerts-noreply@linkedin.com")) == .social)
        #expect(InboxCategory.of(bulk("Why doesn't X exist?", from: "noreply@redditmail.com")) == .social)
    }

    @Test func offersArePromotionsButReceiptsNever() {
        #expect(InboxCategory.of(bulk("These special offers end soon", from: "store@google.test")) == .promotions)
        #expect(InboxCategory.of(bulk("Up to 40% off! Your next trip", from: "deals@air.test")) == .promotions)
        #expect(InboxCategory.of(bulk("LAST CHANCE: your points expire tomorrow", from: "rewards@pizza.test")) == .promotions)
        // Gmail's Promotions, but it's a receipt: Updates.
        #expect(InboxCategory.of(bulk("Your receipt for order #1234", from: "shop@x.test", labels: ["CATEGORY_PROMOTIONS"])) == .updates)
        // "Social Security" in a news digest is not a security notice.
        #expect(InboxCategory.of(bulk("An overlooked Social Security benefit", from: "news@x.test", labels: ["CATEGORY_PROMOTIONS"])) == .promotions)
        #expect(InboxCategory.of(bulk("Get 2 tickets to the show", from: "events@x.test")) == .updates)
    }

    @Test func urgentIsPrimaryWhileItsUrgent() {
        #expect(InboxCategory.of(bulk("Security alert", from: "no-reply@accounts.google.com")) == .primary)
        #expect(InboxCategory.of(bulk("Your password reset link", from: "hello@id.test")) == .primary)
        // An hour on, the code has done its job.
        #expect(InboxCategory.of(bulk("Your password reset link", from: "hello@id.test", age: 7_200)) == .updates)
        #expect(InboxCategory.of(bulk("Security alert", from: "no-reply@accounts.google.com", age: 5 * 86_400)) == .updates)
    }

    @Test func uncategorizedMailFollowsItsSender() {
        let shop = (0..<4).map { _ in bulk("Fall collection", from: "no-reply@shop.test", labels: ["CATEGORY_PROMOTIONS"]) }
        let context = InboxCategory.context(for: shop)
        // No Gmail category on this one: it goes with the rest.
        #expect(InboxCategory.of(bulk("A note from us", from: "no-reply@shop.test", labels: []), context: context) == .promotions)
        // Gmail said Updates: Gmail's reading stands.
        #expect(InboxCategory.of(bulk("Your account changes", from: "no-reply@shop.test"), context: context) == .updates)
    }
}
