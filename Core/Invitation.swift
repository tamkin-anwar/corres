import Foundation

/// A calendar invitation in an email (an .ics with METHOD:REQUEST), or its
/// cancellation (METHOD:CANCEL), and the standard reply to it (RFC 5546
/// iTIP, METHOD:REPLY): what Google Calendar, Outlook and iCloud send when
/// you tap Yes, Maybe or No, so the organizer's calendar shows your answer.
public struct Invitation: Equatable, Sendable {
    public enum Method: Sendable { case request, cancel }

    public let method: Method
    public let uid: String
    public let organizerEmail: String
    public let organizerName: String?
    public let summary: String
    /// Goes up each time the organizer changes the event.
    public let sequence: Int
    public let start: Date?
    public let end: Date?
    public let isAllDay: Bool
    public let location: String?
    /// "Every week", for a repeating event.
    public let repeats: String?
    /// The video call, when the event has one (Meet, Zoom, Teams…).
    public let joinURL: URL?
    /// Lines copied as written, so the organizer's calendar matches them.
    let organizerLine: String
    let startLine: String
    let recurrenceLine: String?
    /// One date of a repeating event: the answer is for that date only.
    let recurrenceIDLine: String?
    /// Everyone invited, by address, to find which of yours it was sent to.
    public let attendees: [String]

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

    /// The name of the video service, for the Join button.
    public var joinService: String? { joinURL.flatMap { ICalendar.service(for: $0) } }

    /// A request (an invitation) or a cancellation, not a published
    /// calendar or someone's reply.
    public static func parse(_ ics: String) -> Invitation? {
        let lines = ICalendar.unfold(ics)
        let method: Method
        if lines.contains(where: { $0.uppercased().hasPrefix("METHOD:REQUEST") }) { method = .request }
        else if lines.contains(where: { $0.uppercased().hasPrefix("METHOD:CANCEL") }) { method = .cancel }
        else { return nil }
        guard let begin = lines.firstIndex(where: { $0.hasPrefix("BEGIN:VEVENT") }) else { return nil }
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
        let summary = ICalendar.text(value("SUMMARY") ?? "Event")
        let defined = ICalendar.definedZones(in: lines)
        func date(_ found: String?) -> (date: Date, allDay: Bool)? {
            guard let found, let colon = found.firstIndex(of: ":") else { return nil }
            return ICalendar.date(String(found[found.index(after: colon)...]), params: String(found[..<colon]), zones: defined)
        }
        let starts = date(start)
        var ends = date(line("DTEND")).map(\.date)
        if ends == nil, let starts, let duration = value("DURATION").flatMap(ICalendar.duration) {
            ends = starts.date.addingTimeInterval(duration)
        }
        // The call's link, from where each calendar puts it.
        let notes = value("DESCRIPTION").map(ICalendar.text)
        let place = value("LOCATION").map(ICalendar.text)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let join = [value("X-GOOGLE-CONFERENCE"), value("X-MICROSOFT-SKYPETEAMSMEETINGURL"), place, notes]
            .compactMap { $0 }.lazy.compactMap(ICalendar.meetingLink).first
        // "Microsoft Teams Meeting", or the link itself, isn't a place.
        let location = place.flatMap { place -> String? in
            guard !place.isEmpty else { return nil }
            if let join, place.contains(join.absoluteString) || place.lowercased().contains((ICalendar.service(for: join) ?? "-").lowercased()) { return nil }
            return place
        }
        let name = organizer.range(of: "CN=", options: .caseInsensitive).map { found -> String in
            let rest = organizer[found.upperBound...]
            let raw = rest.hasPrefix("\"") ? rest.dropFirst().prefix { $0 != "\"" } : rest.prefix { $0 != ";" && $0 != ":" }
            return String(raw).trimmingCharacters(in: .whitespaces)
        }.flatMap { $0.isEmpty || $0.lowercased() == email ? nil : $0 }
        let attendees = event.filter { $0.uppercased().hasPrefix("ATTENDEE") }.compactMap { line -> String? in
            guard let mailto = line.range(of: "mailto:", options: .caseInsensitive) else { return nil }
            return String(line[mailto.upperBound...]).trimmingCharacters(in: .whitespaces).lowercased()
        }
        return Invitation(method: method, uid: uid, organizerEmail: email, organizerName: name, summary: summary,
                          sequence: Int(value("SEQUENCE") ?? "") ?? 0,
                          start: starts?.date, end: ends, isAllDay: starts?.allDay ?? false, location: location,
                          repeats: value("RRULE").flatMap(ICalendar.repeats), joinURL: join,
                          organizerLine: organizer, startLine: start, recurrenceLine: line("RRULE"),
                          recurrenceIDLine: line("RECURRENCE-ID"), attendees: attendees)
    }

