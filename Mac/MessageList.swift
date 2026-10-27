import AppIntents
import AppKit
import SwiftUI

/// The message list: a real AppKit table, the fastest list there is on the
/// Mac (SwiftUI's List slows past ten thousand rows; a mailbox is often
/// more). Native selection, type-to-move, Shift and Command clicks, and
/// rows that slide away when archived.
struct MessageList: NSViewRepresentable {
    /// Compared by `version` alone: SwiftUI compared the rows whole, every
    /// conversation in them, each time the window redrew.
    struct Rows: Equatable {
        let version: Int
        let items: [MacRow]
        static func == (a: Rows, b: Rows) -> Bool { a.version == b.version }
    }
    let list: Rows
    var rows: [MacRow] { list.items }
    let showsReasons: Bool
    let accountColors: [String: NSColor]
    @Binding var selection: Set<ThreadID>
    var onOpen: (Correspondence) -> Void
    var onKey: (MessageListKey) -> Bool
    var menu: (Correspondence) -> NSMenu?
    /// A two-finger swipe on a row: the action, on that row alone.
    var onSwipe: (Correspondence, MacAction) -> Void = { _, _ in }
    /// Scrolled near the end: time to fetch more, where there's more.
    var onReachEnd: () -> Void = {}
    /// Whose photo to show beside a person's mail, from Contacts.
    var people: PeopleDirectory? = nil
    /// View › Bigger and Smaller.
    @AppStorage(CorresSettings.textScaleKey) private var textScale = 1.0
    /// View › Show Sender Pictures: a company's logo or a person's initials
    /// beside each row, as Mail does since macOS 15.4.
    @AppStorage(CorresSettings.macSenderPicturesKey) private var showsPictures = true

