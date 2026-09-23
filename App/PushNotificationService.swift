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
    /// Placeholders. Point these at your own deployment; see
    /// Server/push-relay/README.md step 5. Every call here fails closed
    /// (silently does nothing) until they're set to something real, the
    /// same "no-op rather than crash on unconfigured infrastructure" choice
    /// already made elsewhere in this app.
    static let relayBaseURL = URL(string: "https://example.invalid/corres-push-relay")!
    static let pubsubTopicName = "projects/your-project-id/topics/gmail-push"

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
    /// build trust in.
    func enable(account: String) async {
        let center = UNUserNotificationCenter.current()
        guard let granted = try? await center.requestAuthorization(options: [.alert, .badge, .sound]), granted else {
            errorMessage = "Notifications need permission in iOS Settings to turn on."
            return
        }
        isEnabled = true
        defaults.set(true, forKey: Self.enabledKey)
        UIApplication.shared.registerForRemoteNotifications()
        await renewWatch(account: account)
    }

    func disable(account: String?) async {
        isEnabled = false
        defaults.set(false, forKey: Self.enabledKey)
        UIApplication.shared.unregisterForRemoteNotifications()
        if account != nil {
            try? await client.stopWatching()
        }
        if let deviceTokenHex = defaults.string(forKey: Self.deviceTokenKey) {
            try? await post(path: "unregister", body: ["deviceToken": deviceTokenHex])
        }
        defaults.removeObject(forKey: Self.deviceTokenKey)
    }

    /// Called from `AppDelegate.didRegisterForRemoteNotificationsWithDeviceToken`
    /// once APNs actually hands back a real token (arrives asynchronously
    /// after `registerForRemoteNotifications()`, never synchronously).
    func didRegister(deviceToken: Data, account: String?) async {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        defaults.set(hex, forKey: Self.deviceTokenKey)
        guard let account else { return }
        try? await post(path: "register", body: ["emailAddress": account, "deviceToken": hex])
    }

    /// Gmail's watch subscription expires after about 7 days; this is the
    /// app's only renewal mechanism (called at every launch), so an account
    /// left unopened for a week silently stops getting push until the next
    /// launch. A background-refresh-driven renewal would close that gap;
    /// deliberately not built here, a known and accepted limitation for v1
    /// (see Server/push-relay/README.md).
    func renewWatch(account: String) async {
        guard isEnabled else { return }
        // `watch` is `@discardableResult` on its own declaration, but that
        // doesn't propagate through `try?`, which still warns its own
        // result is unused; discard it explicitly.
        _ = try? await client.watch(topicName: Self.pubsubTopicName)
        if let deviceTokenHex = defaults.string(forKey: Self.deviceTokenKey) {
            try? await post(path: "register", body: ["emailAddress": account, "deviceToken": deviceTokenHex])
        }
    }

    private func post(path: String, body: [String: String]) async throws {
        var request = URLRequest(url: Self.relayBaseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        _ = try await URLSession.shared.data(for: request)
    }
}
