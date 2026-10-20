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

    @Test func readsWhenWhereAndWho() {
        let invite = Invitation.parse(ics.replacingOccurrences(of: "SEQUENCE:2\r", with: "SEQUENCE:2\r\nLOCATION:Room 4\\, Park Building\r"))!
        #expect(invite.method == .request)
        #expect(invite.organizerName == "Sara Wiltshire")
        #expect(invite.location == "Room 4, Park Building")
        #expect(invite.start == Date(timeIntervalSince1970: 1_792_155_600))
        #expect(invite.end == Date(timeIntervalSince1970: 1_792_159_200))
        #expect(!invite.isAllDay)
        #expect(invite.joinURL == nil)
    }

    /// Outlook writes Windows zone names and puts Teams in the location.
    @Test func readsOutlookInvitations() {
        let outlook = """
        BEGIN:VCALENDAR
        METHOD:REQUEST
        BEGIN:VEVENT
        ORGANIZER;CN="Lee, Sam":mailto:sam@contoso.com
        DTSTART;TZID=Eastern Standard Time:20261020T090000
        DURATION:PT45M
        UID:040000008200E00074C5B7101A82E008
        SUMMARY;LANGUAGE=en-US:Weekly sync
        LOCATION;LANGUAGE=en-US:Microsoft Teams Meeting
        RRULE:FREQ=WEEKLY;INTERVAL=2;BYDAY=TU
        X-MICROSOFT-SKYPETEAMSMEETINGURL:https://teams.microsoft.com/l/meetup-join/19%3ameeting_abc
        END:VEVENT
        END:VCALENDAR
        """
        let invite = Invitation.parse(outlook)!
        #expect(invite.organizerName == "Lee, Sam")
        #expect(invite.summary == "Weekly sync")
        // 9 AM in New York is 13:00 UTC in October.
        #expect(invite.start == Date(timeIntervalSince1970: 1_792_501_200))
        #expect(invite.end == Date(timeIntervalSince1970: 1_792_501_200 + 45 * 60))
        #expect(invite.location == nil)
        #expect(invite.joinService == "Microsoft Teams")
        #expect(invite.repeats == "Every 2 weeks")
    }

    @Test func readsCancellationsAndAllDayEvents() {
        let cancel = ics.replacingOccurrences(of: "METHOD:REQUEST", with: "METHOD:CANCEL")
            .replacingOccurrences(of: "DTSTART;TZID=Europe/London:20261016T140000", with: "DTSTART;VALUE=DATE:20261016")
            .replacingOccurrences(of: "SEQUENCE:2\r", with: "SEQUENCE:2\r\nDESCRIPTION:Join: https://meet.google.com/abc-defg-hij\\nThanks\r")
        let invite = Invitation.parse(cancel)!
        #expect(invite.method == .cancel)
        #expect(invite.isAllDay)
        #expect(invite.joinService == "Google Meet")
        #expect(invite.joinURL?.absoluteString == "https://meet.google.com/abc-defg-hij")
    }

    @Test func readsDurationsAndRepeats() {
        #expect(ICalendar.duration("PT1H30M") == 5_400)
        #expect(ICalendar.duration("P1D") == 86_400)
        #expect(ICalendar.repeats("FREQ=WEEKLY;BYDAY=MO,TU,WE,TH,FR") == "Every weekday")
        #expect(ICalendar.repeats("FREQ=MONTHLY") == "Every month")
        #expect(ICalendar.zone("\"W. Europe Standard Time\"")?.identifier == "Europe/Berlin")
    }
}