    func makeNSView(context: Context) -> NSScrollView {
        let table = MessageTableView()
        table.style = .inset
        table.headerView = nil
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.usesAutomaticRowHeights = false
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.backgroundColor = .clear
        table.selectionHighlightStyle = .regular
        let column = NSTableColumn(identifier: .init("thread"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.doubleClicked)
        table.onKey = { [weak coordinator = context.coordinator] key in coordinator?.parent.onKey(key) ?? false }
        table.menuProvider = { [weak coordinator = context.coordinator] row in coordinator?.menu(forRow: row) }
        // Dragged onto a mailbox in the sidebar to move there, as in Mail.
        table.setDraggingSourceOperationMask(.move, forLocal: true)
        table.setDraggingSourceOperationMask([], forLocal: false)
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        context.coordinator.table = table
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.apply(rows: rows, selection: selection, scale: textScale, pictures: showsPictures)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: MessageList
        weak var table: MessageTableView?
        private var rows: [MacRow] = [] { didSet { positions = nil } }
        /// Each row's id and what it shows, kept beside `rows` so an update
        /// compares a few fields per row, not every conversation whole.
        private var keys: [RowKey] = []
        /// Where each conversation is in `rows`, made when first asked.
        private var positions: [ThreadID: Int]?
        private var looks: [RowLook?] = []
        /// What every row's height hangs on: Bigger or Smaller, and whether
        /// the list shows reasons.
        private var layout: Layout?
        private var groupHeight: CGFloat = 30
        private var threadHeight: CGFloat = 76
        /// The selected conversations the list last scrolled to, so a
        /// reshuffle that keeps the same selection doesn't jump to it again.
        private var shownSelection: Set<ThreadID> = []
        private var applyingSelection = false

        init(_ parent: MessageList) { self.parent = parent }

        private struct Layout: Equatable {
            let scale: Double
            let showsReasons: Bool
            let showsPictures: Bool
        }

        func apply(rows newRows: [MacRow], selection: Set<ThreadID>, scale: Double, pictures: Bool) {
            guard let table else { return }
            let newLayout = Layout(scale: scale, showsReasons: parent.showsReasons, showsPictures: pictures)
            if newLayout != layout {
                layout = newLayout
                // Read once here, not once per row: the factor comes from
                // the settings store.
                let factor = MacListScale.factor
                groupHeight = (30 * factor).rounded()
                threadHeight = ((newLayout.showsReasons ? 92 : 76) * factor).rounded()
                // Bigger or Smaller, or another kind of list: every row
                // measured and drawn again.
                rows = newRows
                keys = newRows.map(Self.key)
                looks = newRows.map(RowLook.init)
                withSelectionHeld { table.reloadData() }
            } else if !Self.sameStorage(rows, newRows) {
                update(table, to: newRows)
            }
            // Looked up by id: going through every row copied each
            // conversation out whole, on every change.
            let wanted = IndexSet(selection.compactMap { (positions ?? makePositions())[$0] })
            if table.selectedRowIndexes != wanted {
                withSelectionHeld { table.selectRowIndexes(wanted, byExtendingSelection: false) }
                // Only when the selection itself changed (a key, the next
                // conversation after an archive): new mail reshuffling the
                // list leaves the view where it is.
                let shown = Set(wanted.compactMap { rows[$0].thread?.id })
                if shown != shownSelection, let first = wanted.first { table.scrollRowToVisible(first) }
                shownSelection = shown
            }
        }

        /// From the rows on screen to `newRows`: rows that left are removed,
        /// rows that came are inserted, rows that moved are moved, and only
        /// rows whose content changed are drawn again. A different list
        /// altogether (another mailbox) is drawn again whole.
        private func update(_ table: MessageTableView, to newRows: [MacRow]) {
            let newKeys = newRows.map(Self.key)
            let newLooks = newRows.map(RowLook.init)
            if newKeys == keys {
                let changed = IndexSet(newLooks.indices.filter { newLooks[$0] != looks[$0] })
                rows = newRows
                looks = newLooks
                if !changed.isEmpty { table.reloadData(forRowIndexes: changed, columnIndexes: [0]) }
                return
            }
            let oldLooks = looks
            let oldIndex = Dictionary(keys.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: { first, _ in first })
            let edits = RowEdits(from: keys, to: newKeys)
            // The row at the top of the view stays put when mail arrives or
            // leaves above it, unless the list is already at the top, where
            // new mail should show.
            let sameList = edits.map { $0.removed.count + $0.inserted.count <= RowEdits.limit } ?? false
            let anchor = sameList ? topAnchor(table, leaving: edits?.removed ?? []) : nil
            rows = newRows
            keys = newKeys
            looks = newLooks
            // A conversation leaving the list on its own (answered, say)
            // stays open in the reading pane, as in Mail: the update
            // doesn't count as you choosing nothing.
            withSelectionHeld {
                if let edits, edits.isSmall {
                    if edits.moves.isEmpty, edits.inserted.isEmpty {
                        // Only removals (archive, delete, a move): slide those
                        // rows away. Reduce Motion: no slide.
                        let motion: NSTableView.AnimationOptions = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? [] : [.effectFade, .slideUp]
                        table.removeRows(at: edits.removed, withAnimation: motion)
                    } else {
                        // Arrivals and reorders land at once, as a redraw did.
                        NSAnimationContext.runAnimationGroup { context in
                            context.duration = 0
                            context.allowsImplicitAnimation = false
                            table.beginUpdates()
                            table.removeRows(at: edits.removed, withAnimation: [])
                            for move in edits.moves { table.moveRow(at: move.from, to: move.to) }
                            for run in edits.inserted.rangeView { table.insertRows(at: IndexSet(integersIn: run), withAnimation: []) }
                            table.endUpdates()
                        }
                    }
                    // Kept rows whose content changed (read, flagged, a reply).
                    let changed = IndexSet(newKeys.indices.filter { index in
                        guard !edits.inserted.contains(index), let old = oldIndex[newKeys[index]] else { return false }
                        return oldLooks[old] != newLooks[index]
                    })
                    if !changed.isEmpty { table.reloadData(forRowIndexes: changed, columnIndexes: [0]) }
                } else {
                    table.reloadData()
                }
            }
            if let anchor { restore(anchor, in: table) }
        }

        private func makePositions() -> [ThreadID: Int] {
            var made: [ThreadID: Int] = [:]
            made.reserveCapacity(rows.count)
            for (index, row) in rows.enumerated() {
                if let id = row.threadID, made[id] == nil { made[id] = index }
            }
            positions = made
            return made
        }

        private func withSelectionHeld(_ body: () -> Void) {
            applyingSelection = true
            defer { applyingSelection = false }
            body()
        }

        /// The first row in view that stays in the list, and how far it
        /// sits from the top; nil when the list is scrolled to the very top.
        private func topAnchor(_ table: NSTableView, leaving removed: IndexSet) -> (key: RowKey, offset: CGFloat)? {
            guard let clip = table.enclosingScrollView?.contentView else { return nil }
            var visible = clip.bounds
            visible.origin.y += clip.contentInsets.top
            visible.size.height -= clip.contentInsets.top
            guard visible.minY > 1 else { return nil }
            let inView = table.rows(in: visible)
            guard let row = (inView.location..<inView.location + inView.length).first(where: {
                keys.indices.contains($0) && !removed.contains($0)
            }) else { return nil }
            return (keys[row], table.rect(ofRow: row).minY - clip.bounds.minY)
        }

        /// Scrolls so the anchored row sits where it was.
        private func restore(_ anchor: (key: RowKey, offset: CGFloat), in table: NSTableView) {
            guard let scroll = table.enclosingScrollView, let row = keys.firstIndex(of: anchor.key) else { return }
            let clip = scroll.contentView
            var bounds = clip.bounds
            bounds.origin.y = table.rect(ofRow: row).minY - anchor.offset
            guard abs(bounds.origin.y - clip.bounds.origin.y) > 0.5 else { return }
            clip.scroll(to: clip.constrainBoundsRect(bounds).origin)
            scroll.reflectScrolledClipView(clip)
        }

        /// The same array handed in again (the mailbox's cached rows on a
        /// selection change): nothing to compare.
        private static func sameStorage(_ a: [MacRow], _ b: [MacRow]) -> Bool {
            a.count == b.count && a.withUnsafeBufferPointer { a in b.withUnsafeBufferPointer { a.baseAddress == $0.baseAddress } }
        }

        /// A row's identity, made without building a string per row.
        private static func key(_ row: MacRow) -> RowKey {
            switch row {
            case .group(let title): .group(title)
            case .thread(let thread): .thread(thread.id)
            }
        }

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        /// A dragged row carries its own conversation.
        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
            guard rows.indices.contains(row), let thread = rows[row].thread else { return nil }
            // This row's own: AppKit asks once for each dragged row, so the
            // rest of the selection comes with their own items.
            let item = NSPasteboardItem()
            item.setString(MacDrag.encode([thread.id]), forType: .string)
            return item
        }

        func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
            if case .group = rows[row] { true } else { false }
        }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            if case .group = rows[row] { groupHeight } else { threadHeight }
        }

        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
            rows[row].thread != nil
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            if row >= rows.count - 8 { parent.onReachEnd() }
            switch rows[row] {
            case .group(let title):
                let view = tableView.makeView(withIdentifier: GroupCellView.identifier, owner: nil) as? GroupCellView ?? GroupCellView()
                view.title = title
                return view
            case .thread(let thread):
                let view = tableView.makeView(withIdentifier: ThreadCellView.identifier, owner: nil) as? ThreadCellView ?? ThreadCellView()
                view.configure(thread, showsReason: parent.showsReasons, accountColor: parent.accountColors[thread.id.account],
                               picture: layout?.showsPictures ?? true, people: parent.people)
                // Which email this row is, for Siri ("archive this one").
                if #available(macOS 15.4, *) {
                    view.appEntityIdentifier = EntityIdentifier(for: CorresMailMessage.self, identifier: thread.id.entityKey)
                }
                return view
            }
        }

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !applyingSelection, let table else { return }
            let ids = Set(table.selectedRowIndexes.compactMap { rows.indices.contains($0) ? rows[$0].thread?.id : nil })
            // Chosen here, so already in view.
            shownSelection = ids
            if ids != parent.selection { parent.selection = ids }
        }

        @objc func doubleClicked() {
            guard let table, table.clickedRow >= 0, let thread = rows[table.clickedRow].thread else { return }
            parent.onOpen(thread)
        }

        /// Swipe left to archive or delete, right for Handled or read, as
        /// Mail does on a trackpad.
        func tableView(_ tableView: NSTableView, rowActionsForRow row: Int,
                       edge: NSTableView.RowActionEdge) -> [NSTableViewRowAction] {
            guard let thread = rows[row].thread else { return [] }
            func action(_ title: String, _ symbol: String, _ color: Color, _ macAction: MacAction,
                        style: NSTableViewRowAction.Style = .regular) -> NSTableViewRowAction {
                let made = NSTableViewRowAction(style: style, title: title) { [weak self] _, _ in
                    self?.parent.onSwipe(thread, macAction)
                    tableView.rowActionsVisible = false
                }
                made.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
                made.backgroundColor = NSColor(color)
                return made
            }
            switch edge {
            case .trailing:
                return [action(String(localized: "Archive"), "archivebox.fill", CorresPalette.swipeArchive, .archive),
                        action(String(localized: "Delete"), "trash.fill", CorresPalette.swipeTrash, .trash, style: .destructive)]
            case .leading:
                return [action(String(localized: "Handled"), "checkmark.circle.fill", CorresPalette.swipeHandled, .move(.handled)),
                        action(thread.isUnread ? String(localized: "Read") : String(localized: "Unread"), "envelope.badge.fill",
                               CorresPalette.swipeUnread, .toggleUnread)]
            @unknown default:
                return []
            }
        }

        func menu(forRow row: Int) -> NSMenu? {
            guard rows.indices.contains(row), let thread = rows[row].thread else { return nil }
            // Right-clicking an unselected row acts on that row, as in Mail.
            if !(parent.selection.contains(thread.id)) { parent.selection = [thread.id] }
            return parent.menu(thread)
        }
    }
}

