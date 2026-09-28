import Foundation
import UserNotifications

/// The Brief, delivered: one quiet notification at the time you choose
/// (Settings → Notifications → Morning Brief) with what needs you and who
/// you're waiting on, the same sentence Siri gives for "What needs me".
/// It's a single scheduled notification, rewritten whenever the mail
/// changes, so it reads what Corres knew at the last sync.
@MainActor
enum BriefNotifier {
    static let enabledKey = "corres.brief.enabled"
    static let hourKey = "corres.brief.hour"
    static let minuteKey = "corres.brief.minute"
    private static let identifier = "corres.brief"
    private static var lastSnapshot: WidgetSnapshot?
    private static var lastScheduled: (body: String, fire: DateComponents)?

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }
    static var time: (hour: Int, minute: Int) {
        let defaults = UserDefaults.standard
        return (defaults.object(forKey: hourKey) as? Int ?? 8, defaults.object(forKey: minuteKey) as? Int ?? 0)
    }

    /// Called with every fresh snapshot (see `WidgetBridge`), and with nil
    /// when the setting itself changes.
    static func reschedule(_ snapshot: WidgetSnapshot? = nil) {
        if let snapshot { lastSnapshot = snapshot }
        let center = UNUserNotificationCenter.current()
        guard isEnabled, let snapshot = lastSnapshot, !snapshot.isSample, snapshot.isLocked != true else {
            center.removePendingNotificationRequests(withIdentifiers: [identifier])
            lastScheduled = nil
            return
        }
        let body = WhatNeedsMeIntent.summary(of: snapshot)
        let fire = nextFire()
        if let lastScheduled, lastScheduled.body == body, lastScheduled.fire == fire { return }
        lastScheduled = (body, fire)

        let content = UNMutableNotificationContent()
        content.title = "Your Brief"
        content.body = body
        content.userInfo = ["destination": "brief"]
        content.interruptionLevel = .passive
        let request = UNNotificationRequest(identifier: identifier, content: content,
                                            trigger: UNCalendarNotificationTrigger(dateMatching: fire, repeats: false))
        center.add(request)
    }

    /// Today at the chosen time if it's still ahead, otherwise tomorrow.
    private static func nextFire(now: Date = .now) -> DateComponents {
        let calendar = Calendar.current
        let (hour, minute) = time
        var day = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: now) ?? now
        if day <= now { day = calendar.date(byAdding: .day, value: 1, to: day) ?? day }
        return calendar.dateComponents([.year, .month, .day, .hour, .minute], from: day)
    }
}
