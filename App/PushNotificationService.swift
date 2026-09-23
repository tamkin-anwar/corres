import Foundation
import Observation
import UIKit
import UserNotifications

/// The client half of Batch 25's push relay (see Server/push-relay). This
/// never sends or receives message content: it only (a) asks Gmail to
/// notify the relay's Pub/Sub topic when the mailbox changes
/// (`GmailAPIClient.watch`, using the token this device already holds, so
/// no credential ever reaches the relay), and (b) tells the relay which
/// device token belongs to which Gmail address, so a later contentless
/// ping can be routed to the right device. The actual subject/sender/body
/// a person ends up seeing is fetched by an ordinary sync, on-device, the
/// same as any other sync; nothing here ever touches it.
@MainActor @Observable
final class PushNotificationService {
    /// The studio's real deployment (see Server/push-relay/README.md):
    /// `corres-509320` on GCP, `corres-push-relay` Cloud Function region
    /// us-central1, `gmail-push` Pub/Sub topic. Every call here still fails
    /// closed on any network/auth error rather than crashing, the same
    /// "no-op rather than crash on unconfigured infrastructure" choice
    /// already made elsewhere in this app, which now just also covers a
    /// real but temporarily unreachable relay.
    static let relayBaseURL = URL(string: "https://us-central1-corres-509320.cloudfunctions.net/corres-push-relay")!
    static let pubsubTopicName = "projects/corres-509320/topics/gmail-push"

    private(set) var isEnabled: Bool
    var errorMessage: String?

    private let client = GmailAPIClient()
    private let defaults = UserDefaults.standard
    private static let enabledKey = "corres.push.enabled"
    private static let deviceTokenKey = "corres.push.deviceTokenHex"

    init() {
        isEnabled = defaults.bool(forKey: Self.enabledKey)
    }

    /// Explicit, Preferences-toggle-driven, not asked for at launch: a
    /// permission prompt the person didn't ask for yet is the kind of thing
    /// that erodes trust in exactly the app this session has been trying to
    /// build trust in. One toggle covers every connected account (Batch 29):
    /// there is no real reason to want new-mail pushes from one connected
    /// account but not another.
    func enableAll(accounts: [String]) async {
        let center = UNUserNotificationCenter.current()
        guard let granted = try? await center.requestAuthorization(options: [.alert, .badge, .sound]), granted else {
            errorMessage = "Notifications need permission in iOS Settings to turn on."
            return
        }
        isEnabled = true
        defaults.set(true, forKey: Self.enabledKey)
        UIApplication.shared.registerForRemoteNotifications()
        await renewWatch(accounts: accounts)
    }

    func disableAll(accounts: [String]) async {
        isEnabled = false
        defaults.set(false, forKey: Self.enabledKey)
        UIApplication.shared.unregisterForRemoteNotifications()
        await withTaskGroup(of: Void.self) { group in
            for account in accounts {
                group.addTask { try? await self.client.stopWatching(account: account) }
            }
        }
        if let deviceTokenHex = defaults.string(forKey: Self.deviceTokenKey) {
            try? await post(path: "unregister", body: ["deviceToken": deviceTokenHex])
        }
        defaults.removeObject(forKey: Self.deviceTokenKey)
    }

    /// Disconnecting a single account (Preferences' own per-row Disconnect)
    /// only needs that one account's watch/registration torn down, not every
    /// account's; `disableAll` remains the "turn notifications off entirely"
    /// path.
    func disable(account: String) async {
        try? await client.stopWatching(account: account)
        if let deviceTokenHex = defaults.string(forKey: Self.deviceTokenKey) {
            try? await post(path: "unregister", body: ["deviceToken": deviceTokenHex, "emailAddress": account])
        }
    }

    /// Called from `AppDelegate.didRegisterForRemoteNotificationsWithDeviceToken`
    /// once APNs actually hands back a real token (arrives asynchronously
    /// after `registerForRemoteNotifications()`, never synchronously).
    func didRegister(deviceToken: Data, accounts: [String]) async {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        defaults.set(hex, forKey: Self.deviceTokenKey)
        await withTaskGroup(of: Void.self) { group in
            for account in accounts {
                group.addTask { try? await self.post(path: "register", body: ["emailAddress": account, "deviceToken": hex]) }
            }
        }
    }

    /// Gmail's watch subscription expires after about 7 days; this is the
    /// app's only renewal mechanism (called at every launch), so an account
    /// left unopened for a week silently stops getting push until the next
    /// launch. A background-refresh-driven renewal would close that gap;
    /// deliberately not built here, a known and accepted limitation for v1
    /// (see Server/push-relay/README.md). Covers every connected account:
    /// the relay's `devices` record now maps one device token to a list of
    /// accounts (see Server/push-relay's own doc comment), so each account
    /// needs its own `watch` call and its own `register` post. Fired
    /// concurrently, not one after another: this runs on every launch (see
    /// `AppDelegate.performLaunchWork`) and inside a capped-duration
    /// `BGAppRefreshTask`, so N accounts waiting on each other's network
    /// round trip in turn is real, avoidable time either way.
    func renewWatch(accounts: [String]) async {
        guard isEnabled else { return }
        // Read once, on the main actor, before spawning concurrent child
        // tasks: `UserDefaults` isn't `Sendable`, so a task-group closure
        // can't reach back across the actor boundary to read `self.defaults`
        // directly without forcing an await on every access anyway.
        let deviceTokenHex = defaults.string(forKey: Self.deviceTokenKey)
        await withTaskGroup(of: Void.self) { group in
            for account in accounts {
                group.addTask {
                    // `watch` is `@discardableResult` on its own
                    // declaration, but that doesn't propagate through
                    // `try?`, which still warns its own result is unused;
                    // discard it explicitly.
                    _ = try? await self.client.watch(topicName: Self.pubsubTopicName, account: account)
                    if let deviceTokenHex {
                        try? await self.post(path: "register", body: ["emailAddress": account, "deviceToken": deviceTokenHex])
                    }
                }
            }
        }
    }

    /// The other half of "push" that was missing: until this, a silent
    /// wake-up notification synced new mail into local storage without ever
    /// telling the person it arrived, which defeated the entire point of
    /// turning notifications on. `threads` should already be filtered to
    /// genuinely newly-unread, Screener-approved threads (see
    /// `CorresApp`'s `onRemoteNotification`); this only decides how to
    /// present them. Capped at one notification per wake, not one per
    /// message: a person who hasn't opened Corres in a while could have
    /// dozens of newly-unread threads land in a single sync, and spamming a
    /// notification per message is exactly the kind of thing that gets a
    /// mail app's notifications turned back off.
    func notifyAboutNewMail(_ threads: [Correspondence]) {
        guard !threads.isEmpty else { return }
        let content = UNMutableNotificationContent()
        if threads.count == 1, let thread = threads.first {
            content.title = thread.sender
            content.body = thread.subject
        } else {
            content.title = "\(threads.count) new messages"
            let senders = threads.prefix(3).map(\.sender).joined(separator: ", ")
            content.body = threads.count > 3 ? "\(senders), and more" : senders
        }
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func post(path: String, body: [String: String]) async throws {
        var request = URLRequest(url: Self.relayBaseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        _ = try await URLSession.shared.data(for: request)
    }
}