/// What a conversation's row shows: when none of it changed, the row
/// isn't drawn again.
private struct RowLook: Equatable {
    let sender: String
    let senderEmail: String?
    let toRecipients: [String]
    let ccRecipients: [String]
    let subject: String
    let excerpt: String
    let reason: String
    let receivedAt: Date
    let snoozedUntil: Date?
    let isUnread: Bool
    let isPinned: Bool
    let isFlagged: Bool
    let hasAttachments: Bool

    /// Nil for a group's label, which its id already says all of.
    init?(_ row: MacRow) {
        guard let thread = row.thread else { return nil }
        sender = thread.sender
        senderEmail = thread.senderEmail
        toRecipients = thread.toRecipients
        ccRecipients = thread.ccRecipients
        subject = thread.subject
        excerpt = thread.excerpt
        reason = thread.reason
        receivedAt = thread.receivedAt
        snoozedUntil = thread.snoozedUntil
        isUnread = thread.isUnread
        isPinned = thread.isPinned
        isFlagged = thread.isFlagged
        hasAttachments = !thread.attachments.isEmpty
    }
}

/// A row of the message list, by what it is rather than what it shows.
enum RowKey: Hashable {
    case group(String)
    case thread(ThreadID)
}

/// The table edits that turn one list of row ids into the next: removals
/// at their old positions, then moves one at a time, then insertions at
/// their new positions. Nil when an id repeats, which no diff can place.
struct RowEdits {
    /// Past this many edits, drawing the list again is quicker and clearer.
    static let limit = 100

