import SwiftUI

/// Everything you can do to mail, from a menu, a key, the toolbar or a
/// right-click.
enum MacAction: Equatable {
    case compose, reply, replyAll, forward
    case archive, trash, move(Attention), toggleFlag, toggleUnread, snooze(Date?), askSnooze
    case getMail, show(MacMailbox), next, previous, openInWindow, undo, commandPalette, print, shortcuts, search
}

/// The front window's actions, for the menu bar.
struct MacActions {
    let perform: (MacAction) -> Void
}

private struct MacActionsKey: FocusedValueKey { typealias Value = MacActions }

extension FocusedValues {
    var macActions: MacActions? {
        get { self[MacActionsKey.self] }
        set { self[MacActionsKey.self] = newValue }
    }
}

/// The menu bar, with Mail's own shortcuts, so muscle memory works on day
/// one: ⌘N, ⌘R, ⇧⌘R, ⇧⌘F, ⌃⌘A, ⌘⌫, ⇧⌘L, ⇧⌘U, ⇧⌘N, ⌘1 to ⌘4.
struct MacCommands: Commands {
    @FocusedValue(\.macActions) private var actions

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Message") { actions?.perform(.compose) }
                .keyboardShortcut("n", modifiers: .command)
        }
        CommandGroup(after: .help) {
            Button("Keyboard Shortcuts") { actions?.perform(.shortcuts) }
                .keyboardShortcut("/", modifiers: .command)
        }
        CommandGroup(replacing: .printItem) {
            Button("Print…") { actions?.perform(.print) }
                .keyboardShortcut("p", modifiers: .command)
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
        }
        CommandMenu("Message") {
            Button("Reply") { actions?.perform(.reply) }.keyboardShortcut("r", modifiers: .command)
            Button("Reply All") { actions?.perform(.replyAll) }.keyboardShortcut("r", modifiers: [.command, .shift])
            Button("Forward") { actions?.perform(.forward) }.keyboardShortcut("f", modifiers: [.command, .shift])
            Divider()
            Button("Archive") { actions?.perform(.archive) }.keyboardShortcut("a", modifiers: [.command, .control])
            Button("Delete") { actions?.perform(.trash) }.keyboardShortcut(.delete, modifiers: .command)
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
            Button("Open in New Window") { actions?.perform(.openInWindow) }.keyboardShortcut("o", modifiers: .command)
        }
    }
}
