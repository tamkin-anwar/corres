import Foundation
import Observation
import UserNotifications

/// Send Later. Gmail's API can't schedule a send, so, like Apple Mail,
/// Corres holds the email on this iPhone (never on a server) and sends it
/// at the time you picked:
/// - while Corres is open, on the minute;
/// - in the background, whenever iOS lets it run (background refresh, and
///   each new-mail push that wakes it);
/// - and if iOS hasn't let it run by then, a notification asks you to open
///   Corres, which sends it at once. Nothing goes early, nothing is lost.
///
/// Like Superhuman's, a scheduled reply waits if they answer first: it's
/// held, with a notification, instead of following up on mail that's
/// already been answered.
@MainActor @Observable
final class ScheduledSends {
    static let shared = ScheduledSends()

    struct Item: Codable, Identifiable, Equatable {
        let id: UUID
        var draft: Draft
        var sendAt: Date
        /// Replies after this hold it. Moved to when you gave a held one
        /// a new time, knowing they'd replied.
        var scheduledAt: Date
        /// They replied after it was scheduled; waiting for you to decide.
        var heldBecauseReplied = false
        /// Tried once already, in the Share sheet: sent under its own
        /// Message-ID, after asking Gmail. Optional so saved items decode.
        var fromShareSheet: Bool?

        static func == (a: Item, b: Item) -> Bool {
            a.id == b.id && a.sendAt == b.sendAt && a.heldBecauseReplied == b.heldBecauseReplied
        }
    }

    private(set) var items: [Item] = []
    /// Set by the shell: says it's scheduled, with Undo.
    var announce: ((Item) -> Void)?
    private var timer: Task<Void, Never>?
    /// What the timer sends with, kept from the last `keepTime`, so a send
    /// scheduled while Corres is open goes on its minute too.
    private weak var timeStore: MailStore?
    private weak var timeOutbox: OutboxService?

    private static var fileURL: URL {
        #if DEBUG
        // Screenshots on sample mail beside a real Corres: never its queue.
        if ProcessInfo.processInfo.arguments.contains("-SampleMailOnly") {
            return URL.temporaryDirectory.appending(path: "sample-scheduled-sends.json")
        }
        #endif
        return URL.applicationSupportDirectory.appending(path: "scheduled-sends.json")
    }

    private init() {
        if let data = try? Data(contentsOf: Self.fileURL),
           let saved = try? JSONDecoder().decode([Item].self, from: data) {
            items = saved
        }
    }

    var nextSendAt: Date? { items.filter { !$0.heldBecauseReplied }.map(\.sendAt).min() }

    // MARK: Scheduling

    func schedule(_ draft: Draft, at date: Date) {
        let item = Item(id: draft.id, draft: draft, sendAt: date, scheduledAt: .now)
        items.removeAll { $0.id == item.id }
        items.append(item)
        items.sort { $0.sendAt < $1.sendAt }
        save()
        scheduleReminder(for: item)
        #if os(iOS)
        AppDelegate.scheduleBackgroundRefresh()
        #endif
        rearm()
        announce?(item)
    }