    private(set) var removed = IndexSet()
    private(set) var moves: [(from: Int, to: Int)] = []
    private(set) var inserted = IndexSet()
    /// Few enough edits to apply one by one.
    private(set) var isSmall = false

    init?<Key: Hashable>(from old: [Key], to new: [Key]) {
        var oldIndex: [Key: Int] = [:]
        for (index, key) in old.enumerated() where oldIndex.updateValue(index, forKey: key) != nil { return nil }
        var newKeys = Set<Key>()
        for key in new where !newKeys.insert(key).inserted { return nil }
        removed = IndexSet(old.indices.filter { !newKeys.contains(old[$0]) })
        inserted = IndexSet(new.indices.filter { oldIndex[new[$0]] == nil })
        // The rows in both lists: as they'll be, and as they are once the
        // removals are done.
        let kept = new.filter { oldIndex[$0] != nil }
        var current = old.filter { newKeys.contains($0) }
        var position: [Key: Int] = [:]
        for (index, key) in current.enumerated() { position[key] = index }
        // The most rows already in the right order stay; the rest move.
        let stays = Self.longestRising(kept.compactMap { position[$0] })
        guard removed.count + (kept.count - stays.count) + inserted.count <= Self.limit else { return }
        for index in kept.indices where !stays.contains(index) {
            guard let from = current.firstIndex(of: kept[index]) else { return }
            current.remove(at: from)
            // Right after the row that comes before it in the new list.
            var to = 0
            if index > 0 {
                guard let before = current.firstIndex(of: kept[index - 1]) else { return }
                to = before + 1
            }
            current.insert(kept[index], at: to)
            if from != to { moves.append((from, to)) }
        }
        isSmall = current == kept
    }

