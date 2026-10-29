import Foundation
import Testing
@testable import CorresCore

struct OrganizingTests {
    func email(from sender: String = "Amazon", address: String = "ship-confirm@amazon.com", subject: String = "Your order has shipped",
               to: [String] = ["me@example.com"], cc: [String] = []) -> Correspondence {
        Correspondence(id: ThreadID(account: "me@example.com", providerID: UUID().uuidString), sender: sender,
                       senderEmail: address, organization: "Amazon", subject: subject, excerpt: "Arriving Thursday",
                       body: "Your package is on its way.", receivedAt: .now, dueAt: nil, reason: "", attention: .quiet,
                       toRecipients: to, ccRecipients: cc)
    }

    @Test func aRuleMatchesTheSenderByAddressOrCompany() {
        var rule = MailRule(field: .from, text: "amazon.com", category: .updates)
        #expect(rule.matches(email()))
        rule.text = "AMAZON"
        #expect(rule.matches(email()))
        rule.text = "netflix"
        #expect(!rule.matches(email()))
    }

    @Test func everyWordMustAppear() {
        let rule = MailRule(field: .subject, text: "order shipped", markRead: true)
        #expect(rule.matches(email()))
        #expect(!rule.matches(email(subject: "Your order is ready")))
    }

    @Test func aRuleThatDoesNothingIsNotUsedAndADisabledOneNeverMatches() {
        #expect(!MailRule(field: .from, text: "amazon").isUsable)
        #expect(!MailRule(field: .from, text: "  ", archive: true).isUsable)
        let off = MailRule(field: .from, text: "amazon", isEnabled: false, archive: true)
        #expect(!off.matches(email()))
    }

    @Test func toMatchesAliasesAndCopies() {
        let rule = MailRule(field: .to, text: "team@", flag: true)
        #expect(rule.matches(email(to: ["me@example.com"], cc: ["team@example.com"])))
        #expect(!rule.matches(email()))
    }

    @Test func templatesFillTheFirstName() {
        let template = MailTemplate(name: "Thanks", subject: "Thanks, {first name}", body: "Hi {first name},\nThanks for this.")
        let filled = template.filled(recipientName: "Sofia Laurent")
        #expect(filled.subject == "Thanks, Sofia")
        #expect(filled.body == "Hi Sofia,\nThanks for this.")
    }

    @Test func withNoNameThePlaceholderAndItsSpaceGo() {
        let template = MailTemplate(name: "Thanks", body: "Hi {first name},\nThanks, {name}.")
        #expect(template.filled(recipientName: nil).body == "Hi,\nThanks.")
    }

    @Test func muteBreaksOnlyForMailToYouAlone() {
        let me: Set<String> = ["me@example.com"]
        #expect(MuteRule.breaksMute(email(to: ["me@example.com"]), accountAddresses: me))
        #expect(!MuteRule.breaksMute(email(to: ["me@example.com", "team@example.com"]), accountAddresses: me))
        #expect(!MuteRule.breaksMute(email(to: ["me@example.com"], cc: ["boss@example.com"]), accountAddresses: me))
        #expect(!MuteRule.breaksMute(email(to: ["list@example.com"]), accountAddresses: me))
        // Named, in any case, is still you; an address ending in yours is not.
        #expect(MuteRule.breaksMute(email(to: ["Me <Me@Example.com>"]), accountAddresses: me))
        #expect(!MuteRule.breaksMute(email(to: ["jme@example.com"]), accountAddresses: me))
    }

    @Test func purchaseStagesFollowTheStatus() {
        #expect(PurchaseStage.from(status: "Payment failed", isAlert: true) == .problem)
        #expect(PurchaseStage.from(status: "Out for delivery", isAlert: false) == .onTheWay)
        #expect(PurchaseStage.from(status: "Delivered", isAlert: false) == .delivered)
        #expect(PurchaseStage.from(status: nil, isAlert: false) == .ordered)
        #expect(PurchaseStage.problem < PurchaseStage.onTheWay)
    }
}

struct ShownOrderTests {
    @Test func movesAmongEverythingWhenNothingIsHidden() {
        let all = ["a", "b", "c", "d"]
        // Drag "a" below "c", as onMove reports it: offset 0 to 3.
        #expect(ShownOrder.move(all, shown: all, from: [0], to: 3) == ["b", "c", "a", "d"])
        #expect(ShownOrder.move(all, shown: all, from: [3], to: 0) == ["d", "a", "b", "c"])
    }

    @Test func readsTheOffsetsAgainstTheRowsOnScreen() {
        // "b" is hidden, so a, c and d are on screen; "d" (row 2) goes to the top.
        let moved = ShownOrder.move(["a", "b", "c", "d"], shown: ["a", "c", "d"], from: [2], to: 0)
        // "d" leads the shown ones, and "b" keeps its slot.
        #expect(moved == ["d", "b", "a", "c"])
    }

    @Test func movesSeveralAndKeepsHiddenOnesInPlace() {
        let moved = ShownOrder.move(["h1", "a", "b", "h2", "c"], shown: ["a", "b", "c"], from: [0, 1], to: 3)
        #expect(moved == ["h1", "c", "a", "h2", "b"])
    }
}
