import AppKit
import UserNotifications

/// Notifications and the Dock: a clicked notification opens its
/// conversation, and the app comes forward when the Dock icon is clicked
/// with no window open.
final class MacAppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        let account = info["account"] as? String, thread = info["thread"] as? String
        await MainActor.run {
            if let account, let thread {
                AppRouter.shared.pending = .thread(ThreadID(account: account, providerID: thread))
            } else {
                AppRouter.shared.pending = .destination(.needsYou)
            }
            NSApplication.shared.activate()
        }
    }

    /// While Corres is in front, new mail shows in the list rather than
    /// as a banner over it.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        []
    }
}