    /// The positions in `values` of its longest rising run, gaps allowed.
    /// The values are all different.
    static func longestRising(_ values: [Int]) -> Set<Int> {
        // tails[n]: where the smallest last value of a run n + 1 long is.
        var tails: [Int] = []
        var previous = [Int](repeating: -1, count: values.count)
        for (index, value) in values.enumerated() {
            var low = 0, high = tails.count
            while low < high {
                let middle = (low + high) / 2
                if values[tails[middle]] < value { low = middle + 1 } else { high = middle }
            }
            if low > 0 { previous[index] = tails[low - 1] }
            if low == tails.count { tails.append(index) } else { tails[low] = index }
        }
        var run = Set<Int>()
        var index = tails.last ?? -1
        while index >= 0 {
            run.insert(index)
            index = previous[index]
        }
        return run
    }
}

/// A key pressed in the list that Corres may act on.
struct MessageListKey {
    let characters: String
    let keyCode: UInt16
    let modifiers: NSEvent.ModifierFlags

    static let delete: UInt16 = 51, forwardDelete: UInt16 = 117, returnKey: UInt16 = 36, space: UInt16 = 49
}

/// Space in the list: the open email, a page at a time, as in Mail.
@MainActor
enum MacReadingScroll {
    /// False when there's no email open beside `list` to scroll.
    static func page(down: Bool, beside list: NSView?) -> Bool {
        guard let listScroll = list?.enclosingScrollView, let content = listScroll.window?.contentView,
              let pane = readingScroller(in: content, rightOf: listScroll) else { return false }
        let clip = pane.contentView
        let flipped = pane.documentView?.isFlipped ?? true
        // A screenful, less a line or two kept in view, as paging does.
        let step = max(clip.bounds.height - 40, 40) * (down == flipped ? 1 : -1)
        var bounds = clip.bounds
        bounds.origin.y += step
        clip.scroll(to: clip.constrainBoundsRect(bounds).origin)
        pane.reflectScrolledClipView(clip)
        return true
    }

    /// The tallest scroller to the right of the list: the reading pane.
    private static func readingScroller(in view: NSView, rightOf listScroll: NSScrollView) -> NSScrollView? {
        let listEdge = listScroll.convert(listScroll.bounds, to: nil).maxX
        var best: (scroll: NSScrollView, height: CGFloat)?
        var stack = [view]
        while let next = stack.popLast() {
            if let scroll = next as? NSScrollView, scroll !== listScroll, !scroll.isHiddenOrHasHiddenAncestor {
                let frame = scroll.convert(scroll.bounds, to: nil)
                if frame.minX >= listEdge - 1, frame.height > (best?.height ?? 0) { best = (scroll, frame.height) }
            }
            stack += next.subviews
        }
        return best?.scroll
    }
}

final class MessageTableView: NSTableView {
    var onKey: ((MessageListKey) -> Bool)?
    var menuProvider: ((Int) -> NSMenu?)?

    override func keyDown(with event: NSEvent) {
        let key = MessageListKey(characters: event.charactersIgnoringModifiers ?? "", keyCode: event.keyCode,
                                 modifiers: event.modifierFlags.intersection(.deviceIndependentFlagsMask))
        if onKey?(key) == true { return }
        super.keyDown(with: event)
    }

    // MARK: Focus

