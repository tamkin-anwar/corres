import Foundation

/// Which action fires on a full swipe (not a partial reveal-then-tap) on a
/// Mail row's trailing edge — the single most repeated gesture in the whole
/// app, and, per research grounding this, exactly what Gmail's own
/// well-known "Archive vs Delete on swipe" setting, Apple Mail's per-account
/// swipe configuration, and Spark's customizable swipe actions all treat as
/// a first-class preference, never buried. `CorrespondenceList` reorders its
/// existing trailing swipe buttons so whichever this is set to comes first;
/// Snooze stays fixed, always last, since it opens its own submenu rather
/// than firing directly and wouldn't make sense as a bare full-swipe.
enum PrimarySwipeAction: String, CaseIterable, Identifiable {
    case archive, trash, handled
    var id: String { rawValue }
    var title: String {
        switch self {
        case .archive: "Archive"
        case .trash: "Trash"
        case .handled: "Handled"
        }
    }
}

/// The same "one clear full-swipe default" preference, for a Mail row's
/// leading edge. Deliberately just these two, not "Needs You" too: that
/// button only ever appears conditionally (a thread already marked Needs
/// You has no reason to offer it again), so it was never a sensible
/// candidate for "the one thing a full swipe always does" the way Pin and
/// Unread/Read, always present, are. "Needs You" stays reachable on a
/// partial swipe, just never promoted to the full-swipe trigger.
enum LeadingSwipeAction: String, CaseIterable, Identifiable {
    case pin, unread
    var id: String { rawValue }
    /// The label shown in Preferences' picker; the swipe button itself
    /// still shows a state-dependent label ("Pin"/"Unpin",
    /// "Unread"/"Read") the same way it always has, since a thread already
    /// pinned or already unread needs the button to say what tapping it
    /// will *do*, not just name the fixed category of action.
    var settingsTitle: String {
        switch self {
        case .pin: "Pin"
        case .unread: "Mark Read/Unread"
        }
    }
}
