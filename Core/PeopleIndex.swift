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

    /// "Sara Wiltshire", or "Sara Wiltshire" from sara.wiltshire@….
    public var displayName: String { name.isEmpty ? Correspondence.name(fromAddress: email) : name }

    /// "Sara Wiltshire <sara.wiltshire@example.com>", for a To field.
    public var address: String {
        name.isEmpty ? email : "\(name.contains(",") ? "\"\(name)\"" : name) <\(email)>"
    }
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
            case ",", ";" where !inQuotes && !inAngle: lastSeparator = index
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
        text.range(of: #"^[^\s@<>,;]+@[^\s@<>,;]+\.[^\s@<>,;]{2,}$"#, options: .regularExpression) != nil
    }

    /// Addresses that are never a person to write to.
    public static func isAutomated(_ email: String) -> Bool {
        email.range(of: #"(?i)^(no-?reply|do-?not-?reply|donotreply|notifications?|alerts?|mailer-daemon|postmaster|bounces?|news(letter)?|marketing|info|support|hello|team|updates?|account|accounts|billing|receipts?|orders?|shipping|security)([-_.+].*)?@|@(.*\.)?(bounce|email|mail|e|em|news|notifications?|reply)\.[^.]+\.[^.]+$"#,
                     options: .regularExpression) != nil
    }

    /// Someone you sent mail to.
    public mutating func recordSent(to entry: String, at date: Date) {
        guard let (name, email) = Self.parse(entry) else { return }
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
                for address in thread.toRecipients + thread.ccRecipients where !accounts.contains(address.lowercased()) {
                    recordSent(to: address, at: thread.lastSentAt ?? thread.receivedAt)
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

    /// The people `query` most likely means, best first: every word typed
    /// starts a word of their name or address ("sar", "sara wil",
    /// "wiltshire", "sara.w"), case and accents ignored. `favored` (your
    /// Contacts) rank a little higher.
    public func suggestions(for query: String, excluding: Set<String> = [], favored: Set<String> = [],
                            limit: Int = 6, now: Date = .now) -> [Person] {
        let typed = Self.fold(query).split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init)
        guard !typed.isEmpty else { return [] }
        return people.values
            .filter { !excluding.contains($0.email) }
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
