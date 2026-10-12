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
        #expect(glance?.status == "Payment failed")
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
        #expect(glance?.status == "On its way")
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
        #expect(MailDigest.glance(text: "Hello from the team.\nTotal £14.62", kind: .receipt) == nil)
    }

    // MARK: Layouts from real mail (figures changed)

    /// Stripe: the whole receipt as one run of text.
    @Test func receiptOnOneLine() {
        let text = "Receipt from Render Services, Inc $18.50 Paid October 1, 2026 Download invoice Download receipt Receipt number 2910-3801 Invoice number 2QSAAMRS-0008 Payment method - 1152\nReceipt #2910-3801 PostgresDB Qty 1 $10.50 Servers Qty 1 $7.00 Total $18.50 Amount paid $18.50 Questions? Visit our support site."
        let glance = MailDigest.glance(text: text, subject: "Your receipt from Render Services, Inc #2910-3801", kind: .receipt)
        #expect(glance?.status == "Paid")
        #expect(glance?.facts.first == .init(label: "Amount paid", value: "$18.50"))
        #expect(glance?.facts.contains(.init(label: "Receipt number", value: "2910-3801")) == true)
    }

    /// Lyft: each label over its amount; the card line is what was charged.
    @Test func labelsOverAmounts() {
        let text = "YOUR RIDE TO 2206 ELM ST ON SEPTEMBER 23, 2026 AT 5:29 PM\nThanks for riding with Angel\nAdd tip\nApple Pay (Discover)\n$21.83\nStandard fare (5.38mi, 19m 23s)\n$22.33\nCredits\n-$1.14\nReceipt #2267336246917757830"
        let glance = MailDigest.glance(text: text, subject: "Your ride with Angel on September 23", kind: .receipt)
        #expect(glance?.facts.first == .init(label: "Charged", value: "$21.83"))
    }

    /// DoorDash: the failure and the amount in a sentence.
    @Test func failureInASentence() {
        let text = "we were unable to process your dashpass payment\nHi Tamkin,\nWe were unable to process your recent payment of $9.99 (plus taxes) using your Discover ending in 1234 for your DashPass subscription."
        let glance = MailDigest.glance(text: text, subject: "Action Required: Your DashPass payment has failed - we'll retry soon", kind: .receipt)
        #expect(glance?.status == "Payment failed")
        #expect(glance?.isAlert == true)
        #expect(glance?.facts.first == .init(label: "Amount", value: "$9.99"))
    }

    /// A newsletter that mentions deliveries isn't a delivery.
    @Test func newsletterAboutDeliveriesIsNotShipping() {
        let article = "Good morning. It's Tuesday, and the markets are calm. Here's what's on the menu today: chips, cables and a satellite fight over your home internet. "
            + String(repeating: "Amazon said its drivers will be out for delivery longer this season as orders rise. ", count: 20)
        #expect(MailDigest.kind(subject: "Bezos vs. Musk for your wi-fi", text: article, senderEmail: "crew@morningbrew.com",
                                isBulk: true, looksAutomated: true, hasEvent: false) != .shipping)
    }

    /// An image's alt text holding "<br>" no longer leaks the tag's CSS.
    @Test func quotedAngleBracketInsideATag() {
        let html = #"<img alt="Hi Tamkin,&lt;br>Thanks for choosing us!" style="display: inline-block; color: #4D4F53;"><p>Your order is confirmed.</p>"#
        let text = MailDigest.text(fromHTML: html)
        #expect(!text.contains("display"))
        #expect(text.contains("Your order is confirmed."))
    }

    /// A plain part that only says to read the HTML is passed over.
    @Test func placeholderPlainPartIsSkipped() {
        let plain = "Subject Line: Your Epic Games Receipt\nIt looks like your email client might not support HTML formatted email. Try opening this email in another email client. " + String(repeating: "https://example.com/x ", count: 60)
        let html = "<p>Thanks for your purchase.</p><p>Total $19.99</p><p>Order ID ABC12345</p>"
        #expect(MailDigest.readableText(body: plain, html: html).contains("Total $19.99"))
    }

    /// Epic: labels and values on their own lines, a blank between, and
    /// the currency code after the amount. Paid, by the subject.
    @Test func labelsAboveValuesWithCurrencyCode() {
        let text = "Thank you for your purchase!\nINVOICE ID:\n\nF5238733787\nPrice:\n$24.99 USD\nTOTAL:\n\n$0.00 USD"
        let glance = MailDigest.glance(text: text, subject: "Your Epic Games Receipt", kind: .receipt)
        #expect(glance?.status == "Paid")
        #expect(glance?.facts.first == .init(label: "Total", value: "$0.00"))
        #expect(glance?.facts.contains(.init(label: "Invoice id", value: "F5238733787")) == true)
    }
}
