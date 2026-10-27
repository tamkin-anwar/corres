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
            // Ten seconds at most: a send that's still going then is kept in
            // the outbox and finished at the next launch.
            await Self.wait(upTo: .seconds(10)) { await outbox.sendPendingNow() }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// Runs `work`, waiting for it no longer than `limit`.
    @MainActor private static func wait(upTo limit: Duration, for work: @escaping @MainActor () async -> Void) async {
        @MainActor final class Done { var value = false }
        let done = Done()
        Task { await work(); done.value = true }
        let deadline = ContinuousClock.now + limit
        while !done.value, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
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
        // Mail checked, sorted and notified from launch, whether or not the
        // main window opens (Corres can start in the menu bar).
        Task { await MacServices.shared.launch() }
        // Waking from sleep: the old connections are gone.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { MacAppDelegate.didWake?() }
        }
    }

    func application(_ application: NSApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        MainActor.assumeIsolated { MacAppDelegate.didRegister?(deviceToken) }
    }

    func application(_ application: NSApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // Without a token the Mac gets no pushes: say so in diagnostics.
        HangReporter.note("push registration failed: \((error as NSError).domain) \((error as NSError).code)")
    }

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
