import Foundation

/// What a message itself says, read with plain rules so it works the same
/// on every device, with or without Apple Intelligence. These are the
/// content and thread signals Gmail's Priority Inbox leans on (does it ask
/// something of you, did you reply, is there a date attached), not a score.
public enum MailSignals {
    /// The writer's own words, without the quoted history below them.
    public static func ownText(_ body: String) -> String {
        var kept: [Substring] = []
        for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(">") { continue }
            if trimmed.range(of: #"^On .+ wrote:$"#, options: .regularExpression) != nil { break }
            if trimmed.hasPrefix("-----Original Message-----") || trimmed.hasPrefix("---------- Forwarded message") { break }
            kept.append(line)
        }
        return kept.joined(separator: "\n")
    }

    /// Phrases that ask the reader for something even without a question
    /// mark ("Let me know", "Please confirm").
    private static let requestPattern = #"(?i)\b(can|could|would|will) you\b|\blet me know\b|\bplease (confirm|advise|review|send|reply|respond|approve|sign|share|rsvp|let)\b|\bwhat do you think\b|\byour thoughts\b|\bany (update|news)\b|\bare you (free|available|around)\b|\bwhen (works|would work|are you)\b|\bget back to me\b|\blooking forward to (hearing|your reply)\b|\brsvp\b"#

