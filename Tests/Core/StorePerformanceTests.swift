import Foundation
import SwiftData
import Testing
@testable import CorresCore

/// Times the repository against a real mailbox: set CORRES_PERF_STORE to a
/// copy of a device's default.store (never the original; the sync step
/// writes to it). Skipped otherwise, so it never runs in a normal pass.
struct StorePerformanceTests {
    private static let path = ProcessInfo.processInfo.environment["CORRES_PERF_STORE"]

    @Test(.enabled(if: path != nil)) func realMailboxTimings() async throws {
        let url = URL(fileURLWithPath: try #require(Self.path))
        let schema = Schema(CorresSchemaV1.models)
        let container = try ModelContainer(for: schema, migrationPlan: CorresMigrationPlan.self,
                                           configurations: [ModelConfiguration(schema: schema, url: url)])
        let repository = SwiftDataMailRepository(modelContainer: container)
        let clock = ContinuousClock()

        var threads: [Correspondence] = []
        let firstScreen = try await clock.measure { _ = try await repository.recentThreads(limit: 300) }
        print("PERF first screen of 300 \(firstScreen)")
        let load = try await clock.measure { threads = try await repository.threads() }
        let again = try await clock.measure { threads = try await repository.threads() }
        let sample = try #require(threads.max { $0.receivedAt < $1.receivedAt })
        let sync = try await clock.measure { _ = try await repository.upsert([sample], isInitialSync: false) }
        let open = try await clock.measure { _ = try await repository.applyLoadedContent([sample]) }
        var full: Correspondence?
        let one = try await clock.measure { full = try await repository.thread(sample.id) }

        let context = ModelContext(container)
        var models: [PersistedCorrespondence] = []
        let fetchOnly = try clock.measure { models = try context.fetch(PersistedCorrespondence.summaries(withText: true)) }
        let mapOnly = clock.measure { _ = models.map(\.asListCorrespondence) }
        let noText = try clock.measure { _ = try ModelContext(container).fetch(PersistedCorrespondence.summaries()) }
        print("PERF fetch \(fetchOnly), convert \(mapOnly), fetch without text \(noText)")
        for _ in 1...3 {
            let facts = try clock.measure { _ = try ModelContext(container).fetch(PersistedCorrespondence.senderFacts()) }
            let count = try clock.measure { _ = try ModelContext(container).fetchCount(FetchDescriptor<PersistedCorrespondence>()) }
            let s1 = try await clock.measure { _ = try await repository.upsert([sample], isInitialSync: false) }
            let ids = try clock.measure { var d = FetchDescriptor<PersistedCorrespondence>(); d.propertiesToFetch = [\.compositeID]; _ = try ModelContext(container).fetch(d) }
            print("PERF sender facts \(facts), ids only \(ids), count \(count), sync \(s1)")
        }

        let before = try ModelContext(container).fetch(FetchDescriptor<PersistedCorrespondence>())
            .reduce(into: (count: 0, bytes: 0)) { if let html = $1.htmlBody { $0.count += 1; $0.bytes += html.utf8.count } }
        var moved = 0
        let move = try await clock.measure { while case let n = try await repository.moveContent(batch: 100), n > 0 { moved += n } }
        let after = try ModelContext(container).fetch(FetchDescriptor<PersistedMessageContent>())
            .reduce(into: (count: 0, bytes: 0)) { if let html = $1.html { $0.count += 1; $0.bytes += html.utf8.count } }
        print("PERF moved \(moved) in \(move): before \(before), after \(after)")
        #expect(before.count == after.count && before.bytes == after.bytes)
        let movedLoad = try await clock.measure { threads = try await repository.threads() }
        let movedFirst = try await clock.measure { _ = try await repository.recentThreads(limit: 300) }
        print("PERF after moving: load \(movedLoad), first screen \(movedFirst)")

        let html = threads.reduce(0) { $0 + ($1.htmlBody?.utf8.count ?? 0) }
        print("""
        PERF \(threads.count) conversations, \(html / 1_048_576) MB HTML held in the list
        PERF first load \(load), reload \(again)
        PERF sync of 1 \(sync), message opened \(open), one conversation \(one) (html \(full?.htmlBody != nil))
        """)
    }
}
