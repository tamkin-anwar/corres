import Foundation
import Testing
@testable import CorresCore

/// The words a summary is built from, the checks run on what comes back,
/// and the summary built from the email's own sentences.
struct MailDigestTests {

    // MARK: Readable text

    @Test func htmlOnlyEmailBecomesReadableText() {
        let html = """
        <html><head><style>.x{color:red}</style><title>Hi</title></head><body>
        <span style="display:none">Preheader filler &zwnj;&zwnj;</span>
        <table><tr><td><h1>Your order has shipped</h1></td></tr>
        <tr><td><p>Hi Tamkin,</p><p>Your AirPods Pro (2nd generation) are on the way &amp; should arrive Thursday, Oct 1.</p>
        <p>Order total: $249.00</p><!-- tracking pixel --><script>track()</script></td></tr></table></body></html>
        """
        let text = MailDigest.text(fromHTML: html)
        #expect(text.contains("Your order has shipped"))
        #expect(text.contains("AirPods Pro (2nd generation) are on the way & should arrive Thursday, Oct 1."))
        #expect(text.contains("$249.00"))
        #expect(!text.contains("color:red"))
        #expect(!text.contains("Preheader filler"))
        #expect(!text.contains("track()"))
        #expect(!text.contains("<"))
    }

    @Test func richerOfPlainAndHTMLWins() {
        let snippet = "Your order has shipped Hi Tamkin, Your AirPods are on the way"
        let html = "<p>" + String(repeating: "This newsletter has a lot of real words in it. ", count: 12) + "</p>"
        #expect(MailDigest.readableText(body: snippet, html: html).contains("newsletter"))
        let realPlain = String(repeating: "A proper plain text part with plenty of words. ", count: 10)
        #expect(MailDigest.readableText(body: realPlain, html: html) == realPlain.trimmingCharacters(in: .whitespaces))
    }

    // MARK: Cleaning

    @Test func gmailQuoteWrappedOverTwoLinesIsRemoved() {
        let body = """
        Sounds great, Thursday at 3 works for me. I'll bring the contract.

        On Mon, Sep 28, 2026 at 3:02 PM Sofia Rossi <
        sofia@maisonstudio.com> wrote:
        Could we meet Thursday at 3 to review the contract?
        """
        let cleaned = MailDigest.clean(body)
        #expect(cleaned == "Sounds great, Thursday at 3 works for me. I'll bring the contract.")
    }

    @Test func outlookHistorySignatureAndFooterAreRemoved() {
        let body = """
        Please approve the Q3 budget by Friday.

        Thanks,
        Dana
        --
        Dana Park | CFO
        Sent from my iPhone
        ________________________________
        From: Tamkin Anwar
        Sent: Monday, September 28, 2026 9:00 AM
        To: Dana Park
        Subject: Q3 budget
        """
        let cleaned = MailDigest.clean(body)
        #expect(cleaned.hasPrefix("Please approve the Q3 budget by Friday."))
        #expect(!cleaned.contains("CFO"))
        #expect(!cleaned.contains("Subject"))
    }

    @Test func footersLinksAndSentFromLinesAreDropped() {
        let body = """
        Your statement is ready. The balance of $84.20 is due Oct 12.
        View statement (https://bank.example.com/s?id=123)
        You're receiving this email because you have an account.
        Unsubscribe | Manage preferences
        © 2026 Example Bank. All rights reserved.
        """
        let cleaned = MailDigest.clean(body)
        #expect(cleaned.contains("$84.20 is due Oct 12"))
        #expect(!cleaned.contains("https"))
        #expect(!cleaned.lowercased().contains("unsubscribe"))
        #expect(!cleaned.contains("©"))
        #expect(!cleaned.lowercased().contains("receiving this"))
    }

    @Test func confidentialityNoticeEndsTheText() {
        let body = "Attached is the signed NDA.\n\nCONFIDENTIALITY NOTICE: This e-mail is intended only for the recipient."
        #expect(MailDigest.clean(body) == "Attached is the signed NDA.")
    }

    @Test func tooShortToSummarize() {
        #expect(!MailDigest.isWorthSummarizing("Thanks! See you then."))
        #expect(MailDigest.isWorthSummarizing(String(repeating: "word ", count: 40)))
    }

    // MARK: Kind

    @Test func kindsAreRecognized() {
        func kind(_ subject: String, _ text: String, bulk: Bool = true, automated: Bool = true, event: Bool = false) -> MailDigest.Kind {
            MailDigest.kind(subject: subject, text: text, senderEmail: nil, isBulk: bulk, looksAutomated: automated, hasEvent: event)
        }
        #expect(kind("Your sign-in code", "Your verification code is 482913. It expires in 10 minutes.") == .code)
        #expect(kind("Shipped!", "Your package is out for delivery and will arrive today.") == .shipping)
        #expect(kind("Receipt from Apple", "Your receipt. Order number: W123456. Total $9.99") == .receipt)
        #expect(kind("Invitation: Design review", "Thursday 3pm", event: true) == .invite)
        #expect(kind("Lunch?", "Are you free Thursday?", bulk: false, automated: false) == .personal)
        #expect(kind("Weekly digest", String(repeating: "Story about technology and design. ", count: 30)) == .newsletter)
        #expect(kind("Your account", "Your password was changed.") == .notification)
        // A flight's confirmation code is a booking, not a one-time code.
        #expect(kind("Your trip", "Confirmation code ABC123 for your flight", bulk: true) != .code)
    }

