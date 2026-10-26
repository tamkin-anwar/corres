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

    /// Older than this, the face and the app say when they last heard
    /// from the iPhone, rather than show old numbers as if they were new.
    static let staleAfter: TimeInterval = 3 * 3600

    func isStale(at date: Date) -> Bool { date.timeIntervalSince(updatedAt) > Self.staleAfter }

    /// Saves it, every time, so when it was last heard is always kept;
    /// true when the face needs drawing again: what it shows changed, it
    /// was showing as out of date, or the time moved on enough to matter.
    @discardableResult
    func save() -> Bool {
        let saved = Self.load()
        Self.defaults.set(try? JSONEncoder().encode(self), forKey: Self.key)
        guard let saved else { return true }
        return saved.needsYou != needsYou || saved.waiting != waiting || saved.firstSender != firstSender
            || saved.isStale(at: .now) || updatedAt.timeIntervalSince(saved.updatedAt) > 30 * 60
    }

    /// "Maya" from "Maya Chen": the face has room for a first name.
    static func firstName(_ sender: String) -> String {
        let trimmed = sender.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("@") { return trimmed }
        return trimmed.split(separator: " ").first.map(String.init) ?? trimmed
    }
}