    func reschedule(_ id: UUID, to date: Date) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].sendAt = date
        // Held, and given a new time: their reply is known, so only a
        // later one holds it again. It used to be held again at the new
        // time, every time, for the reply you'd already seen.
        if items[index].heldBecauseReplied { items[index].scheduledAt = .now }
        items[index].heldBecauseReplied = false
        items.sort { $0.sendAt < $1.sendAt }
        save()
        scheduleReminder(for: items.first { $0.id == id }!)
        // Sooner now, perhaps: iOS is told the new earliest moment.
        #if os(iOS)
        AppDelegate.scheduleBackgroundRefresh()
        #endif
        rearm()
    }

    /// Taken off the schedule (Cancel, or opened to edit): its draft.
    @discardableResult
    func remove(_ id: UUID) -> Draft? {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return nil }
        let item = items.remove(at: index)
        save()
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [Self.reminderID(item.id)])
        return item.draft
    }

    /// The account was removed: its scheduled emails go with it, as its
    /// unsent ones do (`OutboxService.forget`). Left here, each one came
    /// due and failed as "Couldn't send" from an account that was gone.
    func forget(account: String) {
        let gone = items.filter { ($0.draft.fromAccount ?? $0.draft.threadID?.account)?.lowercased() == account.lowercased() }
        for item in gone { remove(item.id) }
        if !gone.isEmpty { rearm() }
    }

    // MARK: Sending

    /// Sends whatever is due. Called on launch, on foreground, from
    /// background refresh and from each push that wakes Corres.
    func sendDue(store: MailStore, outbox: OutboxService, now: Date = .now) async {
        adoptShared(now: now)
        // Saved as a draft in the Share sheet with no connection.
        await outbox.saveSharedDrafts()
        guard items.contains(where: { !$0.heldBecauseReplied && $0.sendAt <= now }) else { keepTime(store: store, outbox: outbox); return }
        // On a cold launch: the conversation a reply belongs to, and the
        // account it goes from, both have to be back first.
        if store.state != .loaded { await store.load() }
        await outbox.waitForAccounts()
        for item in items where !item.heldBecauseReplied && item.sendAt <= now {
            // Two checks can overlap (a push as Corres opens): whichever
            // takes it off the list first is the one that sends it.
            guard let current = items.first(where: { $0.id == item.id }), !current.heldBecauseReplied,
                  current.sendAt <= now else { continue }
            let thread = item.draft.threadID.flatMap { store.thread($0) }
            // A reply they've already answered: hold it, and ask.
            if let thread, item.draft.kind != .new, !thread.isFromAccountOwner, thread.receivedAt > item.scheduledAt {
                hold(item, because: thread.sender)
                continue
            }
            remove(item.id)
            await outbox.sendNow(item.draft, replyingTo: thread, asEarlierAttempt: item.fromShareSheet == true)
        }
        keepTime(store: store, outbox: outbox)
    }

    /// Written in the Share sheet with no connection: sent now, from here,
    /// and listed in Send Later until it goes.
    private func adoptShared(now: Date) {
        let shared = ShareOutbox.takeAll()
        guard !shared.isEmpty else { return }
        for draft in shared where !items.contains(where: { $0.id == draft.id }) {
            items.append(Item(id: draft.id, draft: draft, sendAt: now, scheduledAt: now, fromShareSheet: true))
        }
        items.sort { $0.sendAt < $1.sendAt }
        save()
    }

    func sendNow(_ id: UUID, store: MailStore, outbox: OutboxService) async {
        guard let item = items.first(where: { $0.id == id }) else { return }
        remove(id)
        await outbox.sendNow(item.draft, replyingTo: item.draft.threadID.flatMap { store.thread($0) },
                             asEarlierAttempt: item.fromShareSheet == true)
    }

    /// While Corres is open, sends each one on its minute.
    func keepTime(store: MailStore, outbox: OutboxService) {
        timeStore = store
        timeOutbox = outbox
        timer?.cancel()
        guard let next = nextSendAt else { return }
        timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(1, next.timeIntervalSinceNow)))
            guard !Task.isCancelled else { return }
            await self?.sendDue(store: store, outbox: outbox)
        }
    }

    /// The timer set again for the earliest send, once Corres has handed
    /// over what it sends with. Scheduling used to leave the old timer (or
    /// none), so an email sent while Corres was open waited for a refresh.
    private func rearm() {
        guard let store = timeStore, let outbox = timeOutbox else { return }
        keepTime(store: store, outbox: outbox)
    }

    private func hold(_ item: Item, because sender: String) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index].heldBecauseReplied = true
        save()
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Scheduled reply held")
        content.body = String(localized: "\(sender) replied to \u{201C}\(item.draft.subject)\u{201D} before it was sent. Open Corres to send it anyway or change it.")
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: Self.reminderID(item.id), content: content, trigger: nil))
    }

    // MARK: Reminder

    private static func reminderID(_ id: UUID) -> String { "corres.scheduled.\(id.uuidString)" }

    /// A few minutes after its time, in case iOS never let Corres run: a
    /// tap opens Corres, which sends it. Withdrawn the moment it's sent.
    private func scheduleReminder(for item: Item) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [Self.reminderID(item.id)])
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Ready to send")
        let subject = item.draft.subject.isEmpty ? String(localized: "Your email") : item.draft.subject
        content.body = String(localized: "\u{201C}\(subject)\u{201D} is waiting. Open Corres to send it.")
        content.userInfo = ["destination": "scheduled"]
        let fire = max(item.sendAt.addingTimeInterval(3 * 60).timeIntervalSinceNow, 5)
        center.add(UNNotificationRequest(identifier: Self.reminderID(item.id), content: content,
                                         trigger: UNTimeIntervalNotificationTrigger(timeInterval: fire, repeats: false)))
    }

    private func save() {
        #if os(iOS)
        // Its last eight hours, on the Lock Screen (see LiveActivities).
        LiveActivities.syncSendLater(items)
        #endif
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? FileManager.default.createDirectory(at: URL.applicationSupportDirectory, withIntermediateDirectories: true)
        try? data.write(to: Self.fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// "Tomorrow at 8:00 AM", "Monday at 8:00 AM", "Oct 20 at 9:30 AM".
    static func describe(_ date: Date) -> String {
        let calendar = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDateInToday(date) { return String(localized: "today at \(time)") }
        if calendar.isDateInTomorrow(date) { return String(localized: "tomorrow at \(time)") }
        if let days = calendar.dateComponents([.day], from: .now, to: date).day, days < 6 {
            return String(localized: "\(date.formatted(.dateTime.weekday(.wide))) at \(time)")
        }
        return String(localized: "\(date.formatted(.dateTime.month(.abbreviated).day())) at \(time)")
    }

    // MARK: Suggested times

    /// The times offered on Send, as Mail and Spark offer them: this
    /// evening (before 5 PM), tomorrow at the start of your day, and the
    /// first working day after the weekend from the day before it (Monday
    /// from Friday on in most places, Sunday from Thursday in Bangladesh).
    static func suggestions(now: Date = .now,
                            morningHour: Int = UserDefaults.standard.object(forKey: CorresSettings.morningHourKey) as? Int ?? 8)
        -> [(title: String, date: Date)] {
        let calendar = Calendar.current
        var result: [(String, Date)] = []
        let hour = calendar.component(.hour, from: now)
        if hour < 17, let evening = calendar.date(bySettingHour: 18, minute: 0, second: 0, of: now) {
            result.append((String(localized: "This Evening"), evening))
        }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
           let morning = calendar.date(bySettingHour: morningHour, minute: 0, second: 0, of: tomorrow) {
            result.append((String(localized: "Tomorrow Morning"), morning))
        }
        if let workday = TimePhrase.workWeekStartForSendLater(now: now, calendar: calendar),
           let morning = calendar.date(bySettingHour: morningHour, minute: 0, second: 0, of: workday) {
            result.append((String(localized: "\(morning.formatted(.dateTime.weekday(.wide))) Morning"), morning))
        }
        return result
    }
}
