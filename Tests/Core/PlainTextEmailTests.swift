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
