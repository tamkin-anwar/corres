import SwiftUI

/// How Corres sorts mail into Needs You, Primary, Promotions, Social,
/// Updates and the rest: shared by the iPhone, iPad and Mac lists, so a
/// conversation sits in the same place on every device.

struct AccountTag: Hashable {
    let text: String
    let color: Color?

    @MainActor static func make(for account: String, among accounts: [String]) -> AccountTag {
        AccountTag(text: AccountPreferences.tag(for: account, among: accounts),
                   color: AccountPreferences.color(for: account, among: accounts))
    }
}

/// The Mail tab's quick filters. Everything stays in one chronological
/// list; these only narrow it, and never hide mail anywhere else.
/// Where each sender's mail mostly sits, worked out once per change to the
/// mail, not once per row.
@MainActor
enum CategoryContextCache {
    private static var revision: Int?
    private(set) static var latest = InboxCategory.Context()

    static func context(_ store: MailStore) -> InboxCategory.Context {
        if revision != store.contentRevision {
            latest = InboxCategory.context(for: store.threadsIncludingHidden)
            revision = store.contentRevision
        }
        return latest
    }
}

/// Mail's splits. Needs You first: Corres opens on what asks something of
/// you, with the rest of your mail one tap along. Then Primary, as Gmail's
/// tabs and Mail's categories open; Promotions, Social and Updates beside
/// it; Everything. Where an email sits follows what you've taught Corres
/// (`SenderLessons.category`). Flagged and Sent live in Mailboxes.
enum MailFilter: String, CaseIterable, Identifiable {
    case needsYou = "Needs You", primary = "Primary", everything = "Everything", unread = "Unread",
         promotions = "Promotions", social = "Social", updates = "Updates"
    var id: String { rawValue }

    @MainActor func includes(_ thread: Correspondence, context: InboxCategory.Context? = nil) -> Bool {
        switch self {
        case .needsYou: thread.attention == .needsYou
        case .everything: true
        case .unread: thread.isUnread
        case .primary: category(thread, context) == .primary
        case .promotions: category(thread, context) == .promotions
        case .social: category(thread, context) == .social
        case .updates: category(thread, context) == .updates
        }
    }

    var isCategory: Bool { [.primary, .promotions, .social, .updates].contains(self) }

    @MainActor private func category(_ thread: Correspondence, _ context: InboxCategory.Context?) -> InboxCategory {
        InboxCategory.of(thread, override: SenderLessons.category(for: thread), context: context ?? CategoryContextCache.latest)
    }
}
