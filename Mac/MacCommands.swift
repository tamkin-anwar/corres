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
}

/// The main window, opened from outside it: a notification clicked, or a
/// menu choice, while it's closed and Corres runs on in the menu bar.
@MainActor
enum MacWindows {
    /// Kept by the menu bar commands, which are there with or without a window.
    static var openWindow: OpenWindowAction?
    /// Set while the main window is on screen.
    static var mainIsOpen = false

    static func showMain() {
        if !mainIsOpen { openWindow?(id: "main") }
        NSApplication.shared.activate()
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
            Button("Keyboard Shortcuts") { actions?.perform(.shortcuts) }
                .keyboardShortcut("/", modifiers: .command)
            Button("Send Diagnostics…") { actions?.perform(.sendDiagnostics) }
        }
        // Mail's and Safari's Bigger and Smaller, for the email you're reading.
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
            Button("Go To or Do…") { actions?.perform(.commandPalette) }
                .keyboardShortcut("k", modifiers: .command)
            Divider()
            Button("Get New Mail") { actions?.perform(.getMail) }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Divider()
            Button("Needs You") { actions?.perform(.show(.needsYou)) }.keyboardShortcut("1", modifiers: .command)
            Button("Waiting") { actions?.perform(.show(.waiting)) }.keyboardShortcut("2", modifiers: .command)
            Button("Primary") { actions?.perform(.show(.primary)) }.keyboardShortcut("3", modifiers: .command)
            Button("Everything") { actions?.perform(.show(.filter(MailFilter.everything.rawValue))) }
                .keyboardShortcut("4", modifiers: .command)
            Divider()
            // Mail's message filter, and its shortcut.
            Button("Unread Only") { actions?.perform(.toggleUnreadOnly) }
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
}
