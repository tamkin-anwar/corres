import Foundation
import Observation
import UserNotifications

/// "Remind me if no reply", set as you send: if nobody has answered by
/// then, the conversation comes back into Needs You ("No reply from Sara
/// since Monday"), with a notification, as Superhuman reminds you and Spark
/// brings it back to the top. A reply first, and the reminder quietly goes.
@MainActor
final class FollowUps {
    static let shared = FollowUps()

    struct Reminder: Codable, Equatable {
        let threadID: ThreadID
        let due: Date
        let sentAt: Date
        let recipient: String
        let subject: String
    }

    private(set) var reminders: [Reminder] = []
    private static let key = "corres.followUps"

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode([Reminder].self, from: data) {
            reminders = saved
        }
    }

    func add(_ threadID: ThreadID, after interval: TimeInterval, recipient: String, subject: String) {
        reminders.removeAll { $0.threadID == threadID }
        let reminder = Reminder(threadID: threadID, due: .now.addingTimeInterval(interval), sentAt: .now,
                                recipient: recipient, subject: subject)
        reminders.append(reminder)
        save()
        // In case Corres doesn't run around then: the reminder still comes.
        let content = UNMutableNotificationContent()
        content.title = String(localized: "No reply from \(recipient)")
        content.body = String(localized: "\u{201C}\(subject)\u{201D}: follow up?")
        content.userInfo = ["account": threadID.account, "thread": threadID.providerID]
        content.categoryIdentifier = PushNotificationService.messageCategory
        UNUserNotificationCenter.current().add(UNNotificationRequest(
            identifier: Self.notificationID(threadID), content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: max(interval, 60), repeats: false)))
    }

    /// Checked whenever mail syncs: a reply cancels; a reminder that's due
    /// brings the conversation into Needs You.
    func check(store: MailStore, now: Date = .now) async {
        guard !reminders.isEmpty else { return }
        var remaining: [Reminder] = []
        for reminder in reminders {
            guard let thread = store.thread(reminder.threadID) else {
                if reminder.due > now.addingTimeInterval(-7 * 86_400) { remaining.append(reminder) }
                continue
            }
            if !thread.isFromAccountOwner, thread.receivedAt > reminder.sentAt {
                // They answered.
                UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [Self.notificationID(reminder.threadID)])
                continue
            }
            if reminder.due <= now {
                let day = reminder.sentAt.formatted(.dateTime.weekday(.wide))
                if let messageID = thread.latestMessageID {
                    await store.applySemanticTriage(thread.id, from: thread.attention, to: .needsYou,
                                                    reason: String(localized: "No reply from \(reminder.recipient) since \(day). Follow up?"),
                                                    messageID: messageID)
                }
                continue
            }
            remaining.append(reminder)
        }
        if remaining != reminders {
            reminders = remaining
            save()
        }
    }

    private static func notificationID(_ id: ThreadID) -> String { "corres.followUp.\(id.account).\(id.providerID)" }

    private func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(reminders), forKey: Self.key)
    }
}
