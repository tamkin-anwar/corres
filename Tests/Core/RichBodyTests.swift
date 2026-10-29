import Foundation
import Testing
@testable import CorresCore

struct RichBodyTests {
    @Test func plainStaysPlain() {
        #expect(RichBody.html([RichRun("Hi Sara,\nSee you Friday.")]) == nil)
    }

    @Test func stylesListsLinksAndQuotes() {
        let html = RichBody.html([
            RichRun("Hi "), RichRun("Sara", bold: true), RichRun(",\nTo bring:\n• Milk\n• Eggs\n1. First\n2. Second\nSee "),
            RichRun("the plan", link: URL(string: "https://x.test/a?b=1&c=2")),
            RichRun(" <soon>\n\nOn Mon, Sara wrote:\n> Thanks & see you"),
        ])!
        #expect(html.contains("Hi <b>Sara</b>,<br>"))
        #expect(html.contains("<ul><li>Milk</li><li>Eggs</li></ul>"))
        #expect(html.contains("<ol><li>First</li><li>Second</li></ol>"))
        #expect(html.contains("<a href=\"https://x.test/a?b=1&amp;c=2\">the plan</a>"))
        #expect(html.contains("&lt;soon&gt;"))
        #expect(html.contains("Thanks &amp; see you<br></blockquote>"))
    }

    /// Opened again (Undo Send, Send Later, a draft): the same formatting
    /// back on the same words, and nothing else changed.
    @Test func reopenedKeepsItsFormatting() {
        let runs = [
            RichRun("Hi "), RichRun("Sara", bold: true), RichRun(",\nTo bring:\n• "), RichRun("Milk", italic: true),
            RichRun("\n• Eggs & "), RichRun("bread", underline: true, strikethrough: true),
            RichRun("\nSee "), RichRun("the plan", link: URL(string: "https://x.test/a?b=1&c=2")),
            RichRun(" <soon>\n\nOn Mon, Sara wrote:\n> Thanks"),
        ]
        let plain = runs.map(\.text).joined()
        let html = RichBody.html(runs)!
        let back = RichBody.runs(plain: plain, html: html)
        #expect(back.map(\.text).joined() == plain)
        #expect(back.contains(RichRun("Sara", bold: true)))
        #expect(back.contains(RichRun("Milk", italic: true)))
        #expect(back.contains(RichRun("bread", underline: true, strikethrough: true)))
        #expect(back.contains(RichRun("the plan", link: URL(string: "https://x.test/a?b=1&c=2"))))
        // Written back, it's the same email.
        #expect(RichBody.html(back) == html)
    }

    /// A signature added since, or HTML that doesn't match: the words are
    /// kept as they are, never lost.
    @Test func reopenedKeepsEveryWord() {
        let html = RichBody.html([RichRun("Thanks, "), RichRun("Ana", bold: true)])!
        let plain = "Thanks, Ana\n\n-- \nAna Reyes"
        let back = RichBody.runs(plain: plain, html: html)
        #expect(back.map(\.text).joined() == plain)
        #expect(back.contains(RichRun("Ana", bold: true)))
        #expect(RichBody.runs(plain: "Hello", html: "<b>Other</b>") == [RichRun("Hello")])
        #expect(RichBody.runs(plain: "", html: "<b>x</b>").map(\.text).joined() == "")
    }
}
