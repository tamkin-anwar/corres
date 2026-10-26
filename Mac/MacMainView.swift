import SwiftUI

/// The main window: sidebar, message list, and the conversation, the
/// layout every Mac mail app people love shares. Needs You first.
struct MacMainView: View {
    let services: MacServices
    @Bindable var model: MacMailboxModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @State private var columns = NavigationSplitViewVisibility.all
    @State private var snoozing: [Correspondence] = []
    /// Help › Send Diagnostics: the file to share.
    @State private var diagnostics: URL?
    /// Add to Reminders: what happened.
    @State private var reminderOutcome: MailReminders.Outcome?
    @State private var showingPalette = false
    @State private var scheduledSelection: UUID?
    @State private var showingShortcuts = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("corres.mac.welcomed") private var welcomed = false
    @AppStorage(MailFilter.unreadOnlyKey) private var unreadOnly = false
    @AppStorage(CorresSettings.textScaleKey) private var textScale = 1.0
    /// Read while Unread Only was on: kept in the list until you change
    /// mailbox, so the message you're reading doesn't vanish, as in Mail.
    @State private var keptRead: Set<ThreadID> = []
    @State private var showingWelcome = false
    @FocusState private var searchFocused: Bool
    @Environment(\.undoManager) private var undoManager
    /// What Edit › Undo is registered against, for the pill's Undo.
    @State private var mailUndo = MailUndoTarget()
    /// A draft from Drafts that couldn't be fetched whole to continue.
    @State private var draftOpenFailed = false

    private var store: MailStore { services.store }
    private var actions: ThreadActionService { services.threadActions }
    private var accounts: [String] { services.auth.accounts.map(\.email) }

    var body: some View {
        window
            // Edit › Undo (⌘Z) takes back what the pill offers, while it does.
            .onChange(of: [services.outbox.pending?.id, actions.pendingRemoval?.id, actions.lastChange?.id], initial: true) {
                registerMailUndo()
            }
            .onAppear {
                MacWindows.openWindow = openWindow
                MacWindows.mainAppeared { perform($0) }
                reopenUnsentDrafts()
            }
            .onDisappear { MacWindows.mainDisappeared() }
    }

    /// Half the text's growth: at twice the size, columns half as wide again.
    private var columnGrowth: CGFloat { 1 + (MacTextSize.clamped(textScale) - 1) / 2 }

