import Foundation
import NIOCore
import NIOIMAP
import Testing
@testable import Postwright

/// Feeds a recorded server transcript through the real parser into a
/// collector, the same path live replies take.
func collect(_ name: String, tag: String, folder: String = "INBOX") throws -> ResponseCollector {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "txt", subdirectory: "Transcripts"))
    var buffer = ByteBuffer(bytes: try Data(contentsOf: url))
    var parser = ResponseParser()
    var collector = ResponseCollector(tag: tag, folder: folder)
    while buffer.readableBytes > 0, let next = try parser.parseResponseStream(buffer: &buffer) {
        if case .response(let response) = next { collector.receive(response) }
    }
    return collector
}

struct TranscriptTests {
    @Test func iCloudFoldersGetRolesByName() throws {
        let c = try collect("icloud-list", tag: "A2")
        #expect(c.outcome == .ok)
        let folders = c.folders
        #expect(folders.count == 8)
        #expect(folders.folder(for: .inbox)?.path == "INBOX")
        #expect(folders.folder(for: .sent)?.path == "Sent Messages")
        #expect(folders.folder(for: .trash)?.path == "Deleted Messages")
        #expect(folders.folder(for: .junk)?.path == "Junk")
        #expect(folders.folder(for: .archive)?.path == "Archive")
        #expect(folders.first { $0.path == "Archive/Receipts" }?.name == "Receipts")
        #expect(folders.first { $0.path == "Archive/Receipts" }?.role == nil)
        #expect(folders.first { $0.path == "Projects" }?.isSelectable == false)
    }

    @Test func fastmailFoldersGetRolesFromTheServer() throws {
        let c = try collect("fastmail-list", tag: "A2")
        #expect(c.folders.folder(for: .junk)?.path == "Spam")
        #expect(c.folders.folder(for: .sent)?.path == "Sent")
        #expect(c.folders.folder(for: .archive)?.attributes.contains("archive") == true)
    }

    @Test func selectReportsSyncState() throws {
        let c = try collect("select", tag: "A3")
        #expect(c.outcome == .ok)
        #expect(c.selected == SelectedFolder(uidValidity: 1_544_578_391, uidNext: 48213, exists: 1203, highestModSeq: 905_172))
    }

    @Test func fetchBuildsSummariesWithThreadingAndDecodedHeaders() throws {
        let c = try collect("fetch-headers", tag: "A4")
        #expect(c.outcome == .ok)
        #expect(c.messages.count == 3)
        let first = c.messages[0], reply = c.messages[1], order = c.messages[2]
        #expect(first.uid == 48210)
        #expect(first.isSeen)
        #expect(first.subject == "Lunch on Thursday?")
        #expect(first.from == Address(name: "Maya Chen", email: "maya@studio.example"))
        #expect(first.messageID == "a1@studio.example")
        #expect(first.date == ISO8601DateFormatter().date(from: "2026-10-16T13:07:48Z"))
        #expect(reply.inReplyTo == "a1@studio.example")
        #expect(reply.references == ["a1@studio.example"])
        #expect(reply.date != nil, "Date with a (PDT) comment still parses")
        #expect(!reply.isSeen)
        #expect(order.subject == "📦 Your order has shipped")
        #expect(order.from?.name == "Café Lumière")
        #expect(order.isFlagged)
        #expect(order.size == 9001)

        let threads = Threader.threads(c.messages)
        #expect(threads.count == 2)
        #expect(threads.first { $0.messages.count == 2 }?.messages.map(\.uid) == [48210, 48211])
    }
}