    // MARK: Facts

    @Test func factsAreQuotedExactlyAsWritten() {
        let text = "Order number: W48213 has shipped. You were charged $1,249.50 on Sep 28. Arrives Oct 2."
        let facts = MailDigest.facts(in: text)
        #expect(facts.contains("$1,249.50"))
        #expect(facts.contains { $0.contains("W48213") })
        #expect(facts.contains { $0.contains("Oct 2") })
        #expect(!MailDigest.facts(in: "Your order shipped today and more.").contains { $0.lowercased().contains("shipped") })
    }

    @Test func verificationCodeIsFound() {
        #expect(MailDigest.verificationCode(in: "Your Corres sign-in code is 902114. Don't share it.") == "902114")
        #expect(MailDigest.verificationCode(in: "Your code is 4821") == "4821")
        #expect(MailDigest.verificationCode(in: "We shipped 3 items on Sep 28") == nil)
    }

    // MARK: Faithfulness

    private let source = """
    Hi Tamkin, could you send the signed contract to Sofia Rossi by Friday, Oct 2?
    The fee is $4,500 and the kickoff is at Maison Studio.
    """

    @Test func faithfulSummaryPasses() {
        #expect(MailDigest.isFaithful("Send the signed contract to Sofia Rossi by Friday, Oct 2. The fee is $4,500.", source: source))
        #expect(MailDigest.isFaithful("You need to send the contract before the kickoff at Maison Studio.", source: source))
    }

    @Test func inventedFactsAreCaught() {
        #expect(MailDigest.unsupportedClaims(in: "Send the contract by Oct 3.", source: source) == ["3"])
        #expect(MailDigest.unsupportedClaims(in: "The fee is $5,000.", source: source) == ["5000"])
        #expect(MailDigest.unsupportedClaims(in: "Send it by Thursday.", source: source) == ["Thursday"])
        #expect(MailDigest.unsupportedClaims(in: "Send it to Sofia by tomorrow.", source: source) == ["tomorrow"])
        #expect(MailDigest.unsupportedClaims(in: "Send the contract to Marco Bianchi.", source: source) == ["Marco", "Bianchi"])
        #expect(MailDigest.unsupportedClaims(in: "Email it to legal@maison.com.", source: source) == ["legal@maison.com"])
    }

    @Test func numbersMatchWholeNotInsideOthers() {
        let statement = "Statement balance: $1,284.63. Payment due date: Oct 22, 2026. The call is at 3pm."
        #expect(MailDigest.unsupportedClaims(in: "It renews on Oct 28.", source: statement) == ["28"])
        #expect(MailDigest.isFaithful("You owe $1,284.63, due Oct 22, 2026.", source: statement))
        #expect(MailDigest.isFaithful("The call is at 3:00 PM.", source: statement))
        #expect(MailDigest.unsupportedClaims(in: "The call is at 3:30.", source: statement) == ["3:30"])
    }

    @Test func senderVoiceIsCaught() {
        #expect(MailDigest.speaksAsSender("Send the contract. I'd meet at Maison Studio next week."))
        #expect(MailDigest.speaksAsSender("We'll ship it Thursday."))
        #expect(!MailDigest.speaksAsSender("Sofia asks you to send the signed contract by Oct 1."))
        #expect(!MailDigest.speaksAsSender("Your order ships to the US on Oct 2."))
    }

    @Test func keyPointsMustStandAlone() {
        let summary = "Your Chase statement is ready and paid automatically."
        #expect(!MailDigest.isUsefulPoint("$40.00", summary: summary))
        #expect(!MailDigest.isUsefulPoint("10 PM", summary: summary))
        #expect(!MailDigest.isUsefulPoint("Chase statement is ready", summary: summary))
        #expect(MailDigest.isUsefulPoint("Minimum payment $40.00 due Oct 22", summary: summary))
    }

