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

/// Ask's answers get the same check as summaries before they're shown.
struct AskAnswerGroundingTests {
    @Test func aRealAnswerPasses() {
        let email = """
        Sam Lee <sam@example.com>
        Budget for Q4
        Hi Tamkin, could you send me the revised budget numbers by Friday? Thanks, Sam
        """
        #expect(MailDigest.unsupportedClaims(in: "Sam asked you to send the revised budget numbers by Friday.",
                                             source: email).isEmpty)
    }

    @Test func anInventedAnswerFails() {
        // What Ask showed: a person from its instructions and an amount
        // from somewhere else, against a TestFlight email.
        let email = """
        TAMKIN NURUL ANWAR
        Corres 0.2.0 (4) for iOS is now available to test.
        Corres 0.2.0 (4) is ready to test on iOS. To test this app, open TestFlight on your device.
        """
        #expect(!MailDigest.unsupportedClaims(
            in: "Maya asked you to approve a subscription renewal for $98.99/year starting Sep 22, 2027 until canceled.",
            source: email).isEmpty)
    }
}

/// Amounts in taka and rupees get the same check as dollars and pounds.
struct CurrencyGroundingTests {
    @Test func aWrongTakaAmountIsCaught() {
        let email = "Your bKash payment of ৳1,250 to Daraz was successful."
        #expect(MailDigest.unsupportedClaims(in: "You paid ৳1,250 to Daraz.", source: email).isEmpty)
        #expect(!MailDigest.unsupportedClaims(in: "You paid ৳2,500 to Daraz.", source: email).isEmpty)
        #expect(!MailDigest.unsupportedClaims(in: "You paid Tk 3,000 to Daraz.", source: email).isEmpty)
    }
}

/// Numbers read the same in every locale.
struct WorldNumberTests {
    @Test func groupingStylesMatch() {
        #expect(MailDigest.canonicalNumber("1,250") == "1250")
        #expect(MailDigest.canonicalNumber("1.250") == "1250")
        #expect(MailDigest.canonicalNumber("1,25,000") == "125000")
        #expect(MailDigest.canonicalNumber("1,250.00") == "1250")
        #expect(MailDigest.canonicalNumber("1.250,00") == "1250")
        #expect(MailDigest.canonicalNumber("12.50") == "12.5")
        #expect(MailDigest.canonicalNumber("15.10.2026") == "15.10.2026")
    }

    @Test func amountsInAnyFormatAreChecked() {
        // A European receipt summarized in US style, and a wrong one.
        let euro = "Betrag: 1.250,00 € für Ihre Bestellung bei Zalando."
        #expect(MailDigest.unsupportedClaims(in: "You paid €1,250 to Zalando.", source: euro).isEmpty)
        #expect(!MailDigest.unsupportedClaims(in: "You paid €1,520 to Zalando.", source: euro).isEmpty)
        // Bengali digits and lakh grouping.
        let bangla = "আপনার পেমেন্ট ৳১,২৫,০০০ Daraz-এ সফল হয়েছে।"
        #expect(MailDigest.unsupportedClaims(in: "You paid ৳125,000 to Daraz.", source: bangla).isEmpty)
        #expect(!MailDigest.unsupportedClaims(in: "You paid ৳152,000 to Daraz.", source: bangla).isEmpty)
    }

    @Test func amountsInAnyCurrencyAreFound() {
        let facts = MailDigest.facts(in: "Total ₦45,000 paid. Also AED 120 and 3.500 kr on file. Rs. 899 refund.")
        #expect(facts.contains { $0.contains("45,000") })
        #expect(facts.contains { $0.contains("AED 120") })
        #expect(facts.contains { $0.contains("899") })
    }
}

struct NewsletterFramingTests {
    /// Drafts the on-device model wrote for real newsletters (Oct 2026).
    @Test func newsletterFiguresToldAsTheReadersAreCaught() {
        #expect(MailDigest.claimsMoneyToReader("You got a charge of $81,801.71."))
        #expect(MailDigest.claimsMoneyToReader("You got a $499 Alexa Tablet 12 Pro with a $549.99 version."))
        #expect(MailDigest.claimsMoneyToReader("You got $100 for the TCL P80 Ultra's display."))
        #expect(MailDigest.claimsMoneyToReader("You received £20 from the Brew."))
    }

    @Test func offersAndHeadlinesAreFine() {
        #expect(!MailDigest.claimsMoneyToReader("You get $50 off and a free toy when spending $50+. Offer ends 10/12/26."))
        #expect(!MailDigest.claimsMoneyToReader("TSMC reported revenue of $511.86 billion for September."))
        #expect(!MailDigest.claimsMoneyToReader("You saved 30% on watches during the sale."))
    }

    @Test func possessiveNameIsSupported() {
        let source = "TCL's P80 Ultra has a paperlike display."
        #expect(MailDigest.unsupportedClaims(in: "It covers the P80 Ultra's display.", source: source).isEmpty)
        #expect(!MailDigest.unsupportedClaims(in: "It covers the P80 Max's display.", source: source).isEmpty)
    }
}
