import Foundation

/// Compiled regular expressions, built once per pattern for the life of
/// the app. `String.range(of:options: .regularExpression)` compiles its
/// pattern on every call; the inbox's categories alone made hundreds of
/// those calls per refresh, about half a second on the main thread each
/// time the mail changed.
final class PatternCache: @unchecked Sendable {
    static let shared = PatternCache()
    private let lock = NSLock()
    private var compiled: [String: NSRegularExpression] = [:]

    func regex(_ pattern: String, caseInsensitive: Bool) -> NSRegularExpression? {
        let key = (caseInsensitive ? "i:" : "s:") + pattern
        lock.lock(); defer { lock.unlock() }
        if let found = compiled[key] { return found }
        guard let made = try? NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : []) else { return nil }
        compiled[key] = made
        return made
    }
}

extension String {
    /// `range(of: pattern, options: .regularExpression)`, with the pattern
    /// compiled once and kept (`PatternCache`).
    func patternRange(_ pattern: String, caseInsensitive: Bool = false) -> Range<String.Index>? {
        guard let regex = PatternCache.shared.regex(pattern, caseInsensitive: caseInsensitive),
              let match = regex.firstMatch(in: self, range: NSRange(startIndex..., in: self)) else { return nil }
        return Range(match.range, in: self)
    }
}

extension Substring {
    func patternRange(_ pattern: String, caseInsensitive: Bool = false) -> Range<String.Index>? {
        guard let regex = PatternCache.shared.regex(pattern, caseInsensitive: caseInsensitive) else { return nil }
        let text = String(self)
        guard let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let local = Range(match.range, in: text) else { return nil }
        let lower = index(startIndex, offsetBy: text.distance(from: text.startIndex, to: local.lowerBound))
        let upper = index(lower, offsetBy: text.distance(from: local.lowerBound, to: local.upperBound))
        return lower..<upper
    }
}

extension String {
    /// `replacingOccurrences(of: pattern, with:, options: .regularExpression)`
    /// with the pattern compiled once (`PatternCache`). `template` uses $1.
    func replacingPattern(_ pattern: String, with template: String, caseInsensitive: Bool = false) -> String {
        guard let regex = PatternCache.shared.regex(pattern, caseInsensitive: caseInsensitive) else { return self }
        return regex.stringByReplacingMatches(in: self, range: NSRange(startIndex..., in: self), withTemplate: template)
    }
}

/// Answers to pure questions about one piece of text (is this subject a
/// receipt? an offer?), kept so the same conversations aren't re-read on
/// every refresh. Bounded: cleared when it grows past `limit`.
final class Memo<Key: Hashable & Sendable, Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Key: Value] = [:]
    private let limit: Int
    init(limit: Int = 20_000) { self.limit = limit }

    func value(_ key: Key, _ compute: () -> Value) -> Value {
        lock.lock()
        if let found = values[key] { lock.unlock(); return found }
        lock.unlock()
        let made = compute()
        lock.lock()
        if values.count >= limit { values.removeAll(keepingCapacity: true) }
        values[key] = made
        lock.unlock()
        return made
    }
}
