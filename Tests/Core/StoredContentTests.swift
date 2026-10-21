import Foundation
import SwiftData
import Testing
@testable import CorresCore

/// The list reads conversations without their HTML, and the store reads
/// only what changed: neither may ever lose a message.
struct StoredContentTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeRepository() throws -> SwiftDataMailRepository {
        let schema = Schema(CorresSchemaV1.models)
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return SwiftDataMailRepository(modelContainer: try ModelContainer(for: schema, migrationPlan: CorresMigrationPlan.self,
                                                                          configurations: [configuration]))
    }

    private func thread(_ n: Int, message: String, minutes: Double = 0) -> Correspondence {
        Correspondence(id: ThreadID(account: "me@example.com", providerID: "t\(n)"), sender: "Ana Lima",
                       senderEmail: "ana@example.com", organization: "", subject: "Plans \(n)", excerpt: "Hello",
                       body: "Hello \(message)", htmlBody: "<p>Hello \(message)</p>", latestMessageID: message,
                       receivedAt: now.addingTimeInterval(minutes * 60), dueAt: nil,
                       reason: InboxClassifier.legacyUnreadReason, attention: .quiet)
    }

    @Test func theListLeavesOutHTMLAndOpeningReadsIt() async throws {
        let repository = try makeRepository()
        try await repository.upsert([thread(1, message: "m1")], isInitialSync: true)
        let listed = try #require(try await repository.threads().first)
        #expect(listed.htmlBody == nil)
        #expect(listed.body == "Hello m1")
        let opened = try await repository.thread(listed.id)
        #expect(opened?.htmlBody == "<p>Hello m1</p>")
    }

    @Test func syncingAfterAListReadKeepsEveryMessage() async throws {
        let repository = try makeRepository()
        try await repository.upsert([thread(1, message: "m1"), thread(2, message: "m2")], isInitialSync: true)
        _ = try await repository.threads()
        // A new message in the first; the second is untouched but was read
        // without its HTML, and saved alongside.
        try await repository.upsert([thread(1, message: "m3", minutes: 5)], isInitialSync: false)
        _ = try await repository.setUnread(true, for: ThreadID(account: "me@example.com", providerID: "t2"))
        #expect(try await repository.thread(ThreadID(account: "me@example.com", providerID: "t1"))?.htmlBody == "<p>Hello m3</p>")
        #expect(try await repository.thread(ThreadID(account: "me@example.com", providerID: "t2"))?.htmlBody == "<p>Hello m2</p>")
    }

    @Test func changesNameOnlyWhatWasWritten() async throws {
        let repository = try makeRepository()
        try await repository.upsert([thread(1, message: "m1"), thread(2, message: "m2"), thread(3, message: "m3")], isInitialSync: true)
        _ = try await repository.threads()
        let seeded = try #require(try await repository.changes())
        #expect(seeded.updated.count == 3)
        let quiet = try #require(try await repository.changes())
        #expect(quiet.updated.isEmpty && quiet.removed.isEmpty)

        _ = try await repository.setPinned(true, for: ThreadID(account: "me@example.com", providerID: "t1"))
        try await repository.remove(ThreadID(account: "me@example.com", providerID: "t2"))
        try await repository.upsert([thread(4, message: "m4")], isInitialSync: false)
        let changes = try #require(try await repository.changes())
        #expect(Set(changes.updated.map(\.id.providerID)) == ["t1", "t4"])
        #expect(changes.updated.first { $0.id.providerID == "t1" }?.isPinned == true)
        #expect(changes.updated.allSatisfy { $0.htmlBody == nil })
        #expect(changes.removed.map(\.providerID) == ["t2"])
        // Read once.
        let again = try #require(try await repository.changes())
        #expect(again.updated.isEmpty && again.removed.isEmpty)
    }

    @Test func mailSavedTheOldWayIsMovedWhole() async throws {
        let schema = Schema(CorresSchemaV1.models)
        let container = try ModelContainer(for: schema, migrationPlan: CorresMigrationPlan.self,
                                           configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)])
        // As earlier builds saved it: the HTML inside the conversation.
        let context = ModelContext(container)
        let flyer = Correspondence(id: ThreadID(account: "me@example.com", providerID: "flyer"), sender: "Shop",
                                   senderEmail: "hello@shop.example", organization: "", subject: "Sale", excerpt: "",
                                   body: "Sale", htmlBody: "<img src=\"https://shop.example/sale.png\">", latestMessageID: "f1",
                                   receivedAt: now, dueAt: nil, reason: InboxClassifier.legacyUnreadReason, attention: .quiet)
        for item in [thread(1, message: "m1"), flyer] { context.insert(PersistedCorrespondence(from: item)) }
        try context.save()

        let repository = SwiftDataMailRepository(modelContainer: container)
        let flyerID = flyer.id
        #expect(try await repository.thread(flyerID)?.htmlBody == flyer.htmlBody)
        #expect(try await repository.moveContent(batch: 1) == 1)
        #expect(try await repository.moveContent(batch: 10) == 1)
        #expect(try await repository.moveContent(batch: 10) == 0)
        #expect(try await repository.thread(flyerID)?.htmlBody == flyer.htmlBody)
        #expect(try await repository.thread(ThreadID(account: "me@example.com", providerID: "t1"))?.htmlBody == "<p>Hello m1</p>")
        // Still known as bulk mail without its HTML.
        let listed = try #require(try await repository.threads().first { $0.id == flyerID })
        #expect(listed.htmlBody == nil && listed.htmlImageOnly == true && listed.looksAutomated)
        // And gone with its conversation.
        try await repository.remove(flyerID)
        #expect(try ModelContext(container).fetchCount(FetchDescriptor<PersistedMessageContent>()) == 1)
    }

    @Test func recentThreadsAreTheNewest() async throws {
        let repository = try makeRepository()
        try await repository.upsert((1...5).map { thread($0, message: "m\($0)", minutes: Double($0)) }, isInitialSync: true)
        let recent = try await repository.recentThreads(limit: 2)
        #expect(recent.map(\.id.providerID) == ["t5", "t4"])
    }
}