    /// Whether the writer asks the reader something: a real question or a
    /// request. Links are removed first, since their query strings carry
    /// question marks.
    public static func asksSomething(_ text: String) -> Bool {
        let own = ownText(text).replacingOccurrences(of: #"https?://\S+"#, with: "", options: .regularExpression)
        if own.range(of: #"[\p{L}\p{N})"'’]\s?\?"#, options: .regularExpression) != nil { return true }
        return own.range(of: requestPattern, options: .regularExpression) != nil
    }

    /// Words that make a date a deadline when they come right before it:
    /// "due Friday", "by Oct 3", "RSVP by the 12th". Deliberately tight;
    /// a date on its own ("Posted Sep 3") is not a deadline.
    private static let deadlineLeadIn = #"(?i)\b(due|by|before|until|no later than|deadline(\s+is)?:?|expires?|expiring|rsvp(\s+by)?|respond by|reply by|closes?)\s*(on\s+|the\s+)?$"#

    /// The earliest upcoming deadline the message names, within `horizon`.
    /// Relative dates ("by Friday") resolve against now, so this is meant
    /// for mail read as it arrives.
    public static func deadline(in text: String, now: Date = .now, horizon: TimeInterval = 45 * 86_400) -> Date? {
        let own = String(ownText(text).prefix(4_000))
        guard !own.isEmpty,
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else { return nil }
        let ns = own as NSString
        var earliest: Date?
        for match in detector.matches(in: own, range: NSRange(location: 0, length: ns.length)) {
            guard let date = match.date,
                  date > now.addingTimeInterval(-3_600), date < now.addingTimeInterval(horizon) else { continue }
            let start = max(0, match.range.location - 32)
            let before = ns.substring(with: NSRange(location: start, length: match.range.location - start))
            guard before.range(of: deadlineLeadIn, options: .regularExpression) != nil else { continue }
            if earliest.map({ date < $0 }) ?? true { earliest = date }
        }
        return earliest
    }

    /// For automated mail about an appointment, bill or signature, any date
    /// in the next few days is the one that matters, however it's worded:
    /// "Your appointment is tomorrow at 9:00 AM" has no "by" or "due" in
    /// it. Promotions never get here (see `InboxClassifier`).
    public static func timeSensitiveDate(in text: String, now: Date = .now, within: TimeInterval = 3 * 86_400) -> Date? {
        if let due = deadline(in: text, now: now, horizon: within) { return due }
        guard isObligation(text),
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else { return nil }
        let own = String(ownText(text).prefix(4_000))
        return detector.matches(in: own, range: NSRange(location: 0, length: (own as NSString).length))
            .compactMap(\.date)
            .filter { $0 > now.addingTimeInterval(-3_600) && $0 < now.addingTimeInterval(within) }
            .min()
    }

    /// Automated mail that carries a real obligation for this person: a
    /// bill, a signature, a renewal, an appointment. Only ever combined
    /// with a detected deadline, and never applied to promotions.
    /// Something the reader has to do, not just something that will
    /// happen: "payment due", "sign by", "your appointment", "verify".
    /// A welcome, receipt or autopay notice ("will be charged
    /// automatically", "thanks for your payment") is information, never an
    /// obligation, however many dates it names.
    ///
    /// Only the opening counts: a real reminder says what's due up top,
    /// while "pay by the due date each month" in a sale's fine print or
    /// "updates due on job numbers" in a news story said nothing to the
    /// reader, yet brought both into Needs You.
    public static func isObligation(_ text: String) -> Bool {
        let lower = String(text.prefix(obligationOpening)).lowercased()
        let action = #"\b(payment (is )?(due|failed|declined|overdue)|past due|amount due|due (date|on|by)|pay (by|now|your)|bill (is )?(due|ready)|balance (is )?due|invoice (is )?due|sign (by|the|your|here)|signature (requested|required|needed)|please sign|verify (your|by)|action (is )?required|expires? (on|in|soon|today|tomorrow)|expiring|renew (by|before|now)|appointment|check-in|reservation|rsvp|deadline)\b"#
        // Marketing urgency is a sale, not an obligation: "LAST CHANCE,
        // your rewards points expire tomorrow".
        let notice = #"\b(last chance|don.?t miss|limited time|(points|rewards?) (expire|are expiring)|ends (today|tonight|soon)|\d+% off|will be (charged|billed|renewed) (automatically|monthly|annually)|(automatically|auto-?) ?(charged|billed|renews?)|thank(s| you) for (your )?(payment|order|purchase)|payment (received|confirmed|successful)|receipt|welcome to)\b"#
        guard lower.range(of: action, options: .regularExpression) != nil else { return false }
        // An appointment or reservation reminder stays even if it thanks you.
        let reminder = lower.range(of: #"\b(appointment|reservation|check-in|rsvp)\b"#, options: .regularExpression) != nil
        return reminder || lower.range(of: notice, options: .regularExpression) == nil
    }

    /// About something that happens on a day (an appointment, a class, a
    /// flight), not something to get done by one (a bill, a signature).
    /// Once that day is over there's nothing left to do: the email leaves
    /// Needs You by itself, the way Gmail's "Happening soon" cards drop off
    /// after the event. A missed payment is different, and stays overdue.
    public static func isEvent(_ text: String) -> Bool {
        let lower = text.lowercased()
        let event = #"\b(appointments?|reservations?|check-?in|meeting|class(es)?|session|visit|interview|webinar|flight|booking|lesson|tour|consultation|exam|screening|event|concert|show(time)?|game|ceremony)\b"#
        let task = #"\b(payment|pay (by|now|your)|bill|invoice|balance|amount due|past due|sign(ature)?|renew|expir|submit|application|form)\b"#
        return lower.range(of: event, options: .regularExpression) != nil && lower.range(of: task, options: .regularExpression) == nil
    }

    /// How much of an email's start states its obligation, in characters:
    /// the subject and the first few sentences.
    static let obligationOpening = 600

    /// Whether anyone you wrote to is a person rather than a no-reply
    /// system address: waiting on `noreply@` makes no sense.
    public static func hasPersonRecipient(_ recipients: [String], account: String) -> Bool {
        recipients.contains { address in
            let lower = address.lowercased()
            return lower != account.lowercased()
                && lower.range(of: Correspondence.automatedLocalPart, options: .regularExpression) == nil
        }
    }
}

/// Something the reader could put on their calendar: an appointment, a
/// reservation, a meeting, a flight, an interview.
public struct EventSuggestion: Equatable, Sendable {
    public let title: String
    public let start: Date
    /// When the email says (a range, the booking data or an invite);
    /// otherwise an hour after `start`.
    public let end: Date?
    public let location: String?
    /// The confirmation or reservation number, when the email gives one.
    public let confirmation: String?

    public init(title: String, start: Date, end: Date? = nil, location: String?, confirmation: String? = nil) {
        self.title = title
        self.start = start
        self.end = end
        self.location = location
        self.confirmation = confirmation
    }
}

/// Finds the event an email is about, most reliable source first, the
/// order Mail and Gmail use:
/// 1. booking data the sender embedded for mail apps (schema.org JSON-LD:
///    Event, EventReservation, FlightReservation, LodgingReservation,
///    FoodEstablishmentReservation), exact to the minute;
/// 2. a calendar invite (.ics);
/// 3. the wording, with Apple's date and address detectors.
public enum EventFinder {
    public static func event(text: String, html: String?, subject: String, receivedAt: Date,
                             now: Date = .now) -> EventSuggestion? {
        if let html, let structured = fromStructuredData(html, now: now) { return structured }
        return fromWording(text, subject: subject, receivedAt: receivedAt, now: now)
    }

    // MARK: Structured data

    public static func fromStructuredData(_ html: String, now: Date = .now) -> EventSuggestion? {
        let pattern = #"(?is)<script[^>]*type\s*=\s*["']application/ld\+json["'][^>]*>(.*?)</script>"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = html as NSString
        var found: [EventSuggestion] = []
        for match in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let json = ns.substring(with: match.range(at: 1))
            guard let data = json.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) else { continue }
            let items = (object as? [[String: Any]]) ?? [(object as? [String: Any])].compactMap { $0 }
            for item in items.flatMap(flattenGraph) {
                if let event = suggestion(from: item), event.start > now.addingTimeInterval(-3_600) { found.append(event) }
            }
        }
        return found.min { $0.start < $1.start }
    }

    private static func flattenGraph(_ item: [String: Any]) -> [[String: Any]] {
        if let graph = item["@graph"] as? [[String: Any]] { return graph }
        return [item]
    }

    private static func suggestion(from item: [String: Any]) -> EventSuggestion? {
        let type = (item["@type"] as? String) ?? ""
        let reservationFor = item["reservationFor"] as? [String: Any]
        let subject = reservationFor ?? item
        let confirmation = item["reservationNumber"] as? String ?? item["confirmationNumber"] as? String
        switch type {
        case "FlightReservation":
            guard let flight = reservationFor,
                  let departs = date(flight["departureTime"]) else { return nil }
            let airline = (flight["airline"] as? [String: Any])?["name"] as? String
                ?? (flight["airline"] as? [String: Any])?["iataCode"] as? String ?? ""
            let number = flight["flightNumber"] as? String ?? ""
            let from = (flight["departureAirport"] as? [String: Any])?["iataCode"] as? String
            let to = (flight["arrivalAirport"] as? [String: Any])?["iataCode"] as? String
            let route = [from, to].compactMap { $0 }.joined(separator: " → ")
            let title = ["Flight", [airline, number].filter { !$0.isEmpty }.joined(separator: " "), route]
                .filter { !$0.isEmpty }.joined(separator: " ")
            let airport = (flight["departureAirport"] as? [String: Any])?["name"] as? String
            return EventSuggestion(title: title, start: departs, end: date(flight["arrivalTime"]),
                                   location: airport, confirmation: confirmation)
        case "LodgingReservation":
            guard let checkin = date(item["checkinTime"] ?? item["checkinDate"]) else { return nil }
            let name = (reservationFor?["name"] as? String) ?? "Hotel"
            return EventSuggestion(title: "Stay at \(name)", start: checkin, end: date(item["checkoutTime"] ?? item["checkoutDate"]),
                                   location: place(reservationFor?["address"]) ?? place(reservationFor),
                                   confirmation: confirmation)
        case "FoodEstablishmentReservation":
            guard let time = date(item["startTime"] ?? item["startDate"]) else { return nil }
            let name = (reservationFor?["name"] as? String) ?? "Reservation"
            return EventSuggestion(title: name, start: time, end: date(item["endTime"]),
                                   location: place(reservationFor?["address"]) ?? place(reservationFor),
                                   confirmation: confirmation)
        default:
            // Event, EventReservation and other reservations with a start.
            guard type.hasSuffix("Event") || type.hasSuffix("Reservation"),
                  let start = date(subject["startDate"] ?? item["startTime"] ?? item["startDate"]) else { return nil }
            let name = subject["name"] as? String ?? "Event"
            return EventSuggestion(title: name, start: start, end: date(subject["endDate"] ?? item["endTime"]),
                                   location: place(subject["location"]), confirmation: confirmation)
        }
    }

    private static func date(_ value: Any?) -> Date? {
        guard let string = value as? String else { return nil }
        let full = ISO8601DateFormatter()
        full.formatOptions = [.withInternetDateTime]
        if let date = full.date(from: string) { return date }
        full.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = full.date(from: string) { return date }
        // "2026-09-28T14:45:00" with no offset: the reader's own time zone.
        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd"] {
            local.dateFormat = format
            if let date = local.date(from: string) { return date }
        }
        return nil
    }

