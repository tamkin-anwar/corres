import Testing
@testable import CorresCore

struct GlanceTests {
    /// The Uber receipt a tester saw summarized as its upsell and button.
    @Test func failedPaymentReceipt() {
        let text = """
        Failed payment
        8 Oct 2026 , 08:27
        Thanks for riding, Niloy
        Total £14.62
        Trip fare £12.10
        Booking fee £2.52
        Want to switch your payment method?
        Download the receipt in a PDF format Download PDF
        """
        let glance = MailDigest.glance(text: text, kind: .receipt)
        #expect(glance?.status == "Failed payment")
        #expect(glance?.isAlert == true)
        #expect(glance?.facts == [.init(label: "Total", value: "£14.62")])
    }

    @Test func deliveryWithDateAndOrderNumber() {
        let text = """
        YOUR ORDER HAS SHIPPED
        Hi Sam, good news.
        Estimated delivery: Thu, 15 Oct
        Order #112-4471-889
        Subtotal $40.00
        Order total $43.20
        """
        let glance = MailDigest.glance(text: text, kind: .shipping)
        #expect(glance?.status == "Your order has shipped")
        #expect(glance?.isAlert == false)
        #expect(glance?.facts.map(\.label) == ["Order total", "Estimated delivery", "Order"])
        #expect(glance?.facts.first?.value == "$43.20")
    }

    /// Taka, written after the number, as Bangladeshi billers do.
    @Test func billInAnyCurrency() {
        let text = "Your bill is ready\nAmount due 1,250.00 BDT\nDue date 20 October 2026\nAccount 55120"
        let glance = MailDigest.glance(text: text, kind: .notification)
        #expect(glance?.facts.first == .init(label: "Amount due", value: "1,250.00 BDT"))
        #expect(glance?.facts.contains(.init(label: "Due date", value: "20 October 2026")) == true)
    }

    @Test func nothingForPersonalMailOrVagueMail() {
        #expect(MailDigest.glance(text: "Total £14.62\nDue date 3 Nov", kind: .personal) == nil)
        // One stray figure with no status isn't worth a card.
        #expect(MailDigest.glance(text: "Thanks for your order.\nTotal £14.62", kind: .receipt) == nil)
    }
}
