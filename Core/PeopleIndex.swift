import Foundation

/// Someone you correspond with, as Corres knows them from your own mail.
public struct Person: Codable, Hashable, Sendable, Identifiable {
    /// Lowercased.
    public let email: String
    /// As they sign or as you addressed them; empty when only the address
    /// is known.
    public var name: String
    /// Messages you sent them (To or Cc).
    public var sent: Int
    /// Messages they sent you.
    public var received: Int
    public var lastContact: Date
    public var id: String { email }

    /// "Sara Wiltshire", or "Sara Wiltshire" from sara.wiltshire@…; a
    /// directory's "Hoare, Olivia" reads "Olivia Hoare".
    public var displayName: String {
        guard !name.isEmpty else { return Correspondence.name(fromAddress: email) }
        return Self.readable(name)
    }

    /// A display name as people say it: a directory's "Hoare, Olivia" or
    /// Outlook's "Manzo, Goretty@EDD" reads "Olivia Hoare", "Goretty
    /// Manzo". "Acme, Inc." and "Smith, Jones & Co" are left alone.
    public static func readable(_ name: String) -> String {
        let name = calmed(name)
        let parts = name.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty,
              parts[0].split(separator: " ").count <= 2, !parts[0].contains("@") else { return name }
        // "Goretty@EDD", "Goretty (EDD)": the department tag goes.
        var given = parts[1]
        if let cut = given.firstIndex(where: { $0 == "@" || $0 == "(" }) {
            given = given[..<cut].trimmingCharacters(in: .whitespaces)
        }
        let companySuffixes: Set<String> = ["inc", "llc", "ltd", "co", "corp", "gmbh", "plc", "llp", "sa", "ag", "bv", "pty", "limited", "jr", "sr", "ii", "iii", "md", "phd"]
        guard !given.isEmpty, !given.contains("&"), !given.contains(where: \.isNumber),
              !companySuffixes.contains(given.lowercased().trimmingCharacters(in: .punctuationCharacters)),
              given.split(separator: " ").count <= 3 else { return name }
        return given + " " + parts[0]
    }

    /// A name for mail sent with only an address: a person's address reads
    /// as them ("ant.wilson@supabase.com" is "Ant Wilson"), a system's as
    /// its company ("no-reply@vitu.com" is "Vitu"). Gmail and Mail show
    /// the bare address.
    public static func name(forAddress email: String) -> String {
        let lower = email.lowercased()
        let parts = lower.split(separator: "@")
        guard parts.count == 2 else { return email }
        let local = String(parts[0]), domain = String(parts[1])
        let localWords = local.split(whereSeparator: { ".-_+".contains($0) }).filter { !$0.allSatisfy(\.isNumber) }
        let looksPersonal = !PeopleIndex.isAutomated(lower) && (2...3).contains(localWords.count)
            && localWords.allSatisfy { $0.count >= 2 && $0.allSatisfy(\.isLetter) }
        if looksPersonal {
            return localWords.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
        }
        // The company: "mail.doordash.com" → "Doordash", "council.gov.uk" → "Council".
        let labels = domain.split(separator: ".").map(String.init)
        guard labels.count >= 2 else { return email }
        let secondLevel: Set<String> = ["co", "com", "org", "gov", "ac", "net", "edu", "ltd", "plc", "nhs"]
        let organization = labels.count >= 3 && secondLevel.contains(labels[labels.count - 2]) ? labels[labels.count - 3] : labels[labels.count - 2]
        // A personal mailbox that isn't plainly a name ("tamkinanwar7@
        // gmail.com"): the address says it best.
        guard organization.count >= 2, !["gmail", "googlemail", "outlook", "hotmail", "yahoo", "icloud", "me", "aol", "proton", "protonmail", "live"].contains(organization) else {
            return email
        }
        return organization.prefix(1).uppercased() + organization.dropFirst()
    }

