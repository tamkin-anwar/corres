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
    /// Retry on a send the mail server may have taken: asked first.
    @State private var confirmingResend = false

    private var store: MailStore { services.store }
    private var actions: ThreadActionService { services.threadActions }
    private var accounts: [String] { services.auth.accounts.map(\.email) }
    /// For the Message menu's Pin or Unpin.
    private var selectionIsPinned: Bool {
        let selected = model.selectedThreads(in: store)
        return !selected.isEmpty && selected.allSatisfy(\.isPinned)
    }

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
        .focusedSceneValue(\.macActions, MacActions(perform: { perform($0) }, selectionCount: model.selection.count,
                                                     isPinned: selectionIsPinned, isMain: true))
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
        // Without Pro, Corres opens on Primary: Needs You and Waiting stay
        // one click away to look at, never a lock in your face each time.
        .onChange(of: services.requiresPro, initial: true) { _, locked in
            if locked, model.mailbox.isAttentionList { model.mailbox = .primary }
        }
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
                let locked = services.requiresPro
                if !locked, services.store.thread(id)?.attention == .needsYou { model.mailbox = .needsYou }
                // Send Later shows a scheduled email where a conversation would
                // be; a locked list, no conversations at all.
                else if model.mailbox.remoteSource != nil || [.newSenders, .scheduled].contains(model.mailbox)
                            || locked && model.mailbox.isAttentionList {
                    model.mailbox = .filter(MailFilter.everything.rawValue)
                }
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
        .alert("Couldn't Finish That", isPresented: Binding(get: { actions.errorMessage != nil },
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
            } else if services.requiresPro, Self.isQuestion(model.search) {
                lockedAskCard
            }
            if services.requiresPro, model.mailbox.isAttentionList, model.search.isEmpty {
                // Needs You and Waiting without Pro: what they do, and one
                // way in. Mail itself always stays usable.
                ProLockView(destination: model.mailbox == .waiting ? .waiting : .needsYou,
                            onUnlock: { MacPro.open(openWindow) },
                            onOpenMail: { model.mailbox = .primary },
                            openMailTitle: String(localized: "Show Primary"))
            } else if model.mailbox == .scheduled, model.search.isEmpty {
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

    /// A question typed in Search without Pro: the answer is part of
    /// Corres Pro, said plainly, with the way to start the trial.
    private var lockedAskCard: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock").foregroundStyle(CorresPalette.accent)
            Text("Answer from your mail").macFont(.callout, weight: .medium).foregroundStyle(CorresPalette.ink)
            Spacer(minLength: 8)
            Button(MacPro.unlockTitle(services.entitlements)) { MacPro.open(openWindow) }
                .buttonStyle(.borderless)
                .foregroundStyle(CorresPalette.accent)
        }
        .padding(12)
        .background(CorresPalette.surface, in: RoundedRectangle(cornerRadius: 10))
        .padding(10)
        .accessibilityElement(children: .combine)
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
            if model.mailbox.remoteKind == .drafts, model.search.isEmpty {
                // A draft has its conversation's id, so the store would
                // show the conversation it answers in its place.
                draftDetail(thread)
            } else {
                // From the store, which adds the HTML once it's read.
                ReadingPane(thread: store.thread(thread.id) ?? thread, services: services) { kind in compose(kind, thread) }
            }
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

    /// A draft from Drafts, as written: Edit (or a double-click) continues
    /// it in Compose.
    private func draftDetail(_ draft: Correspondence) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(draft.subject.isEmpty ? String(localized: "No subject") : draft.subject)
                    .macFont(size: 24, weight: .regular, design: .serif)
                    .textSelection(.enabled)
                if !draft.toRecipients.isEmpty {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("To").foregroundStyle(CorresPalette.secondary)
                        Text(draft.toRecipients.joined(separator: ", ")).textSelection(.enabled)
                    }
                    .macFont(.subheadline)
                }
                HStack(spacing: 8) {
                    Button("Edit") { open(draft) }
                    Spacer()
                    Button("Delete", role: .destructive) { discardDrafts([draft]) }
                }
                Divider()
                Text(draft.body)
                    .macFont(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(28)
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(CorresPalette.canvas)
        .id(draft.id)
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
                    .help("Archive (⌃⌘A, or E)")
                    // A draft is deleted, not archived.
                    .disabled(model.selection.isEmpty || model.mailbox.remoteKind == .drafts && model.search.isEmpty)
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
                Button("Retry") {
                    if services.outbox.failedMayHaveSent { confirmingResend = true } else { services.outbox.retryFailed() }
                }
                .buttonStyle(.borderless)
                .foregroundStyle(CorresPalette.accent)
                // The mail server took it all and never answered: Retry
                // could send it twice, so it says so first.
                .alert("This email may already have been sent. Check Sent before sending it again.", isPresented: $confirmingResend) {
                    Button("Send Again") { services.outbox.retryFailed() }
                    Button("Cancel", role: .cancel) {}
                }
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
            // In Drafts a row is a draft, but its id is its conversation's:
            // archiving or deleting that took the whole conversation, the
            // emails you were answering too. Delete discards the draft.
            if model.mailbox.remoteKind == .drafts, model.search.isEmpty {
                if action == .trash { discardDrafts(selected) }
                return
            }
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
        case .togglePin:
            guard !selected.isEmpty else { return }
            let pin = !selected.allSatisfy(\.isPinned)
            Task { await actions.setPinned(pin, for: selected) }
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
                Command(title: selected.allSatisfy(\.isPinned) ? "Unpin" : "Pin", detail: what, systemImage: "pin") { perform(.togglePin) },
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

    /// Delete in Drafts: the drafts themselves go from the server, not the
    /// conversations they answer.
    private func discardDrafts(_ selected: [Correspondence]) {
        let found = selected.compactMap { thread in services.remote.draftID(for: thread.id).map { (account: thread.id.account, id: $0) } }
        guard !found.isEmpty else { return }
        let ids = Set(selected.map(\.id))
        if !model.selection.isDisjoint(with: ids) {
            model.selection = model.neighbor(after: ids, in: visibleRows()).map { [$0] } ?? []
        }
        services.remote.remove(ids)
        Task {
            let client = MailClient()
            for draft in found { try? await client.deleteDraft(id: draft.id, account: draft.account) }
        }
    }

    /// Double-click or Return: a draft continues in Compose, anything else
    /// opens in its own window.
    private func open(_ thread: Correspondence) {
        // Searching from Drafts lists conversations, not drafts: one opened
        // as a draft became a reply to yourself with their words in it.
        if model.mailbox.remoteKind == .drafts, model.search.isEmpty {
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
        // Already open in a window: that one comes forward. Two windows on
        // one draft each saved over the other's words.
        let serverID = services.remote.draftID(for: item.id)
        if let open = MacComposeHandoff.window(for: serverID) { openWindow(value: open); return }
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
        draft.gmailDraftID = serverID
        // Opened meanwhile (a second double-click while this one fetched).
        if let open = MacComposeHandoff.window(for: serverID) { openWindow(value: open); return }
        if let answered {
            draft.inReplyTo = answered.messageIdHeader
            // Kept to hand, so Compose finds the conversation it answers.
            if store.thread(answered.id) == nil { store.keepBrowsed([answered]) }
        }
        let handoff = UUID()
        MacComposeHandoff.drafts[handoff] = draft
        let request = ComposeRequest(kind: draft.kind, handoff: handoff)
        if let serverID {
            MacComposeHandoff.live.insert(request.id)
            MacComposeHandoff.noteOpen(request, serverID: serverID)
        }
        openWindow(value: request)
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
        // The press-and-hold menu chosen on the iPhone or iPad (Settings →
        // Customize → Press and Hold), which follows you here: the top
        // row's actions first, then the list, in the same order.
        let layout = CorresSettings.rowMenu
        let top = layout.top.filter { appliesOnMac($0, to: thread) }
        let list = layout.list.filter { appliesOnMac($0, to: thread) && !$0.isDestructive }
        let destructive = layout.list.filter { appliesOnMac($0, to: thread) && $0.isDestructive }
        for group in [top, list, destructive] where !group.isEmpty {
            for action in group { addRowMenuItem(action, for: thread, to: menu) }
            menu.addItem(.separator())
        }
        item(String(localized: "Open in New Window"), "macwindow", .openInWindow)
        return menu
    }

    /// Unsubscribe and Share need a confirmation or a sheet of their own,
    /// which this menu doesn't have on the Mac, so they're left out here.
    private func appliesOnMac(_ action: RowMenuAction, to thread: Correspondence) -> Bool {
        switch action {
        case .unsubscribe, .share: false
        case .vip: thread.senderEmail != nil && !thread.isFromAccountOwner
        // A first email from someone already offers Block Sender above.
        case .block: thread.senderEmail != nil && !thread.isFromAccountOwner && thread.senderDecision != .pending
        case .spam: !thread.isFromAccountOwner
        default: true
        }
    }

    private func addRowMenuItem(_ action: RowMenuAction, for thread: Correspondence, to menu: NSMenu) {
        func entry(_ title: String, _ symbol: String, run: @escaping () -> Void) {
            let item = ClosureMenuItem(title: title, handler: run)
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            menu.addItem(item)
        }
        switch action {
        case .reply: entry(String(localized: "Reply"), action.systemImage) { perform(.reply) }
        case .replyAll: entry(String(localized: "Reply All"), action.systemImage) { perform(.replyAll) }
        case .forward: entry(String(localized: "Forward"), action.systemImage) { perform(.forward) }
        case .archive: entry(String(localized: "Archive"), action.systemImage) { perform(.archive) }
        case .trash: entry(String(localized: "Delete"), action.systemImage) { perform(.trash) }
        case .read:
            entry(thread.isUnread ? String(localized: "Mark as Read") : String(localized: "Mark as Unread"),
                  thread.isUnread ? "envelope.open" : "envelope.badge") { perform(.toggleUnread) }
        case .flag: entry(thread.isFlagged ? String(localized: "Unflag") : String(localized: "Flag"), "flag") { perform(.toggleFlag) }
        case .pin: entry(thread.isPinned ? String(localized: "Unpin") : String(localized: "Pin"), thread.isPinned ? "pin.slash" : "pin") { perform(.togglePin) }
        case .snooze:
            if thread.isSnoozed(at: .now) {
                entry(String(localized: "Unsnooze"), "moon.zzz") { perform(.snooze(nil)) }
            } else {
                entry(String(localized: "Snooze…"), "moon.zzz") { perform(.askSnooze) }
            }
        case .moveTo:
            // One level: Corres's own lists, then the account's labels or folders.
            let move = NSMenuItem(title: String(localized: "Move To"), action: nil, keyEquivalent: "")
            move.image = NSImage(systemSymbolName: action.systemImage, accessibilityDescription: nil)
            let places = NSMenu()
            for attention in Attention.choices {
                let item = ClosureMenuItem(title: attention.title) { perform(.move(attention)) }
                if thread.attention == attention { item.state = .on }
                places.addItem(item)
            }
            let account = thread.id.account
            let labels = services.labelDirectory.labels(for: account).filter { !$0.isCategory }
            if !labels.isEmpty { places.addItem(.separator()) }
            for label in labels {
                let item = ClosureMenuItem(title: label.name) {
                    drop(on: .label(account: account, id: label.id, name: label.name), [thread.id])
                }
                item.image = NSImage(systemSymbolName: label.isFolder ? "folder" : "tag", accessibilityDescription: nil)
                places.addItem(item)
            }
            move.submenu = places
            menu.addItem(move)
        case .mute:
            // Out of your lists, and new replies stay quiet.
            let isMuted = Organizer.shared.isMuted(thread.id)
            entry(isMuted ? String(localized: "Unmute") : String(localized: "Mute"), isMuted ? "bell" : "bell.slash") {
                if isMuted { Organizer.shared.unmute(thread.id) } else { Organizer.shared.mute(thread) }
            }
        case .vip:
            // A VIP's mail always lands in Needs You and always notifies.
            guard let email = thread.senderEmail else { return }
            let isVIP = InboxClassifier.isVIP(email)
            entry(isVIP ? String(localized: "Remove from VIPs") : String(localized: "Add to VIPs"), isVIP ? "star.slash" : "star") {
                Task { await services.store.setVIP(email, account: thread.id.account, isVIP: !isVIP) }
            }
        case .reminder:
            // When to be reminded, as Mail's Remind Me offers.
            let remind = NSMenuItem(title: String(localized: "Add to Reminders"), action: nil, keyEquivalent: "")
            remind.image = NSImage(systemSymbolName: action.systemImage, accessibilityDescription: nil)
            let times = NSMenu()
            for choice in MailReminders.choices(for: thread) {
                times.addItem(ClosureMenuItem(title: choice.title) { perform(.remind(choice.date), on: [thread]) })
            }
            remind.submenu = times
            menu.addItem(remind)
        case .spam:
            entry(String(localized: "Report Spam"), action.systemImage) {
                drop(on: .server(MacRemoteMailboxes.Kind.spam.rawValue), [thread.id])
            }
        case .block:
            guard let email = thread.senderEmail else { return }
            entry(String(localized: "Block Sender"), action.systemImage) {
                let alert = NSAlert()
                alert.messageText = String(localized: "Block \(thread.sender)?")
                alert.informativeText = String(localized: "Their mail is hidden in Corres from now on, with no notice to them. Your email account isn't changed.")
                alert.addButton(withTitle: String(localized: "Block"))
                alert.addButton(withTitle: String(localized: "Cancel"))
                guard alert.runModal() == .alertFirstButtonReturn else { return }
                Task { await services.store.blockSender(email, account: thread.id.account) }
            }
        case .unsubscribe, .share: break
        }
    }

    private func submitSearch() {
        let query = model.search.trimmingCharacters(in: .whitespacesAndNewlines)
        services.ask.reset()
        guard !query.isEmpty else { return }
        // A question gets an answer from your own mail, above the results.
        // Without Pro, the locked card above the results offers the trial.
        if Self.isQuestion(query), !services.requiresPro {
            services.ask.ask(query)
        }
    }

    /// "When is my flight?": a question to answer, not words to find.
    static func isQuestion(_ text: String) -> Bool {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return false }
        return query.hasSuffix("?") || ["when", "what", "where", "who", "how", "did", "do", "is", "does"]
            .contains(query.lowercased().split(separator: " ").first.map(String.init) ?? "")
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
            Text("If Corres froze or quit unexpectedly, this file shows where it stopped: the build, the macOS version, timings and any crash report. Never your mail.")
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
