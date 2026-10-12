import Foundation

/// Primary, Promotions, Social and Updates: Gmail's tabs and Apple Mail's
/// categories, decided from Gmail's own category and Corres's reading,
/// and then by what you've taught it (`override`).
///
/// Primary is people, and anything that needs you wherever it came from
/// (a failed payment, a deadline), as Apple Mail lets time-sensitive mail
/// into Primary.
public enum InboxCategory: String, Codable, CaseIterable, Sendable {
    case primary, promotions, social, updates

    public var title: String {
        switch self {
        case .primary: "Primary"
        case .promotions: "Promotions"
        case .social: "Social"
        case .updates: "Updates"
        }
    }

    /// Gmail's own label for it, so a move here teaches Gmail too.
    public var gmailLabel: String {
        switch self {
        case .primary: "CATEGORY_PERSONAL"
        case .promotions: "CATEGORY_PROMOTIONS"
        case .social: "CATEGORY_SOCIAL"
        case .updates: "CATEGORY_UPDATES"
        }
    }

    public static let gmailLabels: Set<String> = ["CATEGORY_PERSONAL", "CATEGORY_PROMOTIONS", "CATEGORY_SOCIAL",
                                                  "CATEGORY_UPDATES", "CATEGORY_FORUMS"]

    /// Where `thread` belongs. `override`: what you've said about it, its
    /// sender or its kind of mail.
    public static func of(_ thread: Correspondence, override: InboxCategory? = nil) -> InboxCategory {
        if let override { return override }
        if thread.attention == .needsYou || thread.attention == .waiting { return .primary }
        switch InboxClassifier.bulkKind(labelIds: thread.labelIds, looksAutomated: thread.looksAutomated) {
        case nil: return .primary
        case .promotions?: return .promotions
        case .social?: return .social
        case .forums?, .updates?, .automated?: return .updates
        }
    }
}
