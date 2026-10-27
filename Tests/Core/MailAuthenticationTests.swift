import Foundation
import Testing
@testable import CorresCore

/// Company logos (BIMI) show only when the receiving service's own
/// Authentication-Results says DMARC passed for the From domain.
struct MailAuthenticationTests {
    // MARK: Gmail (mx.google.com)

    private let gmailPass = """
    mx.google.com;\r
           dkim=pass header.i=@chase.com header.s=d4815 header.b=Q2x1c3Rlcg;\r
           arc=pass (i=1 spf=pass spfdomain=chase.com dkim=pass dkdomain=chase.com dmarc=pass fromdomain=chase.com);\r
           spf=pass (google.com: domain of no.reply.alerts@chase.com designates 159.53.110.10 as permitted sender) smtp.mailfrom=no.reply.alerts@chase.com;\r
           dmarc=pass (p=REJECT sp=REJECT dis=NONE) header.from=chase.com
    """

    @Test func gmailPassForTheFromDomain() {
        #expect(MailAuthentication.dmarcPasses(headers: [gmailPass], receiver: .google, fromAddress: "no.reply.alerts@chase.com"))
        #expect(MailAuthentication.dmarcPasses(headers: [gmailPass], receiver: .google, fromAddress: "Chase <no.reply.alerts@Chase.COM>"))
    }

    @Test func gmailPassForAnotherDomainDoesNotCount() {
        #expect(!MailAuthentication.dmarcPasses(headers: [gmailPass], receiver: .google, fromAddress: "alerts@chase-secure.com"))
    }

    @Test func gmailFailWithAForgedPassBelowIt() {
        // The sender wrote their own "pass" into the email; Gmail's own
        // header, added on top, says it failed.
        let gmail = "mx.google.com; spf=softfail (google.com: domain of transitioning x@paypal.com does not designate 203.0.113.9 as permitted sender) smtp.mailfrom=x@paypal.com; dmarc=fail (p=REJECT sp=REJECT dis=QUARANTINE) header.from=paypal.com"
        let forged = "mx.google.com; dkim=pass header.i=@paypal.com; dmarc=pass (p=REJECT) header.from=paypal.com"
        #expect(!MailAuthentication.dmarcPasses(headers: [gmail, forged], receiver: .google, fromAddress: "service@paypal.com"))
    }

    @Test func gmailIgnoresAHeaderFromAnotherServer() {
        // No mx.google.com header at the top (mail fetched from elsewhere):
        // whatever another server said doesn't count.
        let other = "mail.example.net 1; dmarc=pass header.from=paypal.com"
        #expect(!MailAuthentication.dmarcPasses(headers: [other], receiver: .google, fromAddress: "service@paypal.com"))
        #expect(!MailAuthentication.dmarcPasses(headers: [], receiver: .google, fromAddress: "service@paypal.com"))
    }

    @Test func gmailDMARCInsideACommentIsNotAResult() {
        // Only the ARC comment mentions dmarc=pass.
        let header = "mx.google.com; arc=pass (i=1 dmarc=pass fromdomain=example.com); spf=pass smtp.mailfrom=example.com"
        #expect(MailAuthentication.dmarcResult(headers: [header], receiver: .google) == nil)
        #expect(!MailAuthentication.dmarcPasses(headers: [header], receiver: .google, fromAddress: "a@example.com"))
    }

    @Test func gmailNoneOrQuarantinedIsNotPass() {
        let none = "mx.google.com; spf=pass smtp.mailfrom=shop.example; dmarc=none header.from=shop.example"
        #expect(!MailAuthentication.dmarcPasses(headers: [none], receiver: .google, fromAddress: "deals@shop.example"))
        let noResult = "mx.google.com; none"
        #expect(!MailAuthentication.dmarcPasses(headers: [noResult], receiver: .google, fromAddress: "deals@shop.example"))
    }

    // MARK: Outlook (Exchange Online Protection)

    @Test func microsoftPassWithNoAuthservID() {
        let header = "spf=pass (sender IP is 40.107.22.52)\r\n smtp.mailfrom=contoso.com; dkim=pass (signature was verified)\r\n header.d=contoso.com;dmarc=pass action=none header.from=contoso.com;compauth=pass\r\n reason=100"
        #expect(MailAuthentication.parse(header).authservID == nil)
        #expect(MailAuthentication.dmarcPasses(headers: [header], receiver: .microsoft, fromAddress: "billing@contoso.com"))
    }

    @Test func microsoftBestGuessPassIsNotPass() {
        // No DMARC record, so no BIMI either.
        let header = "spf=pass (sender IP is 192.0.2.1) smtp.mailfrom=fabrikam.com; dkim=none (message not signed) header.d=none;dmarc=bestguesspass action=none header.from=fabrikam.com;compauth=pass reason=109"
        #expect(MailAuthentication.dmarcResult(headers: [header], receiver: .microsoft)?.value == "bestguesspass")
        #expect(!MailAuthentication.dmarcPasses(headers: [header], receiver: .microsoft, fromAddress: "hi@fabrikam.com"))
    }

