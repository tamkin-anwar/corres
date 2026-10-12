import Foundation
import Observation

/// Notices habits (`SenderHabits`) as you work and offers the change they
/// suggest, once, at the moment it's relevant: right after you archive
/// unread mail from a list you never open, or reply to someone you always
/// answer. Shown by `CorresShell` once any Undo has cleared; accepted,
/// declined for a month, or declined for good. Counted on this iPhone.
@MainActor @Observable
final class HabitWatcher {
    static let shared = HabitWatcher()

    /// The suggestion on screen, if any.
    private(set) var offer: SenderHabits.Suggestion?
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
        if let thread = threads.last { consider(thread) }
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
        consider(thread)
    }

    // MARK: Offering

    private func consider(_ thread: Correspondence) {
        guard offer == nil, let email = thread.senderEmail else { return }
        let isList = thread.listUnsubscribeMailto != nil || thread.listUnsubscribeURL != nil
        guard let suggestion = habits.suggestion(for: email, name: thread.sender, isList: isList,
                                                 isPerson: !thread.looksAutomated && !isList,
                                                 isVIP: InboxClassifier.isVIP(email)) else { return }
        habits.markOffered()
        save()
        offer = suggestion
    }

    var title: String {
        switch offer {
        case .unsubscribe(_, let name, let unopened)?:
            "You haven't opened the last \(unopened) from \(name). Unsubscribe?"
        case .vip(_, let name, .readsQuickly(let minutes))?:
            "You read \(name)'s email within \(minutes == 1 ? "a minute" : "\(minutes) minutes"). Make them a VIP?"
        case .vip(_, let name, .repliesOften(let count))?:
            "You've replied to \(name) \(count) times lately. Make them a VIP?"
        case nil: ""
        }
    }

    var actionTitle: String {
        switch offer {
        case .unsubscribe?: "Unsubscribe"
        case .vip?: "Make VIP"
        case nil: ""
        }
    }

    func accept(store: MailStore, unsubscriber: UnsubscribeService) async {
        guard let offer else { return }
        self.offer = nil
        habits.resolve(offer)
        save()
        let latest = store.threads.filter { $0.senderEmail?.lowercased() == offer.email }.max { $0.receivedAt < $1.receivedAt }
        switch offer {
        case .unsubscribe:
            if let latest { await unsubscriber.unsubscribe(from: latest, store: store) }
        case .vip:
            await store.setVIP(offer.email, account: latest?.id.account ?? "", isVIP: true)
        }
    }

    /// "Not now" (a month) or "Never" (for good).
    func decline(forever: Bool) {
        guard let offer else { return }
        habits.decline(offer, forever: forever)
        save()
        self.offer = nil
    }

    func forgetAll() {
        habits.forgetAll()
        offer = nil
        save()
    }

    private func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(habits), forKey: Self.key)
    }
}
