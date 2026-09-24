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
