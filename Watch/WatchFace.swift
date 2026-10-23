import Foundation

/// What the watch face shows (see `CorresWatchWidgets`): how many emails
/// need you, and who the first is from. The Watch app writes it whenever
/// the iPhone sends mail; the face reads it. A name only, never a subject,
/// and the name is hidden while your wrist is down.
struct WatchFace: Codable, Equatable {
    var needsYou: Int
    var waiting: Int
    var firstSender: String?
    var updatedAt: Date

    static let placeholder = WatchFace(needsYou: 2, waiting: 1, firstSender: "Maya", updatedAt: .now)

    private static let key = "corres.watchFace"
    private static var defaults: UserDefaults { UserDefaults(suiteName: "group.studio.anwarcreative.corres") ?? .standard }

    /// Nil until the iPhone has sent anything.
    static func load() -> WatchFace? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(WatchFace.self, from: $0) }
    }

    /// Saves it; true when it changed, so the face needs drawing again.
    @discardableResult
    func save() -> Bool {
        guard Self.load().map({ $0.needsYou != needsYou || $0.waiting != waiting || $0.firstSender != firstSender }) ?? true else { return false }
        Self.defaults.set(try? JSONEncoder().encode(self), forKey: Self.key)
        return true
    }

    /// "Maya" from "Maya Chen": the face has room for a first name.
    static func firstName(_ sender: String) -> String {
        let trimmed = sender.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("@") { return trimmed }
        return trimmed.split(separator: " ").first.map(String.init) ?? trimmed
    }
}
