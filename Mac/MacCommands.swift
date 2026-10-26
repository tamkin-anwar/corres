import SwiftUI

/// Everything you can do to mail, from a menu, a key, the toolbar or a
/// right-click.
enum MacAction: Equatable {
    case compose, reply, replyAll, forward
    case archive, trash, move(Attention), toggleFlag, toggleUnread, snooze(Date?), askSnooze
    case getMail, show(MacMailbox), next, previous, openInWindow, undo, commandPalette, print, shortcuts, search
    case toggleUnreadOnly, remind(Date?), sendDiagnostics
}

/// The front window's actions, for the menu bar.
struct MacActions {
    let perform: (MacAction) -> Void
    /// How many conversations they'd act on.
    var selectionCount = 1
    /// The main window's: Go To or Do, the mailboxes and the rest of its
    /// own act here, not by way of `MacWindows.perform`.
    var isMain = false
}

/// The main window, opened from outside it: a notification clicked, or a
/// menu choice, while it's closed and Corres runs on in the menu bar.
@MainActor
enum MacWindows {
    /// Kept by the menu bar commands, which are there with or without a window.
    static var openWindow: OpenWindowAction?
    /// Set while the main window is on screen.
    static var mainIsOpen = false
    /// The main window's actions, while it's open.
    private static var mainActions: ((MacAction) -> Void)?
    /// Asked for before the main window was up: done as it appears.
    private static var waiting: [MacAction] = []

    /// Opens the main window, or brings it in front of a compose or
    /// conversation window.
    static func showMain() {
        openWindow?(id: "main")
        NSApplication.shared.activate()
    }

    /// One of the main window's own actions (Go To or Do, a mailbox,
    /// Keyboard Shortcuts, Send Diagnostics), chosen while another window,
    /// or none, is in front: the main window comes forward and does it.
    static func perform(_ action: MacAction) {
        showMain()
        if mainIsOpen, let mainActions { mainActions(action) } else { waiting.append(action) }
    }

    /// The main window, as it appears: anything asked for meanwhile is done.
    static func mainAppeared(_ perform: @escaping (MacAction) -> Void) {
        mainIsOpen = true
        mainActions = perform
        let queued = waiting
        waiting = []
        // Once it's on screen, so a sheet has a window to show on.
        Task { for action in queued { perform(action) } }
    }

    static func mainDisappeared() {
        mainIsOpen = false
        mainActions = nil
    }

    /// Undo Send: the email isn't sent, and opens again in a compose
    /// window to change, as Mail does.
    static func undoSend(_ outbox: OutboxService) {
        outbox.undo()
        guard let draft = outbox.takeShelved() else { return }
        let handoff = UUID()
        MacComposeHandoff.drafts[handoff] = draft
        openWindow?(value: ComposeRequest(kind: draft.kind, handoff: handoff))
    }
}

private struct MacActionsKey: FocusedValueKey { typealias Value = MacActions }

extension FocusedValues {
    var macActions: MacActions? {
        get { self[MacActionsKey.self] }
        set { self[MacActionsKey.self] = newValue }
    }
}

/// View › Bigger and Smaller: one step along `CorresSettings.textScales`.
@MainActor
enum MacTextSize {
    static func step(_ direction: Int) {
        let scales = CorresSettings.textScales
        let current = CorresSettings.textScale
        let next = direction > 0 ? scales.first { $0 > current + 0.001 } : scales.last { $0 < current - 0.001 }
        if let next { CorresSettings.textScale = next }
    }

    /// The stored scale, kept to the steps' range, as `CorresSettings` reads it.
    static func clamped(_ value: Double) -> CGFloat {
        CGFloat(min(max(value, CorresSettings.textScales[0]), CorresSettings.textScales.last!))
    }

    /// ⌘= is ⌘+ without Shift on most keyboards, as in Safari.
    static func installEqualsShortcut() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Caps Lock and the keypad's = don't count as other modifiers.
            guard event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command,
                  event.charactersIgnoringModifiers == "=" else { return event }
            step(+1)
            return nil
        }
    }
}

/// Text in Corres's own Mac views follows View › Bigger and Smaller. macOS
/// text styles are fixed sizes (13pt body), and the system's Text Size
/// setting isn't open to apps other than Apple's, so the scale is applied
/// here: at Actual Size every style is exactly the system's, and each step
/// grows it by the same factor as the email, up to twice the size.
struct MacScaledFont: ViewModifier {
    @AppStorage(CorresSettings.textScaleKey) private var stored = 1.0
    var style: Font.TextStyle?
    var size: CGFloat?
    var weight: Font.Weight?
    var design: Font.Design?

    @ViewBuilder
    func body(content: Content) -> some View {
        // Nothing set when there's nothing to change: even `.font(nil)`
        // takes the place of a button's or a sidebar's own font.
        if let font { content.font(font) } else { content }
    }

