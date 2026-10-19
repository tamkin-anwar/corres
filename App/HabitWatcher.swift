import Foundation
import Observation

/// Notices habits (`SenderHabits`) as you work: unread mail from a list
/// you never open, someone you always answer. What they suggest waits in
/// Settings → Senders, to accept, decline for a month, or decline for
/// good. Counted on this iPhone.
@MainActor @Observable
final class HabitWatcher {
    static let shared = HabitWatcher()

    private var habits: SenderHabits
    private static let key = "corres.habits"

    private init() {
        habits = UserDefaults.standard.data(forKey: Self.key)
            .flatMap { try? JSONDecoder().decode(SenderHabits.self, from: $0) } ?? SenderHabits()
    }

    private var isEnabled: Bool { SenderLessons.isEnabled }

    // MARK: What you did

    /// Archived or deleted. Only unread mail says "I never read these".
    func removed(_ threads: [Correspondence]) {
        guard isEnabled else { return }
        for thread in threads where thread.isUnread && !thread.isFromAccountOwner {
            guard let email = thread.senderEmail else { continue }
            habits.recordRemovedUnread(email)
        }
        save()
    }

    func opened(_ thread: Correspondence) {
        guard isEnabled, thread.isUnread, !thread.isFromAccountOwner, let email = thread.senderEmail else { return }
        habits.recordOpen(email, receivedAt: thread.receivedAt)
        save()
    }

    func replied(to thread: Correspondence) {
        guard isEnabled, !thread.isFromAccountOwner, let email = thread.senderEmail else { return }
        habits.recordReply(to: email)
        save()
    }

    // MARK: Suggestions

    /// What your habits suggest, for Settings → Senders. Never shown over
    /// your mail: an offer that popped up after a swipe interrupted the
    /// very thing it was about.
    func suggestions(in threads: [Correspondence]) -> [SenderHabits.Suggestion] {
        guard isEnabled else { return [] }
        var latest: [String: Correspondence] = [:]
        for thread in threads where !thread.isFromAccountOwner {
            guard let email = thread.senderEmail?.lowercased() else { continue }
            if (latest[email]?.receivedAt ?? .distantPast) < thread.receivedAt { latest[email] = thread }
        }
        return latest.values.sorted { $0.receivedAt > $1.receivedAt }.compactMap { thread in
            let isList = thread.listUnsubscribeMailto != nil || thread.listUnsubscribeURL != nil
            return habits.suggestion(for: thread.senderEmail ?? "", name: thread.sender, isList: isList,
                                     isPerson: !thread.looksAutomated && !isList,
                                     isVIP: InboxClassifier.isVIP(thread.senderEmail ?? ""), paced: false)
        }
    }

    static func title(for suggestion: SenderHabits.Suggestion) -> String {
        switch suggestion {
        case .unsubscribe(_, let name, let unopened):
            "You haven't opened the last \(unopened) from \(name)."
        case .vip(_, let name, .readsQuickly(let minutes)):
            "You read \(name)'s email within \(minutes == 1 ? "a minute" : "\(minutes) minutes")."
        case .vip(_, let name, .repliesOften(let count)):
            "You've replied to \(name) \(count) times lately."
        }
    }

    static func actionTitle(for suggestion: SenderHabits.Suggestion) -> String {
        switch suggestion {
        case .unsubscribe: "Unsubscribe"
        case .vip: "Make VIP"
        }
    }

    func accept(_ suggestion: SenderHabits.Suggestion, store: MailStore, unsubscriber: UnsubscribeService?) async {
        habits.resolve(suggestion)
        save()
        let latest = store.threads.filter { $0.senderEmail?.lowercased() == suggestion.email }.max { $0.receivedAt < $1.receivedAt }
        switch suggestion {
        case .unsubscribe:
            if let latest, let unsubscriber { await unsubscriber.unsubscribe(from: latest, store: store) }
        case .vip:
            await store.setVIP(suggestion.email, account: latest?.id.account ?? "", isVIP: true)
        }
    }

    /// "Not now" (a month) or "Never" (for good).
    func decline(_ suggestion: SenderHabits.Suggestion, forever: Bool) {
        habits.decline(suggestion, forever: forever)
        save()
    }

    func forgetAll() {
        habits.forgetAll()
        save()
    }

    private func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(habits), forKey: Self.key)
    }
}
