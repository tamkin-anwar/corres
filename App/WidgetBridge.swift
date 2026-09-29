import Foundation
import UserNotifications
import WidgetKit

/// Keeps the widgets current: rebuilds the shared snapshot from the same
/// queries the lists use, and asks WidgetKit to reload only when what a
/// widget would show actually changed (reloads are budgeted by iOS).
@MainActor
enum WidgetBridge {
    private static var last: WidgetSnapshot?
    /// Widgets are part of Corres Pro once a real account is connected.
    static var isLocked = false

    private static var pendingUpdate: Task<Void, Never>?

    /// For changes made while the app is in use: waits for a pause, then
    /// sorts in the background. Run inline on every change, the four full
    /// sorts here landed in the middle of each swipe's animation.
    static func scheduleUpdate(from threads: [Correspondence]) {
        pendingUpdate?.cancel()
        let badge = CorresSettings.badge
        pendingUpdate = Task {
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            let built = await Task.detached(priority: .utility) { build(from: threads, now: .now, badge: badge) }.value
            guard !Task.isCancelled else { return }
            apply(built)
        }
    }

    /// Right away, for callers that need it done before they return
    /// (background refresh, a changed setting).
    static func update(from threads: [Correspondence]) {
        pendingUpdate?.cancel()
        apply(build(from: threads, now: .now, badge: CorresSettings.badge))
    }

    private struct Built: Sendable {
        var snapshot: WidgetSnapshot
        let badge: Int
    }

    nonisolated private static func build(from threads: [Correspondence], now: Date, badge: CorresSettings.Badge) -> Built {
        let needs = MailQuery.prioritized(threads, attention: .needsYou, now: now)
        let waiting = MailQuery.prioritized(threads, attention: .waiting, now: now)
        let unread = MailQuery.filter(threads, now: now).filter(\.isUnread).count
        func item(_ thread: Correspondence) -> WidgetSnapshot.Item {
            WidgetSnapshot.Item(account: thread.id.account, threadID: thread.id.providerID, sender: thread.sender,
                                subject: thread.subject, reason: thread.reason, receivedAt: thread.receivedAt,
                                isUnread: thread.isUnread, dueLabel: thread.dueAt.map(dueLabel))
        }
        let isSample = !threads.isEmpty && threads.allSatisfy { $0.id.account == "sample" }
        let snapshot = WidgetSnapshot(needsYouCount: needs.count, waitingCount: waiting.count, unreadCount: unread,
                                      needsYou: needs.prefix(6).map(item), waiting: waiting.prefix(6).map(item),
                                      isSample: isSample, updatedAt: now)
        // Settings → Lists → App icon badge: what needs you (default, in
        // keeping with Corres), everything unread, or nothing. Sample mail
        // never badges the real app icon.
        let count: Int = switch badge {
        case .needsYou: needs.count
        case .unread: unread
        case .off: 0
        }
        return Built(snapshot: snapshot, badge: isSample || threads.isEmpty ? 0 : count)
    }

    private static func apply(_ built: Built) {
        if built.badge != lastBadge {
            lastBadge = built.badge
            // iOS ties badges to notification permission; shows once allowed.
            UNUserNotificationCenter.current().setBadgeCount(built.badge)
        }
        var snapshot = built.snapshot
        snapshot.isLocked = isLocked && !snapshot.isSample
        BriefNotifier.reschedule(snapshot)
        // Compare without the timestamp, so a sync that changed nothing
        // doesn't spend the widget reload budget.
        var comparable = snapshot
        comparable.updatedAt = last?.updatedAt ?? snapshot.updatedAt
        guard comparable != last else { return }
        snapshot.save()
        last = snapshot
        WidgetCenter.shared.reloadAllTimelines()
    }

    private static var lastBadge: Int?

    nonisolated private static func dueLabel(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInTomorrow(date) { return "Tomorrow" }
        return date.formatted(.dateTime.weekday(.abbreviated))
    }
}
