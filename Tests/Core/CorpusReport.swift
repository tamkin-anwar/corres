import Foundation
import SwiftData
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

    @Test(.enabled(if: folder != nil)) func report() async throws {
        let folder = try #require(Self.folder)
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        var rows: [String] = ["#\tkind\tattention\treason\tglance\task\tnext step\tsender\tsubject\tcategory"]
        var index = 0
        for file in files {
            // Sorted by the app's own storage and rules, as a sync would.
            // As each one was when it arrived: unread. Sorting is decided
            // then, and most of a real mailbox has been read (or archived)
            // since.
            let exported = try JSONDecoder().decode([Correspondence].self, from: Data(contentsOf: file)).map { email in
                var arriving = email
                arriving.isUnread = true
                if !arriving.labelIds.contains("UNREAD") { arriving.labelIds.append("UNREAD") }
                return arriving
            }
            let schema = Schema(CorresSchemaV1.models)
            let container = try ModelContainer(for: schema, migrationPlan: CorresMigrationPlan.self,
                                               configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
            let repository = SwiftDataMailRepository(modelContainer: container)
            _ = try await repository.upsert(exported, isInitialSync: false)
            _ = try await repository.applyLoadedContent(exported)
            let emails = try await repository.threads().sorted { $0.receivedAt > $1.receivedAt }
            let categories = InboxCategory.context(for: emails)
            for email in emails {
                index += 1
                let whole = MailDigest.readableText(body: email.body, html: email.htmlBody)
                let cleaned = MailDigest.clean(whole)
                let bulk = InboxClassifier.bulkKind(labelIds: email.labelIds, looksAutomated: email.looksAutomated)
                let kind = bulk == .promotions ? .newsletter
                    : MailDigest.kind(subject: email.subject, text: cleaned, senderEmail: email.senderEmail,
                                      isBulk: bulk != nil, looksAutomated: email.looksAutomated, hasEvent: false, labelIds: email.labelIds)
                let glance = MailDigest.glance(text: cleaned, subject: email.subject, kind: kind).map { glance in
                    ([glance.status.map { (glance.isAlert ? "!" : "") + $0 }].compactMap { $0 }
                        + glance.facts.map { "\($0.label)=\($0.value)" }).joined(separator: " | ")
                } ?? ""
                let ask = kind == .personal ? MailDigest.buriedAsk(text: cleaned) ?? "" : ""
                let step = MailDigest.nextStep(text: whole, html: email.htmlBody, kind: kind).map { "\($0.label) → \($0.host)" } ?? ""
                let fields = ["\(index)", kind.rawValue, email.attention.rawValue, email.reason, glance, ask, step,
                              email.senderEmail ?? email.sender, email.subject, InboxCategory.of(email, context: categories, now: email.receivedAt.addingTimeInterval(600)).rawValue]
                rows.append(fields.map { $0.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ") }
                    .joined(separator: "\t"))
            }
        }
        // CORRES_CORPUS_DUMP=doordash,stripe writes those emails' text as
        // Corres reads it, for seeing why something was or wasn't found.
        if let dump = ProcessInfo.processInfo.environment["CORRES_CORPUS_DUMP"] {
            let terms = dump.lowercased().split(separator: ",").map(String.init)
            var out: [String] = []
            for file in files {
                for email in try JSONDecoder().decode([Correspondence].self, from: Data(contentsOf: file))
                where terms.contains(where: { ((email.senderEmail ?? "") + " " + email.subject).lowercased().contains($0) }) {
                    let text = MailDigest.clean(MailDigest.readableText(body: email.body, html: email.htmlBody))
                    out.append("===== \(email.senderEmail ?? "") | \(email.subject)\n" + String(text.prefix(2500)))
                }
            }
            try out.joined(separator: "\n\n").write(to: folder.appending(path: "dump.txt"), atomically: true, encoding: .utf8)
        }
        try rows.joined(separator: "\n").write(to: folder.appending(path: "report.tsv"), atomically: true, encoding: .utf8)
        print("[Corpus] \(index) emails → \(folder.appending(path: "report.tsv").path)")
    }
}