    private var keyObserver: NSObjectProtocol?

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
        keyObserver = newWindow.map { window in
            NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.takeFocusIfFree() }
            }
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        // The first list in a window (launch) takes the keyboard from
        // anything but a field being typed in, as Mail's list does; later
        // ones (back from Scheduled, or an empty mailbox) only when free,
        // so arrowing through the sidebar stays in the sidebar.
        takeFocusIfFree(firstInWindow: !Self.focusedWindows.contains(window))
        Self.focusedWindows.add(window)
    }

    private static let focusedWindows = NSHashTable<NSWindow>.weakObjects()

    /// Single keys (e, r, j, k) work from launch, as in Mail, without a
    /// click into the list first: the list takes the keyboard when nothing
    /// in its window has it. Never from a field you're typing in.
    func takeFocusIfFree(firstInWindow: Bool = false) {
        // Next turn: the window has finished setting itself up by then.
        Task { @MainActor [weak self] in
            guard let self, let window, !isHiddenOrHasHiddenAncestor else { return }
            let current = window.firstResponder
            let free = current == nil || current === window
            guard free || firstInWindow && !(current is NSText) && !(current is NSTextField) else { return }
            window.makeFirstResponder(self)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        guard row >= 0 else { return nil }
        return menuProvider?(row)
    }
}

/// "DUE SOON", "WHEN YOU CAN".
final class GroupCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("group")
    private let label = NSTextField(labelWithString: "")

    var title: String = "" {
        didSet {
            label.stringValue = title.uppercased()
            label.font = .systemFont(ofSize: MacListScale.size(11), weight: .semibold)
        }
    }

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        label.font = .systemFont(ofSize: MacListScale.size(11), weight: .semibold)
        label.textColor = .tertiaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }
}

