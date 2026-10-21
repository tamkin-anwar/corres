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

    var title: String {
        switch self {
        case .needsYou: String(localized: "Needs You")
        case .primary: String(localized: "Primary")
        case .everything: String(localized: "Everything")
        case .unread: String(localized: "Unread")
        case .promotions: String(localized: "Promotions")
        case .social: String(localized: "Social")
        case .updates: String(localized: "Updates")
        }
    }

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

    /// Unread Only: narrows whichever split is showing to its unread mail,
    /// as Mail's filter button and Gmail's Unread chip do. Remembered, and
    /// shared by every split, so it stays on as you move between them.
    static let unreadOnlyKey = "corres.unreadOnly"

    /// The splits shown as tabs on iPhone and iPad. Unread there is the
    /// Unread Only filter, on any split, rather than a split of its own.
    static var tabs: [MailFilter] { allCases.filter { $0 != .unread } }

    /// With Unread Only on: what's unread, plus what was already showing
    /// (`kept`), so an email you open doesn't vanish from under you, as
    /// in Mail. It goes when you change split or turn the filter off.
    static func unreadOnly(_ threads: [Correspondence], keeping kept: Set<ThreadID>) -> [Correspondence] {
        threads.filter { $0.isUnread || kept.contains($0.id) }
    }

    @MainActor private func category(_ thread: Correspondence, _ context: InboxCategory.Context?) -> InboxCategory {
        InboxCategory.of(thread, override: SenderLessons.category(for: thread), context: context ?? CategoryContextCache.latest)
    }
}
