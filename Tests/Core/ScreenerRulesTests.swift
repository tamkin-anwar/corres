import Testing
@testable import CorresCore

struct ScreenerRulesTests {
    @Test func companyDomainCoversSubdomains() {
        #expect(InboxClassifier.companyDomain(of: "ship-confirm@email.amazon.com") == "amazon.com")
        #expect(InboxClassifier.companyDomain(of: "no-reply@Stripe.com") == "stripe.com")
        #expect(InboxClassifier.companyDomain(of: "orders@mail.tesco.co.uk") == "tesco.co.uk")
        #expect(InboxClassifier.companyDomain(of: "hello@daraz.com.bd") == "daraz.com.bd")
    }

    @Test func freeMailIsNeverACompany() {
        #expect(InboxClassifier.companyDomain(of: "someone@gmail.com") == nil)
        #expect(InboxClassifier.companyDomain(of: "someone@hotmail.co.uk") == nil)
        #expect(InboxClassifier.companyDomain(of: "someone@icloud.com") == nil)
        #expect(InboxClassifier.companyDomain(of: "not an address") == nil)
    }

    @Test func aRuleDecidesNewSendersFromThatCompany() {
        let rules: [String: SenderDecision] = ["amazon.com": .approved, "spammy.biz": .blocked]
        #expect(InboxClassifier.domainDecision(for: "deals@marketing.amazon.com", rules: rules) == .approved)
        #expect(InboxClassifier.domainDecision(for: "win@spammy.biz", rules: rules) == .blocked)
        #expect(InboxClassifier.domainDecision(for: "news@other.com", rules: rules) == nil)
        #expect(InboxClassifier.domainDecision(for: "friend@gmail.com", rules: ["gmail.com": .approved]) == nil)
    }
}
