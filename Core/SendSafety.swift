import Foundation

/// Emails handed to an SMTP server (iCloud and other IMAP accounts), by
/// Message-ID, so a check before sending again can tell "never went" from
/// "may have gone". Sent is no help on its own: iCloud's SMTP doesn't file
/// what it sends, Corres does once the server says it took it, so an answer
/// lost on the way back (or Corres closing before filing) leaves nothing in
/// Sent to find. Pure, so it can be tested; kept by `IMAPMailClient`.
public struct SMTPHandoffs: Codable, Equatable, Sendable {
    public enum State: Codable, Equatable, Sendable {
        /// Handed over, and no answer seen: it may have gone.
        case unconfirmed
        /// The server took it. `conversation` is the id sync gives it.
        case accepted(conversation: String)
    }

    public struct Entry: Codable, Equatable, Sendable {
        public var state: State
        public var at: Date
    }

    /// What a check before sending again concludes.
    public enum Verdict: Equatable, Sendable {
        /// It went: the conversation it's in, when known.
        case sent(conversation: String)
        case notSent
        /// It may have gone, and nothing can say. Never sent again on its
        /// own; only by hand.
        case unknown
    }

    public private(set) var entries: [String: Entry] = [:]

    public init() {}

    static func key(account: String, messageID: String) -> String {
        account.lowercased() + "|" + messageID.trimmingCharacters(in: CharacterSet(charactersIn: "<> ")).lowercased()
    }

    /// Just before it's handed over: from here it may go.
    public mutating func handOver(_ messageID: String, account: String, at date: Date = .now) {
        entries[Self.key(account: account, messageID: messageID)] = Entry(state: .unconfirmed, at: date)
    }

    public mutating func accepted(_ messageID: String, account: String, conversation: String, at date: Date = .now) {
        entries[Self.key(account: account, messageID: messageID)] = Entry(state: .accepted(conversation: conversation), at: date)
    }

    /// Certainly not sent (the server said no, or it never got the end of
    /// the email), or sent again by hand.
    public mutating func forget(_ messageID: String, account: String) {
        entries[Self.key(account: account, messageID: messageID)] = nil
    }

    public func state(of messageID: String, account: String) -> State? {
        entries[Self.key(account: account, messageID: messageID)]?.state
    }

    /// `foundIn`: the conversation the server has a copy in, if it has one.
    public func verdict(for messageID: String, account: String, foundIn: String?) -> Verdict {
        if let foundIn { return .sent(conversation: foundIn) }
        switch state(of: messageID, account: account) {
        case .accepted(let conversation)?: return .sent(conversation: conversation)
        case .unconfirmed?: return .unknown
        case nil: return .notSent
        }
    }

    /// Accepted ones are only needed until the outbox has let go of them;
    /// an unconfirmed one is kept as long as a failed send may still be
    /// waiting to be retried.
    public func pruned(now: Date = .now) -> SMTPHandoffs {
        var result = self
        result.entries = entries.filter { _, entry in
            switch entry.state {
            case .accepted: now.timeIntervalSince(entry.at) < Self.keepAccepted
            case .unconfirmed: now.timeIntervalSince(entry.at) < Self.keepUnconfirmed
            }
        }
        if result.entries.count > Self.maxEntries {
            let newest = result.entries.sorted { $0.value.at > $1.value.at }.prefix(Self.maxEntries)
            result.entries = Dictionary(uniqueKeysWithValues: newest.map { ($0.key, $0.value) })
        }
        return result
    }

    static let keepAccepted: TimeInterval = 14 * 86_400
    static let keepUnconfirmed: TimeInterval = 90 * 86_400
    static let maxEntries = 500
}

