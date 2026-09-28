import Foundation
import WidgetKit

/// Keeps the widgets current: rebuilds the shared snapshot from the same
/// queries the lists use, and asks WidgetKit to reload only when what a
/// widget would show actually changed (reloads are budgeted by iOS).
@MainActor
enum WidgetBridge {
    private static var last: WidgetSnapshot?
    /// Widgets are part of Corres Pro once a real account is connected.
    static var isLocked = false

    static func update(from threads: [Correspondence]) {
        let now = Date.now
        let needs = MailQuery.filter(threads, attention: .needsYou, now: now)
        let waiting = MailQuery.filter(threads, attention: .waiting, now: now)
        let unread = MailQuery.filter(threads, now: now).filter(\.isUnread).count
        func item(_ thread: Correspondence) -> WidgetSnapshot.Item {
            WidgetSnapshot.Item(account: thread.id.account, threadID: thread.id.providerID, sender: thread.sender,
                                subject: thread.subject, reason: thread.reason, receivedAt: thread.receivedAt,
                                isUnread: thread.isUnread, dueLabel: thread.dueAt.map(dueLabel))
        }
        var snapshot = WidgetSnapshot(needsYouCount: needs.count, waitingCount: waiting.count, unreadCount: unread,
                                      needsYou: needs.prefix(6).map(item), waiting: waiting.prefix(6).map(item),
                                      isSample: !threads.isEmpty && threads.allSatisfy { $0.id.account == "sample" },
                                      updatedAt: now)
        snapshot.isLocked = isLocked && !snapshot.isSample
        // Compare without the timestamp, so a sync that changed nothing
        // doesn't spend the widget reload budget.
        var comparable = snapshot
        comparable.updatedAt = last?.updatedAt ?? now
        guard comparable != last else { return }
        snapshot.save()
        last = snapshot
        WidgetCenter.shared.reloadAllTimelines()
    }

    private static func dueLabel(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInTomorrow(date) { return "Tomorrow" }
        return date.formatted(.dateTime.weekday(.abbreviated))
    }
}