    @Test func microsoftFailWithAForgedPassBelowIt() {
        let eop = "spf=fail (sender IP is 198.51.100.7) smtp.mailfrom=microsoft.com; dkim=none (message not signed) header.d=none;dmarc=fail action=oreject header.from=microsoft.com;compauth=fail reason=000"
        let forged = "spf=pass smtp.mailfrom=microsoft.com; dmarc=pass action=none header.from=microsoft.com"
        #expect(!MailAuthentication.dmarcPasses(headers: [eop, forged], receiver: .microsoft, fromAddress: "account-security-noreply@microsoft.com"))
    }

    @Test func microsoftIgnoresAHeaderNamingAnotherServer() {
        let other = "mx.attacker.example; dmarc=pass header.from=contoso.com"
        #expect(!MailAuthentication.dmarcPasses(headers: [other], receiver: .microsoft, fromAddress: "billing@contoso.com"))
        let microsoftHost = "BN8NAM12FT010.mail.protection.outlook.com; dmarc=pass action=none header.from=contoso.com"
        #expect(MailAuthentication.dmarcPasses(headers: [microsoftHost], receiver: .microsoft, fromAddress: "billing@contoso.com"))
    }

    // MARK: iCloud

    private let icloudPass = [
        "bimi.icloud.com; bimi=pass header.d=apple.com header.selector=default policy.authority=pass",
        "dmarc.icloud.com; dmarc=pass header.from=apple.com",
        "dkim-verifier.icloud.com; dkim=pass (2048-bit key) header.d=apple.com header.i=@apple.com header.b=OWQ4Zj",
        "spf.icloud.com; spf=pass (spf.icloud.com: domain of news_us@insideapple.apple.com designates 17.111.110.110 as permitted sender) smtp.mailfrom=news_us@insideapple.apple.com",
    ]

    @Test func icloudPassFromItsOwnHeaders() {
        #expect(MailAuthentication.dmarcPasses(headers: icloudPass, receiver: .icloud, fromAddress: "News@insideapple.apple.com") == false)
        #expect(MailAuthentication.dmarcPasses(headers: icloudPass, receiver: .icloud, fromAddress: "news@apple.com"))
    }

    @Test func icloudFailWithAForgedPassBelowIt() {
        let headers = [
            "dmarc.icloud.com; dmarc=fail header.from=apple.com",
            "spf.icloud.com; spf=fail smtp.mailfrom=apple.com",
            "dmarc.icloud.com; dmarc=pass header.from=apple.com",
        ]
        #expect(!MailAuthentication.dmarcPasses(headers: headers, receiver: .icloud, fromAddress: "news@apple.com"))
    }

    @Test func icloudStopsAtTheFirstHeaderThatIsntIcloud() {
        let headers = [
            "spf.icloud.com; spf=pass smtp.mailfrom=bank.example",
            "mx.sender.example; dmarc=pass header.from=bank.example",
            "dmarc.icloud.com; dmarc=pass header.from=bank.example",
        ]
        #expect(!MailAuthentication.dmarcPasses(headers: headers, receiver: .icloud, fromAddress: "alerts@bank.example"))
    }

    // MARK: Other services and parsing

    @Test func unknownServiceNeverCounts() {
        #expect(!MailAuthentication.dmarcPasses(headers: [gmailPass], receiver: .unknown, fromAddress: "a@chase.com"))
    }

    @Test func parsesVersionCaseQuotesAndFolding() {
        let header = "Mail.Example.ORG 1;\r\n\tDMARC=PASS reason=\"aligned; strict\" (comment (nested) here) Header.From=Example.ORG.;\r\n\tdkim=pass header.d=example.org"
        let parsed = MailAuthentication.parse(header)
        #expect(parsed.authservID == "mail.example.org")
        #expect(parsed.results.count == 2)
        #expect(parsed.results.first?.method == "dmarc")
        #expect(parsed.results.first?.value == "pass")
        #expect(parsed.results.first?.properties["reason"] == "aligned; strict")
        #expect(parsed.results.first?.properties["header.from"] == "Example.ORG.")
        #expect(MailAuthentication.domain(of: "Example.ORG.") == "example.org")
    }

    @Test func passWithoutHeaderFromDoesNotCount() {
        let header = "mx.google.com; dmarc=pass (p=REJECT)"
        #expect(!MailAuthentication.dmarcPasses(headers: [header], receiver: .google, fromAddress: "a@example.com"))
    }

    @Test func showsCompanyLogoOnlyWhenVerifiedAndNotInSpam() {
        var thread = Correspondence(id: ThreadID(account: "me@x.test", providerID: "t1"), sender: "Chase",
                                    senderEmail: "alerts@chase.com", organization: "", subject: "Hi", excerpt: "",
                                    body: "", receivedAt: .now, dueAt: nil, reason: "", attention: .quiet,
                                    labelIds: ["INBOX"])
        #expect(!thread.showsCompanyLogo)
        thread.fromDomainVerified = true
        #expect(thread.showsCompanyLogo)
        thread.labelIds = ["SPAM"]
        #expect(!thread.showsCompanyLogo)
    }
}
