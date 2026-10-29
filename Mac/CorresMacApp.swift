import CoreSpotlight
import GoogleSignIn
import SwiftUI

/// Corres for Mac: a native Mac app on the same engine, sync, sorting and
/// iCloud state as the iPhone app. Its own windows, sidebar, toolbar,
/// menus and keyboard, built for the Mac rather than carried over from
/// iPhone.
@main
struct CorresMacApp: App {
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var appDelegate
    @State private var services = MacServices.shared
    @State private var model = MacMailboxModel()
    @AppStorage("corres.appearance") private var appearance = "system"
    @AppStorage(MacMenuBarSetting.key) private var inMenuBar = true

    var body: some Scene {
        Window("Corres", id: "main") {
            MacMainView(services: services, model: model)
                .environment(services.intelligence)
                .environment(services.router)
                .environment(services.ask)
                .environment(services.entitlements)
                .environment(services.people)
                .tint(CorresPalette.accent)
                .preferredColorScheme(colorScheme)
                .frame(minWidth: 900, minHeight: 560)
                .onOpenURL { url in
                    if !services.router.open(url) { GIDSignIn.sharedInstance.handle(url) }
                }
                // Handed off from your iPhone or iPad.
                .onContinueUserActivity(Handoff.conversation) { activity in
                    if let id = Handoff.threadID(activity) { services.router.pending = .thread(id) }
                }
                // A conversation picked in Spotlight.
                .onContinueUserActivity(CSSearchableItemActionType) { activity in
                    if let id = SpotlightIndex.threadID(from: activity) { services.router.pending = .thread(id) }
                }
        }
        .defaultSize(width: 1280, height: 820)
        .commands {
            MacCommands()
            // Format: Show Fonts, Bold, Italic, Underline.
            MacFormatCommands()
        }

        // Written only when it really changes. macOS reports the item as
        // shown each time SwiftUI updates it; bound straight to the setting,
        // that report saved the same value again, the save redrew every
        // window and the menu bar item, and the update reported again: a
        // loop at full speed from launch (the Mac freezing at start, builds
        // 20 to 22).
        MenuBarExtra(isInserted: Binding(get: { inMenuBar }, set: { if $0 != inMenuBar { inMenuBar = $0 } })) {
            MacMenuBarContent(services: services)
        } label: {
            MacMenuBarLabel(services: services)
        }

        // A conversation in a window of its own.
        WindowGroup("Conversation", for: ThreadID.self) { $id in
            if let id {
                MacConversationWindow(id: id, services: services, model: model)
                    .environment(services.intelligence)
                    .environment(services.people)
                    .tint(CorresPalette.accent)
                    .preferredColorScheme(colorScheme)
                    .macTextSize()
                    .frame(minWidth: 560, minHeight: 480)
            }
        }
        .defaultSize(width: 760, height: 820)

        WindowGroup("New Message", for: ComposeRequest.self) { $request in
            if let request {
                MacComposeView(request: request, services: services)
                    .tint(CorresPalette.accent)
                    .preferredColorScheme(colorScheme)
                    .macTextSize()
            }
        }
        .defaultSize(width: 680, height: 560)
        // What you wrote is kept in Drafts; an empty window shouldn't
        // come back on the next launch.
        .restorationBehavior(.disabled)

        // Corres Pro: monthly or annual, with the free trial. Its own
        // window, opened from a locked list, the menu bar or Settings, so
        // the App Store's confirmation shows in it (`purchase(confirmIn:)`).
        Window("Corres Pro", id: MacPro.windowID) {
            PaywallView()
                .environment(services.entitlements)
                .tint(CorresPalette.accent)
                .preferredColorScheme(colorScheme)
                .onAppear { services.paywallOpen = true }
                .onDisappear { services.paywallOpen = false }
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .defaultPosition(.center)
        .restorationBehavior(.disabled)

        Settings {
            MacSettingsView(services: services)
                .environment(services.entitlements)
                .tint(CorresPalette.accent)
                .preferredColorScheme(colorScheme)
        }
    }

    private var colorScheme: ColorScheme? {
        switch appearance { case "light": .light; case "dark": .dark; default: nil }
    }
}

/// A conversation in a window of its own. Reply, Archive, Flag and the rest
/// of the Message menu act on it while it's in front.
private struct MacConversationWindow: View {
    let id: ThreadID
    let services: MacServices
    let model: MacMailboxModel
    @State private var snoozing = false
    @State private var reminderOutcome: MailReminders.Outcome?
    @State private var mailUndo = MailUndoTarget()
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        content
            // A reply sent from here can be taken back from here.
            .overlay(alignment: .bottom) { MacUndoSend.Pill(outbox: services.outbox) }
            .onChange(of: [services.outbox.pending?.id, services.threadActions.pendingRemoval?.id], initial: true) {
                registerUndo()
            }
            // Gone for good (deleted, or moved by a sync), not just waiting
            // out Undo: the window goes too.
            .onChange(of: isGone, initial: true) { if isGone { dismiss() } }
    }

    /// Edit › Undo: Undo Send first, then this conversation archived or
    /// deleted from here while the main window was closed.
    private func registerUndo() {
        guard let undoManager else { return }
        undoManager.removeAllActions(withTarget: mailUndo)
        if services.outbox.pending != nil {
            MacUndoSend.register(services.outbox, in: undoManager, target: mailUndo)
            return
        }
        let actions = services.threadActions
        guard let pending = actions.pendingRemoval, pending.threads.contains(where: { $0.id == id }) else { return }
        undoManager.registerUndo(withTarget: mailUndo) { _ in
            MainActor.assumeIsolated { actions.undoRemoval() }
        }
        undoManager.setActionName(pending.title)
    }

