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
}
