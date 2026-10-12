import Foundation
import Testing
@testable import CorresCore

struct NextStepTests {
    /// The email a tester reported: its summary repeated it; the useful
    /// thing was the booking link.
    let tetanus = """
    Dear Niloy,
    Our records show that you are due a Tetanus vaccination / booster. A person is due 5 tetanus vaccines in their lifetime, book a booster towards completing your tetanus immunisation. Please visit the link to book.

    Regards,
    Portsdown Group Practice

    https://systmonline.tpp-uk.com/2/Book?id=a2001470_ZV_W6_0
    """

    @Test func aShortEmailGetsNoSummary() {
        #expect(MailDigest.wordCount(tetanus) < MailDigest.minimumWords)
        #expect(!MailDigest.isWorthSummarizing(MailDigest.clean(tetanus)))
    }

    @Test func itsBookingLinkIsTheNextStep() {
        let step = MailDigest.nextStep(text: tetanus, html: nil, kind: .notification)
        #expect(step?.label == "Book")
        #expect(step?.host == "systmonline.tpp-uk.com")
    }

    @Test func aButtonsOwnWordsBecomeTheLabel() {
        let html = """
        <p>Your bill for October is ready.</p>
        <a href="https://example.com/unsubscribe">Unsubscribe</a>
        <a href="https://billing.example.com/pay?id=7">PAY YOUR BILL</a>
        <a href="https://facebook.com/example">Facebook</a>
        """
        let step = MailDigest.nextStep(text: "Your bill for October is ready.", html: html, kind: .receipt)
        #expect(step?.label == "Pay your bill")
        #expect(step?.host == "billing.example.com")
    }

    @Test func plumbingLinksAreNeverTheNextStep() {
        let html = """
        <p>Thanks for reading.</p>
        <a href="https://example.com/preferences">Manage preferences</a>
        <a href="https://example.com/unsubscribe">Unsubscribe</a>
        """
        #expect(MailDigest.nextStep(text: "Thanks for reading.", html: html, kind: .notification) == nil)
    }

    @Test func newslettersHaveNoNextStep() {
        let html = #"<a href="https://shop.example.com/sale">Shop now and book your fitting</a>"#
        #expect(MailDigest.nextStep(text: "Big sale", html: html, kind: .newsletter) == nil)
    }

    @Test func aSummaryThatRepeatsTheOpeningIsCaught() {
        let summary = "Our records show that you are due a Tetanus vaccination / booster. A person is due 5 tetanus vaccines in their lifetime, book a booster towards completing your tetanus immunisation."
        #expect(MailDigest.restatesOpening(summary, of: tetanus))
    }

    @Test func aSummaryThatAddsSomethingIsKept() {
        let email = """
        Hi Tamkin, thanks for the update on the launch plan. I went through the deck with the team this morning. \
        Overall it looks good, but finance flagged that the Q4 budget line is about twelve thousand over what we \
        agreed in September, mostly from the agency retainer. Could you send a revised budget by Thursday so we can \
        take it to the board on Friday? Also, legal needs the vendor contract signed before we can announce anything.
        """
        let summary = "Finance needs a revised Q4 budget by Thursday for Friday's board, and legal needs the vendor contract signed before the announcement."
        #expect(!MailDigest.restatesOpening(summary, of: email))
    }

    /// Nothing buried to point at in a short reminder.
    @Test func aShortReminderHasNoBuriedAsk() {
        #expect(MailDigest.buriedAsk(text: MailDigest.clean(tetanus)) == nil)
    }
}

extension NextStepTests {
    /// Cleaning drops what follows "Regards", where this link is: the next
    /// step reads the whole text.
    @Test func cleaningWouldHaveDroppedTheLink() {
        #expect(!MailDigest.clean(tetanus).contains("systmonline"))
        #expect(MailDigest.nextStep(text: MailDigest.readableText(body: tetanus, html: nil), html: nil, kind: .notification)?.label == "Book")
    }
}

extension NextStepTests {
    @Test func clickTrackersAreNotShownAsTheDestination() {
        #expect(NextStep(label: "Review", url: URL(string: "https://click.e.usa.experian.com/?qs=1")!).host == "")
        #expect(NextStep(label: "Reset", url: URL(string: "https://track.pstmrk.it/3s/x")!).host == "")
        #expect(NextStep(label: "Review", url: URL(string: "https://na4.docusign.net/Signing")!).host == "na4.docusign.net")
        #expect(NextStep(label: "Book", url: URL(string: "https://www.systmonline.tpp-uk.com/")!).host == "systmonline.tpp-uk.com")
    }

    @Test func clickTrackersArentShownAsTheDestination() {
        #expect(NextStep(label: "Update payment", url: URL(string: "https://tracksg.doordash.com/x")!).host == "")
        #expect(NextStep(label: "Pay", url: URL(string: "https://www.trackmybill.com/pay")!).host == "trackmybill.com")
    }
}