    @ViewBuilder
    private var window: some View {
        let shown = visible()
        NavigationSplitView(columnVisibility: $columns) {
            MacSidebar(services: services, model: model, onDrop: drop)
                .macTextSize()
                .navigationSplitViewColumnWidth(min: (190 * columnGrowth).rounded(), ideal: (220 * columnGrowth).rounded(),
                                                max: (300 * columnGrowth).rounded())
        } content: {
            // Wider as the text grows (View › Bigger), so a row still
            // shows who it's from and what it's about.
            listColumn(shown)
                .macTextSize()
                .navigationSplitViewColumnWidth(min: (320 * columnGrowth).rounded(), ideal: (400 * columnGrowth).rounded(),
                                                max: (560 * columnGrowth).rounded())
        } detail: {
            detail
                .macTextSize()
        }
        .searchable(text: $model.search, placement: .toolbar, prompt: "Search, or ask a question")
        .onSubmit(of: .search) { submitSearch() }
        .toolbar(id: "corres.main") { toolbar }
        .overlay(alignment: .bottom) { undoBar }
        .searchFocused($searchFocused)
        .sheet(isPresented: $showingPalette) { MacCommandPalette(commands: paletteCommands) }
        .sheet(isPresented: $showingShortcuts) { MacShortcutsSheet() }
        .sheet(isPresented: $showingWelcome) {
            MacWelcome { welcomed = true; showingWelcome = false }
                .interactiveDismissDisabled()
        }
        .task {
            // After accounts from your other devices have had a moment
            // to arrive, so someone who has them isn't welcomed as new.
            try? await Task.sleep(for: .seconds(2))
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-ShowWelcome") { showingWelcome = true; return }
            if ProcessInfo.processInfo.arguments.contains("-SampleMailOnly") { return }
            #endif
            if !welcomed, accounts.isEmpty { showingWelcome = true } else { welcomed = true }
        }
        .modifier(MacNotices(diagnostics: $diagnostics, reminderOutcome: $reminderOutcome))
        .sheet(isPresented: Binding(get: { !snoozing.isEmpty }, set: { if !$0 { snoozing = [] } })) {
            MacSnoozeSheet { date in
                let threads = snoozing
                snoozing = []
                perform(.snooze(date), on: threads)
            }
        }
        .focusedSceneValue(\.macActions, MacActions(perform: { perform($0) }, selectionCount: model.selection.count, isMain: true))
        .onChange(of: model.selection) { _, selection in if filtersUnread { keptRead.formUnion(selection) } }
        // The next few after the one you're on, and the top of a mailbox,
        // read ahead: arrowing down shows each at once.
        .task(id: [model.selection.first.map { "\($0.account)|\($0.providerID)" } ?? "", model.mailbox.title]) {
            try? await Task.sleep(for: .milliseconds(300))
            let threads = visibleRows().compactMap(\.thread).map(\.id)
            let after = threads.firstIndex { model.selection.contains($0) }.map { Array(threads.dropFirst($0 + 1).prefix(3)) } ?? []
            await store.prefetchStoredContent(after + threads.prefix(6))
        }
        .onChange(of: model.mailbox) { keptRead = [] }
        .onChange(of: unreadOnly) { keptRead = [] }
        // What follows a sync, the widgets, Spotlight and the Dock badge
        // are MacServices' own (`startObserving`), window or not.
        // A notification, a widget or a corres:// link asking for a place.
        #if DEBUG
        // App Store screenshots: -ShowMailbox needsYou|waiting|everything,
        // -SelectThread sample-N, -SearchFor "text".
        .task { await showForScreenshot() }
        #endif
        .onChange(of: services.router.pending, initial: true) { _, target in
            // With two windows open, the first to take a request acts on it.
            guard let target, services.router.pending == target else { return }
            services.router.pending = nil
            switch target {
            case .thread(let id):
                model.search = ""
                if services.store.thread(id)?.attention == .needsYou { model.mailbox = .needsYou }
                else if model.mailbox.remoteSource != nil || model.mailbox == .newSenders { model.mailbox = .filter(MailFilter.everything.rawValue) }
                model.selection = [id]
            case .destination(let destination):
                switch destination {
                case .waiting: model.mailbox = .waiting
                case .mail: model.mailbox = .primary
                default: model.mailbox = .needsYou
                }
            case .compose:
                perform(.compose)
            case .composeTo(let to, let cc, let bcc, let subject, let body):
                openWindow(value: ComposeRequest(kind: .new, to: to, cc: cc, bcc: bcc, subject: subject, body: body))
            case .draft(let draft):
                let handoff = UUID()
                MacComposeHandoff.drafts[handoff] = draft
                if draft.gmailDraftID == nil { MacComposeHandoff.fresh.insert(handoff) }
                openWindow(value: ComposeRequest(kind: draft.kind, handoff: handoff))
            case .search(let words):
                model.search = words
                submitSearch()
            }
        }
        // Typing pauses: ask each account's server too, for mail older
        // than what's on this Mac.
        .task(id: model.search) {
            let query = model.search.trimmingCharacters(in: .whitespacesAndNewlines)
            guard query.count >= 3 else { return }
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            if await services.sync.search(query, accounts: accounts) { await store.refresh() }
        }
        .task(id: model.mailbox) {
            guard let source = model.mailbox.remoteSource else { return }
            await services.remote.refresh(source, accounts: accounts, store: store)
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

    /// Unread Only, on every list, and not while
    /// searching: search looks through everything.
    private var filtersUnread: Bool {
        unreadOnly && model.search.isEmpty
    }

    /// The rows on screen and their counts, kept by the model until the
    /// mail, the mailbox or Unread Only changes, not worked out again on
    /// every change of selection.
    private func visible() -> MacMailboxModel.Visible {
        model.visible(store: store, accounts: accounts, remote: services.remote, serverMatches: serverMatches,
                      unreadOnly: filtersUnread, kept: keptRead)
    }

    private func visibleRows() -> [MacRow] { visible().rows }

    private func listColumn(_ shown: MacMailboxModel.Visible) -> some View {
        let rows = shown.rows
        return VStack(spacing: 0) {
            if services.ask.phase != .idle, !model.search.isEmpty {
                askCard
            }
            if model.mailbox == .scheduled, model.search.isEmpty {
                MacScheduledList(selection: $scheduledSelection)
            } else if model.mailbox == .purchases, model.search.isEmpty {
                PurchasesView(store: store, accounts: accounts) { model.selection = [$0] }
            } else if model.mailbox == .attachments, model.search.isEmpty {
                AttachmentsView(store: store, accounts: accounts) { model.selection = [$0] }
            } else if rows.isEmpty {
                emptyState.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                MessageList(list: .init(version: shown.version, items: rows), showsReasons: model.mailbox.showsReasons && model.search.isEmpty,
                            accountColors: accountColors, selection: $model.selection,
                            onOpen: { thread in open(thread) },
                            onKey: handleKey, menu: contextMenu,
                            onSwipe: { thread, action in perform(action, on: [thread]) },
                            onReachEnd: {
                                // Searching: the next page of each account's results.
                                if !model.search.isEmpty, !services.sync.moreResults.isEmpty {
                                    Task { if await services.sync.searchMore() { await store.refresh() } }
                                    return
                                }
                                guard let source = model.mailbox.remoteSource else { return }
                                Task { await services.remote.loadMore(source, accounts: accounts, store: store) }
                            },
                            people: services.people)
            }
        }
        .navigationTitle(model.search.isEmpty ? model.mailbox.title : String(localized: "Search"))
        .navigationSubtitle(subtitle(shown))
        .background(CorresPalette.canvas)
        .alert("Couldn't Open Draft", isPresented: $draftOpenFailed) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Check your connection and try again.")
        }
    }

    private var serverMatches: Set<ThreadID> {
        let query = model.search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, services.sync.moreResultsQuery == query else { return [] }
        return services.sync.serverMatches
    }

    private func subtitle(_ shown: MacMailboxModel.Visible) -> String {
        let count = shown.count, unread = shown.unread
        if !model.search.isEmpty && services.sync.isSearchingRemote { return String(localized: "Searching your accounts…") }
        if services.isGettingNewMail { return String(localized: "Checking for mail…") }
        if count == 0 { return "" }
        return unread > 0 ? String(localized: "\(count) conversations, \(unread) unread") : String(localized: "\(count) conversations")
    }

    private var accountColors: [String: NSColor] {
        Dictionary(uniqueKeysWithValues: accounts.compactMap { account in
            AccountPreferences.color(for: account, among: accounts).map { (account, NSColor($0)) }
        })
    }

    @ViewBuilder
    private var emptyState: some View {
        if let source = model.mailbox.remoteSource, model.search.isEmpty, !services.remote.hasLoaded(source) || services.remote.loading.contains(source) {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let source = model.mailbox.remoteSource, model.search.isEmpty, services.remote.failed(source) {
            ContentUnavailableView {
                EmptyTitle("Couldn't load \(model.mailbox.title)", systemImage: "wifi.exclamationmark")
            } description: {
                Text("Check your connection, then choose it again.")
            }
        } else if !model.search.isEmpty, services.ask.phase != .idle {
            // A question is answered above; no "No Results" under the answer.
            Color.clear
        } else if !model.search.isEmpty {
            ContentUnavailableView.search(text: model.search)
        } else if filtersUnread {
            ContentUnavailableView {
                EmptyTitle("No unread mail", systemImage: "line.3.horizontal.decrease.circle")
            } description: {
                Text("Nothing unread in \(model.mailbox.title).")
            } actions: {
                Button("Show All") { unreadOnly = false }
            }
        } else if model.mailbox == .needsYou {
            ContentUnavailableView {
                EmptyTitle("Nothing needs you", systemImage: "checkmark.circle")
            } description: {
                Text("Email that asks something of you lands here, with the reason why.")
            }
        } else {
            ContentUnavailableView {
                EmptyTitle(model.mailbox.title, systemImage: model.mailbox.systemImage)
            } description: {
                Text("No conversations here.")
            }
        }
    }

    private var askCard: some View {
        let ask = services.ask
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Label("Answer", systemImage: "sparkle").macFont(.caption, weight: .semibold).foregroundStyle(CorresPalette.accent)
                if ask.phase == .searching || ask.phase == .answering { ProgressView().controlSize(.mini) }
            }
            if let answer = ask.answer {
                // Scrolls within a set height: an answer that asked the
                // column for its full height pushed the whole window's
                // content up out of view.
                ScrollView {
                    Text(answer).macFont(.callout).foregroundStyle(CorresPalette.ink).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 220)
                .fixedSize(horizontal: false, vertical: true)
            } else if ask.phase == .done {
                Text("Couldn't find an answer in your mail.").macFont(.callout).foregroundStyle(CorresPalette.secondary)
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
        if model.mailbox == .scheduled, model.search.isEmpty {
            if let item = ScheduledSends.shared.items.first(where: { $0.id == scheduledSelection }) {
                MacScheduledDetail(item: item, services: services) { draft in
                    let handoff = UUID()
                    MacComposeHandoff.drafts[handoff] = draft
                    openWindow(value: ComposeRequest(kind: draft.kind, handoff: handoff))
                }
            } else {
                ContentUnavailableView {
                    EmptyTitle("Send Later", systemImage: "clock.arrow.circlepath")
                } description: {
                    Text("Choose a scheduled email to read it, send it now, or change its time.")
                }
            }
        } else {
            conversationDetail
        }
    }

    @ViewBuilder
    private var conversationDetail: some View {
        // Still open after it left the list (answered, moved by a sync).
        let selected = model.selectedThreads(in: store)
        if selected.count == 1, let thread = selected.first {
            // From the store, which adds the HTML once it's read.
            ReadingPane(thread: store.thread(thread.id) ?? thread, services: services) { kind in compose(kind, thread) }
        } else if selected.count > 1 {
            ContentUnavailableView {
                EmptyTitle("\(selected.count) conversations selected", systemImage: "square.stack")
            } description: {
                Text("Archive, delete, move or flag them together.")
            }
        } else {
            ContentUnavailableView {
                EmptyTitle("Corres", systemImage: "envelope.open")
            } description: {
                Text("Choose a conversation to read it.")
            }
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    /// Right-click the toolbar › Customize Toolbar… to add, remove or
    /// rearrange, as in Mail.
    private var toolbar: some CustomizableToolbarContent {
        Group {
            ToolbarItem(id: "compose", placement: .primaryAction) {
                Button { perform(.compose) } label: { Label("New Message", systemImage: "square.and.pencil") }
                    .help("New Message (⌘N)")
            }
            ToolbarItem(id: "getMail", placement: .primaryAction) {
                Button { perform(.getMail) } label: { Label("Get Mail", systemImage: "arrow.clockwise") }
                    .help("Get New Mail (⇧⌘N)")
            }
            ToolbarItem(id: "unreadOnly", placement: .primaryAction) {
                Toggle(isOn: $unreadOnly) {
                    Label("Unread Only", systemImage: unreadOnly ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                }
                .help("Show only unread mail in this list (⌘L)")
            }
            ToolbarItem(id: "archive", placement: .primaryAction) {
                Button { perform(.archive) } label: { Label("Archive", systemImage: "archivebox") }
                    .help("Archive (⌃⌘A, or E)").disabled(model.selection.isEmpty)
            }
            ToolbarItem(id: "delete", placement: .primaryAction) {
                Button { perform(.trash) } label: { Label("Delete", systemImage: "trash") }
                    .help("Delete (⌘⌫, or #)").disabled(model.selection.isEmpty)
            }
            ToolbarItem(id: "move", placement: .primaryAction) {
                Menu {
                    ForEach(Attention.choices, id: \.self) { attention in
                        Button(attention.title) { perform(.move(attention)) }
                    }
                } label: { Label("Move", systemImage: "arrow.right.circle") }
                    .help("Needs You, Waiting or Handled").disabled(model.selection.isEmpty)
            }
            ToolbarItem(id: "reply", placement: .primaryAction) {
                Button { perform(.reply) } label: { Label("Reply", systemImage: "arrowshape.turn.up.left") }
                    .help("Reply (⌘R, or R)").disabled(model.selection.count != 1)
            }
            ToolbarItem(id: "replyAll", placement: .primaryAction) {
                Button { perform(.replyAll) } label: { Label("Reply All", systemImage: "arrowshape.turn.up.left.2") }
                    .help("Reply All (⇧⌘R, or A)").disabled(model.selection.count != 1)
            }
            ToolbarItem(id: "forward", placement: .primaryAction) {
                Button { perform(.forward) } label: { Label("Forward", systemImage: "arrowshape.turn.up.right") }
                    .help("Forward (⇧⌘F, or F)").disabled(model.selection.count != 1)
            }
            ToolbarItem(id: "snooze", placement: .primaryAction) {
                Menu {
                    ForEach(SnoozeOption.allCases, id: \.self) { option in
                        Button(option.title) { perform(.snooze(option.date())) }
                    }
                    Divider()
                    Button("Choose a Time…") { perform(.askSnooze) }
                } label: { Label("Snooze", systemImage: "moon.zzz") }
                    .help("Snooze (B)").disabled(model.selection.isEmpty)
            }
            ToolbarItem(id: "flag", placement: .primaryAction) {
                Button { perform(.toggleFlag) } label: { Label("Flag", systemImage: "flag") }
                    .help("Flag (⇧⌘L, or S)").disabled(model.selection.isEmpty)
            }
            ToolbarItem(id: "unread", placement: .primaryAction, showsByDefault: false) {
                Button { perform(.toggleUnread) } label: { Label("Read/Unread", systemImage: "envelope.badge") }
                    .help("Mark as Read or Unread (⇧⌘U, or U)").disabled(model.selection.isEmpty)
            }
            ToolbarItem(id: "print", placement: .primaryAction, showsByDefault: false) {
                Button { perform(.print) } label: { Label("Print", systemImage: "printer") }
                    .help("Print (⌘P)").disabled(model.selection.count != 1)
            }
            ToolbarItem(id: "saveSearch", placement: .primaryAction) {
                // While searching: keep it as a mailbox in the sidebar.
                SaveSearchButton(query: model.search)
                    .help("Save Search")
            }
            ToolbarItem(id: "palette", placement: .primaryAction, showsByDefault: false) {
                Button { perform(.commandPalette) } label: { Label("Go To or Do", systemImage: "command") }
                    .help("Go To or Do (⌘K)")
            }
        }
    }

    // MARK: Undo

    @ViewBuilder
    private var undoBar: some View {
        // A send that didn't go comes first: until now the Mac never said.
        if let failed = services.outbox.failed {
            HStack(spacing: 12) {
                Label {
                    Text("Couldn't send \u{201C}\(failed.draft.subject)\u{201D}").lineLimit(1)
                } icon: {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(CorresPalette.alert)
                }
                if services.outbox.failedSends.count > 1 {
                    Text("and \(services.outbox.failedSends.count - 1) more").foregroundStyle(CorresPalette.secondary)
                }
                Button("Discard") { services.outbox.discardFailed() }.buttonStyle(.borderless)
                Button("Retry") { services.outbox.retryFailed() }.buttonStyle(.borderless)
                    .foregroundStyle(CorresPalette.accent)
            }
            .macFont(.callout)
            .padding(.horizontal, 16).padding(.vertical, 10)
            .corresGlass(in: Capsule())
            .padding(.bottom, 18)
            .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
        } else if let sending = services.outbox.pending {
            // Undo Send: it opens again in a compose window.
            undoPill(String(localized: "Sending \u{201C}\(sending.subjectPreview)\u{201D}"), systemImage: "paperplane") {
                MacWindows.undoSend(services.outbox)
            }
        } else if let pending = actions.pendingRemoval {
            undoPill(pending.title, systemImage: pending.kind.systemImage) { actions.undoRemoval() }
        } else if let change = actions.lastChange {
            undoPill(change.title, systemImage: change.systemImage) { actions.undoLastChange() }
        }
    }

    /// The pill's Undo, as Edit › Undo, named for what it takes back.
    private func registerMailUndo() {
        guard let undoManager else { return }
        undoManager.removeAllActions(withTarget: mailUndo)
        // An email waiting out Undo Send comes first.
        if services.outbox.pending != nil {
            MacUndoSend.register(services.outbox, in: undoManager, target: mailUndo)
            return
        }
        guard let title = actions.pendingRemoval?.title ?? actions.lastChange?.title else { return }
        let actions = actions
        undoManager.registerUndo(withTarget: mailUndo) { _ in
            MainActor.assumeIsolated {
                if actions.pendingRemoval != nil { actions.undoRemoval() } else { actions.undoLastChange() }
            }
        }
        undoManager.setActionName(title)
    }

    /// Emails you were writing when Corres last quit, open again.
    private func reopenUnsentDrafts() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-CorresScreenshots") { return }
        #endif
        for draft in MacComposeDrafts.shared.takeForRestore() {
            let handoff = UUID()
            MacComposeHandoff.drafts[handoff] = draft
            openWindow(value: ComposeRequest(kind: draft.kind, handoff: handoff))
        }
    }

    private func undoPill(_ title: String, systemImage: String, undo: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            Label(title, systemImage: systemImage)
            // ⌘Z is Edit › Undo, which takes this back too (`registerMailUndo`).
            Button("Undo", action: undo).buttonStyle(.borderless)
                .foregroundStyle(CorresPalette.accent)
        }
        .macFont(.callout)
        .padding(.horizontal, 16).padding(.vertical, 10)
        .corresGlass(in: Capsule())
        .padding(.bottom, 18)
        .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
    }

    // MARK: Actions

    #if DEBUG
    private func showForScreenshot() async {
        let args = ProcessInfo.processInfo.arguments
        func value(_ flag: String) -> String? { args.firstIndex(of: flag).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil } }
        guard args.contains("-SampleMailOnly") else { return }
        try? await Task.sleep(for: .seconds(1))
        switch value("-ShowMailbox") {
        case "waiting": model.mailbox = .waiting
        case "everything": model.mailbox = .filter(MailFilter.everything.rawValue)
        case "primary": model.mailbox = .primary
        case "purchases": model.mailbox = .purchases
        case "attachments": model.mailbox = .attachments
        default: model.mailbox = .needsYou
        }
        if let search = value("-SearchFor") {
            model.search = search
            submitSearch()
        }
        // A summary and replies on Maya's email, as Apple Intelligence shows them.
        if args.contains("-SampleReplies"), let maya = services.store.thread(ThreadID(account: "sample", providerID: "sample-0")) {
            services.intelligence.showForScreenshots(
                .init(summary: "Maya needs your approval on the final creative direction before tomorrow's review.",
                      replyIntents: ["Approve the direction", "Ask for one more round"]), on: maya)
        }
        if args.contains("-SettingsTab") { openSettings() }
        if args.contains("-ShowPalette") {
            try? await Task.sleep(for: .milliseconds(600))
            showingPalette = true
        }
        if let to = value("-ComposeTo") { openWindow(value: ComposeRequest(kind: .new, to: to)) }
        if let thread = value("-SelectThread") {
            try? await Task.sleep(for: .milliseconds(300))
            model.selection = [ThreadID(account: "sample", providerID: thread)]
        }
        // Measuring: -stressTrash N selects the top conversation and moves
        // it to Trash with ⌘⌫'s own path, every few seconds, N times.
        if let count = value("-stressTrash").flatMap(Int.init) {
            try? await Task.sleep(for: .seconds(Double(value("-stressTrashDelay").flatMap(Int.init) ?? 20)))
            for _ in 0..<count {
                guard let first = visibleRows().compactMap(\.thread).first else { break }
                model.selection = [first.id]
                try? await Task.sleep(for: .seconds(2))
                FileHandle.standardError.write(Data("stress trash at \(ProcessInfo.processInfo.systemUptime) rows \(visibleRows().count)\n".utf8))
                perform(.trash)
                try? await Task.sleep(for: .seconds(8))
            }
            HangReporter.note("stress trash done")
        }
    }
    #endif

    /// Conversations dragged onto a mailbox: moved there, as in Mail.
    private func drop(on mailbox: MacMailbox, _ ids: [ThreadID]) {
        // Each conversation once, however many times it came in the drag.
        var seen = Set<ThreadID>()
        let threads = ids.filter { seen.insert($0).inserted }.compactMap { store.thread($0) }
        guard !threads.isEmpty else { return }
        switch mailbox {
        case .needsYou: perform(.move(.needsYou), on: threads)
        case .waiting: perform(.move(.waiting), on: threads)
        case .handled: perform(.move(.handled), on: threads)
        case .flagged: Task { await actions.toggleFlagged(true, for: threads) }
        case .server(let raw) where raw == MacRemoteMailboxes.Kind.archive.rawValue: perform(.archive, on: threads)
        case .server(let raw) where raw == MacRemoteMailboxes.Kind.trash.rawValue: perform(.trash, on: threads)
        case .server(let raw) where raw == MacRemoteMailboxes.Kind.spam.rawValue:
            services.remote.remove(Set(threads.map(\.id)))
            Task { for thread in threads { await actions.reportSpam(thread) } }
        case .label(let account, let id, let name):
            // Labels and folders belong to one account.
            let mine = threads.filter { $0.id.account == account }
            if id.hasPrefix("cat:") {
                Task { for thread in mine { await actions.toggleLabel(id, isOn: true, for: thread) } }
            } else {
                services.remote.remove(Set(mine.map(\.id)))
                Task { for thread in mine { await actions.moveToLabel(id, named: name, thread) } }
            }
        default: break
        }
    }

    /// Runs an action on the selection, or on `threads` when given (a
    /// swiped row that isn't selected).
    func perform(_ action: MacAction, on threads: [Correspondence]? = nil) {
        let selected = threads ?? model.selectedThreads(in: store)
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
                let next = model.neighbor(after: ids, in: visibleRows())
                model.selection = next.map { [$0] } ?? []
            }
            services.remote.remove(ids)
            Task { action == .archive ? await actions.archive(selected) : await actions.trash(selected) }
        case .move(let attention):
            guard !selected.isEmpty else { return }
            // Moved out of the list it's in: on to the next, as archiving does.
            let ids = Set(selected.map(\.id))
            if model.mailbox.isAttentionList, !model.selection.isDisjoint(with: ids) {
                model.selection = model.neighbor(after: ids, in: visibleRows()).map { [$0] } ?? []
            }
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
                if !model.selection.isDisjoint(with: ids) { model.selection = model.neighbor(after: ids, in: visibleRows()).map { [$0] } ?? [] }
            }
            Task { for thread in selected { await store.snooze(thread.id, until: date) } }
        case .askSnooze:
            snoozing = selected
        case .sendDiagnostics:
            diagnostics = HangReporter.diagnosticsFile()
        case .remind(let due):
            guard let thread = selected.first else { return }
            Task { reminderOutcome = await MailReminders.add(thread, due: due) }
        case .getMail:
            services.getNewMail()
        case .show(let mailbox):
            model.mailbox = mailbox
        case .toggleUnreadOnly:
            unreadOnly.toggle()
        case .next, .previous:
            let threads = visibleRows().compactMap(\.thread)
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
            if services.outbox.pending != nil { MacWindows.undoSend(services.outbox) }
            else if actions.pendingRemoval != nil { actions.undoRemoval() } else { actions.undoLastChange() }
        case .commandPalette:
            showingPalette = true
        case .shortcuts:
            showingShortcuts = true
        case .search:
            searchFocused = true
        case .print:
            guard let thread = selected.first else { return }
            // The message as it is now, body loaded.
            MacPrinter.print(store.thread(thread.id) ?? thread, in: NSApp.keyWindow)
        }
    }

    /// What ⌘K offers: acting on the selection first, then every place.
    private var paletteCommands: [MacCommandPalette.Command] {
        typealias Command = MacCommandPalette.Command
        var commands: [Command] = [Command(title: "New Message", detail: "⌘N", systemImage: "square.and.pencil") { perform(.compose) }]
        let selected = model.selectedThreads(in: store)
        if !selected.isEmpty {
            let what = selected.count == 1 ? String(localized: "this conversation") : String(localized: "\(selected.count) conversations")
            commands += [
                Command(title: "Archive", detail: what, systemImage: "archivebox") { perform(.archive) },
                Command(title: "Delete", detail: what, systemImage: "trash") { perform(.trash) },
                Command(title: "Snooze…", detail: what, systemImage: "moon.zzz") { perform(.askSnooze) },
                Command(title: selected.allSatisfy(\.isFlagged) ? "Unflag" : "Flag", detail: what, systemImage: "flag") { perform(.toggleFlag) },
                Command(title: selected.allSatisfy(\.isUnread) ? "Mark as Read" : "Mark as Unread", detail: what, systemImage: "envelope.badge") { perform(.toggleUnread) },
            ]
            // Only the moves that change something.
            let moves: [(Attention, String.LocalizationValue, String)] = [(.needsYou, "Move to Needs You", "exclamationmark.circle"),
                                                        (.waiting, "Move to Waiting", "clock"),
                                                        (.handled, "Mark as Handled", "checkmark.circle")]
            for (attention, title, icon) in moves where !selected.allSatisfy({ $0.attention == attention }) {
                commands.append(Command(title: title, detail: what, systemImage: icon) { perform(.move(attention)) })
            }
            if selected.count == 1 {
                commands += [
                    Command(title: "Reply", detail: "⌘R", systemImage: "arrowshape.turn.up.left") { perform(.reply) },
                    Command(title: "Reply All", detail: "⇧⌘R", systemImage: "arrowshape.turn.up.left.2") { perform(.replyAll) },
                    Command(title: "Forward", detail: "⇧⌘F", systemImage: "arrowshape.turn.up.right") { perform(.forward) },
                    Command(title: "Open in New Window", detail: "⌘O", systemImage: "macwindow") { perform(.openInWindow) },
                    Command(title: "Print", detail: "⌘P", systemImage: "printer") { perform(.print) },
                ]
            }
            // Filing, as Gmail's "Move to" does.
            let account = selected[0].id.account
            if selected.allSatisfy({ $0.id.account == account }) {
                for label in services.labelDirectory.labels(for: account) where !label.isCategory {
                    commands.append(Command(title: "Move to \(label.name)", detail: AccountPreferences.nickname(for: account),
                                            systemImage: label.isFolder ? "folder" : "tag") {
                        drop(on: .label(account: account, id: label.id, name: label.name), selected.map(\.id))
                    })
                }
            }
        }
        var places: [MacMailbox] = [.needsYou, .waiting]
        places += [MailFilter.primary, .everything, .promotions, .social, .updates].map { MacMailbox.filter($0.rawValue) }
        places += [.flagged, .snoozed, .handled]
        if !ScheduledSends.shared.items.isEmpty { places.append(.scheduled) }
        places += MacRemoteMailboxes.Kind.allCases.map { MacMailbox.server($0.rawValue) }
        commands += places.map { place in
            Command(title: "Go to \(place.title)", detail: nil, systemImage: place.systemImage) { model.mailbox = place }
        }
        for account in accounts {
            for label in services.labelDirectory.labels(for: account) {
                let place = MacMailbox.label(account: account, id: label.id, name: label.name)
                commands.append(Command(title: "Go to \(label.name)", detail: accounts.count > 1 ? AccountPreferences.nickname(for: account) : nil,
                                        systemImage: place.systemImage) { model.mailbox = place })
            }
        }
        commands += [
            Command(title: "Get New Mail", detail: "⇧⌘N", systemImage: "arrow.clockwise") { perform(.getMail) },
            Command(title: "Keyboard Shortcuts", detail: "?", systemImage: "keyboard") { perform(.shortcuts) },
            Command(title: "Search", detail: "/", systemImage: "magnifyingglass") { perform(.search) },
        ]
        return commands
    }

    /// Double-click or Return: a draft continues in Compose, anything else
    /// opens in its own window.
    private func open(_ thread: Correspondence) {
        if model.mailbox.remoteKind == .drafts {
            Task { await continueDraft(thread) }
        } else {
            openWindow(value: thread.id)
        }
    }

    /// A draft continues whole, as on the iPhone: its full text, its Cc,
    /// and the conversation it answers, so it sends threaded. Outlook and
    /// IMAP list drafts with a preview only, and saving that would have
    /// replaced the draft with its first line.
    private func continueDraft(_ item: Correspondence) async {
        let account = item.id.account
        let client = MailClient()
        var message = item
        if MailAccounts.provider(for: account) != .google, let messageID = message.latestMessageID {
            guard let full = try? await client.fetchFull(ids: [messageID], account: account).items.first else {
                draftOpenFailed = true
                return
            }
            message = full
        }
        // Without its conversation, a reply draft would go out as a new,
        // unthreaded email: say so rather than open it wrong.
        guard let conversation = try? await client.fetchThreadMessages(threadId: message.id.providerID, account: account) else {
            draftOpenFailed = true
            return
        }
        let answered = conversation.last { !$0.labelIds.contains("DRAFT") }
        var draft = Draft(kind: answered == nil ? .new : .reply, threadID: answered?.id, fromAccount: account,
                          to: message.toRecipients.joined(separator: ", "),
                          cc: message.ccRecipients.isEmpty ? nil : message.ccRecipients.joined(separator: ", "),
                          subject: [String(localized: "(no subject)"), "(no subject)"].contains(message.subject) ? "" : message.subject, body: message.body)
        draft.gmailDraftID = services.remote.draftID(for: item.id)
        if let answered {
            draft.inReplyTo = answered.messageIdHeader
            // Kept to hand, so Compose finds the conversation it answers.
            if store.thread(answered.id) == nil { store.keepBrowsed([answered]) }
        }
        let handoff = UUID()
        MacComposeHandoff.drafts[handoff] = draft
        openWindow(value: ComposeRequest(kind: draft.kind, handoff: handoff))
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
        // Caps Lock, the keypad and the fn key aren't modifiers here, and
        // with Caps Lock on, E is still e.
        let modifiers = key.modifiers.subtracting([.capsLock, .numericPad, .function])
        let characters = key.modifiers.contains(.capsLock) ? key.characters.lowercased() : key.characters
        // Space pages through the open email, Shift-Space back, as in Mail.
        if key.keyCode == MessageListKey.space, modifiers.subtracting(.shift).isEmpty {
            return MacReadingScroll.page(down: !modifiers.contains(.shift), beside: NSApp.keyWindow?.firstResponder as? NSView)
        }
        guard modifiers.subtracting(.shift).isEmpty else { return false }
        switch characters {
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
        case "/": perform(.search)
        case "?": perform(.shortcuts)
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
        // A first email from someone: let them in, or not, for every
        // selected sender at once.
        if thread.senderDecision == .pending {
            let chosen = model.selection.contains(thread.id)
                ? model.selection.compactMap { services.store.thread($0) } : [thread]
            var seen = Set<String>()
            let senders = chosen.filter { $0.senderDecision == .pending }.compactMap { pending -> (email: String, account: String)? in
                guard let email = pending.senderEmail, seen.insert("\(pending.id.account)|\(email)").inserted else { return nil }
                return (email, pending.id.account)
            }
            for (decision, title, symbol) in [(SenderDecision.approved, senders.count > 1 ? String(localized: "Allow \(senders.count) Senders") : String(localized: "Allow Sender"), "checkmark.circle"),
                                              (SenderDecision.blocked, senders.count > 1 ? String(localized: "Block \(senders.count) Senders") : String(localized: "Block Sender"), "hand.raised")] {
                let entry = ClosureMenuItem(title: title) {
                    Task { await services.store.setSenderDecision(decision, senders: senders) }
                }
                entry.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
                menu.addItem(entry)
            }
            menu.addItem(.separator())
        }
        item(String(localized: "Reply"), "arrowshape.turn.up.left", .reply)
        item(String(localized: "Reply All"), "arrowshape.turn.up.left.2", .replyAll)
        item(String(localized: "Forward"), "arrowshape.turn.up.right", .forward)
        menu.addItem(.separator())
        item(String(localized: "Archive"), "archivebox", .archive)
        item(String(localized: "Delete"), "trash", .trash)
        menu.addItem(.separator())
        for attention in Attention.choices {
            item(String(localized: "Move to \(attention.title)"),
                 attention == .needsYou ? "exclamationmark.circle" : attention == .waiting ? "clock" : "checkmark.circle",
                 .move(attention))
        }
        menu.addItem(.separator())
        item(thread.isUnread ? String(localized: "Mark as Read") : String(localized: "Mark as Unread"), "envelope.badge", .toggleUnread)
        item(thread.isFlagged ? String(localized: "Unflag") : String(localized: "Flag"), "flag", .toggleFlag)
        if thread.isSnoozed(at: .now) {
            item(String(localized: "Unsnooze"), "moon.zzz", .snooze(nil))
        } else {
            item(String(localized: "Snooze…"), "moon.zzz", .askSnooze)
        }
        // Mute: out of your lists, and new replies stay quiet.
        let isMuted = Organizer.shared.isMuted(thread.id)
        let mute = ClosureMenuItem(title: isMuted ? String(localized: "Unmute") : String(localized: "Mute")) {
            if isMuted { Organizer.shared.unmute(thread.id) } else { Organizer.shared.mute(thread) }
        }
        mute.image = NSImage(systemSymbolName: isMuted ? "bell" : "bell.slash", accessibilityDescription: nil)
        menu.addItem(mute)
        // A VIP's mail always lands in Needs You and always notifies.
        if let email = thread.senderEmail, !thread.isFromAccountOwner {
            let isVIP = InboxClassifier.isVIP(email)
            let vip = ClosureMenuItem(title: isVIP ? String(localized: "Remove from VIPs") : String(localized: "Make VIP")) {
                Task { await services.store.setVIP(email, account: thread.id.account, isVIP: !isVIP) }
            }
            vip.image = NSImage(systemSymbolName: isVIP ? "star.slash" : "star", accessibilityDescription: nil)
            menu.addItem(vip)
        }
        // When to be reminded, as Mail's Remind Me offers.
        let remind = NSMenuItem(title: String(localized: "Add to Reminders"), action: nil, keyEquivalent: "")
        remind.image = NSImage(systemSymbolName: "checklist", accessibilityDescription: nil)
        let times = NSMenu()
        for choice in MailReminders.choices(for: thread) {
            times.addItem(ClosureMenuItem(title: choice.title) { perform(.remind(choice.date), on: [thread]) })
        }
        remind.submenu = times
        menu.addItem(remind)
        menu.addItem(.separator())
        item(String(localized: "Open in New Window"), "macwindow", .openInWindow)
        return menu
    }

    private func submitSearch() {
        let query = model.search.trimmingCharacters(in: .whitespacesAndNewlines)
        services.ask.reset()
        guard !query.isEmpty else { return }
        // A question gets an answer from your own mail, above the results.
        if query.hasSuffix("?") || ["when", "what", "where", "who", "how", "did", "do", "is", "does"]
            .contains(query.lowercased().split(separator: " ").first.map(String.init) ?? "") {
            services.ask.ask(query)
        }
    }
}

