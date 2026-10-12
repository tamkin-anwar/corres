import Foundation

/// What you've taught Corres by correcting it, kept on this iPhone and
/// shown in Settings → Sorting → What Corres Has Learned, where any lesson
/// can be forgotten. Gmail's Priority Inbox learns from "not important"
/// too, but out of sight; here every lesson is said when it's learned
/// ("Won't flag Google again"), listed, and taken back by Undo.
///
/// - Saying "No action needed" about mail Apple Intelligence put in Needs
///   You: it won't bring that sender's mail in again, and takes back what
///   it already brought in.
/// - Moving a sender's automated mail into Needs You yourself: it won't
///   take that sender's mail out.
///
/// Rules and VIPs are untouched; this steers the on-device model.
@MainActor
enum SenderLessons {
    struct Lesson: Codable, Hashable, Identifiable {
        enum Kind: String, Codable { case quiet, keep }
        let email: String
        var name: String
        var kind: Kind
        var learnedAt: Date
        var id: String { email }

        var summary: String {
            switch kind {
            case .quiet: "Its mail needs no action from you"
            case .keep: "Its mail belongs in Needs You"
            }
        }
    }

    private static let lessonsKey = "corres.lessons"
    static let enabledKey = "corres.lessons.enabled"

    /// Settings → Sorting → Learn from My Changes.
    static var isEnabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }

    static var all: [Lesson] {
        get {
            guard let data = UserDefaults.standard.data(forKey: lessonsKey),
                  let lessons = try? JSONDecoder().decode([Lesson].self, from: data) else { return [] }
            return lessons
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: lessonsKey) }
    }

    private static func lesson(for email: String?) -> Lesson? {
        guard isEnabled, let email = email?.lowercased() else { return nil }
        return all.first { $0.email == email }
    }

    static func isQuieted(_ email: String?) -> Bool { lesson(for: email)?.kind == .quiet }
    static func isKept(_ email: String?) -> Bool { lesson(for: email)?.kind == .keep }

    /// Learns from a move you made, and says what it learned (for the Undo
    /// pill), or nil when the move taught nothing.
    static func learn(from thread: Correspondence, was previous: Attention, now attention: Attention) -> String? {
        guard isEnabled, let email = thread.senderEmail?.lowercased(), !thread.isFromAccountOwner else { return nil }
        let kind: Lesson.Kind
        if previous == .needsYou, attention == .quiet, thread.wasPromotedByIntelligence {
            kind = .quiet
        } else if attention == .needsYou, previous != .needsYou, thread.looksAutomated {
            kind = .keep
        } else {
            return nil
        }
        var lessons = all.filter { $0.email != email }
        lessons.append(Lesson(email: email, name: thread.sender, kind: kind, learnedAt: .now))
        all = lessons
        return kind == .quiet ? "Won't flag \(thread.sender) again" : "\(thread.sender) stays in Needs You"
    }

    static func forget(_ email: String) { all = all.filter { $0.email != email } }
    static func forgetAll() { all = [] }
}

extension Correspondence {
    /// In Needs You because the on-device model brought it in: automated
    /// mail, assessed at its latest message, with no rule of Corres's own
    /// behind it.
    var wasPromotedByIntelligence: Bool {
        attention == .needsYou && looksAutomated && triagedMessageID != nil && triagedMessageID == latestMessageID
            && !InboxClassifier.ruleReasons.contains(reason)
    }
}