    /// Which of your addresses it was sent to (an alias, say), so the
    /// organizer's calendar marks you, not a stranger; else `fallback`.
    public func invitedAddress(among yours: [String], fallback: String) -> String {
        let mine = Set(yours.map { $0.lowercased() })
        return attendees.first { mine.contains($0) } ?? fallback
    }

    /// The reply, as the calendar part of an email to the organizer.
    public func reply(_ response: Response, attendee: String, name: String?, now: Date = .now) -> String {
        let stamp = Self.stamp(now)
        let who = name.map { ";CN=\"\($0.replacingOccurrences(of: "\"", with: ""))\"" } ?? ""
        var lines = [
            "BEGIN:VCALENDAR",
            "PRODID:-//Corres//Corres//EN",
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
        if let recurrenceIDLine { lines.append(recurrenceIDLine) }
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

/// Reading .ics files (RFC 5545): what Google Calendar, Outlook and iCloud
/// write, including Outlook's Windows time zone names.
enum ICalendar {
    /// Long lines continue on the next after a space or a tab.
    static func unfold(_ ics: String) -> [String] {
        ics.replacingOccurrences(of: "\r\n ", with: "").replacingOccurrences(of: "\r\n\t", with: "")
            .replacingOccurrences(of: "\n ", with: "").replacingOccurrences(of: "\n\t", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .split(separator: "\n").map(String.init)
    }

    /// A text value with its escapes undone.
    static func text(_ value: String) -> String {
        var result = ""
        var escaped = false
        for character in value {
            if escaped {
                result.append(character == "n" || character == "N" ? "\n" : character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else {
                result.append(character)
            }
        }
        return result
    }

    /// A date or date-time with its parameters (`DTSTART;TZID=...`).
    /// `zones` are the file's own VTIMEZONE definitions (`definedZones`).
    static func date(_ value: String, params: String, zones: [String: TimeZone] = [:]) -> (date: Date, allDay: Bool)? {
        let value = value.trimmingCharacters(in: .whitespaces)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        if value.count == 8 || params.uppercased().contains("VALUE=DATE;") || params.uppercased().hasSuffix("VALUE=DATE") {
            formatter.dateFormat = "yyyyMMdd"
            formatter.timeZone = .current
            return formatter.date(from: String(value.prefix(8))).map { ($0, true) }
        }
        if value.hasSuffix("Z") {
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        } else {
            formatter.dateFormat = "yyyyMMdd'T'HHmmss"
            formatter.timeZone = params.range(of: "TZID=", options: .caseInsensitive).flatMap { found in
                zone(String(params[found.upperBound...].prefix { $0 != ";" }), defined: zones)
            } ?? .current
        }
        return formatter.date(from: value).map { ($0, false) }
    }

    /// A TZID as calendars write it: an IANA name ("Europe/London"), a
    /// Windows name ("AUS Central Standard Time"), Outlook's display name
    /// ("(UTC+09:30) Darwin"), or a name the file defines itself in a
    /// VTIMEZONE (`defined`). Names are matched whole: a loose match once
    /// read "AUS Central Standard Time" as Chicago's "Central".
    static func zone(_ name: String, defined: [String: TimeZone] = [:]) -> TimeZone? {
        let name = name.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
        if let zone = TimeZone(identifier: name) { return zone }
        if let mapped = windowsZones[name] ?? windowsZones.first(where: { $0.key.caseInsensitiveCompare(name) == .orderedSame })?.value,
           let zone = TimeZone(identifier: mapped) {
            return zone
        }
        if let zone = displayNameZone(name) { return zone }
        return defined[name]
    }

    /// "(UTC-05:00) Eastern Time (US & Canada)", "(UTC+05:45) Kathmandu",
    /// "(GMT+10:00) Canberra, Melbourne, Sydney": the offset, and the zone
    /// with that offset whose city or region the rest names, so daylight
    /// saving still applies; otherwise just the offset.
    static func displayNameZone(_ name: String) -> TimeZone? {
        guard let match = name.patternRange(#"^\((?:UTC|GMT)\s*(?:([+\-−])\s*(\d{1,2})(?::?(\d{2}))?)?\)"#) else { return nil }
        let prefix = String(name[match])
        let sign = prefix.contains("-") || prefix.contains("−") ? -1 : 1
        let numbers = prefix.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        let offset = sign * ((numbers.first ?? 0) * 3600 + (numbers.dropFirst().first ?? 0) * 60)
        let rest = name[match.upperBound...].lowercased()
        let reference = Date(timeIntervalSince1970: 1_768_000_000)
        func standardOffset(_ zone: TimeZone) -> Int {
            zone.secondsFromGMT(for: reference) - Int(zone.daylightSavingTimeOffset(for: reference))
        }
        for (words, identifier) in displayNames where rest.contains(words) {
            if let zone = TimeZone(identifier: identifier), standardOffset(zone) == offset { return zone }
        }
        for identifier in Set(windowsZones.values).sorted() {
            guard let zone = TimeZone(identifier: identifier), standardOffset(zone) == offset,
                  let city = identifier.split(separator: "/").last?.replacingOccurrences(of: "_", with: " ").lowercased(),
                  city.count > 2, rest.contains(city) else { continue }
            return zone
        }
        return TimeZone(secondsFromGMT: offset)
    }

    /// Regions in Windows display names that aren't a zone's city.
    private static let displayNames: [(String, String)] = [
        ("eastern time (us", "America/New_York"), ("central time (us", "America/Chicago"),
        ("mountain time (us", "America/Denver"), ("pacific time (us", "America/Los_Angeles"),
        ("alaska", "America/Anchorage"), ("hawaii", "Pacific/Honolulu"), ("arizona", "America/Phoenix"),
        ("atlantic time", "America/Halifax"), ("newfoundland", "America/St_Johns"), ("saskatchewan", "America/Regina"),
        ("dublin", "Europe/London"), ("amsterdam", "Europe/Berlin"), ("brussels", "Europe/Paris"),
        ("new delhi", "Asia/Kolkata"), ("sri jayawardenepura", "Asia/Colombo"), ("beijing", "Asia/Shanghai"),
        ("osaka", "Asia/Tokyo"), ("canberra", "Australia/Sydney"), ("wellington", "Pacific/Auckland"),
        ("astana", "Asia/Almaty"), ("islamabad", "Asia/Karachi"), ("kuala lumpur", "Asia/Singapore"),
        ("hanoi", "Asia/Bangkok"), ("jakarta", "Asia/Bangkok"), ("abu dhabi", "Asia/Dubai"),
    ]

    /// The zones a file defines itself (`BEGIN:VTIMEZONE`), by TZID, for
    /// names nothing else knows. A zone without daylight saving is its
    /// standard offset; one with it is the Windows zone with the same
    /// standard and daylight offsets, so the change dates still apply.
    static func definedZones(in lines: [String]) -> [String: TimeZone] {
        var zones: [String: TimeZone] = [:]
        var index = 0
        while index < lines.count {
            guard lines[index].uppercased().hasPrefix("BEGIN:VTIMEZONE") else { index += 1; continue }
            var tzid: String?
            var section = ""
            var standard: Int?
            var daylight: Int?
            index += 1
            while index < lines.count, !lines[index].uppercased().hasPrefix("END:VTIMEZONE") {
                let line = lines[index]
                let upper = line.uppercased()
                if upper.hasPrefix("TZID"), let colon = line.firstIndex(of: ":") {
                    tzid = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                } else if upper.hasPrefix("BEGIN:STANDARD") { section = "standard" }
                else if upper.hasPrefix("BEGIN:DAYLIGHT") { section = "daylight" }
                else if upper.hasPrefix("TZOFFSETTO:"), let seconds = offset(String(line.dropFirst("TZOFFSETTO:".count))) {
                    if section == "daylight" { daylight = seconds } else if standard == nil { standard = seconds }
                }
                index += 1
            }
            guard let tzid, let standard else { continue }
            if let daylight, daylight != standard {
                let reference = Date(timeIntervalSince1970: 1_768_000_000)
                let summer = Date(timeIntervalSince1970: 1_784_000_000)
                let preferred = ["America/New_York", "America/Chicago", "America/Denver", "America/Los_Angeles", "America/Halifax",
                                 "Europe/London", "Europe/Berlin", "Europe/Bucharest", "Australia/Sydney", "Australia/Adelaide",
                                 "Pacific/Auckland"]
                let candidates = preferred + Set(windowsZones.values).subtracting(preferred).sorted()
                let match = candidates.compactMap(TimeZone.init(identifier:)).first { zone in
                    let offsets = Set([zone.secondsFromGMT(for: reference), zone.secondsFromGMT(for: summer)])
                    return offsets == [standard, daylight]
                }
                zones[tzid] = match ?? TimeZone(secondsFromGMT: standard)
            } else {
                zones[tzid] = TimeZone(secondsFromGMT: standard)
            }
        }
        return zones
    }

    /// "+0930", "-0500", "+053000".
    private static func offset(_ value: String) -> Int? {
        let value = value.trimmingCharacters(in: .whitespaces)
        guard let sign = value.first, sign == "+" || sign == "-" else { return nil }
        let digits = Array(value.dropFirst())
        guard digits.count >= 4, let hours = Int(String(digits[0..<2])), let minutes = Int(String(digits[2..<4])) else { return nil }
        let seconds = digits.count >= 6 ? Int(String(digits[4..<6])) ?? 0 : 0
        return (sign == "-" ? -1 : 1) * (hours * 3600 + minutes * 60 + seconds)
    }

    /// "PT1H30M", "P1D".
    static func duration(_ value: String) -> TimeInterval? {
        var total: TimeInterval = 0
        var number = ""
        var inTime = false
        for character in value.uppercased() {
            switch character {
            case "P", "+": continue
            case "T": inTime = true
            case "0"..."9": number.append(character)
            default:
                guard let amount = Double(number) else { return nil }
                switch character {
                case "W": total += amount * 7 * 86_400
                case "D": total += amount * 86_400
                case "H": total += amount * 3_600
                case "M" where inTime: total += amount * 60
                case "S": total += amount
                default: return nil
                }
                number = ""
            }
        }
        return total > 0 ? total : nil
    }

    /// "FREQ=WEEKLY;INTERVAL=2" is "Every 2 weeks".
    static func repeats(_ rule: String) -> String? {
        var parts: [String: String] = [:]
        for part in rule.uppercased().split(separator: ";") {
            let pair = part.split(separator: "=", maxSplits: 1)
            if pair.count == 2 { parts[String(pair[0])] = String(pair[1]) }
        }
        let interval = Int(parts["INTERVAL"] ?? "1") ?? 1
        let unit: (one: String, many: String)
        switch parts["FREQ"] {
        case "DAILY": unit = ("day", "days")
        case "WEEKLY":
            if interval == 1, parts["BYDAY"] == "MO,TU,WE,TH,FR" { return "Every weekday" }
            unit = ("week", "weeks")
        case "MONTHLY": unit = ("month", "months")
        case "YEARLY": unit = ("year", "years")
        default: return nil
        }
        return interval > 1 ? "Every \(interval) \(unit.many)" : "Every \(unit.one)"
    }

    /// The first link to a video call in some text.
    static func meetingLink(in text: String) -> URL? {
        guard let regex = try? NSRegularExpression(pattern: #"https?://[^\s<>"'\\)\]]+"#) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        for match in regex.matches(in: text, range: range) {
            guard let found = Range(match.range, in: text) else { continue }
            let link = String(text[found]).trimmingCharacters(in: CharacterSet(charactersIn: ".,;>"))
            if let url = URL(string: link), service(for: url) != nil { return url }
        }
        return nil
    }

    static func service(for url: URL) -> String? {
        guard let host = url.host?.lowercased() else { return nil }
        func on(_ domain: String) -> Bool { host == domain || host.hasSuffix("." + domain) }
        if on("meet.google.com") { return "Google Meet" }
        if on("zoom.us") || on("zoom.com") { return "Zoom" }
        if on("teams.microsoft.com") || on("teams.live.com") { return "Microsoft Teams" }
        if on("webex.com") { return "Webex" }
        if on("facetime.apple.com") { return "FaceTime" }
        if on("whereby.com") { return "Whereby" }
        return nil
    }

    /// Outlook names zones the Windows way.
    static let windowsZones: [String: String] = [
        "Eastern Standard Time": "America/New_York", "Central Standard Time": "America/Chicago",
        "Mountain Standard Time": "America/Denver", "US Mountain Standard Time": "America/Phoenix",
        "Pacific Standard Time": "America/Los_Angeles", "Alaskan Standard Time": "America/Anchorage",
        "Hawaiian Standard Time": "Pacific/Honolulu", "Atlantic Standard Time": "America/Halifax",
        "Newfoundland Standard Time": "America/St_Johns", "Canada Central Standard Time": "America/Regina",
        "Central Standard Time (Mexico)": "America/Mexico_City", "SA Pacific Standard Time": "America/Bogota",
        "E. South America Standard Time": "America/Sao_Paulo", "Argentina Standard Time": "America/Argentina/Buenos_Aires",
        "GMT Standard Time": "Europe/London", "Greenwich Standard Time": "Atlantic/Reykjavik",
        "UTC": "UTC", "Coordinated Universal Time": "UTC",
        "W. Europe Standard Time": "Europe/Berlin", "Romance Standard Time": "Europe/Paris",
        "Central Europe Standard Time": "Europe/Budapest", "Central European Standard Time": "Europe/Warsaw",
        "E. Europe Standard Time": "Europe/Chisinau", "FLE Standard Time": "Europe/Kiev",
        "GTB Standard Time": "Europe/Bucharest", "Russian Standard Time": "Europe/Moscow",
        "Turkey Standard Time": "Europe/Istanbul", "Israel Standard Time": "Asia/Jerusalem",
        "South Africa Standard Time": "Africa/Johannesburg", "Egypt Standard Time": "Africa/Cairo",
        "Arabian Standard Time": "Asia/Dubai", "Arab Standard Time": "Asia/Riyadh",
        "Pakistan Standard Time": "Asia/Karachi", "India Standard Time": "Asia/Kolkata",
        "Bangladesh Standard Time": "Asia/Dhaka", "SE Asia Standard Time": "Asia/Bangkok",
        "China Standard Time": "Asia/Shanghai", "Singapore Standard Time": "Asia/Singapore",
        "Taipei Standard Time": "Asia/Taipei", "Tokyo Standard Time": "Asia/Tokyo",
        "Korea Standard Time": "Asia/Seoul", "AUS Eastern Standard Time": "Australia/Sydney",
        "E. Australia Standard Time": "Australia/Brisbane", "Cen. Australia Standard Time": "Australia/Adelaide",
        "W. Australia Standard Time": "Australia/Perth", "New Zealand Standard Time": "Pacific/Auckland",
        "AUS Central Standard Time": "Australia/Darwin", "Tasmania Standard Time": "Australia/Hobart",
        "Aus Central W. Standard Time": "Australia/Eucla", "Lord Howe Standard Time": "Australia/Lord_Howe",
        "Nepal Standard Time": "Asia/Kathmandu", "Sri Lanka Standard Time": "Asia/Colombo",
        "Myanmar Standard Time": "Asia/Yangon", "Afghanistan Standard Time": "Asia/Kabul", "Iran Standard Time": "Asia/Tehran",
        "West Asia Standard Time": "Asia/Tashkent", "Central Asia Standard Time": "Asia/Almaty",
        "Qyzylorda Standard Time": "Asia/Qyzylorda", "Ekaterinburg Standard Time": "Asia/Yekaterinburg",
        "Omsk Standard Time": "Asia/Omsk", "N. Central Asia Standard Time": "Asia/Novosibirsk",
        "Altai Standard Time": "Asia/Barnaul", "Tomsk Standard Time": "Asia/Tomsk",
        "North Asia Standard Time": "Asia/Krasnoyarsk", "W. Mongolia Standard Time": "Asia/Hovd",
        "North Asia East Standard Time": "Asia/Irkutsk", "Ulaanbaatar Standard Time": "Asia/Ulaanbaatar",
        "Malay Peninsula Standard Time": "Asia/Singapore", "Transbaikal Standard Time": "Asia/Chita",
        "Yakutsk Standard Time": "Asia/Yakutsk", "North Korea Standard Time": "Asia/Pyongyang",
        "Vladivostok Standard Time": "Asia/Vladivostok", "West Pacific Standard Time": "Pacific/Port_Moresby",
        "Magadan Standard Time": "Asia/Magadan", "Sakhalin Standard Time": "Asia/Sakhalin",
        "Russia Time Zone 3": "Europe/Samara", "Russia Time Zone 10": "Asia/Srednekolymsk",
        "Russia Time Zone 11": "Asia/Kamchatka", "Bougainville Standard Time": "Pacific/Bougainville",
        "Norfolk Standard Time": "Pacific/Norfolk", "Central Pacific Standard Time": "Pacific/Guadalcanal",
        "Fiji Standard Time": "Pacific/Fiji", "Chatham Islands Standard Time": "Pacific/Chatham",
        "Tonga Standard Time": "Pacific/Tongatapu", "Samoa Standard Time": "Pacific/Apia",
        "Line Islands Standard Time": "Pacific/Kiritimati", "Dateline Standard Time": "Etc/GMT+12",
        "UTC-11": "Etc/GMT+11", "UTC-09": "Etc/GMT+9", "UTC-08": "Etc/GMT+8", "UTC-02": "Etc/GMT+2",
        "UTC+12": "Etc/GMT-12", "UTC+13": "Etc/GMT-13",
        "Aleutian Standard Time": "America/Adak", "Marquesas Standard Time": "Pacific/Marquesas",
        "Yukon Standard Time": "America/Whitehorse", "Pacific Standard Time (Mexico)": "America/Tijuana",
        "Mountain Standard Time (Mexico)": "America/Mazatlan", "Central America Standard Time": "America/Guatemala",
        "Easter Island Standard Time": "Pacific/Easter", "Eastern Standard Time (Mexico)": "America/Cancun",
        "US Eastern Standard Time": "America/Indiana/Indianapolis", "Haiti Standard Time": "America/Port-au-Prince",
        "Cuba Standard Time": "America/Havana", "Turks And Caicos Standard Time": "America/Grand_Turk",
        "Paraguay Standard Time": "America/Asuncion", "Venezuela Standard Time": "America/Caracas",
        "Central Brazilian Standard Time": "America/Cuiaba", "SA Western Standard Time": "America/La_Paz",
        "Pacific SA Standard Time": "America/Santiago", "Tocantins Standard Time": "America/Araguaina",
        "SA Eastern Standard Time": "America/Cayenne", "Greenland Standard Time": "America/Nuuk",
        "Montevideo Standard Time": "America/Montevideo", "Magallanes Standard Time": "America/Punta_Arenas",
        "Saint Pierre Standard Time": "America/Miquelon", "Bahia Standard Time": "America/Bahia",
        "Mid-Atlantic Standard Time": "Etc/GMT+2", "Azores Standard Time": "Atlantic/Azores",
        "Cape Verde Standard Time": "Atlantic/Cape_Verde", "Morocco Standard Time": "Africa/Casablanca",
        "W. Central Africa Standard Time": "Africa/Lagos", "Namibia Standard Time": "Africa/Windhoek",
        "Sao Tome Standard Time": "Africa/Sao_Tome", "Libya Standard Time": "Africa/Tripoli",
        "Sudan Standard Time": "Africa/Khartoum", "South Sudan Standard Time": "Africa/Juba",
        "E. Africa Standard Time": "Africa/Nairobi", "Mauritius Standard Time": "Indian/Mauritius",
        "Kaliningrad Standard Time": "Europe/Kaliningrad", "Belarus Standard Time": "Europe/Minsk",
        "Volgograd Standard Time": "Europe/Volgograd", "Astrakhan Standard Time": "Europe/Astrakhan",
        "Saratov Standard Time": "Europe/Saratov", "Jordan Standard Time": "Asia/Amman",
        "Middle East Standard Time": "Asia/Beirut", "Syria Standard Time": "Asia/Damascus",
        "West Bank Standard Time": "Asia/Hebron", "Arabic Standard Time": "Asia/Baghdad",
        "Azerbaijan Standard Time": "Asia/Baku", "Georgian Standard Time": "Asia/Tbilisi",
        "Caucasus Standard Time": "Asia/Yerevan",
    ]
}