/// What the mail's Undo is registered against in the window's undo manager.
final class MailUndoTarget {}

/// Undo Send, in any window: the pill while an email waits to go, and
/// Edit › Undo (⌘Z) taking it back.
@MainActor
enum MacUndoSend {
    static func register(_ outbox: OutboxService, in undoManager: UndoManager, target: MailUndoTarget) {
        undoManager.registerUndo(withTarget: target) { _ in
            MainActor.assumeIsolated { MacWindows.undoSend(outbox) }
        }
        undoManager.setActionName(String(localized: "Send"))
    }

    /// For a window with no pill of its own (a conversation in its own
    /// window): what's sending, with Undo.
    struct Pill: View {
        let outbox: OutboxService
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            if let sending = outbox.pending {
                HStack(spacing: 12) {
                    Label(String(localized: "Sending \u{201C}\(sending.subjectPreview)\u{201D}"), systemImage: "paperplane")
                        .lineLimit(1)
                    Button("Undo") { MacWindows.undoSend(outbox) }.buttonStyle(.borderless)
                        .foregroundStyle(CorresPalette.accent)
                }
                .macFont(.callout)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .corresGlass(in: Capsule())
                .padding(.bottom, 18)
                .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
            }
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

/// The diagnostics file, as a sheet item.
private struct DiagnosticsFile: Identifiable {
    let url: URL
    var id: URL { url }
}

/// Send Diagnostics, and what happened with Add to Reminders: kept apart
/// from the main view so its long chain of modifiers stays quick to build.
private struct MacNotices: ViewModifier {
    @Binding var diagnostics: URL?
    @Binding var reminderOutcome: MailReminders.Outcome?

