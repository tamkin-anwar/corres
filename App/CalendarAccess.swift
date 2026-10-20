import EventKit
import Observation

/// Your calendar, for invitations: whether you're free when one asks for
/// you, whether it's already on your calendar, and taking off an event the
/// organizer canceled. Read on this device only, and only after you tap
/// Check Your Calendar on an invitation; nothing from it leaves the device.
@MainActor @Observable
final class CalendarAccess {
    static let shared = CalendarAccess()

    let store = EKEventStore()
    private(set) var canRead = false
    /// Not asked yet: an invitation offers to check.
    private(set) var canAsk = false
    /// Bumped when the calendar changes, so open invitations look again.
    private(set) var revision = 0

    private init() {
        refresh()
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.revision += 1 }
        }
    }

    func refresh() {
        let status = EKEventStore.authorizationStatus(for: .event)
        canRead = status == .fullAccess
        canAsk = status == .notDetermined
    }

    func requestRead() async {
        _ = try? await store.requestFullAccessToEvents()
        refresh()
        revision += 1
    }

    /// Enough to add an event, without reading anything.
    func requestWrite() async -> Bool {
        let status = EKEventStore.authorizationStatus(for: .event)
        if status == .fullAccess || status == .writeOnly { return true }
        let granted = (try? await store.requestWriteOnlyAccessToEvents()) ?? false
        refresh()
        return granted
    }

    /// What's already on your calendar then, besides this event itself:
    /// busy time only, leaving out all-day events and ones you declined.
    func overlaps(start: Date, end: Date, excluding title: String) -> [EKEvent] {
        guard canRead, end > start else { return [] }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate).filter { event in
            !event.isAllDay && event.availability != .free && event.status != .canceled
                && event.startDate < end && event.endDate > start
                && !Self.isSame(event, title: title, start: start)
                && event.attendees?.first(where: \.isCurrentUser)?.participantStatus != .declined
        }
        .sorted { $0.startDate < $1.startDate }
    }

    /// This event on your calendar, when it's there: Google, Outlook and
    /// iCloud add invitations by themselves.
    func event(title: String, start: Date) -> EKEvent? {
        guard canRead else { return nil }
        let predicate = store.predicateForEvents(withStart: start.addingTimeInterval(-60), end: start.addingTimeInterval(86_400), calendars: nil)
        return store.events(matching: predicate).first { Self.isSame($0, title: title, start: start) }
    }

    func add(title: String, start: Date, end: Date, allDay: Bool, location: String?, url: URL?, notes: String?) throws {
        let event = EKEvent(eventStore: store)
        event.title = title
        event.startDate = start
        event.endDate = end
        event.isAllDay = allDay
        event.location = location
        event.url = url
        event.notes = notes
        event.calendar = store.defaultCalendarForNewEvents
        try store.save(event, span: .thisEvent)
    }

    func remove(_ event: EKEvent) throws {
        try store.remove(event, span: .thisEvent)
    }

    private static func isSame(_ event: EKEvent, title: String, start: Date) -> Bool {
        abs(event.startDate.timeIntervalSince(start)) < 60
            && (event.title ?? "").trimmingCharacters(in: .whitespaces).caseInsensitiveCompare(title.trimmingCharacters(in: .whitespaces)) == .orderedSame
    }
}