    /// Not in your mail any more, nor hidden while Undo is offered.
    private var isGone: Bool {
        let store = services.store
        return store.state == .loaded && !store.hiddenIDs.contains(id) && store.thread(id) == nil
    }

    @ViewBuilder
    private var content: some View {
        if let thread = services.store.thread(id) {
            ReadingPane(thread: thread, services: services) { kind in
                openWindow(value: ComposeRequest(kind: kind, thread: thread.id))
            }
            .focusedSceneValue(\.macActions, MacActions(perform: { perform($0, on: thread) }, isPinned: thread.isPinned,
                                                         canOpenInWindow: false))
            .sheet(isPresented: $snoozing) {
                MacSnoozeSheet { date in
                    snoozing = false
                    perform(.snooze(date), on: thread)
                }
            }
            .alert("Couldn't Add to Reminders", isPresented: Binding(get: { reminderOutcome != nil && reminderOutcome != .added },
                                                                    set: { if !$0 { reminderOutcome = nil } })) {
                Button("OK", role: .cancel) { reminderOutcome = nil }
            } message: {
                if reminderOutcome == .notAllowed {
                    Text("Corres doesn't have access to Reminders. You can allow it in System Settings > Privacy & Security > Reminders.")
                } else {
                    Text("Reminders didn't save it. Try again.")
                }
            }
        } else if services.store.hiddenIDs.contains(id) {
            // Archived or deleted elsewhere, and Undo still on offer.
            ContentUnavailableView {
                EmptyTitle("Conversation Moved", systemImage: "tray")
            } description: {
                Text("It was archived, deleted or moved. Undo brings it back.")
            } actions: {
                if services.threadActions.pendingRemoval?.threads.contains(where: { $0.id == id }) == true {
                    Button("Undo") { services.threadActions.undoRemoval() }
                }
            }
            .focusedSceneValue(\.macActions, MacActions(perform: { perform($0) }, selectionCount: 0))
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// With no conversation to act on: what doesn't need one.
    private func perform(_ action: MacAction) {
        switch action {
        case .compose: openWindow(value: ComposeRequest(kind: .new))
        case .undo: undo()
        case .getMail: services.getNewMail()
        case .show, .toggleUnreadOnly, .commandPalette, .shortcuts, .search, .sendDiagnostics, .next, .previous:
            MacWindows.perform(action)
        default: break
        }
    }

    /// Undo Send first, then whatever the main window's pill offers.
    private func undo() {
        let actions = services.threadActions
        if services.outbox.pending != nil { MacWindows.undoSend(services.outbox) }
        else if actions.pendingRemoval != nil { actions.undoRemoval() } else { actions.undoLastChange() }
    }

    private func perform(_ action: MacAction, on thread: Correspondence) {
        let actions = services.threadActions
        switch action {
        case .compose:
            openWindow(value: ComposeRequest(kind: .new))
        case .reply, .replyAll, .forward:
            openWindow(value: ComposeRequest(kind: action == .reply ? .reply : action == .replyAll ? .replyAll : .forward, thread: thread.id))
        case .archive, .trash:
            // Settings → Ask Before Moving to Trash, as in the main window.
            if action == .trash, !MacTrashConfirmation.allows(1) { return }
            // Gone from your mail, so the window goes too; Undo is in the
            // main window. With that closed, this window stays, saying it
            // moved, with Undo, until it's done (`isGone`).
            services.remote.remove([thread.id])
            Task { action == .archive ? await actions.archive([thread]) : await actions.trash([thread]) }
            if MacWindows.mainIsOpen { dismiss() }
        case .move(let attention):
            Task { await actions.setAttention(attention, for: [thread]) }
        case .toggleFlag:
            Task { await actions.toggleFlagged(!thread.isFlagged, for: [thread]) }
        case .togglePin:
            Task { await actions.togglePinned(thread) }
        case .toggleUnread:
            Task { await actions.toggleUnread(!thread.isUnread, for: [thread]) }
        case .snooze(let date):
            Task { await services.store.snooze(thread.id, until: date) }
            if date != nil { dismiss() }
        case .askSnooze:
            snoozing = true
        case .remind(let due):
            Task { reminderOutcome = await MailReminders.add(thread, due: due) }
        case .print:
            MacPrinter.print(services.store.thread(thread.id) ?? thread, in: NSApp.keyWindow)
        case .undo:
            undo()
        case .getMail:
            services.getNewMail()
        case .show(let mailbox):
            model.mailbox = mailbox
            MacWindows.showMain()
        case .toggleUnreadOnly, .commandPalette, .shortcuts, .search, .sendDiagnostics, .next, .previous:
            // The main window's own: it comes forward and does it.
            MacWindows.perform(action)
        case .openInWindow:
            break
        }
    }
}

/// Opening Corres Pro's window from anywhere: a locked list, a locked
/// answer in Search, the menu bar or Settings.
@MainActor
enum MacPro {
    static let windowID = "pro"

    static func open(_ openWindow: OpenWindowAction) {
        openWindow(id: windowID)
        NSApp.activate()
    }

    /// "Try Corres Pro Free" while the free trial is still on offer to
    /// this Apple Account, "Get Corres Pro" after it.
    static func unlockTitle(_ entitlements: EntitlementStore) -> String {
        entitlements.isEligibleForTrial ? String(localized: "Try Corres Pro Free") : String(localized: "Get Corres Pro")
    }
}
