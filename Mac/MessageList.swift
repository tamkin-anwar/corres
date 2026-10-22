import AppIntents
import AppKit
import SwiftUI

/// The message list: a real AppKit table, the fastest list there is on the
/// Mac (SwiftUI's List slows past ten thousand rows; a mailbox is often
/// more). Native selection, type-to-move, Shift and Command clicks, and
/// rows that slide away when archived.
struct MessageList: NSViewRepresentable {
    let rows: [MacRow]
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
        context.coordinator.apply(rows: rows, selection: selection)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var parent: MessageList
        weak var table: MessageTableView?
        private var rows: [MacRow] = []
        private var applyingSelection = false

        init(_ parent: MessageList) { self.parent = parent }

        func apply(rows newRows: [MacRow], selection: Set<ThreadID>) {
            guard let table else { return }
            if newRows != rows {
                let oldIDs = rows.map(Self.key)
                let newIDs = newRows.map(Self.key)
                let newSet = Set(newIDs)
                // Only removals (archive, delete, a move): slide those rows
                // away rather than redrawing the whole list.
                let removed = IndexSet(oldIDs.indices.filter { !newSet.contains(oldIDs[$0]) })
                let kept = oldIDs.enumerated().filter { !removed.contains($0.offset) }.map(\.element)
                rows = newRows
                // A conversation leaving the list on its own (answered, say)
                // stays open in the reading pane, as in Mail: the update
                // doesn't count as you choosing nothing.
                applyingSelection = true
                defer { applyingSelection = false }
                if !removed.isEmpty, kept == newIDs, removed.count < 50 {
                    // System Settings › Accessibility › Reduce Motion: no slide.
                    let motion: NSTableView.AnimationOptions = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? [] : [.effectFade, .slideUp]
                    table.removeRows(at: removed, withAnimation: motion)
                    // Content in the kept rows may have changed too (read state).
                    table.reloadData(forRowIndexes: IndexSet(integersIn: 0..<newRows.count), columnIndexes: [0])
                } else if oldIDs == newIDs {
                    let changed = IndexSet(newRows.indices)
                    table.reloadData(forRowIndexes: changed, columnIndexes: [0])
                } else {
                    table.reloadData()
                }
            }
            let wanted = IndexSet(rows.indices.filter { rows[$0].thread.map { selection.contains($0.id) } ?? false })
            if table.selectedRowIndexes != wanted {
                applyingSelection = true
                table.selectRowIndexes(wanted, byExtendingSelection: false)
                applyingSelection = false
                if let first = wanted.first { table.scrollRowToVisible(first) }
            }
        }

        private static func key(_ row: MacRow) -> String {
            switch row {
            case .group(let title): "group:" + title
            case .thread(let thread): thread.id.account + "|" + thread.id.providerID
            }
        }

        func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

        /// A dragged row carries its conversation, and the rest of the
        /// selection when it's part of it.
        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
            guard rows.indices.contains(row), let thread = rows[row].thread else { return nil }
            let ids = parent.selection.contains(thread.id) ? parent.selection : [thread.id]
            let item = NSPasteboardItem()
            item.setString(MacDrag.encode(ids), forType: .string)
            return item
        }

        func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
            if case .group = rows[row] { true } else { false }
        }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            switch rows[row] {
            case .group: 30
            case .thread: parent.showsReasons ? 92 : 76
            }
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
                view.configure(thread, showsReason: parent.showsReasons, accountColor: parent.accountColors[thread.id.account])
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
                return [action("Archive", "archivebox.fill", CorresPalette.swipeArchive, .archive),
                        action("Delete", "trash.fill", CorresPalette.swipeTrash, .trash, style: .destructive)]
            case .leading:
                return [action("Handled", "checkmark.circle.fill", CorresPalette.swipeHandled, .move(.handled)),
                        action(thread.isUnread ? "Read" : "Unread", "envelope.badge.fill", CorresPalette.swipeUnread, .toggleUnread)]
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

/// A key pressed in the list that Corres may act on.
struct MessageListKey {
    let characters: String
    let keyCode: UInt16
    let modifiers: NSEvent.ModifierFlags

    static let delete: UInt16 = 51, forwardDelete: UInt16 = 117, returnKey: UInt16 = 36, space: UInt16 = 49
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

    var title: String = "" { didSet { label.stringValue = title.uppercased() } }

    init() {
        super.init(frame: .zero)
        identifier = Self.identifier
        label.font = .systemFont(ofSize: 11, weight: .semibold)
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
    private var isUnread = false
    private var showsReason = false
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
        time.font = .systemFont(ofSize: 11)
        marks.font = .systemFont(ofSize: 10)
        subject.font = .systemFont(ofSize: 13)
        detail.font = .systemFont(ofSize: 12)
        for view in [dot, sender, time, marks, accountDot, subject, detail] {
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

            sender.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
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
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ thread: Correspondence, showsReason: Bool, accountColor: NSColor?) {
        isUnread = thread.isUnread
        self.showsReason = showsReason
        sender.stringValue = thread.isFromAccountOwner && !thread.toRecipients.isEmpty
            ? String(localized: "To: \(thread.counterpartName())") : thread.sender
        subject.stringValue = thread.subject.isEmpty ? String(localized: "No subject") : thread.subject
        time.stringValue = MacDates.short(thread.receivedAt)
        symbols = []
        if thread.isSnoozed(at: .now) { symbols.append(("moon.zzz.fill", .secondaryLabelColor)) }
        if thread.isPinned { symbols.append(("pin.fill", NSColor(CorresPalette.pin))) }
        if thread.isFlagged { symbols.append(("flag.fill", NSColor(CorresPalette.flag))) }
        if !thread.attachments.isEmpty { symbols.append(("paperclip", .secondaryLabelColor)) }
        accountDot.isHidden = accountColor == nil
        accountDot.layer?.backgroundColor = accountColor?.cgColor
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

    private func updateColors() {
        let selected = backgroundStyle == .emphasized
        let accent = NSColor(named: "corresAccent") ?? .controlAccentColor
        dot.isHidden = !isUnread
        dot.layer?.backgroundColor = (selected ? NSColor.white : accent).cgColor
        sender.font = .systemFont(ofSize: 13, weight: isUnread ? .semibold : .regular)
        subject.font = .systemFont(ofSize: 13, weight: isUnread ? .medium : .regular)
        sender.textColor = selected ? .white : .labelColor
        subject.textColor = selected ? .white : .labelColor
        time.textColor = selected ? NSColor.white.withAlphaComponent(0.85) : .secondaryLabelColor
        let markText = NSMutableAttributedString()
        for symbol in symbols {
            let configuration = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
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
                .foregroundColor: selected ? NSColor.white : accent, .font: NSFont.systemFont(ofSize: 12, weight: .medium)])
            if lines.count > 1 {
                styled.append(NSAttributedString(string: "\n" + lines[1], attributes: [.paragraphStyle: oneLine,
                    .foregroundColor: selected ? NSColor.white.withAlphaComponent(0.8) : NSColor.secondaryLabelColor,
                    .font: NSFont.systemFont(ofSize: 12)]))
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
