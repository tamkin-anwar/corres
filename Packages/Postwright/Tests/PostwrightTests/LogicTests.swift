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
        let stored = FolderSyncState(uidValidity: 7, uidNext: 100, highestModSeq: 50)
        let plan = SyncPlanner.plan(stored: stored, selected: .init(uidValidity: 7, uidNext: 100, exists: 99, highestModSeq: 50), capabilities: condstore)
        #expect(plan == .upToDate)
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
