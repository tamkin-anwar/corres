import SwiftUI

/// The two actions available on a Mail row's trailing edge (Archive/Trash/
/// Handled), assignable independently to the short and long swipe distance
/// (see `PremiumSwipeRow`). Kept as one shared enum for both distances
/// rather than two separate types, since the set of sensible trailing
/// actions doesn't change based on which distance is being configured.
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
    var systemImage: String {
        switch self {
        case .archive: "archivebox.fill"
        case .trash: "trash.fill"
        case .handled: "checkmark.circle.fill"
        }
    }
    var tint: Color {
        switch self {
        case .archive: CorresPalette.swipeArchive
        case .trash: CorresPalette.swipeTrash
        case .handled: CorresPalette.swipeHandled
        }
    }
}

/// The leading-edge counterpart to `PrimarySwipeAction`: Pin and Mark
/// Read/Unread, assignable to the leading edge's short and long distance.
enum LeadingSwipeAction: String, CaseIterable, Identifiable {
    case pin, unread, flag
    var id: String { rawValue }
    /// The label shown in Preferences' picker; the swipe row's own visual
    /// still shows a state-dependent label/icon ("Pin"/"Unpin",
    /// "Unread"/"Read") the same way it always has, since a thread already
    /// pinned or already unread needs the gesture to show what it will
    /// *do*, not just name the fixed category of action.
    var settingsTitle: String {
        switch self {
        case .pin: "Pin"
        case .unread: "Mark Read/Unread"
        case .flag: "Flag"
        }
    }
}
