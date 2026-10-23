import Foundation
import Testing
@testable import Postwright

struct SyncPlannerTests {
    let plain = Capabilities(["IMAP4rev1", "IDLE"])
    let condstore = Capabilities(["IMAP4rev1", "IDLE", "CONDSTORE"])

    @Test func firstSyncIsFull() {
        let plan = SyncPlanner.plan(stored: nil, selected: .init(uidValidity: 7, uidNext: 100, exists: 99, highestModSeq: nil), capabilities: plain)
        #expect(plan == .full(newest: SyncPlanner.firstSyncLimit))
    }

    @Test func renumberedFolderStartsOver() {
        let stored = FolderSyncState(uidValidity: 7, uidNext: 100)
        let plan = SyncPlanner.plan(stored: stored, selected: .init(uidValidity: 8, uidNext: 5, exists: 4, highestModSeq: nil), capabilities: plain)
        #expect(plan == .full(newest: SyncPlanner.firstSyncLimit))
    }

    @Test func condstoreSkipsAnUnchangedFolder() {
        let stored = FolderSyncState(uidValidity: 7, uidNext: 100, highestModSeq: 50, exists: 99)
        let plan = SyncPlanner.plan(stored: stored, selected: .init(uidValidity: 7, uidNext: 100, exists: 99, highestModSeq: 50), capabilities: condstore)
        #expect(plan == .upToDate)
    }

    /// An expunge needn't move the counter without QRESYNC: a smaller
    /// count still sends the sync looking.
    @Test func condstoreLooksAgainWhenTheCountDrops() {
        let stored = FolderSyncState(uidValidity: 7, uidNext: 100, highestModSeq: 50, exists: 99)
        let plan = SyncPlanner.plan(stored: stored, selected: .init(uidValidity: 7, uidNext: 100, exists: 98, highestModSeq: 50), capabilities: condstore)
        #expect(plan == .incremental(newFrom: nil, changedSince: nil, checkFlagsOfKnown: true))
    }

    /// State saved before the count was kept: looked at once, not trusted.
    @Test func condstoreWithoutAStoredCountLooksOnce() {
        let stored = FolderSyncState(uidValidity: 7, uidNext: 100, highestModSeq: 50)
        let plan = SyncPlanner.plan(stored: stored, selected: .init(uidValidity: 7, uidNext: 100, exists: 99, highestModSeq: 50), capabilities: condstore)
        #expect(plan != .upToDate)
    }

    /// Cursors written before `exists` still decode.
    @Test func olderStateDecodesWithoutACount() throws {
        let json = #"{"uidValidity":7,"uidNext":100,"highestModSeq":50}"#
        let state = try JSONDecoder().decode(FolderSyncState.self, from: Data(json.utf8))
        #expect(state == FolderSyncState(uidValidity: 7, uidNext: 100, highestModSeq: 50))
    }

    @Test func condstoreAsksOnlyForWhatChanged() {
        let stored = FolderSyncState(uidValidity: 7, uidNext: 100, highestModSeq: 50)
        let plan = SyncPlanner.plan(stored: stored, selected: .init(uidValidity: 7, uidNext: 103, exists: 102, highestModSeq: 58), capabilities: condstore)
        #expect(plan == .incremental(newFrom: 100, changedSince: 50, checkFlagsOfKnown: false))
    }

    @Test func withoutCondstoreFlagsAreCompared() {
        let stored = FolderSyncState(uidValidity: 7, uidNext: 100)
        let plan = SyncPlanner.plan(stored: stored, selected: .init(uidValidity: 7, uidNext: 100, exists: 99, highestModSeq: nil), capabilities: plain)
        #expect(plan == .incremental(newFrom: nil, changedSince: nil, checkFlagsOfKnown: true))
    }
}

struct FlagChangesTests {
    let read: Set<String> = ["\\seen"]
    let unread: Set<String> = []
    let readFlagged: Set<String> = ["\\seen", "\\flagged"]

    @Test func unchangedFlagsReportNothing() {
        let previous: [UInt32: UInt8] = [1: 1, 2: 0, 3: 3]
        let result = FlagChanges.compare(known: [1, 2, 3], previous: previous,
                                         current: [1: read, 2: unread, 3: readFlagged.union(["\\recent", "$junk"])])
        #expect(result.changed.isEmpty)
        #expect(result.vanished.isEmpty)
        #expect(result.codes == previous)
    }

    @Test func readOrFlaggedElsewhereIsReported() {
        let result = FlagChanges.compare(known: [1, 2, 3], previous: [1: 0, 2: 1, 3: 1],
                                         current: [1: read, 2: unread, 3: readFlagged])
        #expect(result.changed == [1, 2, 3])
        #expect(result.codes == [1: 1, 2: 0, 3: 3])
    }

    /// Gone from the folder: reported as vanished, and not kept.
    @Test func vanishedMessageIsReported() {
        let result = FlagChanges.compare(known: [1, 2], previous: [1: 1, 2: 1], current: [1: read])
        #expect(result.changed.isEmpty)
        #expect(result.vanished == [2])
        #expect(result.codes == [1: 1])
    }

