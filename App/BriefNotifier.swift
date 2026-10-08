import Foundation
import UserNotifications

/// The Brief, delivered: one quiet notification at the time you choose
/// (Settings → Notifications → Morning Brief) with what needs you and who
/// you're waiting on, the same sentence Siri gives for "What needs me".
/// It's one daily notification, rewritten whenever the mail changes, so it
/// reads what Corres knew at the last sync.
@MainActor
enum BriefNotifier {
    static let enabledKey = "corres.brief.enabled"
    static let hourKey = "corres.brief.hour"
    static let minuteKey = "corres.brief.minute"
    private static let identifier = "corres.brief"
    private static var lastSnapshot: WidgetSnapshot?
    private static var lastScheduled: (body: String, fire: DateComponents)?
    /// Whether the pending Brief has already been removed, so a Brief that's
    /// switched off isn't removed again on every change to the mail.
    private static var isCleared = false

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }
    static var time: (hour: Int, minute: Int) {
        let defaults = UserDefaults.standard
        return (defaults.object(forKey: hourKey) as? Int ?? 8, defaults.object(forKey: minuteKey) as? Int ?? 0)
    }

    /// Called with every fresh snapshot (see `WidgetBridge`), and with nil
    /// when the setting itself changes.
    static func reschedule(_ snapshot: WidgetSnapshot? = nil) {
        if let snapshot { lastSnapshot = snapshot }
        let identifier = Self.identifier
        guard isEnabled, let snapshot = lastSnapshot, !snapshot.isSample, snapshot.isLocked != true else {
            lastScheduled = nil
            guard !isCleared else { return }
            isCleared = true
            // Off the main thread: removing a pending notification waits on
            // the system's notification service, and found live on a freshly
            // started iPhone, that wait froze Corres right after launch.
            Task.detached(priority: .utility) {
                UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [identifier])
            }
            return
        }
        isCleared = false
        let body = WhatNeedsMeIntent.summary(of: snapshot)
        // Every day at that time, even on days Corres isn't opened; each
        // sync rewrites what it says.
        let fire = DateComponents(hour: time.hour, minute: time.minute)
        if let lastScheduled, lastScheduled.body == body, lastScheduled.fire == fire { return }
        lastScheduled = (body, fire)

        Task.detached(priority: .utility) {
            let content = UNMutableNotificationContent()
            content.title = "Your Brief"
            content.body = body
            content.userInfo = ["destination": "brief"]
            content.interruptionLevel = .passive
            let request = UNNotificationRequest(identifier: identifier, content: content,
                                                trigger: UNCalendarNotificationTrigger(dateMatching: fire, repeats: true))
            try? await UNUserNotificationCenter.current().add(request)
        }
    }
}
