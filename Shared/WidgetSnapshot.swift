import Foundation

/// What the Home Screen and Lock Screen widgets show, written by the app
/// into the shared App Group whenever its mail changes. Only this small
/// summary crosses into the widget: counts, and sender / subject / reason
/// for the few conversations shown. Compiled into both the app and the
/// widget extension, so it depends on nothing else.
struct WidgetSnapshot: Codable, Equatable {
    struct Item: Codable, Equatable, Identifiable {
        let account: String
        let threadID: String
        let sender: String
        let subject: String
        let reason: String
        let receivedAt: Date
        let isUnread: Bool
        let dueLabel: String?
        var id: String { account + "|" + threadID }

        /// Opens this conversation in Corres.
        var url: URL {
            var components = URLComponents()
            components.scheme = WidgetSnapshot.urlScheme
            components.host = "thread"
            components.queryItems = [URLQueryItem(name: "account", value: account), URLQueryItem(name: "id", value: threadID)]
            return components.url ?? WidgetSnapshot.url(for: "needs-you")
        }
    }

    var needsYouCount: Int
    var waitingCount: Int
    var unreadCount: Int
    var needsYou: [Item]
    var waiting: [Item]
    var isSample: Bool
    /// Pro has lapsed: the widget invites opening Corres instead of showing mail.
    var isLocked: Bool? = nil
    var updatedAt: Date

    static let appGroup = "group.studio.anwarcreative.corres"
    static let urlScheme = "corres"
    private static let fileName = "widget-snapshot.json"

    static func url(for destination: String) -> URL { URL(string: "\(urlScheme)://\(destination)")! }

    static let placeholder = WidgetSnapshot(
        needsYouCount: 3, waitingCount: 2, unreadCount: 5,
        needsYou: [
            Item(account: "", threadID: "1", sender: "Maya Chen", subject: "The next chapter",
                 reason: "Asks you to approve the direction", receivedAt: .now, isUnread: true, dueLabel: "Tomorrow"),
            Item(account: "", threadID: "2", sender: "Oliver Grant", subject: "A moment before we move forward",
                 reason: "Waiting for your choice", receivedAt: .now.addingTimeInterval(-3600), isUnread: true, dueLabel: nil),
            Item(account: "", threadID: "3", sender: "Sofia Laurent", subject: "A place at the table",
                 reason: "Asks you to confirm Thursday", receivedAt: .now.addingTimeInterval(-7200), isUnread: false, dueLabel: "Thu"),
        ],
        waiting: [
            Item(account: "", threadID: "4", sender: "James Okafor", subject: "Partnership proposal",
                 reason: "Sending a revised scope", receivedAt: .now.addingTimeInterval(-86_400), isUnread: false, dueLabel: nil),
        ],
        isSample: true, updatedAt: .now)

    private static var fileURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?.appendingPathComponent(fileName)
    }

    static func load() -> WidgetSnapshot? {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(WidgetSnapshot.self, from: data)
    }

    func save() {
        guard let url = Self.fileURL else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(self) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