    /// A name shouted in capitals reads as a name: "TAMKIN NURUL ANWAR" is
    /// "Tamkin Nurul Anwar", "LABCORP" is "Labcorp", "BANK OF AMERICA" is
    /// "Bank of America". Acronyms stay: no vowel ("CVS", "BMW", "USPS"),
    /// a digit or "&" ("AT&T", "3M"), or a single short word ("NASA").
    /// Mixed case is left exactly as written ("McDonald", "iCloud").
    static func calmed(_ name: String) -> String {
        let letters = name.filter(\.isLetter)
        guard letters.count >= 4, letters != letters.lowercased() else { return name }
        let words = name.split(separator: " ", omittingEmptySubsequences: false)
        // "TAMKIN NURUL ANWAR via TestFlight": a run of shouted words in an
        // otherwise written name. Only words in capitals change.
        func isShouted(_ word: Substring) -> Bool {
            let wordLetters = word.filter(\.isLetter)
            return wordLetters.count >= 3 && wordLetters == wordLetters.uppercased() && wordLetters != wordLetters.lowercased()
        }
        if letters != letters.uppercased() {
            guard words.filter(isShouted).count >= 2 else { return name }
        }
        let lettered = words.filter { $0.contains(where: \.isLetter) }
        if lettered.count == 1, letters.count <= 4 { return name }
        let small: Set<String> = ["of", "and", "the", "for", "at", "in", "on", "de", "la", "le", "du", "van", "von", "da", "di", "bin", "binti"]
        let vowels = Set("AEIOUYÀÁÂÄÈÉÊËÌÍÎÏÒÓÔÖÙÚÛÜ")
        // Common ones with a vowel in them.
        let acronyms: Set<String> = ["USPS", "UPS", "USA", "USAA", "US", "UK", "EU", "UN", "UAE", "IRS", "AARP", "NASA", "UCLA", "IBM", "AI", "IT",
                                     "ESPN", "NFL", "NBA", "MLB", "NHS", "BBC", "UBS", "AIG", "AOL", "HSBC", "IEEE", "LLC", "INC", "LTD", "PLC", "CEO", "VIP", "EA", "BRAC", "BUET", "DU"]
        var index = 0
        return words.map { word -> String in
            defer { if word.contains(where: \.isLetter) { index += 1 } }
            let text = String(word)
            guard text.contains(where: \.isLetter), text == text.uppercased() else { return text }
            if text.contains(where: { $0.isNumber || $0 == "&" }) || !text.contains(where: { vowels.contains($0) })
                || acronyms.contains(text.trimmingCharacters(in: .punctuationCharacters)) { return text }
            let lower = text.lowercased()
            if index > 0, small.contains(lower) { return lower }
            // "O'BRIEN" → "O'Brien", "JEAN-LUC" → "Jean-Luc".
            var result = ""
            var capitalizeNext = true
            for character in lower {
                result += capitalizeNext ? character.uppercased() : String(character)
                capitalizeNext = character == "-" || character == "'" || character == "’"
            }
            return result
        }.joined(separator: " ")
    }

    /// "Sara Wiltshire <sara.wiltshire@example.com>", for a To field.
    public var address: String {
        name.isEmpty ? email : "\(name.contains(",") ? "\"\(name)\"" : name) <\(email)>"
    }
}

extension Person {
    /// The name to call someone by, in a greeting or on the Lock Screen:
    /// "Maya" from "Maya Patel" or "Patel, Maya", and "Rahim" from "Md.
    /// Rahim Uddin", "Mohammad Rahim" or "Dr. Rahim Khan": titles and the
    /// name prefixes common in Bangladesh, India and Pakistan are skipped,
    /// unless nothing else is left. A Chinese, Japanese or Korean name
    /// comes family name first, and its given name alone is too familiar
    /// for a greeting, so it stays whole: "王伟", "田中 太郎", "김민준".
    public static func firstName(of name: String) -> String {
        let name = readable(name).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return "" }
        if name.unicodeScalars.contains(where: { scalar in
            [0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xAC00...0xD7A3].contains { $0.contains(scalar.value) }
        }) { return name }
        let words = name.split(separator: " ").map(String.init)
        let given = words.drop { namePrefixes.contains($0.lowercased().trimmingCharacters(in: .punctuationCharacters)) }
        return given.first ?? words.first ?? name
    }

    /// Titles and name prefixes that come before the name someone goes by.
    static let namePrefixes: Set<String> = [
        "mr", "mrs", "ms", "miss", "mx", "dr", "prof", "engr", "eng", "adv", "md", "mst", "mosammat", "mohammad",
        "mohammed", "muhammad", "muhammed", "mohamed", "mohd", "syed", "sayed", "sk", "shri", "sri", "smt",
    ]
}

