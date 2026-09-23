import UIKit

/// A minimal bridge for the two callbacks SwiftUI's `App` protocol has no
/// direct equivalent for: getting the real APNs device token back, and
/// waking up for a silent background push. Deliberately thin: it holds no
/// state and does no work of its own, only forwards to closures `CorresApp`
/// wires up once its own `store`/`sync`/`auth`/`pushService` exist (this
/// delegate is constructed by `@UIApplicationDelegateAdaptor` before that
/// happens, so it cannot hold direct references to them at init time).
final class AppDelegate: NSObject, UIApplicationDelegate {
    var onDeviceToken: ((Data) -> Void)?
    var onRemoteNotification: (() async -> Void)?

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        onDeviceToken?(deviceToken)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // Best-effort feature: a failed APNs registration (no network, a
        // simulator with no push entitlement, etc.) should not surface as
        // an error anywhere a person would see it unprompted.
    }

    func application(_ application: UIApplication,
                     didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        await onRemoteNotification?()
        return .newData
    }
}
