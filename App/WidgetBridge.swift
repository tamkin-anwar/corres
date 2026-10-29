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
            await buildInBackground(from: currentThreads(), priority: .utility)
        }
    }

    /// Right away, for callers that need it done before they return
    /// (a changed setting, leaving the app).
    static func update(from threads: [Correspondence]) {
        pendingUpdate?.cancel()
        generation &+= 1
        apply(build(from: threads, now: .now, badge: BadgeInputs.current(threads), handled: WidgetHandoff.pendingHandledIDs()))
    }

    /// Now, but sorted off the main thread, for callers that can wait for
    /// it (a push, the lock changing at launch). The same sorts on the main
    /// thread took tens of milliseconds on a big mailbox.
    static func updateInBackground(from threads: [Correspondence]) async {
        pendingUpdate?.cancel()
        await buildInBackground(from: threads, priority: .userInitiated)
    }

    /// Whichever update started last is the one shown: an older one that
    /// finishes after it is dropped.
    private static var generation = 0

    private static func buildInBackground(from threads: [Correspondence], priority: TaskPriority) async {
        generation &+= 1
        let started = generation
        let badge = BadgeInputs.current(threads)
        let handled = WidgetHandoff.pendingHandledIDs()
        let built = await Task.detached(priority: priority) {
            build(from: threads, now: .now, badge: badge, handled: handled)
        }.value
        guard !Task.isCancelled, started == generation else { return }
        apply(built)
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

    /// `handled`: marked Handled on a widget and not yet applied by the app
    /// (`WidgetHandoff`), left out of Needs You so they don't come back.
    nonisolated private static func build(from threads: [Correspondence], now: Date, badge: BadgeInputs,
                                          handled: Set<String>) -> Built {
        func isHandled(_ thread: Correspondence) -> Bool { handled.contains(thread.id.account + "|" + thread.id.providerID) }
        let needs = MailQuery.prioritized(threads, attention: .needsYou, now: now).filter { !isHandled($0) }
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
            count = MailQuery.prioritized(counted, attention: .needsYou, now: now).filter { !isHandled($0) }.count
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
        // Handled on a widget while this was being put together.
        let handled = WidgetHandoff.pendingHandledIDs()
        let shown = snapshot.needsYou.count
        snapshot.needsYou.removeAll { handled.contains($0.id) }
        snapshot.needsYouCount = max(0, snapshot.needsYouCount - (shown - snapshot.needsYou.count))
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
