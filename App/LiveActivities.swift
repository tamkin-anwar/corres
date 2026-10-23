#if os(iOS)
import ActivityKit
import Foundation
import UIKit

/// Corres's Live Activities (see `LiveActivityKinds`): an email's last
/// hours in Send Later, and a package out for delivery today. Apple keeps
/// Live Activities to tasks under eight hours with a clear end, so each
/// starts no more than eight hours out and ends when the email goes, or
/// the package arrives, or the day is over. Starting one needs Corres
/// open; updating and ending don't.
@MainActor
enum LiveActivities {
    static let deliveriesKey = "corres.deliveryActivities"
    static var deliveriesOn: Bool { UserDefaults.standard.object(forKey: deliveriesKey) as? Bool ?? true }
    private static let window: TimeInterval = 8 * 3600

    private static var canStart: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled && UIApplication.shared.applicationState == .active
    }

    // MARK: Send Later

    static func syncSendLater(_ items: [ScheduledSends.Item], now: Date = .now) {
        let wanted = items.filter { !$0.heldBecauseReplied && $0.sendAt > now && $0.sendAt.timeIntervalSince(now) <= window }
        let byID = Dictionary(wanted.map { ($0.id.uuidString, $0) }, uniquingKeysWith: { a, _ in a })
        for activity in Activity<SendLaterActivity>.activities {
            if let item = byID[activity.attributes.itemID] {
                if activity.content.state.sendAt != item.sendAt {
                    update(SendLaterActivity.self, id: activity.id, content(for: item))
                }
            } else {
                end(SendLaterActivity.self, id: activity.id)
            }
        }
        guard canStart else { return }
        let running = Set(Activity<SendLaterActivity>.activities.map(\.attributes.itemID))
        for item in wanted where !running.contains(item.id.uuidString) {
            let link = item.draft.threadID.flatMap(MailReminders.link(to:)) ?? WidgetSnapshot.url(for: "mail")
            let attributes = SendLaterActivity(itemID: item.id.uuidString, recipient: recipient(item.draft.to), link: link)
            _ = try? Activity.request(attributes: attributes, content: content(for: item))
        }
    }

    private static func content(for item: ScheduledSends.Item) -> ActivityContent<SendLaterActivity.ContentState> {
        ActivityContent(state: .init(sendAt: item.sendAt), staleDate: item.sendAt.addingTimeInterval(10 * 60))
    }

    /// "Maya", or "Maya +2": a first name only, for the Lock Screen.
    static func recipient(_ field: String) -> String {
        let people = PeopleIndex.entries(in: field).compactMap(PeopleIndex.parse)
        guard let first = people.first else { return String(localized: "your recipient") }
        let name = first.name.isEmpty ? first.email : (first.name.split(separator: " ").first.map(String.init) ?? first.name)
        return people.count > 1 ? "\(name) +\(people.count - 1)" : name
    }

    // MARK: Deliveries

    private static var pendingDeliveries: Task<Void, Never>?

    /// After the mail changes: a burst of changes (a swipe, each batch of
    /// a first sync) makes one pass.
    static func scheduleDeliveries(_ threads: @escaping @MainActor () -> [Correspondence]) {
        pendingDeliveries?.cancel()
        pendingDeliveries = Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            syncDeliveries(threads())
        }
    }

    /// What each shipping email says, kept by message: reading its whole
    /// body again on every change to the mail was most of the work here.
    private static let statuses = Memo<String, String?>(limit: 2_000)

    /// From today's shipping emails: one Live Activity per store whose
    /// latest says out for delivery, marked delivered when its email comes.
    static func syncDeliveries(_ threads: [Correspondence], now: Date = .now, calendar: Calendar = .current) {
        let endOfDay = calendar.date(bySettingHour: 21, minute: 0, second: 0, of: now) ?? now
        guard deliveriesOn, now < endOfDay else {
            for activity in Activity<DeliveryActivity>.activities { end(DeliveryActivity.self, id: activity.id) }
            return
        }
        // Today's bounds worked out once, not once per conversation.
        let startOfToday = calendar.startOfDay(for: now)
        let startOfTomorrow = calendar.date(byAdding: .day, value: 1, to: startOfToday) ?? .distantFuture
        let today = threads
            .filter { $0.receivedAt >= startOfToday && $0.receivedAt < startOfTomorrow && $0.id.account != "sample" && $0.mailKind == .shipping }
            .sorted { $0.receivedAt < $1.receivedAt }
        var latest: [String: (thread: Correspondence, delivered: Bool)] = [:]
        for thread in today {
            let key = "\(thread.id.entityKey)|\(thread.latestMessageID ?? thread.subject)|\(thread.body.utf8.count)|\(thread.excerpt.utf8.count)"
            let status = statuses.value(key) {
                let text = thread.body.isEmpty ? thread.excerpt : thread.body
                return MailDigest.glance(text: text, subject: thread.subject, kind: .shipping)?.status
            }
            let store = (thread.senderEmail.flatMap(BrandLogos.domain(of:)) ?? thread.sender).lowercased()
            if status == "Out for delivery" {
                latest[store] = (thread, false)
            } else if status == "Delivered", let earlier = latest[store] {
                latest[store] = (earlier.thread, true)
            }
        }
        let running = Activity<DeliveryActivity>.activities
        for activity in running {
            let match = latest.values.first { $0.thread.id.entityKey == activity.attributes.threadKey }
            if match?.delivered == true, !activity.content.state.delivered {
                end(DeliveryActivity.self, id: activity.id, ActivityContent(state: .init(delivered: true), staleDate: nil),
                    policy: .after(now.addingTimeInterval(30 * 60)))
            } else if let stale = activity.content.staleDate, stale < now {
                end(DeliveryActivity.self, id: activity.id)
            }
        }
        guard canStart else { return }
        let keys = Set(running.map(\.attributes.threadKey))
        for (_, entry) in latest where !entry.delivered && !keys.contains(entry.thread.id.entityKey) {
            let thread = entry.thread
            let link = MailReminders.link(to: thread.id) ?? WidgetSnapshot.url(for: "mail")
            let from = thread.organization.isEmpty ? thread.sender : thread.organization
            let attributes = DeliveryActivity(threadKey: thread.id.entityKey, from: from,
                                              carrier: carrier(in: thread), link: link)
            let stale = min(now.addingTimeInterval(window), endOfDay)
            _ = try? Activity.request(attributes: attributes, content: ActivityContent(state: .init(delivered: false), staleDate: stale))
        }
    }

    /// By id, so the activity itself never crosses into the task.
    private static func end(_ kind: SendLaterActivity.Type, id: String) {
        Task {
            for activity in Activity<SendLaterActivity>.activities where activity.id == id {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    private static func update(_ kind: SendLaterActivity.Type, id: String, _ content: ActivityContent<SendLaterActivity.ContentState>) {
        Task {
            for activity in Activity<SendLaterActivity>.activities where activity.id == id { await activity.update(content) }
        }
    }

    private static func end(_ kind: DeliveryActivity.Type, id: String, _ final: ActivityContent<DeliveryActivity.ContentState>? = nil,
                            policy: ActivityUIDismissalPolicy = .immediate) {
        Task {
            for activity in Activity<DeliveryActivity>.activities where activity.id == id {
                await activity.end(final, dismissalPolicy: policy)
            }
        }
    }

    #if DEBUG
    /// -DemoLiveActivities: both, with sample content, to see them.
    static func demo() {
        guard ProcessInfo.processInfo.arguments.contains("-DemoLiveActivities"), canStart else { return }
        _ = try? Activity.request(attributes: SendLaterActivity(itemID: "demo", recipient: "Maya", link: WidgetSnapshot.url(for: "mail")),
                                  content: ActivityContent(state: .init(sendAt: .now.addingTimeInterval(95 * 60)), staleDate: nil))
        _ = try? Activity.request(attributes: DeliveryActivity(threadKey: "demo", from: "Atelier Supply", carrier: "UPS",
                                                               link: WidgetSnapshot.url(for: "mail")),
                                  content: ActivityContent(state: .init(delivered: false), staleDate: nil))
    }
    #endif

    private static func carrier(in thread: Correspondence) -> String? {
        let text = (thread.subject + " " + thread.body).lowercased()
        for (word, name) in [("ups", "UPS"), ("usps", "USPS"), ("fedex", "FedEx"), ("dhl", "DHL"), ("royal mail", "Royal Mail"),
                             ("amazon logistics", "Amazon")] where text.range(of: "\\b\(word)\\b", options: .regularExpression) != nil {
            return name
        }
        return nil
    }
}
#endif
