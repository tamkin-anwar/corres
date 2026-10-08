import Foundation
import Testing
@testable import CorresCore

/// The labeled set `MailDigest.minimumClaimSupport` was calibrated on:
/// faithful paraphrases of real kinds of mail must pass, and statements the
/// email never makes (including the one found live: "Address change
/// approved" for an email of photos and captions) must be caught.
struct ClaimGroundingTests {
    @Test func paraphrasesPassAndMadeUpClaimsAreCaught() {
        let cases: [(String, String, String, Bool)] = [
            ("sofia", "Hello, Could you confirm Thursday's conversation? The meeting is Thursday, October 1, 2026 at 3:00 PM, at Maison Studio, 120 Grand Street. We have taken time to consider the details and would appreciate your perspective.", "Sofia wants you to confirm Thursday's meeting at Maison Studio.", true),
            ("maya", "Hello, Your approval on the final direction is the last piece. We have taken time to consider the details and would appreciate your perspective. Everything you need for this conversation is here. Warmly, Maya Chen", "Maya is waiting on your approval of the final direction.", true),
            ("receipt", "Thanks for your order. Order #A1B2-3C4D. Coffee beans $18.00. Grinder $95.00. Total $113.00. Your items ship within 2 business days.", "Your order of coffee beans and a grinder came to $113.00 and ships within 2 business days.", true),
            ("shipping", "Good news! Your package is on its way. Estimated delivery: Friday, Oct 9. Track your package with UPS tracking number 1Z999AA10123456784.", "Your package is on its way and should arrive Friday, Oct 9.", true),
            ("launch", "Hi Tamkin, We narrowed it down to two options for the launch: a soft launch in November with the beta group, or a full public launch in January. Marketing prefers January. Can you decide by Monday so we can book the campaign?", "The team is choosing between a November soft launch and a January public launch, and needs your decision by Monday.", true),
            ("newsletter", "Welcome to the Gear Patrol newsletter, where we gather the day's best gear news, roundups and stories. James Bond Has a New Watch. It Isn't an Omega. It does suit a British spy, though. Today's Best Deals: Save on Patagonia, Yeti and More.", "Gear Patrol's newsletter covers James Bond's new watch and deals on Patagonia and Yeti.", true),
            ("statement", "Your statement is ready. Minimum payment due: $40.00 by Oct 22. Statement balance: $1,284.63. Log in to view your statement and make a payment.", "Your statement is ready, with a $40.00 minimum payment due Oct 22.", true),
            ("security", "We noticed a new sign-in to your account from Chrome on Mac in Corona, CA. If this was you, you can ignore this email. If not, secure your account now.", "There was a new sign-in to your account from Chrome on a Mac; secure your account if it wasn't you.", true),
            ("photos", "Section 0 text under the image. Section 1 text under the image. Section 2 text under the image. Section 3 text under the image.", "You need to confirm the change.", false),
            ("photos2", "Section 0 text under the image. Section 1 text under the image. Section 2 text under the image.", "Address change approved", false),
            ("maya-bad", "Hello, Your approval on the final direction is the last piece. We have taken time to consider the details and would appreciate your perspective.", "Maya cancelled the project and asked for a refund.", false),
            ("receipt-bad", "Thanks for your order. Coffee beans $18.00. Grinder $95.00. Total $113.00.", "Your subscription was renewed and your card will be charged next month.", false),
            ("launch-bad", "We narrowed it down to two options for the launch: a soft launch in November with the beta group, or a full public launch in January.", "The launch was postponed because the budget was cut.", false),
            ("security-bad", "We noticed a new sign-in to your account from Chrome on Mac. If this was you, you can ignore this email.", "Your password was changed and your account is locked.", false),
        ]
        for (name, source, summary, good) in cases {
            let flagged = MailDigest.ungroundedClaims(in: summary, source: source)
            #expect(flagged.isEmpty == good, "\(name): \(flagged)")
        }
    }
}
