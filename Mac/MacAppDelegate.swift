import AppKit
import UserNotifications

/// Notifications and the Dock: a clicked notification opens its
/// conversation, and the app comes forward when the Dock icon is clicked
/// with no window open.
final class MacAppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    /// Archive, Mark as Read and Reply from a notification, done without
    /// bringing Corres forward. Set by MacServices once it's running.
    @MainActor static var handleAction: (@MainActor (_ action: String, _ id: ThreadID, _ typed: String?) async -> Void)?

    /// The push token, and a wake-up push, handed to MacServices.
    @MainActor static var didRegister: ((Data) -> Void)?
    @MainActor static var didWake: (() -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        MacTextSize.installEqualsShortcut()
    }

    func application(_ application: NSApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        MainActor.assumeIsolated { MacAppDelegate.didRegister?(deviceToken) }
    }

    func application(_ application: NSApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {}

    /// A silent push: mail changed on the server, so check now rather
    /// than at the next 20-second look.
    func application(_ application: NSApplication, didReceiveRemoteNotification userInfo: [String: Any]) {
        MainActor.assumeIsolated { MacAppDelegate.didWake?() }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        let account = info["account"] as? String, thread = info["thread"] as? String
        let action = response.actionIdentifier
        let typed = (response as? UNTextInputNotificationResponse)?.userText
        if action != UNNotificationDefaultActionIdentifier, let account, let thread {
            let id = ThreadID(account: account, providerID: thread)
            await MainActor.run { () -> Task<Void, Never> in
                Task { @MainActor in await MacAppDelegate.handleAction?(action, id, typed) }
            }.value
            return
        }
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