    /// A UID with nothing kept for it, or nothing kept at all, is always
    /// reported: never assumed unchanged.
    @Test func newOrUnrecordedMessagesAreReported() {
        let one = FlagChanges.compare(known: [1, 2], previous: [1: 1], current: [1: read, 2: read])
        #expect(one.changed == [2])
        let all = FlagChanges.compare(known: [1, 2], previous: nil, current: [1: read, 2: unread])
        #expect(all.changed == [1, 2])
        #expect(all.codes == [1: 1, 2: 0])
    }

    /// The caller's own bits ride along untouched and never count as a change.
    @Test func callerBitsAreCarriedOver() {
        let result = FlagChanges.compare(known: [1, 2], previous: [1: 4 | 1, 2: 4], current: [1: read, 2: read])
        #expect(result.changed == [2])
        #expect(result.codes == [1: 5, 2: 5])
    }

    @Test func flagCaseDoesNotMatter() {
        #expect(FlagChanges.code(["\\Seen", "\\FLAGGED"]) == 3)
        #expect(FlagChanges.code(["\\draft"]) == 0)
    }
}

struct ThreaderTests {
    func message(_ uid: UInt32, _ id: String?, replyTo: String? = nil, refs: [String] = [], folder: String = "INBOX", minutes: Double) -> MessageSummary {
        MessageSummary(uid: uid, folder: folder, flags: [], subject: "Hello", from: nil, to: [],
                       date: Date(timeIntervalSince1970: minutes * 60), messageID: id, inReplyTo: replyTo, references: refs)
    }

    @Test func sentReplyJoinsTheInboxConversation() {
        let threads = Threader.threads([
            message(1, "a", minutes: 1),
            message(9, "b", replyTo: "a", folder: "Sent Messages", minutes: 2),
            message(2, "c", replyTo: "b", refs: ["a", "b"], minutes: 3),
        ])
        #expect(threads.count == 1)
        #expect(threads[0].messages.map(\.uid) == [1, 9, 2])
    }

    @Test func sameSubjectAloneDoesNotJoin() {
        #expect(Threader.threads([message(1, "a", minutes: 1), message(2, "b", minutes: 2)]).count == 2)
    }

    @Test func aMissingMiddleMessageStillLinksBothEnds() {
        // c references a and b; b was never synced.
        let threads = Threader.threads([message(1, "a", minutes: 1), message(3, "c", replyTo: "b", refs: ["a", "b"], minutes: 3)])
        #expect(threads.count == 1)
    }

    @Test func theSameMessageInTwoFoldersCountsOnce() {
        let threads = Threader.threads([message(1, "a", minutes: 1), message(77, "a", folder: "Archive", minutes: 1)])
        #expect(threads.count == 1)
        #expect(threads[0].messages.count == 1)
    }

    @Test func newestConversationFirst() {
        let threads = Threader.threads([message(1, "old", minutes: 1), message(2, "new", minutes: 9)])
        #expect(threads.map(\.id) == ["new", "old"])
    }
}

struct HeaderDecodingTests {
    @Test func encodedWords() {
        #expect(MIMEWords.decode("=?UTF-8?B?8J+TpiBZb3VyIG9yZGVy?=") == "📦 Your order")
        #expect(MIMEWords.decode("=?utf-8?q?Caf=C3=A9?= au lait") == "Café au lait")
        #expect(MIMEWords.decode("=?UTF-8?Q?a?= =?UTF-8?Q?b?=") == "ab")
        #expect(MIMEWords.decode("=?ISO-8859-1?Q?Gr=FC=DFe?=") == "Grüße")
        #expect(MIMEWords.decode("Plain subject") == "Plain subject")
    }

    @Test func datesInTheirRealShapes() {
        let expected = ISO8601DateFormatter().date(from: "2026-10-16T13:07:48Z")
        #expect(RFC2822Date.parse("Fri, 16 Oct 2026 09:07:48 -0400") == expected)
        #expect(RFC2822Date.parse("16 Oct 2026 09:07:48 -0400") == expected)
        #expect(RFC2822Date.parse("Fri, 16 Oct 2026 06:07:48 -0700 (PDT)") == expected)
        #expect(RFC2822Date.parse("Fri,  16 Oct 2026 13:07:48 +0000") == expected)
    }

    @Test func referencesHeader() {
        #expect(messageIDs(in: "<a@x> <b@y>\r\n <c@z>") == ["a@x", "b@y", "c@z"])
    }
}

struct CapabilityTests {
    @Test func iCloudBeforeLogin() {
        let caps = Capabilities(["XAPPLEPUSHSERVICE", "IMAP4", "IMAP4rev1", "SASL-IR", "AUTH=ATOKEN", "AUTH=PLAIN", "AUTH=XOAUTH2"])
        #expect(caps.authPlain)
        #expect(!caps.idle)
        #expect(!caps.move)
    }

    @Test func qresyncImpliesCondstore() {
        #expect(Capabilities(["QRESYNC"]).condstore)
    }
}
