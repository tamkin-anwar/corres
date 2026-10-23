import AppKit
import UserNotifications

/// Notifications and the Dock: a clicked notification opens its
/// conversation, and the app comes forward when the Dock icon is clicked
/// with no window open.
final class MacAppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    /// Quitting while an email is in its Undo countdown: it goes first.
    /// Emails still being written are saved to Drafts (for up to a few
    /// seconds) and kept on this Mac, to open again at the next launch.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let drafts = MacComposeDrafts.shared
        drafts.isQuitting = true
        guard let outbox = Organizer.shared.outbox else {
            drafts.writeNow()
            return .terminateNow
        }
        Task { @MainActor in
            drafts.saveAllNow(outbox: outbox, store: Organizer.shared.store)
            _ = await outbox.finishDraftSaves(timeout: .seconds(3))
            drafts.noteSavedDrafts(from: outbox)
            await outbox.sendPendingNow()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// Archive, Mark as Read and Reply from a notification, done without
    /// bringing Corres forward. Set by MacServices once it's running.
    @MainActor static var handleAction: (@MainActor (_ action: String, _ id: ThreadID, _ typed: String?) async -> Void)?

    /// The push token, and a wake-up push, handed to MacServices.
    @MainActor static var didRegister: ((Data) -> Void)?
    @MainActor static var didReceivePush: (() -> Void)?
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
        MainActor.assumeIsolated { MacAppDelegate.didReceivePush?() }
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
            // With the main window closed (Corres stays in the menu bar),
            // it opens and takes the request as it appears.
            MacWindows.showMain()
        }
    }

    /// While Corres is in front, new mail shows in the list rather than
    /// as a banner over it.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        []
    }
}