/// One conversation: unread dot, sender and time, subject, then the
/// preview, or in Needs You and Waiting the one-line reason it's there.
final class ThreadCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("thread")

    private let dot = NSView()
    private let sender = NSTextField(labelWithString: "")
    private let time = NSTextField(labelWithString: "")
    private let marks = NSTextField(labelWithString: "")
    private let accountDot = NSView()
    private let subject = NSTextField(labelWithString: "")
    private let detail = NSTextField(wrappingLabelWithString: "")
    /// The sender's picture: the same avatar as on iPhone (a company's
    /// logo through Corres's relay, a contact's photo, or initials).
    private let picture = NSHostingView(rootView: AnyView(EmptyView()))
    private var pictureSize: NSLayoutConstraint!
    private var textLeading: NSLayoutConstraint!
    private var isUnread = false
    private var showsReason = false
    private var accountColor: NSColor?
    /// Pinned, flagged, has attachments: small symbols before the time.
    private var symbols: [(name: String, color: NSColor)] = []

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        accountDot.wantsLayer = true
        accountDot.layer?.cornerRadius = 3.5
        for field in [sender, time, marks, subject] {
            field.lineBreakMode = .byTruncatingTail
            field.maximumNumberOfLines = 1
            field.cell?.truncatesLastVisibleLine = true
        }
        detail.maximumNumberOfLines = 2
        detail.lineBreakMode = .byTruncatingTail
        detail.cell?.truncatesLastVisibleLine = true
        time.alignment = .right
        applyFonts()
        for view in [dot, picture, sender, time, marks, accountDot, subject, detail] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        sender.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        time.setContentCompressionResistancePriority(.required, for: .horizontal)
        time.setContentHuggingPriority(.required, for: .horizontal)
        marks.setContentHuggingPriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            dot.centerYAnchor.constraint(equalTo: sender.centerYAnchor),

            picture.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            picture.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            picture.heightAnchor.constraint(equalTo: picture.widthAnchor),

            sender.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            sender.trailingAnchor.constraint(lessThanOrEqualTo: marks.leadingAnchor, constant: -6),

            marks.trailingAnchor.constraint(equalTo: accountDot.leadingAnchor, constant: -5),
            marks.firstBaselineAnchor.constraint(equalTo: time.firstBaselineAnchor),

            accountDot.widthAnchor.constraint(equalToConstant: 7),
            accountDot.heightAnchor.constraint(equalToConstant: 7),
            accountDot.trailingAnchor.constraint(equalTo: time.leadingAnchor, constant: -6),
            accountDot.centerYAnchor.constraint(equalTo: time.centerYAnchor),

            time.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            time.firstBaselineAnchor.constraint(equalTo: sender.firstBaselineAnchor),

            subject.leadingAnchor.constraint(equalTo: sender.leadingAnchor),
            subject.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            subject.topAnchor.constraint(equalTo: sender.bottomAnchor, constant: 2),

            detail.leadingAnchor.constraint(equalTo: sender.leadingAnchor),
            detail.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            detail.topAnchor.constraint(equalTo: subject.bottomAnchor, constant: 2),
        ])
        pictureSize = picture.widthAnchor.constraint(equalToConstant: 32)
        textLeading = sender.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20)
        NSLayoutConstraint.activate([pictureSize, textLeading])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ thread: Correspondence, showsReason: Bool, accountColor: NSColor?, picture showsPicture: Bool = true,
                   people: PeopleDirectory? = nil) {
        isUnread = thread.isUnread
        picture.isHidden = !showsPicture
        if showsPicture {
            // Pictures grow less than the text, leaving it the room.
            let side = (32 * min(MacListScale.factor, 1.5)).rounded()
            pictureSize.constant = side
            textLeading.constant = 18 + side + 10
            let avatar = CorrespondentAvatar(initials: thread.initials, email: thread.senderEmail, size: CGSize(width: side, height: side))
            picture.rootView = people.map { AnyView(avatar.environment($0)) } ?? AnyView(avatar)
        } else {
            textLeading.constant = 20
        }
        self.showsReason = showsReason
        sender.stringValue = thread.isFromAccountOwner && !thread.toRecipients.isEmpty
            ? String(localized: "To: \(thread.counterpartName())") : thread.sender
        subject.stringValue = thread.subject.isEmpty ? String(localized: "No subject") : thread.subject
        time.stringValue = MacDates.short(thread.receivedAt)
        // Differentiate Without Color: the account by name, not only its dot.
        if accountColor != nil, NSWorkspace.shared.accessibilityDisplayShouldDifferentiateWithoutColor {
            time.stringValue = AccountPreferences.nickname(for: thread.id.account) + " · " + time.stringValue
        }
        symbols = []
        if thread.isSnoozed(at: .now) { symbols.append(("moon.zzz.fill", .secondaryLabelColor)) }
        if thread.isPinned { symbols.append(("pin.fill", NSColor(CorresPalette.pin))) }
        if thread.isFlagged { symbols.append(("flag.fill", NSColor(CorresPalette.flag))) }
        if !thread.attachments.isEmpty { symbols.append(("paperclip", .secondaryLabelColor)) }
        accountDot.isHidden = accountColor == nil
        self.accountColor = accountColor
        if showsReason, !thread.reason.isEmpty {
            // The reason, then the preview: one line each.
            let preview = thread.excerpt.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
            detail.stringValue = "↪ " + thread.displayReason + (preview.isEmpty ? "" : "\n" + preview)
            detail.maximumNumberOfLines = 2
        } else {
            detail.stringValue = thread.excerpt.trimmingCharacters(in: .whitespacesAndNewlines)
            detail.maximumNumberOfLines = 2
        }
        updateColors()
        // VoiceOver hears what the row shows: its state, who, what, when
        // and why it's here.
        var spoken: [String] = []
        if thread.isUnread { spoken.append(String(localized: "Unread")) }
        if thread.isFlagged { spoken.append(String(localized: "Flagged")) }
        if thread.isPinned { spoken.append(String(localized: "Pinned")) }
        spoken += [sender.stringValue, subject.stringValue, time.stringValue]
        if !thread.attachments.isEmpty { spoken.append(String(localized: "Has attachments")) }
        if showsReason, !thread.reason.isEmpty { spoken.append(thread.displayReason) }
        setAccessibilityLabel(spoken.joined(separator: ", "))
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { updateColors() }
    }

    /// Light or Dark (the Mac's, or Settings › Appearance): the dots are
    /// layer colors, fixed when set, so they're set again in the new one.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    /// At View › Bigger and Smaller's size.
    private func applyFonts() {
        time.font = .systemFont(ofSize: MacListScale.size(11))
        marks.font = .systemFont(ofSize: MacListScale.size(10))
        detail.font = .systemFont(ofSize: MacListScale.size(12))
        sender.font = .systemFont(ofSize: MacListScale.size(13), weight: isUnread ? .semibold : .regular)
        subject.font = .systemFont(ofSize: MacListScale.size(13), weight: isUnread ? .medium : .regular)
    }

    private func updateColors() {
        let selected = backgroundStyle == .emphasized
        let accent = NSColor(named: "corresAccent") ?? .controlAccentColor
        dot.isHidden = !isUnread
        effectiveAppearance.performAsCurrentDrawingAppearance {
            dot.layer?.backgroundColor = (selected ? NSColor.white : accent).cgColor
            accountDot.layer?.backgroundColor = accountColor?.cgColor
        }
        applyFonts()
        sender.textColor = selected ? .white : .labelColor
        subject.textColor = selected ? .white : .labelColor
        time.textColor = selected ? NSColor.white.withAlphaComponent(0.85) : .secondaryLabelColor
        let markText = NSMutableAttributedString()
        for symbol in symbols {
            let configuration = NSImage.SymbolConfiguration(pointSize: MacListScale.size(10), weight: .semibold)
                .applying(.init(paletteColors: [selected ? .white : symbol.color]))
            guard let image = NSImage(systemSymbolName: symbol.name, accessibilityDescription: nil)?
                .withSymbolConfiguration(configuration) else { continue }
            let attachment = NSTextAttachment()
            attachment.image = image
            markText.append(NSAttributedString(attachment: attachment))
            markText.append(NSAttributedString(string: " "))
        }
        marks.attributedStringValue = markText
        if showsReason, let text = Optional(detail.stringValue), text.hasPrefix("↪ ") {
            let lines = text.split(separator: "\n", maxSplits: 1).map(String.init)
            let oneLine = NSMutableParagraphStyle()
            oneLine.lineBreakMode = .byTruncatingTail
            let styled = NSMutableAttributedString(string: lines[0], attributes: [.paragraphStyle: oneLine,
                .foregroundColor: selected ? NSColor.white : accent, .font: NSFont.systemFont(ofSize: MacListScale.size(12), weight: .medium)])
            if lines.count > 1 {
                styled.append(NSAttributedString(string: "\n" + lines[1], attributes: [.paragraphStyle: oneLine,
                    .foregroundColor: selected ? NSColor.white.withAlphaComponent(0.8) : NSColor.secondaryLabelColor,
                    .font: NSFont.systemFont(ofSize: MacListScale.size(12))]))
            }
            detail.attributedStringValue = styled
        } else {
            detail.textColor = selected ? NSColor.white.withAlphaComponent(0.8) : .secondaryLabelColor
        }
    }
}