    private static func place(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        guard let object = value as? [String: Any] else { return nil }
        if let address = object["address"] { return place(address) ?? object["name"] as? String }
        let parts = ["name", "streetAddress", "addressLocality", "addressRegion", "postalCode"]
            .compactMap { object[$0] as? String }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    // MARK: Calendar invites

    /// The first event in an .ics invite, times in their stated zone.
    public static func fromInvite(_ ics: String, now: Date = .now) -> EventSuggestion? {
        let unfolded = ics.replacingOccurrences(of: "\r\n ", with: "").replacingOccurrences(of: "\n ", with: "")
        guard let block = unfolded.range(of: "BEGIN:VEVENT") else { return nil }
        var fields: [String: (value: String, params: String)] = [:]
        for line in unfolded[block.upperBound...].split(whereSeparator: \.isNewline) {
            if line.hasPrefix("END:VEVENT") { break }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon]
            let name = String(key.split(separator: ";").first ?? "")
            if fields[name] == nil { fields[name] = (String(line[line.index(after: colon)...]), String(key)) }
        }
        func icsDate(_ field: (value: String, params: String)?) -> Date? {
            guard let field else { return nil }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            if field.value.hasSuffix("Z") {
                formatter.timeZone = TimeZone(identifier: "UTC")
                formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
            } else if let tz = field.params.range(of: "TZID=") {
                formatter.timeZone = TimeZone(identifier: String(field.params[tz.upperBound...]).components(separatedBy: ";")[0])
                formatter.dateFormat = "yyyyMMdd'T'HHmmss"
            } else {
                formatter.dateFormat = field.value.count == 8 ? "yyyyMMdd" : "yyyyMMdd'T'HHmmss"
            }
            return formatter.date(from: field.value)
        }
        guard let start = icsDate(fields["DTSTART"]), start > now.addingTimeInterval(-3_600) else { return nil }
        func text(_ key: String) -> String? {
            fields[key]?.value.replacingOccurrences(of: "\\,", with: ",").replacingOccurrences(of: "\\n", with: " ")
        }
        return EventSuggestion(title: text("SUMMARY") ?? "Event", start: start, end: icsDate(fields["DTEND"]),
                               location: text("LOCATION").flatMap { $0.isEmpty ? nil : $0 })
    }

