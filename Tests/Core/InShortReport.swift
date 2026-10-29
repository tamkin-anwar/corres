import Foundation
import SwiftData
import Testing
@testable import CorresCore

/// What the In short card says for each email of a real mailbox exported
/// from a development build (see `CorpusReport`), written to `inshort.tsv`
/// beside it, with the share of emails where it says nothing beyond where
/// the email was sorted. Skipped unless `CORRES_CORPUS` names the folder;
/// the mail never leaves this Mac.
///
///     CORRES_CORPUS=<folder> swift test --filter InShortReport
struct InShortReport {
    @Test(.enabled(if: CorpusReport.folder != nil)) func report() async throws {
        let folder = try #require(CorpusReport.folder)
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        var rows = ["#\tkind\tattention\tbefore\tafter\tsender\tsubject"]
        var total = 0, bareBefore = 0, bareAfter = 0, quietBefore = 0, quietAfter = 0
        var byKind: [String: (total: Int, bare: Int)] = [:]
        for file in files {
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
            for email in emails {
                total += 1
                let before = Self.before(email)
                let card = InShort.make(for: email, now: email.receivedAt.addingTimeInterval(600))
                let after = (card.lines + [InShort.statusLine(for: email, topic: card.topic, now: email.receivedAt.addingTimeInterval(600))]).joined(separator: " ¦ ")
                if before.bare { bareBefore += 1 }
                if card.saysOnlyWhereItIs { bareAfter += 1 }
                if before.bare, email.attention == .quiet { quietBefore += 1 }
                if card.saysOnlyWhereItIs, email.attention == .quiet { quietAfter += 1 }
                byKind[card.topic.rawValue, default: (0, 0)].total += 1
                if card.saysOnlyWhereItIs { byKind[card.topic.rawValue, default: (0, 0)].bare += 1 }
                rows.append(["\(total)", card.topic.rawValue, email.attention.rawValue, before.text, after,
                             email.senderEmail ?? email.sender, email.subject]
                    .map { $0.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ") }
                    .joined(separator: "\t"))
            }
        }
        // CORRES_INSHORT_DEBUG=store,bank writes those emails' text as the
        // card reads it (cells on their own lines) to debug.txt.
        if let terms = ProcessInfo.processInfo.environment["CORRES_INSHORT_DEBUG"]?.lowercased().split(separator: ",") {
            var out: [String] = []
            for file in files {
                for email in try JSONDecoder().decode([Correspondence].self, from: Data(contentsOf: file))
                where terms.contains(where: { ((email.senderEmail ?? "") + " " + email.subject).lowercased().contains($0) }) {
                    let blocks = MailDigest.clean(MailDigest.readableText(body: email.body, html: email.htmlBody, cellBreaks: true))
                    out.append("===== \(email.senderEmail ?? "") | \(email.subject) | words \(MailDigest.wordCount(blocks))\n" + String(blocks.prefix(3000)))
                }
            }
            try out.joined(separator: "\n\n").write(to: folder.appending(path: "debug.txt"), atomically: true, encoding: .utf8)
        }
        let share = { (count: Int) in total == 0 ? 0 : Int((Double(count) / Double(total) * 100).rounded()) }
        let kinds = byKind.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value.bare)/\($0.value.total)" }.joined(separator: ", ")
        let summary = "\(total) emails. Only where it's sorted, before: \(bareBefore) (\(share(bareBefore))%), after: \(bareAfter) (\(share(bareAfter))%). Only \"No action needed\", before: \(quietBefore) (\(share(quietBefore))%), after: \(quietAfter) (\(share(quietAfter))%). After by kind: \(kinds)"
        rows.append("# " + summary)
        try rows.joined(separator: "\n").write(to: folder.appending(path: "inshort.tsv"), atomically: true, encoding: .utf8)
        print("[InShort] " + summary)
    }

    /// The card as it was before the gist, without Apple Intelligence
    /// (which in the summary audit showed a summary on 1 email in 133):
    /// key figures, a buried ask or a next step, then the status line.
    static func before(_ email: Correspondence) -> (text: String, bare: Bool) {
        let whole = MailDigest.readableText(body: email.body, html: email.htmlBody)
        let cleaned = MailDigest.clean(whole)
        let bulk = InboxClassifier.bulkKind(labelIds: email.labelIds, looksAutomated: email.looksAutomated)
        let kind = bulk == .promotions ? .newsletter
            : MailDigest.kind(subject: email.subject, text: cleaned, senderEmail: email.senderEmail,
                              isBulk: bulk != nil, looksAutomated: email.looksAutomated, hasEvent: false, labelIds: email.labelIds)
        var parts: [String] = []
        if let glance = MailDigest.glance(text: cleaned, subject: email.subject, kind: kind, html: email.htmlBody) {
            parts.append(([glance.status].compactMap { $0 } + glance.facts.map { "\($0.label) \($0.value)" }).joined(separator: ", "))
        } else if kind == .personal, let ask = MailDigest.buriedAsk(text: cleaned) {
            parts.append("Asks you: " + ask)
        }
        if let step = MailDigest.nextStep(text: whole, html: email.htmlBody, kind: kind) { parts.append("Next step: " + step.label) }
        let bare = parts.isEmpty
        parts.append("\(email.attention.rawValue): \(email.displayReason)")
        return (parts.joined(separator: " ¦ "), bare)
    }
}