    private var font: Font? {
        let scale = MacTextSize.clamped(stored)
        if let size { return .system(size: (size * scale).rounded(), weight: weight, design: design) }
        guard let style else {
            // No style: the default text, left to the system at Actual Size
            // (a sidebar keeps the size set in System Settings).
            return scale == 1 ? nil : .system(size: (NSFont.systemFontSize * scale).rounded())
        }
        if scale == 1 { return .system(style, design: design, weight: weight) }
        let base = NSFont.preferredFont(forTextStyle: style.appKit)
        return .system(size: (base.pointSize * scale).rounded(), weight: weight ?? (style == .headline ? .bold : nil),
                       design: design)
    }
}

extension View {
    /// A text style that grows with View › Bigger (`MacScaledFont`).
    func macFont(_ style: Font.TextStyle, weight: Font.Weight? = nil, design: Font.Design? = nil) -> some View {
        modifier(MacScaledFont(style: style, weight: weight, design: design))
    }

    /// A designed size (a serif heading) that grows with View › Bigger.
    func macFont(size: CGFloat, weight: Font.Weight? = nil, design: Font.Design? = nil) -> some View {
        modifier(MacScaledFont(size: size, weight: weight, design: design))
    }

    /// For a window's content: text without a style of its own, and
    /// buttons, grow too. Not for a toolbar: its fields keep their height.
    func macTextSize() -> some View {
        modifier(MacScaledFont()).modifier(MacScaledControls(base: .regular))
    }

    /// A control size that steps up as the text grows (View › Bigger):
    /// macOS draws a button's title at its control size, not the font's.
    func macControlSize(_ base: ControlSize) -> some View {
        modifier(MacScaledControls(base: base))
    }
}

struct MacScaledControls: ViewModifier {
    @AppStorage(CorresSettings.textScaleKey) private var stored = 1.0
    var base: ControlSize

    func body(content: Content) -> some View {
        content.controlSize(size)
    }

    private var size: ControlSize {
        let order: [ControlSize] = [.mini, .small, .regular, .large, .extraLarge]
        let scale = MacTextSize.clamped(stored)
        let steps = scale >= 1.75 ? 2 : scale >= 1.3 ? 1 : 0
        let start = order.firstIndex(of: base) ?? 2
        return order[min(start + steps, order.count - 1)]
    }
}

private extension Font.TextStyle {
    var appKit: NSFont.TextStyle {
        switch self {
        case .largeTitle: .largeTitle
        case .title: .title1
        case .title2: .title2
        case .title3: .title3
        case .headline: .headline
        case .subheadline: .subheadline
        case .callout: .callout
        case .footnote: .footnote
        case .caption: .caption1
        case .caption2: .caption2
        default: .body
        }
    }
}

/// The menu bar, with Mail's own shortcuts, so muscle memory works on day
/// one: ⌘N, ⌘R, ⇧⌘R, ⇧⌘F, ⌃⌘A, ⌘⌫, ⇧⌘L, ⇧⌘U, ⇧⌘N, ⌘L, ⌘1 to ⌘4.
struct MacCommands: Commands {
    @FocusedValue(\.macActions) private var actions
    @Environment(\.openWindow) private var openWindow
    @AppStorage(CorresSettings.textScaleKey) private var textScale = 1.0
    @AppStorage(CorresSettings.macSenderPicturesKey) private var showsSenderPictures = true

    /// Nothing to act on: no window with mail in front, or nothing chosen.
    private var noSelection: Bool { (actions?.selectionCount ?? 0) == 0 }

