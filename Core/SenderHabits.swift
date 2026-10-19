import Foundation

/// How you treat each sender's mail, counted on this iPhone, so Corres can
/// notice a habit and offer the change it suggests: unsubscribe from a
/// list you never open, or make a VIP of someone you always read at once.
///
/// Gmail's Manage subscriptions only sorts senders by how much they send;
/// no mail app notices what you do with it. Corres does, and asks rather
/// than acts: one suggestion at a time, at the moment it's relevant (right
/// after the archive or reply that shows the habit), at most once a day,
/// and "Not now" means not for a month.
public struct SenderHabits: Codable, Sendable, Equatable {
    public struct Habit: Codable, Sendable, Equatable {
        /// When you archived or deleted their mail without opening it.
        public var removedUnread: [Date] = []
        /// When you opened their mail, and how long after it arrived.
        public var opens: [Open] = []
        /// When you replied to them.
        public var replies: [Date] = []
    }

    public struct Open: Codable, Sendable, Equatable {
        public var at: Date
        public var minutesAfterArrival: Double
    }

    public enum Suggestion: Equatable, Sendable {
        /// "You haven't opened the last 6 from Medium."
        case unsubscribe(email: String, name: String, unopened: Int)
        /// "You read Sara's mail within minutes" / "You reply to Sara often."
        case vip(email: String, name: String, reason: VIPReason)

        public var email: String {
            switch self { case .unsubscribe(let email, _, _), .vip(let email, _, _): email }
        }
        public var kind: String {
            switch self { case .unsubscribe: "unsubscribe"; case .vip: "vip" }
        }
    }

    public enum VIPReason: Equatable, Sendable { case readsQuickly(minutes: Int), repliesOften(count: Int) }

    public private(set) var habits: [String: Habit] = [:]
    /// "kind|email" → until when it isn't offered again.
    public private(set) var declined: [String: Date] = [:]
    public private(set) var lastOffered: Date?

    public init() {}

    /// Only what's recent counts: habits change.
    static let window: TimeInterval = 60 * 86_400
    static let unsubscribeAfter = 4
    static let quickMinutes = 30.0
    static let vipOpens = 5
    static let vipReplies = 3

    // MARK: Recording

    public mutating func recordRemovedUnread(_ email: String, at date: Date = .now) {
        update(email, at: date) { $0.removedUnread.append(date) }
    }

    public mutating func recordOpen(_ email: String, receivedAt: Date, at date: Date = .now) {
        let minutes = max(0, date.timeIntervalSince(receivedAt) / 60)
        update(email, at: date) { $0.opens.append(Open(at: date, minutesAfterArrival: minutes)) }
    }

    public mutating func recordReply(to email: String, at date: Date = .now) {
        update(email, at: date) { $0.replies.append(date) }
    }

    private mutating func update(_ email: String, at date: Date, _ change: (inout Habit) -> Void) {
        let key = email.lowercased()
        var habit = habits[key] ?? Habit()
        change(&habit)
        let cutoff = date.addingTimeInterval(-Self.window)
        habit.removedUnread = habit.removedUnread.filter { $0 > cutoff }.suffix(20)
        habit.opens = habit.opens.filter { $0.at > cutoff }.suffix(20)
        habit.replies = habit.replies.filter { $0 > cutoff }.suffix(20)
        habits[key] = habit
    }

    // MARK: Suggesting

    /// What this sender's habit suggests now, if anything. `isList`: their
    /// mail can be unsubscribed from; `isPerson`: a person, not a system;
    /// `isVIP`: already one.
    /// `paced`: at most one a day, for an offer that interrupts. A list you
    /// open yourself (Settings → Senders) shows them all.
    public func suggestion(for email: String, name: String, isList: Bool, isPerson: Bool, isVIP: Bool,
                           paced: Bool = true, now: Date = .now) -> Suggestion? {
        let key = email.lowercased()
        guard let habit = habits[key] else { return nil }
        if paced, let last = lastOffered, now.timeIntervalSince(last) < 20 * 3_600 { return nil }
        let cutoff = now.addingTimeInterval(-Self.window)
        let removed = habit.removedUnread.filter { $0 > cutoff }
        let opens = habit.opens.filter { $0.at > cutoff }
        let replies = habit.replies.filter { $0 > cutoff }

        if isList, removed.count >= Self.unsubscribeAfter, opens.isEmpty, !isDeclined("unsubscribe", key, now: now) {
            return .unsubscribe(email: key, name: name, unopened: removed.count)
        }
        guard isPerson, !isVIP, !isDeclined("vip", key, now: now) else { return nil }
        if replies.count >= Self.vipReplies {
            return .vip(email: key, name: name, reason: .repliesOften(count: replies.count))
        }
        let sorted = opens.map(\.minutesAfterArrival).sorted()
        if sorted.count >= Self.vipOpens {
            let median = sorted[sorted.count / 2]
            if median <= Self.quickMinutes { return .vip(email: key, name: name, reason: .readsQuickly(minutes: max(1, Int(median.rounded())))) }
        }
        return nil
    }

    public func isDeclined(_ kind: String, _ email: String, now: Date = .now) -> Bool {
        (declined["\(kind)|\(email.lowercased())"] ?? .distantPast) > now
    }

    public mutating func markOffered(at date: Date = .now) { lastOffered = date }

    /// "Not now": a month. "Never": for good.
    public mutating func decline(_ suggestion: Suggestion, forever: Bool, at date: Date = .now) {
        declined["\(suggestion.kind)|\(suggestion.email)"] = forever ? .distantFuture : date.addingTimeInterval(30 * 86_400)
    }

    /// Done (unsubscribed, or made a VIP): the habit has been acted on.
    public mutating func resolve(_ suggestion: Suggestion) {
        habits[suggestion.email] = nil
    }

    public mutating func forgetAll() {
        habits = [:]
        declined = [:]
        lastOffered = nil
    }
}

/// Which snooze you pick for each kind of email, so your usual one comes
/// first, marked: receipts to the weekend, a friend's email to this
/// evening. Mail, Gmail and Spark show the same presets every time.
public struct SnoozeHabits: Codable, Sendable, Equatable {
    /// Kind of email → preset → how often.
    public private(set) var counts: [String: [String: Int]] = [:]

    public init() {}

    public mutating func record(_ option: String, for kind: String) {
        counts[kind, default: [:]][option, default: 0] += 1
    }

    /// Your usual, once it is one: picked at least 3 times and most of the
    /// time (60%).
    public func usual(for kind: String) -> String? {
        guard let options = counts[kind] else { return nil }
        let total = options.values.reduce(0, +)
        guard let top = options.max(by: { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }),
              top.value >= 3, Double(top.value) / Double(total) >= 0.6 else { return nil }
        return top.key
    }
}
