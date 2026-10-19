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
                if !removed.isEmpty, kept == newIDs, removed.count < 50 {
                    table.removeRows(at: removed, withAnimation: [.effectFade, .slideUp])
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
            switch rows[row] {
            case .group(let title):
                let view = tableView.makeView(withIdentifier: GroupCellView.identifier, owner: nil) as? GroupCellView ?? GroupCellView()
                view.title = title
                return view
            case .thread(let thread):
                let view = tableView.makeView(withIdentifier: ThreadCellView.identifier, owner: nil) as? ThreadCellView ?? ThreadCellView()
                view.configure(thread, showsReason: parent.showsReasons, accountColor: parent.accountColors[thread.id.account])
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
            ? "To: " + thread.counterpartName() : thread.sender
        subject.stringValue = thread.subject.isEmpty ? "(No subject)" : thread.subject
        time.stringValue = MacDates.short(thread.receivedAt)
        var markText = ""
        if thread.isPinned { markText += "📌" }
        if thread.isFlagged { markText += "⚑" }
        if !thread.attachments.isEmpty { markText += "📎" }
        marks.stringValue = markText
        accountDot.isHidden = accountColor == nil
        accountDot.layer?.backgroundColor = accountColor?.cgColor
        if showsReason, !thread.reason.isEmpty {
            detail.stringValue = "↪ " + thread.reason
            detail.maximumNumberOfLines = 1
            // The preview, shortened, after the reason.
            let preview = thread.excerpt.trimmingCharacters(in: .whitespacesAndNewlines)
            if !preview.isEmpty { detail.maximumNumberOfLines = 2; detail.stringValue = "↪ " + thread.reason + "\n" + preview }
        } else {
            detail.stringValue = thread.excerpt.trimmingCharacters(in: .whitespacesAndNewlines)
            detail.maximumNumberOfLines = 2
        }
        updateColors()
        setAccessibilityLabel("\(thread.isUnread ? "Unread. " : "")\(thread.sender). \(thread.subject). \(MacDates.short(thread.receivedAt))")
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
        marks.textColor = selected ? .white : NSColor(named: "corresAccent") ?? .secondaryLabelColor
        if showsReason, let text = Optional(detail.stringValue), text.hasPrefix("↪ ") {
            let lines = text.split(separator: "\n", maxSplits: 1).map(String.init)
            let styled = NSMutableAttributedString(string: lines[0], attributes: [
                .foregroundColor: selected ? NSColor.white : accent, .font: NSFont.systemFont(ofSize: 12, weight: .medium)])
            if lines.count > 1 {
                styled.append(NSAttributedString(string: "\n" + lines[1], attributes: [
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
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        if let days = calendar.dateComponents([.day], from: date, to: now).day, days < 7 { return date.formatted(dayFormat) }
        if calendar.isDate(date, equalTo: now, toGranularity: .year) { return date.formatted(dateFormat) }
        return date.formatted(olderFormat)
    }
}
