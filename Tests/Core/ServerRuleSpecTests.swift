import Foundation
import Testing
@testable import CorresCore

struct ServerRuleSpecTests {
    @Test func gmailFilterFromCompany() throws {
        let rule = MailRule(field: .from, text: "amazon.com", category: .updates, markRead: true, archive: true)
        let spec = try #require(ServerRuleSpec.gmail(for: rule))
        #expect(spec.query == "from:amazon.com")
        #expect(spec.removeLabelIds == ["UNREAD", "INBOX"])
        #expect(spec.addLabelIds == ["CATEGORY_UPDATES"])
        #expect(spec.withoutCategory.addLabelIds.isEmpty)
    }

    @Test func gmailEveryWordMustAppear() {
        #expect(ServerRuleSpec.gmailQuery(field: .subject, words: ["weekly", "digest"]) == "subject:weekly subject:digest")
        #expect(ServerRuleSpec.gmailQuery(field: .to, words: ["team@x.com"]) == "{to:team@x.com cc:team@x.com}")
        #expect(ServerRuleSpec.gmailQuery(field: .anywhere, words: ["(urgent)"]) == "{from:\"(urgent)\" subject:\"(urgent)\"}")
    }

    @Test func gmailSearchSyntaxIsQuoted() {
        #expect(ServerRuleSpec.quoted("-draft") == "\"-draft\"")
        #expect(ServerRuleSpec.quoted("OR") == "\"OR\"")
        #expect(ServerRuleSpec.quoted("or") == "or")
        #expect(ServerRuleSpec.quoted("news-letter") == "news-letter")
    }

    @Test func needsYouOnlyStaysInCorres() {
        let rule = MailRule(field: .from, text: "boss", attention: .needsYou)
        #expect(ServerRuleSpec.gmail(for: rule) == nil)
        #expect(ServerRuleSpec.outlook(for: rule) == nil)
    }

    @Test func outlookTakesReadAndArchiveOnly() throws {
        let flagOnly = MailRule(field: .from, text: "news", flag: true)
        #expect(ServerRuleSpec.outlook(for: flagOnly) == nil)
        let rule = MailRule(field: .subject, text: "Weekly  digest", category: .promotions, markRead: true)
        let spec = try #require(ServerRuleSpec.outlook(for: rule))
        #expect(spec.condition == "subjectContains")
        #expect(spec.phrase == "Weekly digest")
        #expect(spec.markAsRead && !spec.archive)
        #expect(spec.displayName == "Corres · subject Weekly digest")
    }

    @Test func offRulesGoNowhere() {
        var rule = MailRule(field: .from, text: "amazon.com", archive: true)
        rule.isEnabled = false
        #expect(ServerRuleSpec.gmail(for: rule) == nil)
        #expect(ServerRuleSpec.outlook(for: rule) == nil)
    }

    @Test func signatureChangesWithTheRule() throws {
        let one = try #require(ServerRuleSpec.gmail(for: MailRule(field: .from, text: "a.com", archive: true)))
        let two = try #require(ServerRuleSpec.gmail(for: MailRule(field: .from, text: "a.com", markRead: true)))
        #expect(ServerRuleSpec.signature(one) != ServerRuleSpec.signature(two))
        #expect(ServerRuleSpec.signature(one) == ServerRuleSpec.signature(one))
    }

    @Test func olderRulesDecodeWithoutTheNewField() throws {
        let json = #"{"id":"6F1C1A55-1B4E-4C55-9C2B-2B7E1C5E4A10","field":"from","text":"x","isEnabled":true,"markRead":true,"archive":false,"flag":false,"createdAt":0}"#
        let rule = try JSONDecoder().decode(MailRule.self, from: Data(json.utf8))
        #expect(rule.inAccounts == nil)
    }
}
