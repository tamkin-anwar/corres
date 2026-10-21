import Foundation
import SwiftData
import Testing
@testable import CorresCore

/// Guards the speed work (see `StorePerformanceTests` for the real-mailbox
/// numbers): with a mailbox on disk, a sync, an opened email and the
/// lists' update after a change must each touch only what they need. A
/// change that goes back to reading every conversation fails here, long
/// before anyone feels it on a phone.
struct StoreSpeedBudgetTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func everydayWorkDoesntReadTheWholeMailbox() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "corres-speed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let schema = Schema(CorresSchemaV1.models)
        let container = try ModelContainer(for: schema, migrationPlan: CorresMigrationPlan.self,
                                           configurations: [ModelConfiguration(schema: schema, url: directory.appending(path: "mail.store"))])
        let repository = SwiftDataMailRepository(modelContainer: container)
        let html = "<table><tr><td>" + String(repeating: "<p>A long designed email, line after line.</p>", count: 200) + "</td></tr></table>"
        let mailbox = (0..<1_500).map { n in
            Correspondence(id: ThreadID(account: "me@example.com", providerID: "t\(n)"), sender: "Sender \(n % 90)",
                           senderEmail: "sender\(n % 90)@example.com", organization: "", subject: "Subject \(n)", excerpt: "Hello",
                           body: "Hello there, number \(n).", htmlBody: html, latestMessageID: "m\(n)",
                           receivedAt: now.addingTimeInterval(Double(n) * 60), dueAt: nil,
                           reason: InboxClassifier.legacyUnreadReason, attention: .quiet)
        }
        try await repository.upsert(mailbox, isInitialSync: true)
        let listed = try await repository.threads()
        #expect(listed.count == 1_500)
        _ = try await repository.changes()

        let clock = ContinuousClock()
        let newest = mailbox[mailbox.count - 1]
        // Warm what's kept in memory once, as a launch does.
        _ = try await repository.upsert([newest], isInitialSync: false)

        var reply = mailbox[10]
        reply = reply.updatingContent(from: Correspondence(id: reply.id, sender: "Sender 10", senderEmail: "sender10@example.com",
                                                           organization: "", subject: "Re: Subject 10", excerpt: "Thanks",
                                                           body: "Thanks!", htmlBody: "<p>Thanks!</p>", latestMessageID: "m10b",
                                                           receivedAt: now.addingTimeInterval(200_000), dueAt: nil,
                                                           reason: InboxClassifier.legacyUnreadReason, attention: .quiet),
                                      preserveAttention: false)
        let sync = try await clock.measure { _ = try await repository.upsert([reply], isInitialSync: false) }
        let update = try await clock.measure { _ = try await repository.changes() }
        let open = try await clock.measure { _ = try await repository.thread(newest.id) }
        let first = try await clock.measure { _ = try await repository.recentThreads(limit: 300) }
        let whole = try await clock.measure { _ = try await repository.threads() }
        print("SPEED sync \(sync), update \(update), open \(open), first screen \(first), whole list \(whole)")

        // Each of these used to scale with the whole mailbox.
        #expect(sync < .milliseconds(80))
        #expect(update < .milliseconds(80))
        #expect(open < .milliseconds(40))
        #expect(first < whole)
        #expect(try await repository.thread(reply.id)?.htmlBody == "<p>Thanks!</p>")
    }
}