    @Test func looseRelativeDaysAreRepaired() {
        let source = "Motion variables let teams reuse easing. Tickets cost €349 until October 15."
        #expect(MailDigest.repairingRelativeDays("You can reuse motion variables today. Tickets cost €349 until October 15.", source: source)
                == "You can reuse motion variables. Tickets cost €349 until October 15.")
        #expect(MailDigest.repairingRelativeDays("Nothing is needed from you today.", source: source) == "Nothing is needed from you.")
        // Anything else wrong isn't repaired.
        #expect(MailDigest.repairingRelativeDays("Tickets cost €399 today.", source: source) == nil)
    }

    @Test func readerNameBecomesYou() {
        #expect(MailDigest.addressingReader("Pending Tamkin's approval by October 9", names: ["Tamkin"]) == "Pending your approval by October 9")
        #expect(MailDigest.addressingReader("Ship to: Tamkin, Corona, CA", names: ["Tamkin"]) == nil)
        #expect(MailDigest.addressingReader("Sofia asks you to sign", names: ["Tamkin"]) == "Sofia asks you to sign")
    }

    @Test func bareLinksAndVaguePointsAreDropped() {
        #expect(!MailDigest.isUsefulPoint("myaccount.google.com/notifications", summary: "A new sign-in"))
        #expect(!MailDigest.isUsefulPoint("Check activity", summary: "A new sign-in"))
        #expect(MailDigest.isUsefulPoint("Tax $0.87 on Sep 27", summary: "You were charged $10.86"))
    }

    // MARK: Summary from the email's own sentences

    @Test func extractivePrefersTheAskOverTheGreeting() {
        let text = """
        Hi Tamkin,
        Hope you're doing well!
        We finished the second round of designs last week and the team is happy with them.
        Could you review the pricing page and send feedback by Wednesday?
        Best regards,
        Sofia
        """
        let summary = MailDigest.extractiveSummary(text: text, kind: .personal)
        #expect(summary == "Could you review the pricing page and send feedback by Wednesday?")
    }

    @Test func extractiveNeverAddsWords() {
        let text = "Your subscription renews on Oct 28 for $9.99. No action is needed if you want to keep it. Manage it anytime in Settings."
        let summary = MailDigest.extractiveSummary(text: text, kind: .receipt) ?? ""
        #expect(MailDigest.isFaithful(summary, source: text))
        #expect(summary.contains("$9.99"))
    }

    @Test func extractiveCodeReturnsTheSentenceWithTheCode() {
        let text = "Hello,\nYour verification code is 551209. It expires in 10 minutes.\nIf you didn't ask for this, ignore this email."
        #expect(MailDigest.extractiveSummary(text: text, kind: .code) == "Your verification code is 551209.")
    }

    // MARK: Conversations and long emails

    @Test func transcriptKeepsOrderAndMarksTheLatest() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let messages = [
            MailDigest.Message(sender: "Sofia Rossi", isFromReader: false, date: now, text: "Can we move the review to Thursday?"),
            MailDigest.Message(sender: "Tamkin", isFromReader: true, date: now.addingTimeInterval(3_600), text: "Thursday works. 3pm?"),
            MailDigest.Message(sender: "Sofia Rossi", isFromReader: false, date: now.addingTimeInterval(7_200), text: "3pm is perfect, see you then."),
        ]
        let (text, shortened) = MailDigest.transcript(messages, budget: 6_000)
        #expect(!shortened)
        let sofia = text.range(of: "Can we move")!.lowerBound
        let you = text.range(of: "[You ·")!.lowerBound
        let latest = text.range(of: "— latest]")!.lowerBound
        #expect(sofia < you && you < latest)
        #expect(text.contains("3pm is perfect"))
    }

    @Test func longThreadsKeepTheEndsAndMarkTheMiddle() {
        let now = Date.now
        let messages = (0..<12).map { MailDigest.Message(sender: "P\($0)", isFromReader: false, date: now, text: "Message number \($0).") }
        let (text, shortened) = MailDigest.transcript(messages, budget: 6_000)
        #expect(shortened)
        #expect(text.contains("[5 earlier messages omitted]"))
        #expect(text.contains("Message number 0.") && text.contains("Message number 11."))
        #expect(!text.contains("Message number 4."))
    }

    @Test func longEmailSplitsIntoSections() {
        let paragraph = String(repeating: "Sentence of the report. ", count: 40)
        let text = Array(repeating: paragraph, count: 6).joined(separator: "\n\n")
        let sections = MailDigest.sections(of: text, size: 2_500)
        #expect(sections.count >= 3)
        #expect(sections.allSatisfy { $0.count <= 2_500 })
        #expect(sections.joined().filter { !$0.isWhitespace }.count == text.filter { !$0.isWhitespace }.count)
    }

    /// Preheaders hidden by collapsing them (Cerberus, Litmus templates)
    /// or Outlook-only hiding never reach a summary.
    @Test func hiddenPreheadersOfEveryKindAreDropped() {
        let html = """
        <div style="max-height:0; overflow:hidden; mso-hide:all;" aria-hidden="true">Preview text only.</div>
        <span style="mso-hide: all; font-size: 0">Filler</span>
        <p>Your order has shipped.</p>
        """
        let text = MailDigest.text(fromHTML: html)
        #expect(text.contains("Your order has shipped."))
        #expect(!text.contains("Preview text only."))
        #expect(!text.contains("Filler"))
    }
}