    func body(content: Content) -> some View {
        content
            .sheet(item: Binding(get: { diagnostics.map(DiagnosticsFile.init) }, set: { if $0 == nil { diagnostics = nil } })) { file in
                diagnosticsSheet(file.url)
            }
            .alert(reminderOutcome == .added ? "Added to Reminders" : "Couldn't Add to Reminders",
                   isPresented: Binding(get: { reminderOutcome != nil }, set: { if !$0 { reminderOutcome = nil } })) {
                Button("OK", role: .cancel) { reminderOutcome = nil }
            } message: {
                reminderMessage
            }
    }

    private func diagnosticsSheet(_ url: URL) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Send Diagnostics").macFont(.headline)
            Text("If Corres froze, closed or acted up, this file says where: the build, the macOS version, timings and any crash report. Never your mail.")
                .foregroundStyle(CorresPalette.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                Spacer()
                Button("Done") { diagnostics = nil }.keyboardShortcut(.cancelAction)
                ShareLink(item: url) { Text("Share…") }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    @ViewBuilder private var reminderMessage: some View {
        switch reminderOutcome {
        case .notAllowed: Text("Corres doesn't have access to Reminders. You can allow it in System Settings > Privacy & Security > Reminders.")
        case .failed: Text("Reminders didn't save it. Try again.")
        default: Text("Click the link in the reminder to come back to this email.")
        }
    }
}