/// Everyone you correspond with, offered the way people expect from Mail
/// and Gmail: type "sar" and Sara is there, because you write to her. Built
/// on this iPhone from your own mail (who you've written to counts most,
/// then who writes to you), never from a server.
///
/// Ranked by how much and how recently you've been in touch, so the Sara
/// you email weekly comes before a Sara who wrote once in March. Automated
/// senders (no-reply, notifications) are left out unless you've written
/// to them yourself.
public struct PeopleIndex: Codable, Sendable, Equatable {
    public private(set) var people: [String: Person] = [:]

    public init() {}

    /// Leaves these addresses out (people you said not to suggest).
    public mutating func remove(_ emails: Set<String>) {
        for email in emails { people[email] = nil }
    }

    // MARK: Recording

    /// One address field's entries, as written: "Sara <s@x.com>, b@y.com".
    /// Splits on top-level commas only (`"Doe, Jane" <jane@x.com>` is one).
    public static func entries(in field: String) -> [String] {
        var entries: [String] = []
        var current = ""
        var inQuotes = false
        var inAngle = false
        for character in field {
            if character == "\"" { inQuotes.toggle() }
            if character == "<" { inAngle = true }
            if character == ">" { inAngle = false }
            if (character == "," || character == ";") && !inQuotes && !inAngle {
                entries.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        entries.append(current)
        return entries.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// A To or Cc field as Compose shows it: the finished recipients (the
    /// chips) and what's still being typed after the last comma, exactly
    /// as typed.
    public static func split(_ field: String) -> (finished: [String], typing: String) {
        var inQuotes = false
        var inAngle = false
        var lastSeparator: String.Index?
        for index in field.indices {
            switch field[index] {
            case "\"": inQuotes.toggle()
            case "<": inAngle = true
            case ">": inAngle = false
            case ",", ";":
                if !inQuotes && !inAngle { lastSeparator = index }
            default: break
            }
        }
        guard let lastSeparator else { return ([], field.drop(while: \.isWhitespace).description) }
        let typing = field[field.index(after: lastSeparator)...].drop(while: \.isWhitespace)
        return (entries(in: String(field[..<lastSeparator])), String(typing))
    }

    /// "Sara Wiltshire" <Sara@Example.com> → (Sara Wiltshire, sara@example.com).
    /// Nil when there's no address in it.
    public static func parse(_ entry: String) -> (name: String, email: String)? {
        var name = ""
        var email = entry
        if let open = entry.lastIndex(of: "<"), let close = entry.lastIndex(of: ">"), open < close {
            email = String(entry[entry.index(after: open)..<close])
            name = String(entry[..<open])
        }
        email = email.trimmingCharacters(in: .whitespaces).lowercased()
        name = name.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\"'")))
        guard isAddress(email) else { return nil }
        // A "name" that is just the address again says nothing.
        if name.lowercased() == email || name.contains("@") { name = "" }
        return (name, email)
    }