/// Outlook drafts a large send made and couldn't remove at the time (the
/// connection went), or that were asked to send with no clear answer. Graph
/// sends a draft later than it answers (202 Accepted), and a sent draft
/// keeps its id in Sent Items, so one is deleted only once Graph shows it's
/// still a draft, and, if it was asked to send, only after Graph has had
/// time to send it. Pure, so it can be tested; kept by `OutlookClient`.
public struct LeftoverDrafts: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var account: String
        public var draftID: String
        /// The email's Message-ID, without angle brackets.
        public var messageID: String?
        /// When it was asked to send without a clear answer; nil when it
        /// never was, so it can't have gone.
        public var sendAskedAt: Date?

        public init(account: String, draftID: String, messageID: String?, sendAskedAt: Date?) {
            self.account = account
            self.draftID = draftID
            self.messageID = messageID
            self.sendAskedAt = sendAskedAt
        }
    }

    public enum Action: Equatable, Sendable {
        /// Still a draft and can't be on its way: delete it.
        case delete
        /// Still a draft, but Graph may yet send it: leave it for now.
        case wait
        /// Sent (it's the copy in Sent Items now), or already gone: leave
        /// the message alone and stop tracking it.
        case forget
    }

    /// How long Graph is given to send a draft it was asked to send.
    public static let settleTime: TimeInterval = 10 * 60

    public private(set) var entries: [Entry] = []

    public init() {}

    public mutating func add(_ entry: Entry) {
        entries.removeAll { $0.account == entry.account && $0.draftID == entry.draftID }
        entries.append(entry)
        if entries.count > 200 { entries.removeFirst(entries.count - 200) }
    }

    public mutating func remove(draftID: String, account: String) {
        entries.removeAll { $0.account == account && $0.draftID == draftID }
    }

    public func entries(for account: String) -> [Entry] { entries.filter { $0.account == account } }

    /// `isDraft`: what Graph says now, nil when the message is gone.
    public static func action(for entry: Entry, isDraft: Bool?, now: Date = .now) -> Action {
        guard let isDraft, isDraft else { return .forget }
        guard let asked = entry.sendAskedAt else { return .delete }
        return now.timeIntervalSince(asked) >= settleTime ? .delete : .wait
    }
}

extension RemoteMessageChange {
    /// Moved out of the Inbox elsewhere (archived, or moved to a folder),
    /// as opposed to trashed, marked spam or deleted, with its labels known.
    public var leftInbox: Bool {
        guard removed, let labels = currentLabelIds else { return false }
        return !labels.contains("INBOX") && !labels.contains("TRASH") && !labels.contains("SPAM")
    }

    /// Conversations that may have been archived elsewhere although no
    /// change names the message Corres keeps for them: their latest is your
    /// own reply, which was never in the Inbox, so archiving on the web
    /// changes only the older messages. Each is worth asking the server
    /// about (`stillInInbox`) before it leaves Corres.
    public static func archivedBehindLatest(_ changes: [RemoteMessageChange], stored: [Correspondence]) -> [ThreadID] {
        let reported = Set(changes.map { $0.threadID.account + "|" + $0.messageID })
        let archived = Set(changes.filter { $0.leftInbox && !$0.threadID.providerID.isEmpty }.map(\.threadID))
        return stored.filter { thread in
            guard archived.contains(thread.id), let latest = thread.latestMessageID,
                  !thread.labelIds.contains("INBOX"), thread.labelIds.contains("SENT") else { return false }
            // A change for the latest itself is handled as it always was.
            return !reported.contains(thread.id.account + "|" + latest)
        }.map(\.id)
    }

    /// Whether any message of a conversation, by its labels, is still in
    /// the Inbox.
    public static func stillInInbox(_ messageLabels: [[String]]) -> Bool {
        messageLabels.contains { $0.contains("INBOX") }
    }
}

extension Correspondence {
    /// The copy of an email Corres sent, out of its conversation: the one
    /// with the Message-ID Corres stamped on it. The newest of your own was
    /// the guess before, which is another email when you'd written again
    /// since (a stand-in repaired days later, or a conversation that goes
    /// back and forth).
    public static func sentCopy(in messages: [Correspondence], messageID: String?) -> Correspondence? {
        func bare(_ id: String) -> String { id.trimmingCharacters(in: CharacterSet(charactersIn: "<> ")).lowercased() }
        if let messageID, let match = messages.last(where: { $0.messageIdHeader.map(bare) == bare(messageID) }) {
            return match
        }
        return messages.last { $0.isFromAccountOwner } ?? messages.last
    }
}
