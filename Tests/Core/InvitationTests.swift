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

    // MARK: Time zones around the world

    @Test func windowsZoneNamesMatchWhole() {
        #expect(ICalendar.zone("AUS Central Standard Time")?.identifier == "Australia/Darwin")
        #expect(ICalendar.zone("Cen. Australia Standard Time")?.identifier == "Australia/Adelaide")
        #expect(ICalendar.zone("Tasmania Standard Time")?.identifier == "Australia/Hobart")
        #expect(ICalendar.zone("Nepal Standard Time")?.identifier == "Asia/Kathmandu")
        #expect(ICalendar.zone("Sri Lanka Standard Time")?.identifier == "Asia/Colombo")
        #expect(ICalendar.zone("Myanmar Standard Time")?.identifier == "Asia/Yangon")
        #expect(ICalendar.zone("Bangladesh Standard Time")?.identifier == "Asia/Dhaka")
        #expect(ICalendar.zone("Central Standard Time")?.identifier == "America/Chicago")
        // Never a loose match: an unknown name with "Central" in it isn't Chicago.
        #expect(ICalendar.zone("Some Central Zone") == nil)
    }

    @Test func everyWindowsZoneIsARealZone() {
        for (name, identifier) in ICalendar.windowsZones {
            #expect(TimeZone(identifier: identifier) != nil, "\(name) → \(identifier)")
        }
    }

    @Test func outlookDisplayNamesUseTheirOffset() {
        #expect(ICalendar.zone("(UTC-05:00) Eastern Time (US & Canada)")?.identifier == "America/New_York")
        #expect(ICalendar.zone("(UTC-06:00) Central Time (US & Canada)")?.identifier == "America/Chicago")
        #expect(ICalendar.zone("(UTC+09:30) Darwin")?.identifier == "Australia/Darwin")
        #expect(ICalendar.zone("(UTC+10:00) Canberra, Melbourne, Sydney")?.identifier == "Australia/Sydney")
        #expect(ICalendar.zone("(UTC+06:00) Dhaka")?.identifier == "Asia/Dhaka")
        #expect(ICalendar.zone("(UTC+05:30) Chennai, Kolkata, Mumbai, New Delhi")?.identifier == "Asia/Kolkata")
        // A place Corres doesn't know: the offset itself.
        #expect(ICalendar.zone("(UTC+05:45) Somewhere")?.secondsFromGMT() == 5 * 3600 + 45 * 60)
    }

    @Test func zonesTheFileDefinesItself() {
        let ics = """
        BEGIN:VCALENDAR\r
        METHOD:REQUEST\r
        BEGIN:VTIMEZONE\r
        TZID:Customized Time Zone\r
        BEGIN:STANDARD\r
        DTSTART:16010101T000000\r
        TZOFFSETFROM:+0930\r
        TZOFFSETTO:+0930\r
        END:STANDARD\r
        END:VTIMEZONE\r
        BEGIN:VEVENT\r
        ORGANIZER;CN=Sam:mailto:sam@example.com.au\r
        DTSTART;TZID=Customized Time Zone:20261020T090000\r
        DURATION:PT1H\r
        UID:abc\r
        SUMMARY:Catch-up\r
        END:VEVENT\r
        END:VCALENDAR\r
        """
        let invite = Invitation.parse(ics)!
        // 9 AM at UTC+9:30 is 23:30 UTC the day before.
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        #expect(invite.start.map { utc.dateComponents([.day, .hour, .minute], from: $0) } == DateComponents(day: 19, hour: 23, minute: 30))

        let daylight = ICalendar.definedZones(in: ICalendar.unfold("""
        BEGIN:VTIMEZONE
        TZID:My Zone
        BEGIN:STANDARD
        TZOFFSETFROM:-0400
        TZOFFSETTO:-0500
        END:STANDARD
        BEGIN:DAYLIGHT
        TZOFFSETFROM:-0500
        TZOFFSETTO:-0400
        END:DAYLIGHT
        END:VTIMEZONE
        """))
        #expect(daylight["My Zone"]?.identifier == "America/New_York")
    }
}
