import SwiftUI

/// The main window: sidebar, message list, and the conversation, the
/// layout every Mac mail app people love shares. Needs You first.
struct MacMainView: View {
    let services: MacServices
    @Bindable var model: MacMailboxModel
    @Environment(\.openWindow) private var openWindow
    @State private var columns = NavigationSplitViewVisibility.all
    @State private var snoozing: [Correspondence] = []

    private var store: MailStore { services.store }
    private var dockCount: Int {
        guard services.entitlements.isPro || accounts.isEmpty else { return 0 }
        return MailQuery.prioritized(store.threads, attention: .needsYou).count
    }
    private var actions: ThreadActionService { services.threadActions }
    private var accounts: [String] { services.auth.accounts.map(\.email) }

    var body: some View {
        let rows = model.rows(store: store, accounts: accounts, remote: services.remote)
        NavigationSplitView(columnVisibility: $columns) {
            MacSidebar(services: services, model: model)
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 300)
        } content: {
            listColumn(rows)
                .navigationSplitViewColumnWidth(min: 320, ideal: 400, max: 560)
        } detail: {
            detail
        }
        .searchable(text: $model.search, placement: .toolbar, prompt: "Search, or ask a question")
        .onSubmit(of: .search) { submitSearch() }
        .toolbar { toolbar }
        .overlay(alignment: .bottom) { undoBar }
        .sheet(isPresented: Binding(get: { !snoozing.isEmpty }, set: { if !$0 { snoozing = [] } })) {
            MacSnoozeSheet { date in
                let threads = snoozing
                snoozing = []
                perform(.snooze(date), on: threads)
            }
        }
        .focusedSceneValue(\.macActions, MacActions(perform: { perform($0) }))
        // What needs you, on the Dock icon.
        .onChange(of: dockCount, initial: true) { _, count in
            NSApplication.shared.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
        }
        .onChange(of: services.sync.lastCompletedSync) { services.afterSync() }
        .onChange(of: services.sync.syncProgress) { Task { await store.refresh() } }
        // A notification, a widget or a corres:// link asking for a place.
        .onChange(of: services.router.pending, initial: true) { _, target in
            guard let target else { return }
            services.router.pending = nil
            switch target {
            case .thread(let id):
                model.search = ""
                if services.store.thread(id)?.attention == .needsYou { model.mailbox = .needsYou }
                else if model.mailbox.remoteKind != nil || model.mailbox == .newSenders { model.mailbox = .filter(MailFilter.everything.rawValue) }
                model.selection = [id]
            case .destination(let destination):
                switch destination {
                case .waiting: model.mailbox = .waiting
                case .mail: model.mailbox = .primary
                default: model.mailbox = .needsYou
                }
            case .compose:
                perform(.compose)
            case .composeTo(let to, let subject, let body):
                openWindow(value: ComposeRequest(kind: .new, to: to, subject: subject, body: body))
            default:
                break
            }
        }
        .task(id: model.mailbox) {
            guard let kind = model.mailbox.remoteKind else { return }
            await services.remote.refresh(kind, accounts: accounts, store: store)
        }
        .alert("Couldn't Save", isPresented: Binding(get: { store.errorMessage != nil },
                                                     set: { if !$0 { store.errorMessage = nil } })) {
            Button("OK", role: .cancel) { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
        .alert("Something Went Wrong", isPresented: Binding(get: { actions.errorMessage != nil },
                                                            set: { if !$0 { actions.errorMessage = nil } })) {
            Button("OK", role: .cancel) { actions.errorMessage = nil }
        } message: { Text(actions.errorMessage ?? "") }
    }

    // MARK: List

    private func listColumn(_ rows: [MacRow]) -> some View {
        VStack(spacing: 0) {
            if services.ask.phase != .idle, !model.search.isEmpty {
                askCard
            }
            if rows.isEmpty {
                emptyState
            } else {
                MessageList(rows: rows, showsReasons: model.mailbox.showsReasons && model.search.isEmpty,
                            accountColors: accountColors, selection: $model.selection,
                            onOpen: { thread in open(thread) },
                            onKey: handleKey, menu: contextMenu,
                            onSwipe: { thread, action in perform(action, on: [thread]) },
                            onReachEnd: {
                                guard let kind = model.mailbox.remoteKind else { return }
                                Task { await services.remote.loadMore(kind, accounts: accounts, store: store) }
                            })
            }
        }
        .navigationTitle(model.search.isEmpty ? model.mailbox.title : "Search")
        .navigationSubtitle(subtitle(rows))
        .background(CorresPalette.canvas)
    }

    private func subtitle(_ rows: [MacRow]) -> String {
        let count = rows.compactMap(\.thread).count
        if services.sync.isSyncing { return "Checking for mail…" }
        if count == 0 { return "" }
        let unread = rows.compactMap(\.thread).filter(\.isUnread).count
        return unread > 0 ? "\(count) conversations, \(unread) unread" : "\(count) conversations"
    }

    private var accountColors: [String: NSColor] {
        Dictionary(uniqueKeysWithValues: accounts.compactMap { account in
            AccountPreferences.color(for: account, among: accounts).map { (account, NSColor($0)) }
        })
    }

    @ViewBuilder
    private var emptyState: some View {
        if let kind = model.mailbox.remoteKind, model.search.isEmpty, !services.remote.hasLoaded(kind) || services.remote.loading.contains(kind) {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let kind = model.mailbox.remoteKind, model.search.isEmpty, services.remote.failed(kind) {
            ContentUnavailableView("Couldn't load \(kind.title)", systemImage: "wifi.exclamationmark",
                                   description: Text("Check your connection, then choose it again."))
        } else if !model.search.isEmpty {
            ContentUnavailableView.search(text: model.search)
        } else if model.mailbox == .needsYou {
            ContentUnavailableView("Nothing needs you",
                                   systemImage: "checkmark.circle",
                                   description: Text("Email that asks something of you lands here, with the reason why."))
        } else {
            ContentUnavailableView(model.mailbox.title, systemImage: model.mailbox.systemImage,
                                   description: Text("No conversations here."))
        }
    }

    private var askCard: some View {
        let ask = services.ask
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Label("Answer", systemImage: "sparkle").font(.caption.weight(.semibold)).foregroundStyle(CorresPalette.accent)
                if ask.phase == .searching || ask.phase == .answering { ProgressView().controlSize(.mini) }
            }
            if let answer = ask.answer {
                Text(answer).font(.callout).foregroundStyle(CorresPalette.ink).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } else if ask.phase == .done {
                Text("Couldn't find an answer in your mail.").font(.callout).foregroundStyle(CorresPalette.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(CorresPalette.surface, in: RoundedRectangle(cornerRadius: 10))
        .padding(10)
    }

    // MARK: Detail

    @ViewBuilder
    private var detail: some View {
        let selected = model.selectedThreads
        if selected.count == 1, let thread = selected.first {
            ReadingPane(thread: thread, services: services) { kind in compose(kind, thread) }
        } else if selected.count > 1 {
            ContentUnavailableView("\(selected.count) conversations selected", systemImage: "square.stack",
                                   description: Text("Archive, delete, move or flag them together."))
        } else {
            ContentUnavailableView {
                Label("Corres", systemImage: "envelope.open")
            } description: {
                Text("Choose a conversation to read it.")
            }
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button { perform(.compose) } label: { Label("New Message", systemImage: "square.and.pencil") }
                .help("New Message (⌘N)")
            Button { perform(.archive) } label: { Label("Archive", systemImage: "archivebox") }
                .help("Archive (⌃⌘A, or E)").disabled(model.selection.isEmpty)
            Button { perform(.trash) } label: { Label("Delete", systemImage: "trash") }
                .help("Delete (⌘⌫, or #)").disabled(model.selection.isEmpty)
            Menu {
                ForEach(Attention.choices, id: \.self) { attention in
                    Button(attention.title) { perform(.move(attention)) }
                }
            } label: { Label("Move", systemImage: "arrow.right.circle") }
                .help("Needs You, Waiting or Handled").disabled(model.selection.isEmpty)
            Button { perform(.reply) } label: { Label("Reply", systemImage: "arrowshape.turn.up.left") }
                .help("Reply (⌘R, or R)").disabled(model.selection.count != 1)
            Button { perform(.replyAll) } label: { Label("Reply All", systemImage: "arrowshape.turn.up.left.2") }
                .help("Reply All (⇧⌘R, or A)").disabled(model.selection.count != 1)
            Button { perform(.forward) } label: { Label("Forward", systemImage: "arrowshape.turn.up.right") }
                .help("Forward (⇧⌘F, or F)").disabled(model.selection.count != 1)
            Menu {
                ForEach(SnoozeOption.allCases, id: \.self) { option in
                    Button(option.title) { perform(.snooze(option.date())) }
                }
                Divider()
                Button("Choose a Time…") { perform(.askSnooze) }
            } label: { Label("Snooze", systemImage: "moon.zzz") }
                .help("Snooze (B)").disabled(model.selection.isEmpty)
            Button { perform(.toggleFlag) } label: { Label("Flag", systemImage: "flag") }
                .help("Flag (⇧⌘L, or S)").disabled(model.selection.isEmpty)
        }
    }

    // MARK: Undo

    @ViewBuilder
    private var undoBar: some View {
        if let pending = actions.pendingRemoval {
            undoPill(pending.title, systemImage: pending.kind.systemImage) { actions.undoRemoval() }
        } else if let change = actions.lastChange {
            undoPill(change.title, systemImage: change.systemImage) { actions.undoLastChange() }
        }
    }

    private func undoPill(_ title: String, systemImage: String, undo: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Label(title, systemImage: systemImage)
            Button("Undo", action: undo).buttonStyle(.borderless).keyboardShortcut("z", modifiers: .command)
                .foregroundStyle(CorresPalette.accent)
        }
        .font(.callout)
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(CorresPalette.line))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        .padding(.bottom, 18)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    // MARK: Actions

    /// Runs an action on the selection, or on `threads` when given (a
    /// swiped row that isn't selected).
    func perform(_ action: MacAction, on threads: [Correspondence]? = nil) {
        let selected = threads ?? model.selectedThreads
        switch action {
        case .compose:
            openWindow(value: ComposeRequest(kind: .new))
        case .reply, .replyAll, .forward:
            guard let thread = selected.first else { return }
            compose(action == .reply ? .reply : action == .replyAll ? .replyAll : .forward, thread)
        case .archive, .trash:
            guard !selected.isEmpty else { return }
            let ids = Set(selected.map(\.id))
            if !model.selection.isDisjoint(with: ids) {
                let next = model.neighbor(after: ids)
                model.selection = next.map { [$0] } ?? []
            }
            services.remote.remove(ids)
            Task { action == .archive ? await actions.archive(selected) : await actions.trash(selected) }
        case .move(let attention):
            guard !selected.isEmpty else { return }
            Task { await actions.setAttention(attention, for: selected) }
        case .toggleFlag:
            guard !selected.isEmpty else { return }
            let flag = !selected.allSatisfy(\.isFlagged)
            Task { await actions.toggleFlagged(flag, for: selected) }
        case .toggleUnread:
            guard !selected.isEmpty else { return }
            let unread = !selected.allSatisfy(\.isUnread)
            Task { await actions.toggleUnread(unread, for: selected) }
        case .snooze(let date):
            guard !selected.isEmpty else { return }
            if date != nil {
                let ids = Set(selected.map(\.id))
                if !model.selection.isDisjoint(with: ids) { model.selection = model.neighbor(after: ids).map { [$0] } ?? [] }
            }
            Task { for thread in selected { await store.snooze(thread.id, until: date) } }
        case .askSnooze:
            snoozing = selected
        case .getMail:
            Task { await services.checkForMail() }
        case .show(let mailbox):
            model.mailbox = mailbox
        case .next, .previous:
            let threads = model.rows(store: store, accounts: accounts, remote: services.remote).compactMap(\.thread)
            guard !threads.isEmpty else { return }
            let current = threads.firstIndex { model.selection.contains($0.id) }
            let index = switch (action, current) {
            case (.next, nil): 0
            case (.next, let i?): min(i + 1, threads.count - 1)
            case (_, nil): threads.count - 1
            case (_, let i?): max(i - 1, 0)
            }
            model.selection = [threads[index].id]
        case .openInWindow:
            guard let thread = selected.first else { return }
            open(thread)
        case .undo:
            if actions.pendingRemoval != nil { actions.undoRemoval() } else { actions.undoLastChange() }
        }
    }

    /// Double-click or Return: a draft continues in Compose, anything else
    /// opens in its own window.
    private func open(_ thread: Correspondence) {
        if model.mailbox.remoteKind == .drafts {
            openWindow(value: ComposeRequest(kind: .new, to: thread.toRecipients.joined(separator: ", "),
                                             subject: thread.subject, body: thread.body,
                                             account: thread.id.account,
                                             serverDraftID: services.remote.draftID(for: thread.id)))
        } else {
            openWindow(value: thread.id)
        }
    }

    private func compose(_ kind: Draft.Kind, _ thread: Correspondence) {
        openWindow(value: ComposeRequest(kind: kind, thread: thread.id))
    }

    /// Single keys while the list has focus, Gmail's and Superhuman's
    /// set, alongside Mail's Command shortcuts in the menus.
    private func handleKey(_ key: MessageListKey) -> Bool {
        if key.keyCode == MessageListKey.delete || key.keyCode == MessageListKey.forwardDelete {
            perform(.trash); return true
        }
        if key.keyCode == MessageListKey.returnKey { perform(.openInWindow); return true }
        guard key.modifiers.subtracting(.shift).isEmpty else { return false }
        switch key.characters {
        case "e", "y": perform(.archive)
        case "#": perform(.trash)
        case "r": perform(.reply)
        case "a": perform(.replyAll)
        case "f": perform(.forward)
        case "s": perform(.toggleFlag)
        case "u": perform(.toggleUnread)
        case "c": perform(.compose)
        case "j": perform(.next)
        case "k": perform(.previous)
        case "h": perform(.move(.handled))
        case "z": perform(.undo)
        case "b": perform(.askSnooze)
        default: return false
        }
        return true
    }

    private func contextMenu(_ thread: Correspondence) -> NSMenu? {
        let menu = NSMenu()
        func item(_ title: String, _ symbol: String, _ action: MacAction) {
            let entry = ClosureMenuItem(title: title) { perform(action) }
            entry.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            menu.addItem(entry)
        }
        item("Reply", "arrowshape.turn.up.left", .reply)
        item("Reply All", "arrowshape.turn.up.left.2", .replyAll)
        item("Forward", "arrowshape.turn.up.right", .forward)
        menu.addItem(.separator())
        item("Archive", "archivebox", .archive)
        item("Delete", "trash", .trash)
        menu.addItem(.separator())
        for attention in Attention.choices {
            item("Move to \(attention.title)", attention == .needsYou ? "exclamationmark.circle" : attention == .waiting ? "clock" : "checkmark.circle",
                 .move(attention))
        }
        menu.addItem(.separator())
        item(thread.isUnread ? "Mark as Read" : "Mark as Unread", "envelope.badge", .toggleUnread)
        item(thread.isFlagged ? "Unflag" : "Flag", "flag", .toggleFlag)
        if thread.isSnoozed(at: .now) {
            item("Unsnooze", "moon.zzz", .snooze(nil))
        } else {
            item("Snooze…", "moon.zzz", .askSnooze)
        }
        menu.addItem(.separator())
        item("Open in New Window", "macwindow", .openInWindow)
        return menu
    }

    private func submitSearch() {
        let query = model.search.trimmingCharacters(in: .whitespacesAndNewlines)
        services.ask.reset()
        guard !query.isEmpty else { return }
        // Older mail the Mac hasn't synced: ask each account's server too.
        Task {
            if await services.sync.search(query, accounts: accounts) { await store.refresh() }
        }
        // A question gets an answer from your own mail, above the results.
        if query.hasSuffix("?") || ["when", "what", "where", "who", "how", "did", "do", "is", "does"]
            .contains(query.lowercased().split(separator: " ").first.map(String.init) ?? "") {
            services.ask.ask(query)
        }
    }
}

/// An NSMenuItem that runs a closure.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func run() { handler() }
}
