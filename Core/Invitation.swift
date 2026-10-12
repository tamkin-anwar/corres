import Foundation

/// A calendar invitation in an email (an .ics with METHOD:REQUEST), and the
/// standard reply to it (RFC 5546 iTIP, METHOD:REPLY): what Google
/// Calendar, Outlook and iCloud send when you tap Yes, Maybe or No, so the
/// organizer's calendar shows your answer.
public struct Invitation: Equatable, Sendable {
    public let uid: String
    public let organizerEmail: String
    public let summary: String
    public let sequence: Int
    /// Lines copied as written, so the organizer's calendar matches them.
    let organizerLine: String
    let startLine: String
    let recurrenceLine: String?

    public enum Response: String, Sendable {
        case accepted = "ACCEPTED", tentative = "TENTATIVE", declined = "DECLINED"

        public var verb: String {
            switch self {
            case .accepted: "Accepted"
            case .tentative: "Maybe"
            case .declined: "Declined"
            }
        }
    }

    /// Only a request (an invitation), not a published calendar or a
    /// cancellation.
    public static func parse(_ ics: String) -> Invitation? {
        let unfolded = ics.replacingOccurrences(of: "\r\n ", with: "").replacingOccurrences(of: "\n ", with: "")
            .replacingOccurrences(of: "\r", with: "")
        let lines = unfolded.split(separator: "\n").map(String.init)
        guard lines.contains(where: { $0.uppercased().hasPrefix("METHOD:REQUEST") }),
              let begin = lines.firstIndex(where: { $0.hasPrefix("BEGIN:VEVENT") }) else { return nil }
        let event = lines[begin...].prefix { !$0.hasPrefix("END:VEVENT") }
        func line(_ name: String) -> String? {
            event.first { $0.uppercased().hasPrefix(name + ":") || $0.uppercased().hasPrefix(name + ";") }
        }
        func value(_ name: String) -> String? {
            guard let found = line(name), let colon = found.firstIndex(of: ":") else { return nil }
            return String(found[found.index(after: colon)...])
        }
        guard let uid = value("UID"), let organizer = line("ORGANIZER"), let start = line("DTSTART"),
              let mailto = organizer.range(of: "mailto:", options: .caseInsensitive) else { return nil }
        let email = String(organizer[mailto.upperBound...]).trimmingCharacters(in: .whitespaces).lowercased()
        let summary = (value("SUMMARY") ?? "Event").replacingOccurrences(of: "\\,", with: ",")
        return Invitation(uid: uid, organizerEmail: email, summary: summary,
                          sequence: Int(value("SEQUENCE") ?? "") ?? 0,
                          organizerLine: organizer, startLine: start, recurrenceLine: line("RRULE"))
    }

    /// The reply, as the calendar part of an email to the organizer.
    public func reply(_ response: Response, attendee: String, name: String?, now: Date = .now) -> String {
        let stamp = Self.stamp(now)
        let who = name.map { ";CN=\"\($0.replacingOccurrences(of: "\"", with: ""))\"" } ?? ""
        var lines = [
            "BEGIN:VCALENDAR",
            "PRODID:-//Corres//Corres for iPhone//EN",
            "VERSION:2.0",
            "CALSCALE:GREGORIAN",
            "METHOD:REPLY",
            "BEGIN:VEVENT",
            "UID:\(uid)",
            "SEQUENCE:\(sequence)",
            "DTSTAMP:\(stamp)",
            startLine,
        ]
        if let recurrenceLine { lines.append(recurrenceLine) }
        lines += [
            organizerLine,
            "ATTENDEE;PARTSTAT=\(response.rawValue)\(who):mailto:\(attendee)",
            "SUMMARY:\(summary.replacingOccurrences(of: ",", with: "\\,"))",
            "END:VEVENT",
            "END:VCALENDAR",
        ]
        return lines.joined(separator: "\r\n") + "\r\n"
    }

    static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: date)
    }
}
