import Foundation
import Testing
@testable import CorresCore

struct InvitationTests {
    let ics = """
    BEGIN:VCALENDAR\r
    PRODID:-//Google Inc//Google Calendar 70.9054//EN\r
    VERSION:2.0\r
    METHOD:REQUEST\r
    BEGIN:VEVENT\r
    DTSTART;TZID=Europe/London:20261016T140000\r
    DTEND;TZID=Europe/London:20261016T150000\r
    ORGANIZER;CN=Sara Wiltshire:mailto:sara@portsmouth.ac.uk\r
    UID:abc123@google.com\r
    ATTENDEE;CUTYPE=INDIVIDUAL;ROLE=REQ-PARTICIPANT;PARTSTAT=NEEDS-ACTION;CN=me@x.test:mailto:me@x.test\r
    SEQUENCE:2\r
    SUMMARY:Project review\\, round 2\r
    END:VEVENT\r
    END:VCALENDAR\r
    """

    @Test func readsAnInvitation() {
        let invite = Invitation.parse(ics)!
        #expect(invite.uid == "abc123@google.com")
        #expect(invite.organizerEmail == "sara@portsmouth.ac.uk")
        #expect(invite.summary == "Project review, round 2")
        #expect(invite.sequence == 2)
        #expect(invite.invitedAddress(among: ["other@gmail.com", "ME@x.test"], fallback: "other@gmail.com") == "me@x.test")
        #expect(invite.invitedAddress(among: ["other@gmail.com"], fallback: "other@gmail.com") == "other@gmail.com")
        #expect(Invitation.parse(ics.replacingOccurrences(of: "METHOD:REQUEST", with: "METHOD:PUBLISH")) == nil)
    }

    @Test func answersOneDateOfASeries() {
        let one = ics.replacingOccurrences(of: "SEQUENCE:2\r", with: "SEQUENCE:2\r\nRECURRENCE-ID;TZID=Europe/London:20261016T140000\r")
        let reply = Invitation.parse(one)!.reply(.declined, attendee: "me@x.test", name: nil)
        #expect(reply.contains("RECURRENCE-ID;TZID=Europe/London:20261016T140000"))
    }

    @Test func repliesTheWayCalendarsExpect() {
        let reply = Invitation.parse(ics)!.reply(.accepted, attendee: "me@x.test", name: "Tamkin Anwar",
                                                 now: Date(timeIntervalSince1970: 1_791_800_000))
        #expect(reply.contains("METHOD:REPLY\r\n"))
        #expect(reply.contains("UID:abc123@google.com\r\n"))
        #expect(reply.contains("SEQUENCE:2\r\n"))
        #expect(reply.contains("DTSTART;TZID=Europe/London:20261016T140000\r\n"))
        #expect(reply.contains("ORGANIZER;CN=Sara Wiltshire:mailto:sara@portsmouth.ac.uk\r\n"))
        #expect(reply.contains("ATTENDEE;PARTSTAT=ACCEPTED;CN=\"Tamkin Anwar\":mailto:me@x.test\r\n"))
        #expect(reply.contains("SUMMARY:Project review\\, round 2\r\n"))
    }
}