    // MARK: Wording

    private static let eventWords = #"appointment|reservation|booking|meeting|interview|flight|check-in|event|dinner|lunch|call|webinar|session|visit|consultation|class|concert|show"#

    /// The earliest upcoming date with a clock time in the next three
    /// months. Relative days ("tomorrow", "Friday") resolve against today,
    /// so they only count in mail that arrived today; explicit dates
    /// always do. A range ("2:45–3:30 PM") sets the end.
    public static func fromWording(_ text: String, subject: String, receivedAt: Date, now: Date = .now) -> EventSuggestion? {
        let own = String(MailSignals.ownText(text).prefix(6_000))
        let all = subject + "\n" + own
        guard all.range(of: "(?i)\\b(" + eventWords + ")\\b", options: .regularExpression) != nil,
              let dates = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else { return nil }
        let arrivedToday = Calendar.current.isDate(receivedAt, inSameDayAs: now)
        let ns = own as NSString
        let calendar = Calendar.current
        // Each date the detector finds is a day, a time, or both. A time on
        // its own ("doors open 19:15", "7.15pm") comes back as today at that
        // time, so a meeting on Thursday the 15th showed as today at 19:15.
        struct Found { let date: Date; let duration: TimeInterval; let hasTime: Bool; let hasDay: Bool }
        let found = dates.matches(in: own, range: NSRange(location: 0, length: ns.length)).compactMap { match -> Found? in
            guard let date = match.date else { return nil }
            let phrase = ns.substring(with: match.range).lowercased()
            let hasTime = phrase.range(of: #"\d:\d\d|\d[.:]\d\d\s?(am|pm)\b|\d\s?(am|pm)\b|noon"#, options: .regularExpression) != nil
            // A day: a weekday or month name, a numeric date (not "7.15pm"),
            // or today/tomorrow.
            // In any language: a time alone comes back as today (or
            // tomorrow, once it's passed), so a date on any other day means
            // the phrase named one.
            let dayOffset = calendar.dateComponents([.day], from: calendar.startOfDay(for: now),
                                                    to: calendar.startOfDay(for: date)).day ?? 0
            let hasDay = dayOffset > 1 || dayOffset < 0
                || phrase.range(of: #"\b(mon|tue|wed|thu|fri|sat|sun)[a-z]*\b|\b(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\b|\b\d{1,4}[/-]\d{1,2}\b|\b\d{1,2}\.\d{1,2}\.\d{2,4}\b|\b(today|tonight|tomorrow)\b"#,
                                options: .regularExpression) != nil
            // "Tomorrow" in an email from days ago isn't tomorrow now.
            let isRelative = phrase.range(of: #"\b(today|tonight|tomorrow)\b"#, options: .regularExpression) != nil
            if isRelative, !arrivedToday { return nil }
            return Found(date: date, duration: match.duration, hasTime: hasTime, hasDay: hasDay)
        }
        let window = { (date: Date) in date > now && date < now.addingTimeInterval(92 * 86_400) }
        // Day and time together.
        var timed = found.filter { $0.hasTime && $0.hasDay && window($0.date) }.map { ($0.date, $0.duration) }
        // Day in one place, time in another ("Thursday 15 October … from
        // 19:15"): put together, as Mail does.
        if timed.isEmpty, let day = found.filter({ $0.hasDay && !$0.hasTime }).map(\.date)
            .filter({ calendar.startOfDay(for: $0) >= calendar.startOfDay(for: now) && $0 < now.addingTimeInterval(92 * 86_400) })
            .min(), let time = found.first(where: { $0.hasTime && !$0.hasDay }) {
            let clock = calendar.dateComponents([.hour, .minute], from: time.date)
            if let combined = calendar.date(bySettingHour: clock.hour ?? 0, minute: clock.minute ?? 0, second: 0, of: day),
               window(combined) {
                timed = [(combined, time.duration)]
            }
        }
        // A time alone means today only in mail that came today.
        if timed.isEmpty, arrivedToday {
            timed = found.filter { $0.hasTime && !$0.hasDay && window($0.date) }.map { ($0.date, $0.duration) }
        }
        guard let (start, duration) = timed.min(by: { $0.0 < $1.0 }) else { return nil }

        var location: String?
        if let addresses = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.address.rawValue),
           let match = addresses.firstMatch(in: own, range: NSRange(location: 0, length: ns.length)) {
            location = ns.substring(with: match.range)
                .replacingOccurrences(of: #"\s*\n\s*"#, with: ", ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var title = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        // A capitalised name right before the event word ("Labcorp
        // appointment", "Delta flight"); the event word in any case.
        let named = try? NSRegularExpression(pattern: "\\b([A-Z][\\w&'.-]*)\\s+(?i:(" + eventWords + "))\\b")
        let skip: Set<String> = ["your", "the", "our", "this", "an", "a", "upcoming", "next", "for", "of", "my", "new"]
        for match in named?.matches(in: all, range: NSRange(location: 0, length: (all as NSString).length)) ?? [] {
            let name = (all as NSString).substring(with: match.range(at: 1))
            guard !skip.contains(name.lowercased()) else { continue }
            let kind = (all as NSString).substring(with: match.range(at: 2))
            title = name + " " + kind.prefix(1).uppercased() + kind.dropFirst().lowercased()
            break
        }
        let confirmation = all.firstMatch(of: /(?i)confirmation(?:\s+(?:number|code|#))?\s*[:#]?\s*([A-Z0-9-]{5,})/).map { String($0.1) }
        return EventSuggestion(title: title, start: start, end: duration > 0 ? start.addingTimeInterval(duration) : nil,
                               location: location, confirmation: confirmation)
    }
}
