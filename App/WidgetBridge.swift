#if os(macOS)
import AppKit
#endif
import Foundation
import UserNotifications
import WidgetKit

/// Keeps the widgets current: rebuilds the shared snapshot from the same
/// queries the lists use, and asks WidgetKit to reload only when what a
/// widget would show actually changed (reloads are budgeted by iOS).
@MainActor
enum WidgetBridge {
    private static var last: WidgetSnapshot?
    /// Widgets are part of Corres Pro once a real account is connected.
    static var isLocked = false

    /// Whether widgets, Siri and the Brief lock: a real account connected
    /// and no Pro (a subscription, or a TestFlight build's beta access).
    /// Before the first check answers, the last known answer stands in, so
    /// a subscriber's widgets never flash locked.
    static func locks(connected: Bool, entitlements: EntitlementStore) -> Bool {
        connected && !entitlements.isProForDisplay
    }

    private static var pendingUpdate: Task<Void, Never>?

    /// For changes made while the app is in use: waits for a pause, then
    /// sorts in the background. Run inline on every change, the four full
    /// sorts here landed in the middle of each swipe's animation.
    /// `threads` is read only once the wait is over: called on every
    /// change to the mail, reading it straight away put a pass over the
    /// whole mailbox inside each swipe's animation.
    static func scheduleUpdate(from currentThreads: @escaping @MainActor () -> [Correspondence]) {
        pendingUpdate?.cancel()
        pendingUpdate = Task {
            try? await Task.sleep(for: .milliseconds(800))
            guard !Task.isCancelled else { return }
            let threads = currentThreads()
            let badge = BadgeInputs.current(threads)
            let built = await Task.detached(priority: .utility) { build(from: threads, now: .now, badge: badge) }.value
            guard !Task.isCancelled else { return }
            apply(built)
        }
    }

    /// Right away, for callers that need it done before they return
    /// (background refresh, a changed setting).
    static func update(from threads: [Correspondence]) {
        pendingUpdate?.cancel()
        apply(build(from: threads, now: .now, badge: BadgeInputs.current(threads)))
    }

    /// What the badge counts, gathered on the main actor (your lessons and
    /// which accounts are in All Inboxes), so the count itself can run off it.
    struct BadgeInputs: Sendable {
        let kind: CorresSettings.Badge
        /// Accounts left out of All Inboxes are left out of the badge too.
        let hiddenAccounts: Set<String>
        /// Where you've moved an email or sender, for Primary.
        let categoryOverrides: [ThreadID: InboxCategory]
        let since: Date?

        @MainActor static func current(_ threads: [Correspondence]) -> BadgeInputs {
            // Free with no Pro, where Needs You is locked: counting a list you
            // can't open would be a number with nowhere to go, so the badge
            // counts unread Primary mail instead, as Mail does with its inbox.
            let chosen = CorresSettings.badge
            let kind: CorresSettings.Badge = chosen == .needsYou && WidgetBridge.isLocked ? .primary : chosen
            let accounts = UserDefaults.standard.stringArray(forKey: "corres.connectedAccounts") ?? []
            let hidden = Set(accounts.filter { !AccountPreferences.showsInAllInboxes($0) })
            var overrides: [ThreadID: InboxCategory] = [:]
            if kind == .primary {
                for thread in threads where thread.isUnread {
                    if let category = SenderLessons.category(for: thread) { overrides[thread.id] = category }
                }
            }
            let since = UserDefaults.standard.object(forKey: CorresSettings.lastLeftKey) as? Date
            return BadgeInputs(kind: kind, hiddenAccounts: hidden.count < accounts.count ? hidden : [],
                               categoryOverrides: overrides, since: since)
        }
    }

    private struct Built: Sendable {
        var snapshot: WidgetSnapshot
        let badge: Int
    }

    nonisolated private static func build(from threads: [Correspondence], now: Date, badge: BadgeInputs) -> Built {
        let needs = MailQuery.prioritized(threads, attention: .needsYou, now: now)
        let waiting = MailQuery.prioritized(threads, attention: .waiting, now: now)
        let unread = MailQuery.filter(threads, now: now).filter(\.isUnread).count
        let known = Correspondence.knownSenderNames(threads)
        // Waiting is your own messages: named for who you're waiting on.
        func item(_ thread: Correspondence) -> WidgetSnapshot.Item {
            WidgetSnapshot.Item(account: thread.id.account, threadID: thread.id.providerID,
                                sender: thread.counterpartName(knownNames: known),
                                subject: thread.subject, reason: thread.displayReason, receivedAt: thread.receivedAt,
                                isUnread: thread.isUnread, dueLabel: thread.dueAt.map(dueLabel))
        }
        let isSample = !threads.isEmpty && threads.allSatisfy { $0.id.account == "sample" }
        let snapshot = WidgetSnapshot(needsYouCount: needs.count, waitingCount: waiting.count, unreadCount: unread,
                                      needsYou: needs.prefix(6).map(item), waiting: waiting.prefix(6).map(item),
                                      isSample: isSample, updatedAt: now)
        // Settings → Lists → App icon badge: what needs you (default, in
        // keeping with Corres), everything unread, or nothing. Sample mail
        // never badges the real app icon.
        let counted = badge.hiddenAccounts.isEmpty ? threads : threads.filter { !badge.hiddenAccounts.contains($0.id.account) }
        let inbox = MailQuery.filter(counted, now: now).filter(\.isUnread)
        let count: Int
        switch badge.kind {
        case .needsYou:
            count = MailQuery.prioritized(counted, attention: .needsYou, now: now).count
        case .primary:
            let context = InboxCategory.context(for: counted)
            count = inbox.filter { InboxCategory.of($0, override: badge.categoryOverrides[$0.id], context: context, now: now) == .primary }.count
        case .unread:
            count = inbox.count
        case .new:
            count = badge.since.map { since in inbox.filter { $0.receivedAt > since }.count } ?? 0
        case .off:
            count = 0
        }
        return Built(snapshot: snapshot, badge: isSample || threads.isEmpty ? 0 : count)
    }

    private static func apply(_ built: Built) {
        if built.badge != lastBadge {
            lastBadge = built.badge
            #if os(macOS)
            // The Dock icon, by the same rules as the iPhone's: the only
            // place the Mac sets it, and it needs no notification permission.
            NSApplication.shared.dockTile.badgeLabel = built.badge > 0 ? "\(built.badge)" : nil
            #else
            // iOS ties badges to notification permission; shows once allowed.
            UNUserNotificationCenter.current().setBadgeCount(built.badge)
            #endif
        }
        var snapshot = built.snapshot
        snapshot.isLocked = isLocked && !snapshot.isSample
        BriefNotifier.reschedule(snapshot)
        // Compare without the timestamp, so a sync that changed nothing
        // doesn't spend the widget reload budget.
        var comparable = snapshot
        comparable.updatedAt = last?.updatedAt ?? snapshot.updatedAt
        guard comparable != last else { return }
        snapshot.save()
        last = snapshot
        WidgetCenter.shared.reloadAllTimelines()
    }

    private static var lastBadge: Int?

    nonisolated private static func dueLabel(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return String(localized: "Today") }
        if calendar.isDateInTomorrow(date) { return String(localized: "Tomorrow") }
        return date.formatted(.dateTime.weekday(.abbreviated))
    }
}
