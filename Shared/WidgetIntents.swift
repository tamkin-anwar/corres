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

    /// Each tap is a small file of its own: the widget and the app never
    /// read and rewrite one shared list at the same moment, which could
    /// lose a tap made while the app was taking the others.
    private static var handledFolder: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: WidgetSnapshot.appGroup)?
            .appendingPathComponent("WidgetHandled", isDirectory: true)
    }

    /// Set by the app at launch: a Handled the system runs inside the app
    /// (it's open) is applied at once rather than on the next sync.
    nonisolated(unsafe) static var applyHandled: (@MainActor @Sendable () -> Void)?

    static func markHandled(_ id: String) {
        guard let folder = handledFolder else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? Data(id.utf8).write(to: folder.appendingPathComponent(UUID().uuidString), options: .atomic)
    }

    /// A Handled tap waiting for the app: the "account|thread" id, and the
    /// file that keeps it until the app has applied it.
    struct HandledTap {
        let id: String
        let file: URL
    }

    /// The taps not yet applied, oldest first. Read only: each stays until
    /// the app has moved its conversation and calls `finishHandled`, so a
    /// tap is never lost to an app that quits, or isn't ready, halfway.
    static func pendingHandled() -> [HandledTap] {
        // Taps saved by an earlier version, in the old shared list: kept as
        // files like the rest.
        if let old = defaults?.stringArray(forKey: handledKey), !old.isEmpty {
            old.forEach(markHandled)
            defaults?.removeObject(forKey: handledKey)
        }
        guard let folder = handledFolder,
              let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.creationDateKey],
                                                                       options: .skipsHiddenFiles) else { return [] }
        func created(_ file: URL) -> Date { (try? file.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast }
        return files.sorted { created($0) < created($1) }.compactMap { file in
            guard let data = try? Data(contentsOf: file), !data.isEmpty else { return nil }
            return HandledTap(id: String(decoding: data, as: UTF8.self), file: file)
        }
    }

    /// The ids of the taps not yet applied: kept out of the widget's Needs
    /// You until then, so a snapshot the app writes meanwhile never brings
    /// a handled email back.
    static func pendingHandledIDs() -> Set<String> {
        Set(pendingHandled().map(\.id))
    }

    /// Taps the app has applied (or whose conversation is gone).
    static func finishHandled(_ taps: [HandledTap]) {
        for tap in taps { try? FileManager.default.removeItem(at: tap.file) }
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
        if let apply = WidgetHandoff.applyHandled { await apply() }
        return .result()
    }
}
