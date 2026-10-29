import Foundation
import Testing
@testable import CorresCore

/// The small pieces behind the speed and stability sweep: settings read
/// across threads, rows read without decoding what isn't there, and
/// pattern checks kept per text.
struct SpeedSweepTests {
    @Test func lockedValueSetsOnlyWhenDifferent() {
        let box = LockedValue<Set<String>>(["a@x.test"])
        #expect(box.set(["a@x.test"]) == false)
        #expect(box.set(["b@x.test"]) == true)
        #expect(box.value == ["b@x.test"])
        box.value = []
        #expect(box.value.isEmpty)
    }

    /// Replaced on one thread while others read it, as Settings does while
    /// a sync saves mail: every read sees a whole set, never a freed one.
    @Test func lockedValueSurvivesReadsDuringWrites() {
        let box = LockedValue<Set<String>>([])
        let sets: [Set<String>] = (0..<8).map { size in Set((0..<(size * 50)).map { "person\($0)@x.test" }) }
        let partial = LockedValue(false)
        DispatchQueue.concurrentPerform(iterations: 8) { worker in
            for round in 0..<500 {
                if worker == 0 {
                    box.value = sets[round % sets.count]
                } else {
                    let read = box.value
                    if read.count % 50 != 0 || (!read.isEmpty && !read.contains("person0@x.test")) { partial.value = true }
                }
            }
        }
        #expect(partial.value == false)
    }

    @Test func rowsWithoutAttachmentsSkipDecoding() throws {
        #expect(PersistedCorrespondence.attachments(from: Data()).isEmpty)
        #expect(PersistedCorrespondence.attachments(from: Data("[]".utf8)).isEmpty)
        #expect(PersistedCorrespondence.attachments(from: Data("null".utf8)).isEmpty)
        let one = [MailAttachment(id: "1", filename: "Lease.pdf", mimeType: "application/pdf", sizeBytes: 2_048)]
        let saved = try JSONEncoder().encode(one)
        #expect(PersistedCorrespondence.attachments(from: saved) == one)
        #expect(try JSONEncoder().encode([MailAttachment]()) == Data("[]".utf8))
    }

    @Test func keptPatternAnswersMatchFreshOnes() {
        let event = "Your appointment is confirmed\nSee you Tuesday at 10"
        let bill = "Your appointment invoice\nAmount due Friday"
        for _ in 0..<3 {
            #expect(MailSignals.isEvent(event))
            #expect(!MailSignals.isEvent(bill))
        }
        let alert = "New sign-in to your account\nIf this was you, you can ignore this email."
        for _ in 0..<3 {
            #expect(MailDigest.isConfirmationAlert(alert))
            #expect(!MailDigest.isConfirmationAlert("Lunch on Friday?\nAre you free?"))
        }
    }
}
