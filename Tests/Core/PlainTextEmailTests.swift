import Foundation
import Testing
@testable import CorresCore

struct PlainTextEmailTests {
    @Test func textIsEscaped() {
        let html = PlainTextEmail.html(from: "Use <b>bold</b> & \"quotes\"")
        #expect(html.contains("Use &lt;b&gt;bold&lt;/b&gt; &amp; &quot;quotes&quot;"))
        #expect(!html.contains("<b>"))
    }

    @Test func replyHistoryBecomesAFoldableQuote() {
        let text = """
        Sounds good, see you then.

        On Tue, Oct 7, 2026 at 3:12 PM Maya Chen <maya@example.com>
        wrote:

        > Can we meet Thursday?
        >
        > > Earlier message
        """
        let html = PlainTextEmail.html(from: text)
        #expect(html.contains("Sounds good, see you then."))
        #expect(html.contains(#"<div class="corres-quote">On Tue, Oct 7"#))
        #expect(html.contains(#"<blockquote type="cite">Can we meet Thursday?"#))
        #expect(html.contains(#"<blockquote type="cite">Earlier message</blockquote>"#))
        #expect(!html.contains("&gt; Can"))
    }

    @Test func quoteWithoutAttributionIsStillAQuote() {
        let html = PlainTextEmail.html(from: "Yes\n> Are you coming?")
        #expect(html.contains(#"Yes\#n<blockquote type="cite">Are you coming?</blockquote>"#))
    }

    @Test func hardWrappedParagraphsAreJoined() {
        let text = """
        Thanks for sending the draft over. I read through it this morning and
        I think the second section needs a little more detail about the budget
        before we share it with the rest of the team next week.

        Two things:
        - the timeline
        - the costs
        """
        let lines = PlainTextEmail.unwrapped(text.components(separatedBy: "\n"))
        #expect(lines[0].hasPrefix("Thanks for sending") && lines[0].hasSuffix("next week."))
        #expect(lines.contains("Two things:"))
        #expect(lines.contains("- the timeline"))
        #expect(lines.contains("- the costs"))
    }

    @Test func shortLinesKeepTheirBreaks() {
        let text = "Hi Sam,\nSee you at 5.\nThanks,\nAlex"
        #expect(PlainTextEmail.unwrapped(text.components(separatedBy: "\n")) == text.components(separatedBy: "\n"))
    }

    @Test func formatFlowedLinesAreJoined() {
        let lines = PlainTextEmail.unwrapped(["This line continues ", "on the next one.", "", "-- ", "Alex"])
        #expect(lines == ["This line continues on the next one.", "", "-- ", "Alex"])
    }
}

struct PreviewNoiseTests {
    @Test func newsletterPaddingLeavesThePreview() {
        #expect("Introducing the PRX Skeleton &zwnj; &zwnj; &zwnj;&#847; &zwnj;".previewText == "Introducing the PRX Skeleton")
        #expect("This week\u{200C} \u{200B}\u{00AD}\u{034F} in review".previewText == "This week in review")
        #expect("[cid:image001.png@01DD5FDE.D10AB060] Your Amazon Offer".previewText == "Your Amazon Offer")
        #expect("Hello TAMKIN NURUL, -------------------- Thank you".previewText == "Hello TAMKIN NURUL, Thank you")
        #expect("Plain words stay just as they are.".previewText == "Plain words stay just as they are.")
        #expect("It&rsquo;s here &mdash; finally".previewText == "It’s here — finally")
    }

    @Test func storedPreviewsComeOutClean() {
        let thread = Correspondence(id: ThreadID(account: "a", providerID: "1"), sender: "Tissot", senderEmail: nil, organization: "",
                                    subject: "S", excerpt: "Tissot &zwnj; &zwnj; &zwnj;", body: "", htmlBody: nil, latestMessageID: nil,
                                    receivedAt: .now, dueAt: nil, reason: "", attention: .quiet)
        #expect(thread.excerpt == "Tissot")
    }
}
