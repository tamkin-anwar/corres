import EventKit
import Foundation

/// "Remind me about this": an email added to Reminders, as Siri does in
/// Mail, with a link that opens it straight back in Corres. Reminders has
/// no add sheet of its own for apps to show, so Corres asks once for
/// permission, the first time you use it, and only ever adds.
@MainActor
enum MailReminders {
    enum Outcome { case added, notAllowed, failed }

    private static let store = EKEventStore()

    /// When it can be due, for the menu: tonight, tomorrow morning, and the
    /// email's own deadline when it has one.
    static func choices(for thread: Correspondence, now: Date = .now, calendar: Calendar = .current) -> [(title: String, date: Date?)] {
        var choices: [(String, Date?)] = []
        if let tonight = calendar.date(bySettingHour: 18, minute: 0, second: 0, of: now), tonight.timeIntervalSince(now) > 30 * 60 {
            choices.append((String(localized: "This Evening"), tonight))
        }
        choices.append((String(localized: "Tomorrow Morning"), tomorrowMorning(now: now, calendar: calendar)))
        if let due = thread.dueAt, due > now {
            let when = due.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
            choices.append((String(localized: "When It's Due, \(when)"), due))
        }
        choices.append((String(localized: "No Date"), nil))
        return choices
    }

    static func tomorrowMorning(now: Date = .now, calendar: Calendar = .current) -> Date {
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) ?? now.addingTimeInterval(86_400)
        return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow) ?? tomorrow
    }

    static func add(_ thread: Correspondence, due: Date?) async -> Outcome {
        let granted: Bool
        if EKEventStore.authorizationStatus(for: .reminder) == .fullAccess {
            granted = true
        } else {
            granted = (try? await store.requestFullAccessToReminders()) ?? false
        }
        guard granted, let list = store.defaultCalendarForNewReminders() else { return .notAllowed }
        let reminder = EKReminder(eventStore: store)
        reminder.calendar = list
        let subject = thread.subject.trimmingCharacters(in: .whitespacesAndNewlines)
        reminder.title = subject.isEmpty ? String(localized: "Email from \(thread.sender)") : subject
        let from = thread.isFromAccountOwner ? String(localized: "To \(thread.counterpartName())") : String(localized: "From \(thread.sender)")
        reminder.notes = [from, thread.excerpt.previewText].filter { !$0.isEmpty }.joined(separator: "\n")
        reminder.url = link(to: thread.id)
        if let due {
            reminder.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: due)
            reminder.addAlarm(EKAlarm(absoluteDate: due))
        }
        do {
            try store.save(reminder, commit: true)
            return .added
        } catch {
            return .failed
        }
    }

    /// corres://thread?account=…&id=…, which opens the conversation.
    static func link(to id: ThreadID) -> URL? {
        var components = URLComponents()
        components.scheme = WidgetSnapshot.urlScheme
        components.host = "thread"
        components.queryItems = [URLQueryItem(name: "account", value: id.account), URLQueryItem(name: "id", value: id.providerID)]
        return components.url
    }
}
