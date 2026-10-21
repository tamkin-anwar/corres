import AppIntents
import Foundation
import WidgetKit

/// Actions that start outside Corres: a Control Center button, or Handled
/// on a widget. Compiled into the app and the widget extension. What the
/// app has to do is handed over through the App Group: a place to open
/// (`pendingRoute`), or conversations marked Handled from a widget, which
/// the app moves the next time it runs.
enum WidgetHandoff {
    private static var defaults: UserDefaults? { UserDefaults(suiteName: WidgetSnapshot.appGroup) }
    private static let routeKey = "corres.pendingRoute"
    private static let handledKey = "corres.widgetHandled"

    /// Set by the app at launch, so a control that opens the app routes
    /// at once.
    nonisolated(unsafe) static var open: (@MainActor (String) -> Void)?

    @MainActor
    static func route(_ destination: String) {
        if let open { open(destination) } else { defaults?.set(destination, forKey: routeKey) }
    }

    /// The place a control asked for before the app was ready, once.
    static func takePendingRoute() -> String? {
        guard let route = defaults?.string(forKey: routeKey) else { return nil }
        defaults?.removeObject(forKey: routeKey)
        return route
    }

    static func markHandled(_ id: String) {
        var ids = defaults?.stringArray(forKey: handledKey) ?? []
        if !ids.contains(id) { ids.append(id) }
        defaults?.set(ids, forKey: handledKey)
    }

    /// "account|thread" ids marked Handled from a widget since last time.
    static func takeHandled() -> [String] {
        let ids = defaults?.stringArray(forKey: handledKey) ?? []
        defaults?.removeObject(forKey: handledKey)
        return ids
    }
}

/// Control Center, the Lock Screen and the Action button: a new email.
struct ComposeControlIntent: AppIntent {
    static let title: LocalizedStringResource = "New Email"
    static let description = IntentDescription("Start a new email in Corres.")
    @available(iOS 26.0, macOS 26.0, *)
    static var supportedModes: IntentModes { .foreground(.immediate) }
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        WidgetHandoff.route("compose")
        return .result()
    }
}

/// Control Center: straight to what needs you.
struct OpenNeedsYouControlIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Needs You"
    static let description = IntentDescription("Open Needs You in Corres.")
    @available(iOS 26.0, macOS 26.0, *)
    static var supportedModes: IntentModes { .foreground(.immediate) }
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        WidgetHandoff.route("needs-you")
        return .result()
    }
}

/// Handled, from a Needs You widget: gone from the widget at once, and
/// moved in Corres the next time it runs.
struct MarkHandledFromWidgetIntent: AppIntent {
    static let title: LocalizedStringResource = "Mark as Handled"
    static let isDiscoverable = false

    @Parameter(title: "Conversation") var conversation: String

    init() {}
    init(conversation: String) { self.conversation = conversation }

    func perform() async throws -> some IntentResult {
        WidgetHandoff.markHandled(conversation)
        if var snapshot = WidgetSnapshot.load() {
            let before = snapshot.needsYou.count
            snapshot.needsYou.removeAll { $0.id == conversation }
            snapshot.needsYouCount = max(0, snapshot.needsYouCount - (before - snapshot.needsYou.count))
            snapshot.save()
        }
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}
