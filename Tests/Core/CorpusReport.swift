import Foundation
import Testing
@testable import CorresCore

/// Runs Corres's reading over real mail exported from a development build
/// (Settings → Developer → Export Test Corpus) and writes what it decided
/// for each email to a report beside the corpus. Skipped unless
/// `CORRES_CORPUS` names the folder; the mail never leaves this Mac.
///
///     CORRES_CORPUS=<folder> swift test --filter CorpusReport
struct CorpusReport {
    static let folder = ProcessInfo.processInfo.environment["CORRES_CORPUS"].map { URL(fileURLWithPath: $0) }

    @Test(.enabled(if: folder != nil)) func report() throws {
        let folder = try #require(Self.folder)
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        var rows: [String] = ["#\tkind\tattention\treason\tglance\task\tnext step\tsender\tsubject"]
        var index = 0
        for file in files {
            let emails = try JSONDecoder().decode([Correspondence].self, from: Data(contentsOf: file))
            for email in emails {
                index += 1
                let whole = MailDigest.readableText(body: email.body, html: email.htmlBody)
                let cleaned = MailDigest.clean(whole)
                let bulk = InboxClassifier.bulkKind(labelIds: email.labelIds, looksAutomated: email.looksAutomated)
                let kind = bulk == .promotions ? .newsletter
                    : MailDigest.kind(subject: email.subject, text: cleaned, senderEmail: email.senderEmail,
                                      isBulk: bulk != nil, looksAutomated: email.looksAutomated, hasEvent: false)
                let glance = MailDigest.glance(text: cleaned, kind: kind).map { glance in
                    ([glance.status.map { (glance.isAlert ? "!" : "") + $0 }].compactMap { $0 }
                        + glance.facts.map { "\($0.label)=\($0.value)" }).joined(separator: " | ")
                } ?? ""
                let ask = kind == .personal ? MailDigest.buriedAsk(text: cleaned) ?? "" : ""
                let step = MailDigest.nextStep(text: whole, html: email.htmlBody, kind: kind).map { "\($0.label) → \($0.host)" } ?? ""
                let fields = ["\(index)", kind.rawValue, email.attention.rawValue, email.reason, glance, ask, step,
                              email.senderEmail ?? email.sender, email.subject]
                rows.append(fields.map { $0.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ") }
                    .joined(separator: "\t"))
            }
        }
        try rows.joined(separator: "\n").write(to: folder.appending(path: "report.tsv"), atomically: true, encoding: .utf8)
        print("[Corpus] \(index) emails → \(folder.appending(path: "report.tsv").path)")
    }
}
