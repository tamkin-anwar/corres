import Foundation

/// The Today card above Needs You: what today holds, from Corres's own
/// data alone, with no model writing anything. Built from the Needs You
/// list (deadlines, meetings, replies you owe) and today's shipping mail,
/// in a fixed order: overdue and due today, today's meetings, deliveries
/// arriving today, then the email you've owed a reply longest.
public struct TodayBrief: Equatable, Sendable {
    public enum Kind: String, Sendable, Equatable {
        /// Its deadline has passed.
        case overdue
        /// Due before today ends.
        case dueToday
        /// An invitation or appointment today that hasn't finished.
        case meeting
        /// Out for delivery, with no "Delivered" since.
        case delivery
        /// A person wrote to you and is waiting for your answer.
        case reply
    }

    public struct Item: Identifiable, Equatable, Sendable {
        public var id: ThreadID { thread.id }
        public let kind: Kind
        public let thread: Correspondence
        /// When it's due or starts, or when they wrote (a reply).
        public let date: Date?
        /// The date carries a time of day ("5:00 PM"), not just a day.
        public let hasTime: Bool
    }

    /// Overdue and due today, events left out.
    public let due: Int
    /// Of `due`, the ones already past their deadline.
    public let overdue: Int
    public let meetings: Int
    public let deliveries: Int
    /// Emails from people in Needs You with no deadline today.
    public let replies: Int
    /// At most `limit` items, in the card's order.
    public let top: [Item]

    /// Nothing due, nothing today, nothing owed: the card stays away.
    public var isEmpty: Bool { due == 0 && meetings == 0 && deliveries == 0 && replies == 0 }

    public static let empty = TodayBrief(due: 0, overdue: 0, meetings: 0, deliveries: 0, replies: 0, top: [])

    public init(due: Int, overdue: Int, meetings: Int, deliveries: Int, replies: Int, top: [Item]) {
        self.due = due
        self.overdue = overdue
        self.meetings = meetings
        self.deliveries = deliveries
        self.replies = replies
        self.top = top
    }

    /// - Parameters:
    ///   - needsYou: the Needs You list as it's shown (snoozed, screened
    ///     and past events already left out).
    ///   - deliveries: today's packages still on their way
    ///     (`arriving(from:store:)`).
    ///   - isMeeting: whether an email is about something that happens at
    ///     a time (an invitation, an appointment) rather than a task.
    ///   - isPerson: whether a person wrote it, so an answer is owed.
    public static func make(needsYou: [Correspondence], deliveries: [Correspondence], now: Date,
                            calendar: Calendar = .current, limit: Int = 3,
                            isMeeting: (Correspondence) -> Bool,
                            isPerson: (Correspondence) -> Bool) -> TodayBrief {
        let startOfToday = calendar.startOfDay(for: now)
        let endOfToday = calendar.date(byAdding: .day, value: 1, to: startOfToday) ?? now.addingTimeInterval(86_400)
        var due: [Item] = []
        var meetings: [Item] = []
        var replies: [Item] = []
        for thread in needsYou {
            if let date = thread.dueAt, date < endOfToday {
                let timed = hasTime(date, calendar: calendar)
                if isMeeting(thread), date >= startOfToday {
                    // Today's, until an hour after it starts.
                    if date.addingTimeInterval(3_600) > now {
                        meetings.append(Item(kind: .meeting, thread: thread, date: date, hasTime: timed))
                    }
                    continue
                }
                // An earlier day's invitation still in Needs You shows there
                // as overdue, so it's overdue here too.
                // A day with no time is due until that day ends.
                let late = timed ? date < now : date < startOfToday
                due.append(Item(kind: late ? .overdue : .dueToday, thread: thread, date: date, hasTime: timed))
                continue
            }
            if isPerson(thread) {
                replies.append(Item(kind: .reply, thread: thread, date: thread.receivedAt, hasTime: true))
            }
        }
        due.sort { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }
        meetings.sort { ($0.date ?? .distantPast) < ($1.date ?? .distantPast) }
        let longestOwed = replies.min { $0.thread.receivedAt < $1.thread.receivedAt }
        let arriving = deliveries.map { Item(kind: .delivery, thread: $0, date: nil, hasTime: false) }
        var top = due + meetings + arriving
        if let longestOwed { top.append(longestOwed) }
        // One row per conversation, the first reason it earned.
        var seen = Set<ThreadID>()
        top = top.filter { seen.insert($0.id).inserted }
        return TodayBrief(due: due.count, overdue: due.filter { $0.kind == .overdue }.count, meetings: meetings.count, deliveries: deliveries.count,
                          replies: replies.count, top: Array(top.prefix(limit)))
    }

    /// Today's shipping emails, oldest first, as (email, status line):
    /// one per store whose latest says out for delivery and hasn't said
    /// delivered since. The same reading as the delivery Live Activity.
    public static func arriving(from shipping: [(thread: Correspondence, status: String?)],
                                store: (Correspondence) -> String) -> [Correspondence] {
        var latest: [String: Correspondence] = [:]
        var order: [String] = []
        for (thread, status) in shipping.sorted(by: { $0.thread.receivedAt < $1.thread.receivedAt }) {
            let key = store(thread)
            if status == "Out for delivery" {
                if latest[key] == nil, !order.contains(key) { order.append(key) }
                latest[key] = thread
            } else if status == "Delivered" {
                latest[key] = nil
            }
        }
        return order.compactMap { latest[$0] }
    }

    /// Deadlines read from "by Friday" land on midnight, noon (where the
    /// date detector and `LocalDates` put a day with no time) or the day's
    /// last minute: a day, not a time worth printing. Read as a time, "Pay
    /// by Friday" showed "Due 12:00 PM" and turned Overdue at one o'clock.
    public static func hasTime(_ date: Date, calendar: Calendar = .current) -> Bool {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let hour = parts.hour ?? 0, minute = parts.minute ?? 0
        return !(hour == 0 && minute == 0) && !(hour == 12 && minute == 0) && !(hour == 23 && minute == 59)
    }
}