    public static func isAddress(_ text: String) -> Bool {
        text.patternRange(#"^[^\s@<>,;]+@[^\s@<>,;]+\.[^\s@<>,;]{2,}$"#) != nil
    }

    /// Addresses that are never a person to write to.
    public static func isAutomated(_ email: String) -> Bool {
        email.patternRange(#"(?i)^([^@]*[-_.])?(no[-_.]?reply|do-?not-?reply)@|^(no-?reply|do-?not-?reply|donotreply|notifications?|alerts?|mailer-daemon|postmaster|bounces?|news(letter)?|marketing|info|support|hello|team|updates?|account|accounts|billing|receipts?|orders?|shipping|security)([-_.+].*)?@|@(.*\.)?(bounce|email|mail|e|em|news|notifications?|reply)\.[^.]+\.[^.]+$"#) != nil
    }

    /// Mail you "sent" that went to a machine, not a person: an
    /// unsubscribe request (Corres sends these for you), a bounce or
    /// list address.
    public static func isOptOut(_ email: String, subject: String = "") -> Bool {
        email.patternRange(#"(?i)(unsub|bounce|opt-?out|list-manage|^leave-|^remove-|^reply\+)"#) != nil
            || subject.patternRange(#"(?i)^\s*(unsubscribe|opt.?out)\b"#) != nil
    }

    /// A desk rather than a person: support@, a Zendesk queue, hr@. Still
    /// suggested when you type it, just not ahead of people before you do.
    public static func isRole(_ person: Person) -> Bool {
        let local = person.email.split(separator: "@").first.map(String.init) ?? person.email
        return local.patternRange(#"(?i)^(support|help|helpdesk|service|services|customer.?service|customer.?care|cs|cx|care|info|contact|hello|team|admin|office|hr|careers|jobs|recruiting|talent|intern\w*|evaluations?|finance|billing|accounts?|sales|ops|operations|orders?|returns|reservations?|bookings?|enquiries|inquiries|feedback|press|media)([-_.+0-9].*)?$"#) != nil
            || person.email.patternRange(#"(?i)@(.*\.)?(zendesk|freshdesk|helpscout|intercom-mail|kustomer|gorgias)\."#) != nil
            || person.name.contains(where: \.isNumber)
            // "Intake Coordinator", "Evaluations AUTA", "BIMMER TECH".
            // "HighGainProject" is read as "High Gain Project".
            || person.name.replacingPattern(#"([a-z])([A-Z])"#, with: "$1 $2")
                .patternRange(#"(?i)\b(coordinator|team|support|services?|project|tech|evaluations?|department|dept|office|desk|admissions|registrar|bursar|finance|payroll|accounts|recruit\w*|careers|center|centre|group|store|shop|customer|help|info|admin|billing|notifications?|operations|inc|llc|ltd)\b"#) != nil
            // "TASTeam", "ITSupport": a desk word run on at the end.
            || (!person.name.contains(" ") && person.name.patternRange(#"(?i)(team|support|desk|services?|office|admin|helpdesk|notifications?)$"#) != nil
                && person.name.count > 5)
            || (person.name.count > 3 && person.name == person.name.uppercased() && person.name.contains(where: \.isLetter) && person.name.contains(" "))
    }

    /// Someone you sent mail to.
    public mutating func recordSent(to entry: String, at date: Date, subject: String = "") {
        guard let (name, email) = Self.parse(entry), !Self.isOptOut(email, subject: subject) else { return }
        var person = people[email] ?? Person(email: email, name: "", sent: 0, received: 0, lastContact: date)
        person.sent += 1
        // How you addressed them wins over a guess.
        if !name.isEmpty, person.name.isEmpty || person.received == 0 { person.name = name }
        person.lastContact = max(person.lastContact, date)
        people[email] = person
    }

    /// Someone who wrote to you. Automated senders aren't people.
    public mutating func recordReceived(from name: String, email: String, at date: Date, isAutomated: Bool) {
        let email = email.lowercased()
        guard Self.isAddress(email), !isAutomated || people[email] != nil, !Self.isAutomated(email) || people[email] != nil
        else { return }
        var person = people[email] ?? Person(email: email, name: "", sent: 0, received: 0, lastContact: date)
        person.received += 1
        // As they sign their own mail.
        if !name.isEmpty, !name.contains("@") { person.name = name }
        person.lastContact = max(person.lastContact, date)
        people[email] = person
    }

    /// Everyone in synced mail: senders of mail to you, recipients of mail
    /// from you. `accounts` are your own addresses, never suggested.
    public static func from(_ threads: [Correspondence], accounts: Set<String>) -> PeopleIndex {
        var index = PeopleIndex()
        index.add(threads, accounts: accounts)
        return index
    }

    public mutating func add(_ threads: [Correspondence], accounts: Set<String>) {
        for thread in threads where thread.id.account != "sample" {
            if thread.isFromAccountOwner {
                // By address: "Tamkin <me@x.com>" is still you.
                for address in thread.toRecipients + thread.ccRecipients
                where !accounts.contains(address.lowercased()) && !accounts.contains(Correspondence.bareAddress(address)) {
                    recordSent(to: address, at: thread.lastSentAt ?? thread.receivedAt, subject: thread.subject)
                }
            } else if let email = thread.senderEmail, !accounts.contains(email.lowercased()) {
                recordReceived(from: thread.sender, email: email, at: thread.receivedAt, isAutomated: thread.looksAutomated)
            }
        }
    }

    /// Someone in your Contacts: offered by name even before any mail.
    public mutating func recordContact(name: String, email: String) {
        let email = email.lowercased()
        guard Self.isAddress(email) else { return }
        var person = people[email] ?? Person(email: email, name: "", sent: 0, received: 0, lastContact: .distantPast)
        if person.name.isEmpty || (person.sent == 0 && person.received == 0) { person.name = name }
        people[email] = person
    }

    /// Combines two indexes, e.g. synced mail with the Sent history.
    public mutating func merge(_ other: PeopleIndex) {
        for (email, theirs) in other.people {
            guard var mine = people[email] else { people[email] = theirs; continue }
            mine.sent = max(mine.sent, theirs.sent)
            mine.received = max(mine.received, theirs.received)
            mine.lastContact = max(mine.lastContact, theirs.lastContact)
            if mine.name.isEmpty { mine.name = theirs.name }
            people[email] = mine
        }
    }

    // MARK: Suggesting

    /// Who to offer before anything is typed, as Gmail does: the people
    /// you're in touch with now. Someone you write to counts for far more
    /// than someone who writes to you, and this month far more than last
    /// year; a sender who has never heard back from you only after a few
    /// emails. Names read one way ("Hoare, Olivia" is "Olivia Hoare"), but
    /// two addresses are never merged by name: two people can share one,
    /// so Compose tells same-named people apart by their address.
    ///
    /// People come first: a support desk you emailed about a ticket ranks
    /// well below a friend, and your own other addresses (`ownNames`)
    /// aren't offered at all.
    public func top(limit: Int = 6, excluding: Set<String> = [], favored: Set<String> = [],
                    ownNames: Set<String> = [], now: Date = .now) -> [Person] {
        let own = Set(ownNames.map { Self.fold($0) })
        let ranked = people.values
            .filter { !excluding.contains($0.email) && ($0.sent > 0 || $0.received >= 3) && $0.lastContact > .distantPast }
            .filter { !own.contains(Self.fold($0.displayName)) && !Self.isOptOut($0.email) }
            .map { person -> (Person, Double) in
                let days = max(0, now.timeIntervalSince(person.lastContact) / 86_400)
                let closeness = log2(1 + Double(person.sent)) * 2.5 + log2(1 + Double(person.received)) * 0.5
                    + 5 * exp(-days / 21) + (favored.contains(person.email) ? 1 : 0)
                let score = Self.isRole(person) || Self.isAutomated(person.email) ? closeness * 0.4 : closeness
                return (person, score)
            }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.email < $1.0.email }
        return ranked.prefix(limit).map(\.0)
    }

    /// The people `query` most likely means, best first: every word typed
    /// starts a word of their name or address ("sar", "sara wil",
    /// "wiltshire", "sara.w"), case and accents ignored. `favored` (your
    /// Contacts) rank a little higher.
    public func suggestions(for query: String, excluding: Set<String> = [], favored: Set<String> = [],
                            limit: Int = 6, now: Date = .now) -> [Person] {
        let typed = Self.fold(query).split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init)
        guard !typed.isEmpty else { return [] }
        return people.values
            .filter { !excluding.contains($0.email) && !Self.isOptOut($0.email) }
            .compactMap { person -> (Person, Double)? in
                guard let match = Self.match(typed, person) else { return nil }
                return (person, match + Self.closeness(person, now: now) + (favored.contains(person.email) ? 2 : 0))
            }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.email < $1.0.email }
            .prefix(limit)
            .map(\.0)
    }

    /// How well the words typed fit: nil if any doesn't; more for the start
    /// of a first name, the whole address, or an exact word.
    static func match(_ typed: [String], _ person: Person) -> Double? {
        let nameWords = fold(person.displayName).split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        let email = fold(person.email)
        let local = email.split(separator: "@").first.map(String.init) ?? email
        let addressWords = email.split(whereSeparator: { ".-_+@".contains($0) }).map(String.init)
        var score = 0.0
        for word in typed {
            if email.hasPrefix(word) || (word.contains("@") && email.contains(word)) {
                score += word.count >= local.count ? 7 : 5
            } else if let index = nameWords.firstIndex(where: { $0.hasPrefix(word) }) {
                score += (index == 0 ? 5 : 4) + (nameWords[index] == word ? 1 : 0)
            } else if addressWords.contains(where: { $0.hasPrefix(word) }) {
                score += 3
            } else if word.count >= 3, email.contains(word) {
                score += 1
            } else {
                return nil
            }
        }
        return score
    }

    /// How much you're in touch: writing to someone counts most; recent
    /// counts more than long ago.
    static func closeness(_ person: Person, now: Date) -> Double {
        let days = max(0, now.timeIntervalSince(person.lastContact) / 86_400)
        return log2(1 + Double(person.sent)) * 2.5 + log2(1 + Double(person.received)) + 3 * exp(-days / 45)
    }

    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }
}