enum MacDates {
    private static let timeFormat: Date.FormatStyle = .dateTime.hour().minute()
    private static let dayFormat: Date.FormatStyle = .dateTime.weekday(.abbreviated)
    private static let dateFormat: Date.FormatStyle = .dateTime.month(.abbreviated).day()
    private static let olderFormat: Date.FormatStyle = .dateTime.month(.defaultDigits).day().year(.twoDigits)

    /// 9:41 AM today, Tue this week, Oct 3 this year, 10/3/25 before.
    static func short(_ date: Date, now: Date = .now) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return date.formatted(timeFormat) }
        if calendar.isDateInYesterday(date) { return String(localized: "Yesterday") }
        if let days = calendar.dateComponents([.day], from: date, to: now).day, days < 7 { return date.formatted(dayFormat) }
        if calendar.isDate(date, equalTo: now, toGranularity: .year) { return date.formatted(dateFormat) }
        return date.formatted(olderFormat)
    }
}

/// The list follows View › Bigger and Smaller by the same factor as the
/// rest of the window and the email, up to twice the size. Row heights are
/// worked out from it too (`Coordinator.apply`), so nothing is cut off.
enum MacListScale {
    @MainActor static var factor: CGFloat { CGFloat(CorresSettings.textScale) }
    @MainActor static func size(_ base: CGFloat) -> CGFloat { (base * factor).rounded() }
}
