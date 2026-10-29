import Foundation

/// One action in the menu that opens when you press and hold an email in a
/// list (Settings → Customize → Press and Hold). The raw value is what's
/// saved, so it never changes with the language.
public enum RowMenuAction: String, CaseIterable, Identifiable, Sendable {
    case reply, replyAll, forward, archive, trash, read, flag, snooze, pin,
         moveTo, mute, vip, unsubscribe, share, reminder, spam, block

    public var id: String { rawValue }

    /// The name in Settings. The menu itself says what the action will do
    /// to that email ("Unflag" on a flagged one).
    public var title: String {
        switch self {
        case .reply: String(localized: "Reply")
        case .replyAll: String(localized: "Reply All")
        case .forward: String(localized: "Forward")
        case .archive: String(localized: "Archive")
        case .trash: String(localized: "Trash")
        case .read: String(localized: "Mark as Read or Unread")
        case .flag: String(localized: "Flag")
        case .snooze: String(localized: "Snooze")
        case .pin: String(localized: "Pin")
        case .moveTo: String(localized: "Move To")
        case .mute: String(localized: "Mute")
        case .vip: String(localized: "VIP")
        case .unsubscribe: String(localized: "Unsubscribe")
        case .share: String(localized: "Share")
        case .reminder: String(localized: "Add to Reminders")
        case .spam: String(localized: "Report Spam")
        case .block: String(localized: "Block Sender")
        }
    }

    public var systemImage: String {
        switch self {
        case .reply: "arrowshape.turn.up.left"
        case .replyAll: "arrowshape.turn.up.left.2"
        case .forward: "arrowshape.turn.up.right"
        case .archive: "archivebox"
        case .trash: "trash"
        case .read: "envelope.badge"
        case .flag: "flag"
        case .snooze: "clock"
        case .pin: "pin"
        case .moveTo: "folder"
        case .mute: "bell.slash"
        case .vip: "star"
        case .unsubscribe: "envelope.badge.shield.half.filled"
        case .share: "square.and.arrow.up"
        case .reminder: "checklist"
        case .spam: "xmark.bin"
        case .block: "hand.raised"
        }
    }

    /// Grouped in Settings so the list reads as kinds of action, the same
    /// groups as the email toolbar's.
    public var group: String {
        switch self {
        case .archive, .trash, .read, .flag, .snooze, .pin: String(localized: "Everyday")
        case .reply, .replyAll, .forward, .share: String(localized: "Send and Share")
        case .moveTo, .mute, .vip, .reminder: String(localized: "Organize")
        case .unsubscribe, .spam, .block: String(localized: "Unwanted Mail")
        }
    }

    /// The row of icons at the top takes one tap and no more: not a
    /// submenu (Move To, Add to Reminders), and nothing that asks first or
    /// can't be taken back (Unsubscribe, Report Spam, Block Sender).
    public var fitsTopRow: Bool {
        switch self {
        case .moveTo, .reminder, .unsubscribe, .spam, .block: false
        default: true
        }
    }

    /// Shown in red, in a section of their own at the end.
    public var isDestructive: Bool { self == .spam || self == .block }
}

/// What the press-and-hold menu shows, in order: up to four icons along
/// the top, then a short list. Apple's guidelines ask a context menu for
/// few items, the most used first; Gmail and Spark let you choose them.
public struct RowMenuLayout: Equatable, Sendable {
    public var top: [RowMenuAction]
    public var list: [RowMenuAction]

    /// An iPhone's menu fits four icons across.
    public static let topLimit = 4
    /// Past this the useful actions end up below the fold on an iPhone.
    public static let listLimit = 8

    public static let standard = RowMenuLayout(top: [.reply, .archive, .trash, .read],
                                               list: [.flag, .snooze, .pin, .moveTo, .mute])

    public init(top: [RowMenuAction], list: [RowMenuAction]) {
        self.top = top
        self.list = list
    }

    /// From what's saved: "" is the default, "-" chosen empty. Names this
    /// version doesn't know (from a newer one on another device) are
    /// skipped, each action shows once, the top row keeps to what fits it,
    /// and both keep to their limits.
    public init(topRaw: String, listRaw: String) {
        let top = topRaw.isEmpty ? Self.standard.top
            : Array(Self.parse(topRaw).filter(\.fitsTopRow).prefix(Self.topLimit))
        let list = listRaw.isEmpty ? Self.standard.list : Self.parse(listRaw)
        self.top = top
        self.list = Array(list.filter { !top.contains($0) }.prefix(Self.listLimit))
    }

    private static func parse(_ raw: String) -> [RowMenuAction] {
        guard raw != "-" else { return [] }
        var seen = Set<RowMenuAction>()
        return raw.split(separator: ",").compactMap { RowMenuAction(rawValue: String($0)) }
            .filter { seen.insert($0).inserted }
    }

    /// "-" stands for an empty one, so it isn't mistaken for the default.
    public static func raw(for actions: [RowMenuAction]) -> String {
        actions.isEmpty ? "-" : actions.map(\.rawValue).joined(separator: ",")
    }

    public var topRaw: String { Self.raw(for: top) }
    public var listRaw: String { Self.raw(for: list) }

    /// In neither place, to add.
    public var unused: [RowMenuAction] {
        RowMenuAction.allCases.filter { !top.contains($0) && !list.contains($0) }
    }

    public var topIsFull: Bool { top.count >= Self.topLimit }
    public var listIsFull: Bool { list.count >= Self.listLimit }

    public func canAdd(_ action: RowMenuAction, toTop: Bool) -> Bool {
        toTop ? action.fitsTopRow && !topIsFull && !top.contains(action) : !listIsFull && !list.contains(action)
    }

    /// Adds it at the end of the top row or the list, taking it out of the
    /// other, when there's room.
    public mutating func add(_ action: RowMenuAction, toTop: Bool) {
        guard canAdd(action, toTop: toTop) else { return }
        if toTop {
            list.removeAll { $0 == action }
            top.append(action)
        } else {
            top.removeAll { $0 == action }
            list.append(action)
        }
    }
}