    var body: some Commands {
        let _ = MacWindows.openWindow = openWindow
        CommandGroup(replacing: .newItem) {
            // From any window, or none: a compose window of its own.
            Button("New Message") {
                if let actions { actions.perform(.compose) } else { openWindow(value: ComposeRequest(kind: .new)) }
            }
            .keyboardShortcut("n", modifiers: .command)
        }
        CommandGroup(after: .help) {
            Button("Keyboard Shortcuts") { inMain(.shortcuts) }
                .keyboardShortcut("/", modifiers: .command)
            Button("Send Diagnostics…") { inMain(.sendDiagnostics) }
        }
        // Mail's and Safari's Bigger and Smaller: the email you're reading,
        // and the text around it (`MacScaledFont`, `MacListScale`).
        CommandGroup(after: .toolbar) {
            Divider()
            Button("Bigger") { MacTextSize.step(+1) }
                .keyboardShortcut("+", modifiers: .command)
                .disabled(textScale >= CorresSettings.textScales.last!)
            Button("Smaller") { MacTextSize.step(-1) }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(textScale <= CorresSettings.textScales[0])
            Button("Actual Size") { CorresSettings.textScale = 1 }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(textScale == 1)
            Divider()
            // As Mail has it: pictures beside each row, or a denser list.
            Toggle("Show Sender Pictures", isOn: $showsSenderPictures)
            Divider()
        }
        CommandGroup(replacing: .printItem) {
            Button("Print…") { actions?.perform(.print) }
                .keyboardShortcut("p", modifiers: .command)
                .disabled(noSelection)
        }
        CommandMenu("Mailbox") {
            Button("Go To or Do…") { inMain(.commandPalette) }
                .keyboardShortcut("k", modifiers: .command)
            Divider()
            // From any window, or none, without bringing one forward.
            Button("Get New Mail") { MacServices.shared.getNewMail() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Divider()
            Button("Needs You") { inMain(.show(.needsYou)) }.keyboardShortcut("1", modifiers: .command)
            Button("Waiting") { inMain(.show(.waiting)) }.keyboardShortcut("2", modifiers: .command)
            Button("Primary") { inMain(.show(.primary)) }.keyboardShortcut("3", modifiers: .command)
            Button("Everything") { inMain(.show(.filter(MailFilter.everything.rawValue))) }
                .keyboardShortcut("4", modifiers: .command)
            Divider()
            // Mail's message filter, and its shortcut.
            Button("Unread Only") { inMain(.toggleUnreadOnly) }
                .keyboardShortcut("l", modifiers: .command)
        }
        CommandMenu("Message") {
            Group {
                Button("Reply") { actions?.perform(.reply) }.keyboardShortcut("r", modifiers: .command)
                Button("Reply All") { actions?.perform(.replyAll) }.keyboardShortcut("r", modifiers: [.command, .shift])
                Button("Forward") { actions?.perform(.forward) }.keyboardShortcut("f", modifiers: [.command, .shift])
                Divider()
                Button("Archive") { actions?.perform(.archive) }.keyboardShortcut("a", modifiers: [.command, .control])
                // ⌘⌫ in a text field (search, a reply) deletes to the start of
                // the line there, as everywhere on the Mac, not the conversation.
                Button("Delete") {
                    if NSApp.keyWindow?.firstResponder is NSText {
                        NSApp.sendAction(#selector(NSResponder.deleteToBeginningOfLine(_:)), to: nil, from: nil)
                    } else {
                        actions?.perform(.trash)
                    }
                }
                .keyboardShortcut(.delete, modifiers: .command)
                Divider()
                Button("Move to Needs You") { actions?.perform(.move(.needsYou)) }
                    .keyboardShortcut("1", modifiers: [.command, .control])
                Button("Move to Waiting") { actions?.perform(.move(.waiting)) }
                    .keyboardShortcut("2", modifiers: [.command, .control])
                Button("Mark as Handled") { actions?.perform(.move(.handled)) }
                    .keyboardShortcut("3", modifiers: [.command, .control])
                Divider()
                Menu("Snooze") {
                    ForEach(SnoozeOption.allCases, id: \.self) { option in
                        Button(option.title) { actions?.perform(.snooze(option.date())) }
                    }
                    Divider()
                    Button("Choose a Time…") { actions?.perform(.askSnooze) }
                }
                Button("Flag") { actions?.perform(.toggleFlag) }.keyboardShortcut("l", modifiers: [.command, .shift])
                Button("Mark as Read or Unread") { actions?.perform(.toggleUnread) }.keyboardShortcut("u", modifiers: [.command, .shift])
                Divider()
                Menu("Add to Reminders") {
                    Button("Tomorrow Morning") { actions?.perform(.remind(MailReminders.tomorrowMorning())) }
                    Button("No Date") { actions?.perform(.remind(nil)) }
                }
                Button("Open in New Window") { actions?.perform(.openInWindow) }.keyboardShortcut("o", modifiers: .command)
            }
            .disabled(noSelection)
        }
    }

    /// The main window's own: there when it's in front, otherwise it comes
    /// forward first (a compose window, Settings or nothing in front).
    private func inMain(_ action: MacAction) {
        if let actions, actions.isMain { actions.perform(action) } else { MacWindows.perform(action) }
    }
}

/// Format, as in Mail: Show Fonts, Bold, Italic and Underline for what
/// you're writing. Not SwiftUI's own Format menu, whose Bigger and Smaller
/// took ⌘+ and ⌘- from View › Bigger and Smaller.
struct MacFormatCommands: Commands {
    var body: some Commands {
        CommandMenu("Format") {
            Button("Show Fonts") { NSFontManager.shared.orderFrontFontPanel(nil) }
                .keyboardShortcut("t", modifiers: .command)
            Divider()
            Button("Bold") { Self.toggle(.boldFontMask) }
                .keyboardShortcut("b", modifiers: .command)
            Button("Italic") { Self.toggle(.italicFontMask) }
                .keyboardShortcut("i", modifiers: .command)
            Button("Underline") { NSApp.sendAction(#selector(NSText.underline(_:)), to: nil, from: nil) }
                .keyboardShortcut("u", modifiers: .command)
        }
    }

    /// On, or off when what's selected has it already. The font manager
    /// reads the trait from the sender's tag, as from the standard menu item.
    @MainActor private static func toggle(_ trait: NSFontTraitMask) {
        let fonts = NSFontManager.shared
        let sender = NSMenuItem()
        sender.tag = Int(trait.rawValue)
        if let font = fonts.selectedFont, fonts.traits(of: font).contains(trait) {
            fonts.removeFontTrait(sender)
        } else {
            fonts.addFontTrait(sender)
        }
    }
}
