import Foundation
import Observation

@MainActor @Observable
final class MailStore {
    enum LoadState: Equatable { case idle, loading, loaded, failed }
    /// Everything in the store, including threads hidden while an Archive
    /// or Trash is waiting out its Undo window.
    private var allThreads: [Correspondence] = [] {
        didSet {
            listedThreads = allThreads.filter { !$0.isArchivedCopy }
            positions = Dictionary(allThreads.indices.map { (allThreads[$0].id, $0) }, uniquingKeysWith: { first, _ in first })
            if !holdingRevision { revision &+= 1; contentRevision &+= 1 }
        }
    }
    /// What the lists show: the Inbox and conversations you started.
    /// Archived mail kept for search (`Correspondence.isArchivedCopy`) is
    /// left out of every list, count, badge and notification.
    private(set) var listedThreads: [Correspondence] = []
    /// Removed from view the instant Archive/Trash is tapped, before Gmail
    /// is told, so Undo can bring them straight back.
    private(set) var hiddenIDs: Set<ThreadID> = [] { didSet { if !holdingRevision { revision &+= 1 } } }
    @ObservationIgnored private var holdingRevision = false
    /// Where each conversation is in `allThreads`: `thread(_:)` is asked
    /// many times a redraw, and searched 5,000 conversations each time.
    @ObservationIgnored private var positions: [ThreadID: Int] = [:]

    /// The HTML of conversations opened lately. The lists hold every
    /// conversation without it (see `SwiftDataMailRepository.threads`);
    /// it's read from storage, about a millisecond, when one is opened.
    private(set) var contents: [ThreadID: String] = [:]
    /// Conversations already looked up, HTML or not, oldest first.
    @ObservationIgnored private var contentOrder: [ThreadID] = []
    private static let contentsKept = 40

    /// Whether a conversation's HTML is still to be read from storage:
    /// the reader waits for it rather than drawing the plain text first.
    func needsStoredContent(_ id: ThreadID) -> Bool {
        guard let thread = thread(id), thread.isBodyLoaded, thread.htmlBody == nil else { return false }
        return !contentOrder.contains(id)
    }

    /// Reads HTML apart from the repository, so an open never waits on a
    /// sync (`MessageContentReader`). Set by the app.
    @ObservationIgnored var contentReader: MessageContentReader?

    /// Reads an opened conversation's HTML from storage.
    func loadStoredContent(_ id: ThreadID) async {
        guard needsStoredContent(id) else { return }
        let html: String? = if let contentReader { await contentReader.html(for: id) }
            else { try? await repository.thread(id)?.htmlBody }
        remember(html, for: id)
    }

    /// The conversations at the top of a list, read ahead so opening one
    /// shows it at once.
    func prefetchStoredContent(_ ids: [ThreadID]) async {
        for id in ids where needsStoredContent(id) {
            await loadStoredContent(id)
        }
    }

    /// The whole conversation as stored, for work that reads the message
    /// itself (a summary) without opening it. Not kept.
    func storedThread(_ thread: Correspondence) async -> Correspondence {
        guard thread.isBodyLoaded, thread.htmlBody == nil else { return thread }
        if let html = contents[thread.id] { var full = thread; full.htmlBody = html; return full }
        return (try? await repository.thread(thread.id)) ?? thread
    }

    private func remember(_ html: String?, for id: ThreadID) {
        contentOrder.removeAll { $0 == id }
        contentOrder.append(id)
        contents[id] = html
        if contentOrder.count > Self.contentsKept {
            let old = contentOrder.removeFirst()
            contents[old] = nil
        }
    }

    /// Several changes the lists see as one, so they rebuild once.
    private func asOneChange(_ changes: () -> Void) {
        let isOutermost = !holdingRevision
        holdingRevision = true
        changes()
        guard isOutermost else { return }
        holdingRevision = false
        revision &+= 1
        contentRevision &+= 1
    }

    /// The same for a run of saved changes (Select All, then Mark as Read):
    /// the lists are worked out again once at the end, not after each of
    /// hundreds.
    func asOneChange(_ changes: () async -> Void) async {
        let isOutermost = !holdingRevision
        holdingRevision = true
        await changes()
        guard isOutermost else { return }
        holdingRevision = false
        revision &+= 1
        contentRevision &+= 1
    }
    /// Bumped when the mail itself changes, not when a row is only hidden
    /// for Undo: a swipe then filters the rows a list already has instead
    /// of sorting the whole mailbox again inside the row's animation.
    private(set) var contentRevision = 0
    /// Every conversation, hidden ones and archived copies included (see
    /// `contentRevision`).
    var threadsIncludingHidden: [Correspondence] { allThreads }
    /// The lists' conversations, hidden ones included.
    var listedIncludingHidden: [Correspondence] { listedThreads }
    /// Everything Search can find: the lists plus archived mail.
    var searchableThreads: [Correspondence] {
        hiddenIDs.isEmpty ? allThreads : allThreads.filter { !hiddenIDs.contains($0.id) }
    }
    /// Bumped whenever `threads` could read differently, so a list can keep
    /// its filtered, sorted rows until something actually changed instead
    /// of rebuilding them on every redraw (see `CorrespondenceList`).
    private(set) var revision = 0
    var threads: [Correspondence] {
        hiddenIDs.isEmpty ? listedThreads : listedThreads.filter { !hiddenIDs.contains($0.id) }
    }

    /// Mail opened from a mailbox (Trash, Spam, a label, All Mail) that
    /// isn't in the Inbox: in memory only, so it can be read and acted on
    /// without showing up in Mail, Needs You or the Brief.
    private(set) var browsed: [ThreadID: Correspondence] = [:]

    /// A conversation by id, wherever it came from: the Inbox, or a mailbox.
    /// With its HTML, once read (`loadStoredContent`).
    func thread(_ id: ThreadID) -> Correspondence? {
        guard !hiddenIDs.contains(id) else { return nil }
        if let index = positions[id], allThreads.indices.contains(index), allThreads[index].id == id {
            var found = allThreads[index]
            if found.htmlBody == nil, let html = contents[id] { found.htmlBody = html }
            return found
        }
        return browsed[id]
    }

    /// The counts the sidebars, Dock, menu bar and account switcher show,
    /// worked out once per change to the mail (and each minute, as snoozes
    /// wake) and shared. Each used to sort or filter the whole mailbox on
    /// every redraw; the Mac, with five of them, froze for seconds at
    /// launch while sync changed the mail again and again.
    struct Overview {
        var needsYou: [Correspondence] = []
        var waitingCount = 0
        var unreadCount = 0
        var primaryUnread = 0
    }

    /// `account` nil is All Inboxes (`AccountPreferences.scope`).
    func overview(account: String? = nil, all accounts: [String] = []) -> Overview {
        let minute = Int(Date.now.timeIntervalSince1970 / 60)
        let key = "\(account ?? "*")|\(accounts.joined(separator: ","))|\(UserDefaults.standard.integer(forKey: AccountPreferences.revisionKey))"
        if let cached = overviews[key], cached.revision == revision, cached.minute == minute { return cached.value }
        let scoped = AccountPreferences.scope(threads, account: account, all: accounts, by: \.id.account)
        let inbox = MailQuery.filter(scoped)
        let context = CategoryContextCache.context(self)
        let value = Overview(
            needsYou: MailQuery.prioritized(scoped, attention: .needsYou),
            waitingCount: MailQuery.filter(scoped, attention: .waiting).count,
            unreadCount: inbox.reduce(0) { $0 + ($1.isUnread ? 1 : 0) },
            primaryUnread: inbox.reduce(0) { $0 + ($1.isUnread && MailFilter.primary.includes($1, context: context) ? 1 : 0) })
        if overviews.count > 12 { overviews.removeAll() }
        overviews[key] = (revision, minute, value)
        return value
    }
    @ObservationIgnored private var overviews: [String: (revision: Int, minute: Int, value: Overview)] = [:]

    /// Address → the name its owner writes under, worked out once per
    /// change to the mail: rows ask it for every sent email on screen.
    var knownSenderNames: [String: String] {
        if knownNamesRevision != revision {
            knownNamesCache = Correspondence.knownSenderNames(allThreads)
            knownNamesRevision = revision
        }
        return knownNamesCache
    }
    @ObservationIgnored private var knownNamesCache: [String: String] = [:]
    @ObservationIgnored private var knownNamesRevision = -1

    /// Keeps a mailbox's rows openable. Mail already in the Inbox stays as
    /// the Inbox has it.
    func keepBrowsed(_ items: [Correspondence]) {
        let synced = Set(allThreads.map(\.id))
        for item in items where !synced.contains(item.id) {
            // Content already loaded for it isn't thrown away by a refresh.
            if let existing = browsed[item.id], existing.isBodyLoaded, !item.isBodyLoaded,
               existing.latestMessageID == item.latestMessageID { continue }
            browsed[item.id] = item
        }
    }

    func forgetBrowsed(_ id: ThreadID) { browsed[id] = nil }

    /// Saved in Corres's own lists (the Inbox), not only opened from a mailbox.
    func isInLists(_ id: ThreadID) -> Bool { listedThreads.contains { $0.id == id } }

    /// A mailbox's conversation, moved back to the Inbox: it joins the
    /// lists now instead of waiting for the next sync to bring it.
    func adoptIntoInbox(_ thread: Correspondence) async {
        var item = await storedThread(browsed[thread.id] ?? thread)
        // A copy from the list carries no HTML: read the message again
        // when it's opened, rather than saving it without.
        if item.htmlBody == nil { item.isBodyLoaded = false }
        item.labelIds.removeAll { ["TRASH", "SPAM"].contains($0) }
        if !item.labelIds.contains("INBOX") { item.labelIds.append("INBOX") }
        browsed[thread.id] = nil
        _ = try? await repository.upsert([item], isInitialSync: true)
        await refresh()
    }

    /// A removal the server refused after all (it waited while offline):
    /// the conversation comes back as it was.
    func putBack(_ thread: Correspondence) async {
        // Its saved copy came from the list, without the HTML: the message
        // is read again when opened, rather than saved without it.
        var thread = thread
        if thread.htmlBody == nil { thread.isBodyLoaded = false }
        _ = try? await repository.upsert([thread], isInitialSync: true)
        await refresh()
    }

    func hide(_ id: ThreadID) { hiddenIDs.insert(id) }
    /// For a setting that changes what the lists show without changing any
    /// mail (Screen new senders): every list rebuilds on its next redraw.
    func listsShouldRebuild() { revision &+= 1; contentRevision &+= 1 }
    func unhide(_ id: ThreadID) { hiddenIDs.remove(id) }
    private(set) var state = LoadState.idle
    private(set) var pending: Set<ThreadID> = []
    private(set) var sending: Set<UUID> = []
    var errorMessage: String?
    private let repository: any MailRepository

    /// Sample mail is only for trying Corres before Gmail is connected; an
    /// empty store with an account connected stays empty.
    var seedsSampleMail: () -> Bool = { true }

    init(repository: any MailRepository) { self.repository = repository }

    /// The first load shows the launch mark; every later one (after a
    /// sync, a push, pull to refresh) updates the lists in place. Flipping
    /// back to `.loading` swapped every list out for a moment, which threw
    /// away its scroll position and dropped you back at the top mid-task.
    func load() async {
        if state == .loaded {
            if seedsSampleMail() { try? await repository.seedIfNeeded(now: Self.sampleNow) }
            await refresh()
            return
        }
        // A second caller during the first load waits for it: a
        // notification's Archive on a cold launch used to find no threads
        // and do nothing.
        if let firstLoad {
            await firstLoad.value
            return
        }
        let task = Task { await loadFirst() }
        firstLoad = task
        await task.value
        firstLoad = nil
    }

    private var firstLoad: Task<Void, Never>?

    /// Once, after updating from a build that kept each email's HTML inside
    /// its conversation: moved to its own place a batch at a time, between
    /// everything else, which makes every later read of the lists several
    /// times faster. Nothing changes on screen.
    private func moveStoredContent() {
        Task(priority: .utility) { [repository] in
            var moved = 0
            while let count = try? await repository.moveContent(batch: 100), count > 0 {
                moved += count
                try? await Task.sleep(for: .milliseconds(150))
            }
            if moved > 0 {
                HangReporter.note("moved \(moved) messages' HTML")
                await refresh()
            }
        }
    }
    private static let firstScreen = 300

    /// When sample mail is dated from. App Store screenshots show 9:41, so
    /// there the mail arrives that morning, whatever time they're taken.
    static var sampleNow: Date {
        guard EntitlementStore.isScreenshotMode,
              let morning = Calendar.current.date(bySettingHour: 9, minute: 41, second: 0, of: .now) else { return .now }
        // Before 9:41 it's yesterday's, so nothing arrives in the future.
        return morning > .now ? morning.addingTimeInterval(-86_400) : morning
    }

    /// The mailbox, read in the background while the window is still being
    /// built (which keeps the main thread busy for a second or more on a
    /// Mac): by the time the lists can show, the mail is already here.
    private var earlyRead: (first: Task<[Correspondence], Error>, all: Task<[Correspondence], Error>)?

    func readEarly() {
        var sample = seedsSampleMail()
        #if DEBUG
        // Timing launches on a copy of a real mailbox, with no account.
        if ProcessInfo.processInfo.arguments.contains("-MeasureLaunch") { sample = false }
        #endif
        guard earlyRead == nil, state == .idle, !sample else { return }
        let repository = self.repository
        let first = Task.detached(priority: .userInitiated) { try await repository.recentThreads(limit: MailStore.firstScreen) }
        let all = Task.detached(priority: .userInitiated) {
            _ = try? await first.value
            return try await repository.threads()
        }
        earlyRead = (first, all)
    }

    /// What the screen shows: the lists as soon as the newest mail is
    /// read, before the rest of the mailbox follows.
    var displayState: LoadState { state == .loading && !allThreads.isEmpty ? .loaded : state }

    private func loadFirst() async {
        state = .loading
        do {
            if seedsSampleMail() { try await repository.seedIfNeeded(now: Self.sampleNow) }
            // The newest first, so the first screen is up in a moment, then
            // everything (thousands of conversations take a few seconds on
            // a phone). Lists show as soon as the first part is here.
            HangReporter.step("reading mail")
            let early = earlyRead
            earlyRead = nil
            if let early, let first = try? await early.first.value { allThreads = first } else {
                allThreads = try await repository.recentThreads(limit: Self.firstScreen)
            }
            HangReporter.step("newest \(allThreads.count) read")
            if let early, let all = try? await early.all.value { allThreads = all } else {
                allThreads = try await repository.threads()
            }
            HangReporter.step("all \(allThreads.count) read")
            #if DEBUG
            await padForStressTest()
            await loadRenderTestEmails()
            #endif
            state = .loaded
            afterRefresh?()
            moveStoredContent()
            // The newest few, read ahead: the first one opened shows at once.
            Task { await prefetchStoredContent(threads.sorted { $0.receivedAt > $1.receivedAt }.prefix(8).map(\.id)) }
        } catch is CancellationError {
            state = .idle
        } catch {
            state = .failed
        }
    }

    #if DEBUG
    /// Launch with `-stressThreads 2000` to pad sample mail with copies of
    /// what loaded (each an hour older than the last), saved like real
    /// mail so every action works on them, for measuring scrolling and
    /// swiping on an inbox the size of a real one. Removed with the rest
    /// of the sample mail.
    /// Launch with `-renderTestEmails <folder>` to add each .html file in
    /// it as a sample email (images allowed), for checking how real email
    /// HTML renders. Removed with the rest of the sample mail.
    private func loadRenderTestEmails() async {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flag = arguments.firstIndex(of: "-renderTestEmails"), flag + 1 < arguments.count else { return }
        let folder = URL(fileURLWithPath: arguments[flag + 1])
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { return }
        // .html files are HTML mail; .txt files are plain-text mail.
        let emails = files.filter { ["html", "txt"].contains($0.pathExtension) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .enumerated().compactMap { index, file -> Correspondence? in
                guard let content = try? String(contentsOf: file, encoding: .utf8) else { return nil }
                let name = file.deletingPathExtension().lastPathComponent
                let isText = file.pathExtension == "txt"
                return Correspondence(id: ThreadID(account: "sample", providerID: "render-\(name)"), sender: "Render test",
                                      organization: "Corres", subject: name, excerpt: "Rendering test: \(name)",
                                      body: isText ? content : name, htmlBody: isText ? nil : content, receivedAt: .now.addingTimeInterval(Double(-index) * 60), dueAt: nil,
                                      reason: "", attention: .quiet, imagesTrusted: true)
            }
        _ = try? await repository.upsert(emails, isInitialSync: true)
        allThreads = (try? await repository.threads()) ?? allThreads
    }

    private func padForStressTest() async {
        let arguments = ProcessInfo.processInfo.arguments
        // An ordinary launch clears copies a stress run left behind, so
        // they don't sit beside real mail afterwards.
        if !arguments.contains("-stressThreads") {
            let leftovers = allThreads.filter { $0.id.providerID.contains("-stress") }.map(\.id)
            guard !leftovers.isEmpty else { return }
            for id in leftovers { try? await repository.remove(id) }
            allThreads = (try? await repository.threads()) ?? allThreads
            return
        }
        guard let flag = arguments.firstIndex(of: "-stressThreads"), flag + 1 < arguments.count,
              let count = Int(arguments[flag + 1]), count > 0,
              !allThreads.isEmpty, !allThreads.contains(where: { $0.id.providerID.contains("-stress") }) else { return }
        let base = allThreads
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        var copies: [Correspondence] = []
        copies.reserveCapacity(count)
        for index in 0..<count {
            let source = base[index % base.count]
            guard let data = try? encoder.encode(source),
                  var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  var id = object["id"] as? [String: Any],
                  let providerID = id["providerID"] as? String,
                  let received = object["receivedAt"] as? Double else { continue }
            id["providerID"] = "\(providerID)-stress\(index)"
            object["id"] = id
            object["receivedAt"] = received - Double(index + 1) * 3_600
            guard let copyData = try? JSONSerialization.data(withJSONObject: object),
                  let copy = try? decoder.decode(Correspondence.self, from: copyData) else { continue }
            copies.append(copy)
        }
        _ = try? await repository.upsert(copies, isInitialSync: false)
        allThreads = (try? await repository.threads()) ?? allThreads
    }
    #endif

    /// Re-fetches `threads` without touching `state`: unlike `load()`, this
    /// is for refreshing an already-loaded list after something changed
    /// underneath it (a remote search merging results in), not the initial
    /// load. `load()`'s `state = .loading` transition would otherwise flash
    /// the whole list away to a spinner on every debounced search tick.
    /// Reloads the lists from the store. Calls that arrive while one is
    /// running (a sync saves a batch every moment) fold into one more
    /// reload after it, instead of each reading the whole mailbox.
    func refresh() async {
        if isRefreshing {
            // Returns once a reload that started after this call is done,
            // so the caller still sees what it just changed.
            refreshAgain = true
            await withCheckedContinuation { refreshWaiters.append($0) }
            return
        }
        isRefreshing = true
        repeat {
            refreshAgain = false
            let waiting = refreshWaiters
            refreshWaiters = []
            // Only what changed since the last read, once the whole mailbox
            // is here: reading all of it again took seconds on a phone.
            if state == .loaded, let changes = try? await repository.changes() {
                apply(changes)
            } else {
                allThreads = (try? await repository.threads()) ?? allThreads
            }
            // Everyone who asked before this reload began now has it.
            waiting.forEach { $0.resume() }
        } while refreshAgain
        isRefreshing = false
        afterRefresh?()
    }
    private func apply(_ changes: StoredChanges) {
        guard !changes.updated.isEmpty || !changes.removed.isEmpty else { return }
        var threads = allThreads
        var known = positions
        for item in changes.updated {
            if let index = known[item.id], threads.indices.contains(index) {
                threads[index] = item
            } else {
                known[item.id] = threads.count
                threads.append(item)
            }
        }
        if !changes.removed.isEmpty {
            let gone = Set(changes.removed)
            threads.removeAll { gone.contains($0.id) }
        }
        allThreads = threads
    }

    /// Told after each reload from storage, which is when new mail has
    /// arrived: rules and muted conversations act on it (Organizer).
    @ObservationIgnored var afterRefresh: (@MainActor () -> Void)?
    @ObservationIgnored private var isRefreshing = false
    @ObservationIgnored private var refreshAgain = false
    @ObservationIgnored private var refreshWaiters: [CheckedContinuation<Void, Never>] = []

    /// Removes an account's mail from this iPhone after the account is
    /// removed from Corres. If no mail is left at all, `load()` brings the
    /// sample conversations back, the same state as a fresh install.
    func removeAccountData(_ account: String) async {
        do {
            try await repository.deleteAccountData(account)
            allThreads = try await repository.threads()
            if allThreads.isEmpty {
                state = .idle
                await load()
            }
        } catch {
            errorMessage = String(localized: "Couldn't remove this account's mail from your \(Device.name). Try again.")
        }
    }

    /// Once a real Gmail account is connected, the fictional sample threads
    /// have no reason to keep sitting alongside real mail, mixed into the
    /// same Brief/Needs You/Waiting counts and rows: they existed only to
    /// give a pre-connection preview. Safe to call unconditionally; a no-op
    /// once no sample threads remain.
    func deleteSampleDataIfPresent() async {
        guard allThreads.contains(where: { $0.id.account == "sample" }) else { return }
        do {
            try await repository.deleteSampleData()
            allThreads = try await repository.threads()
        } catch {
            errorMessage = String(localized: "Couldn't remove sample data. Try again.")
        }
    }

    // Your own moves, pins and snoozes follow you to your other devices
    // (`CloudSync`); one arriving from another device isn't sent back.
    func update(_ id: ThreadID, to attention: Attention) async {
        await mutate(id) { try await self.repository.setAttention(attention, for: id) }
        CloudSync.shared.recordAttention(attention, for: id, messageID: thread(id)?.latestMessageID)
    }

    func setPinned(_ isPinned: Bool, for id: ThreadID) async {
        await mutate(id) { try await self.repository.setPinned(isPinned, for: id) }
        CloudSync.shared.recordPinned(isPinned, for: id)
    }

    func snooze(_ id: ThreadID, until: Date?) async {
        await mutate(id) { try await self.repository.snooze(id, until: until) }
        CloudSync.shared.recordSnooze(until: until, for: id)
    }

    func setUnread(_ isUnread: Bool, for id: ThreadID) async {
        if updateBrowsed(id, { $0.isUnread = isUnread }) { return }
        await mutate(id) { try await self.repository.setUnread(isUnread, for: id) }
    }

    func setLabelIds(_ labelIds: [String], for id: ThreadID) async {
        if updateBrowsed(id, { $0.labelIds = labelIds }) { return }
        await mutate(id) { try await self.repository.setLabelIds(labelIds, for: id) }
    }

    /// Called by `SemanticTriageService` once it has actually assessed one
    /// message on-device. Deliberately not routed through `mutate`: nothing
    /// the person did caused this write, so a failure has no business
    /// surfacing `mutate`'s own user-visible error banner; the thread just
    /// keeps whatever Gmail-unread-state-derived reason it already had,
    /// correct even if not yet refined, and gets naturally retried the next
    /// time `SemanticTriageService` finds it still untriaged.
    func applySemanticTriage(_ id: ThreadID, from expected: Attention, to result: Attention,
                             reason: String?, messageID: String) async {
        guard let updated = try? await repository.applySemanticTriage(id, from: expected, to: result,
                                                                      reason: reason, messageID: messageID) else { return }
        if let index = allThreads.firstIndex(where: { $0.id == updated.id }) {
            allThreads[index] = updated
        }
    }

    /// A body fetched for a thread synced metadata-first. Not routed through
    /// `mutate`: nothing the person decided changed, so a failure has no
    /// business showing a save-error alert; the thread just stays unloaded.
    func applyLoadedContent(_ items: [Correspondence]) async {
        // Arrived for a conversation being read: keep its HTML, since the
        // reload below brings the list back without it.
        for item in items { remember(item.htmlBody, for: item.id) }
        // A mailbox's conversation, opened: its full message replaces the
        // preview, keeping what's been changed on it here.
        let browsedItems = items.filter { item in browsed[item.id] != nil && !allThreads.contains { $0.id == item.id } }
        for item in browsedItems {
            var loaded = item
            if let existing = browsed[item.id] { loaded.isUnread = existing.isUnread; loaded.labelIds = existing.labelIds }
            browsed[item.id] = loaded
        }
        guard (try? await repository.applyLoadedContent(items)) ?? 0 > 0 else { return }
        await refresh()
    }

    /// Bump the version whenever `InboxClassifier`'s rules change, so
    /// already-synced threads get re-sorted under the new rules too (v2
    /// added the "someone you've written to" signal, v3 the 30-day limit).
    private static let attentionRulesMigrationKey = "corres.migration.inboxClassifier.v13"

    /// Runs `MailRepository.reclassifyLegacySyncDefaults` once per rules
    /// version. Only marks itself done on success, so a failed attempt
    /// simply runs again next launch.
    /// Re-sorts every thread whose place is still a rule decision, after a
    /// VIP or sorting setting changes. Nothing the person moved, and nothing
    /// Apple Intelligence already refined, is touched.
    /// Adding a VIP lets them past the Screener and brings their unread
    /// mail into Needs You now, not just from the next email on.
    func setVIP(_ senderEmail: String, account: String, isVIP: Bool) async {
        CorresSettings.setVIP(senderEmail, isVIP)
        CorresSettings.applyToCore()
        if isVIP {
            if threads.contains(where: { $0.senderEmail?.lowercased() == senderEmail.lowercased() && $0.senderDecision == .pending }) {
                await approveSender(senderEmail, account: account)
            }
            for thread in threads where thread.senderEmail?.lowercased() == senderEmail.lowercased()
                && thread.isUnread && thread.attention == .quiet {
                await update(thread.id, to: .needsYou)
            }
        }
        await reapplyRules()
    }

    func reapplyRules() async {
        _ = try? await repository.reclassifyLegacySyncDefaults()
        await refresh()
    }

    func migrateAttentionRulesIfNeeded() async {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.attentionRulesMigrationKey) else { return }
        guard (try? await repository.reclassifyLegacySyncDefaults()) != nil else { return }
        defaults.set(true, forKey: Self.attentionRulesMigrationKey)
        await refresh()
    }

    /// Every thread currently held by the Screener, awaiting a one-time
    /// approve/block decision on its sender. Excluded from Brief/Needs You/
    /// Waiting/Mail by `MailQuery.filter` until decided.
    var pendingSenderThreads: [Correspondence] { threads.filter { $0.senderDecision == .pending } }

    func approveSender(_ senderEmail: String, account: String) async {
        await setSenderDecision(.approved, senderEmail: senderEmail, account: account)
    }

    func blockSender(_ senderEmail: String, account: String) async {
        await setSenderDecision(.blocked, senderEmail: senderEmail, account: account)
    }

    /// Decides many senders at once (Allow All, Block All, Undo), then
    /// reloads once.
    func setSenderDecision(_ decision: SenderDecision, senders: [(email: String, account: String)]) async {
        do {
            for sender in senders {
                CloudSync.shared.recordDecision(decision, sender: sender.email, account: sender.account)
                try await repository.setSenderDecision(decision, forSenderEmail: sender.email, account: sender.account)
            }
            await refresh()
        } catch {
            errorMessage = String(localized: "Couldn't update these senders. Try again.")
        }
    }

    /// "Allow everyone from amazon.com": decides every waiting sender from
    /// that company now, and new ones as they arrive. Nil removes the rule
    /// (new senders from there are screened again; decisions already made
    /// stay). Returns the senders it decided, for Undo.
    @discardableResult
    func setDomainRule(_ domain: String, _ decision: SenderDecision?) async -> [(email: String, account: String)] {
        CorresSettings.setDomainRule(domain, decision)
        CorresSettings.applyToCore()
        guard let decision else { return [] }
        var seen = Set<String>()
        let senders = pendingSenderThreads.compactMap { thread -> (email: String, account: String)? in
            guard let email = thread.senderEmail, InboxClassifier.companyDomain(of: email) == domain,
                  seen.insert("\(thread.id.account)|\(email)").inserted else { return nil }
            return (email, thread.id.account)
        }
        await setSenderDecision(decision, senders: senders)
        return senders
    }

    /// A decision another device made, applied here.
    func approveOrBlock(_ decision: SenderDecision, sender: String, account: String) async {
        await setSenderDecision(decision, senderEmail: sender, account: account)
    }

    private func setSenderDecision(_ decision: SenderDecision, senderEmail: String, account: String) async {
        CloudSync.shared.recordDecision(decision, sender: senderEmail, account: account)
        do {
            try await repository.setSenderDecision(decision, forSenderEmail: senderEmail, account: account)
            await refresh()
        } catch {
            errorMessage = String(localized: "Couldn't update this sender. Try again.")
        }
    }

    /// Trusts `senderEmail` for remote images going forward, not just this
    /// one message: the smaller, no-infrastructure alternative to Apple's
    /// own Mail Privacy Protection (a server-side relay Corres deliberately
    /// doesn't run). A full re-fetch, not a spliced single-row update, since
    /// this can change more than one existing thread at once, the same
    /// tradeoff `approveSender`/`blockSender` already made for the same
    /// reason: a rare, deliberate action, not a hot-path one.
    func trustSenderImages(_ senderEmail: String, account: String) async {
        do {
            try await repository.trustSenderImages(forSenderEmail: senderEmail, account: account)
            await refresh()
        } catch {
            errorMessage = String(localized: "Couldn't remember this sender. Try again.")
        }
    }

    /// Called by `UnsubscribeService` once it has actually acted (a real
    /// one-click POST or opt-out email), never speculatively: this is what
    /// makes the unsubscribe banner stop asking again for this sender's
    /// future mail, the same propagate-to-every-thread mechanism
    /// `trustSenderImages` already uses for its own per-sender fact.
    func markSenderUnsubscribed(_ senderEmail: String, account: String) async {
        do {
            try await repository.markSenderUnsubscribed(forSenderEmail: senderEmail, account: account)
            await refresh()
        } catch {
            errorMessage = String(localized: "Couldn't remember this unsubscribe. Try again.")
        }
    }

    /// Returns whether the send succeeded. `realThreadID` is the real Gmail
    /// identity OutboxService already established by actually sending via
    /// Gmail (nil when the draft stayed local-only); see MailRepository.send.
    @discardableResult
    func send(_ draft: Draft, realThreadID: ThreadID? = nil, sentCopy: Correspondence? = nil) async -> Bool {
        guard !sending.contains(draft.id) else { return false }
        sending.insert(draft.id)
        defer { sending.remove(draft.id) }
        do {
            let updated = try await repository.send(draft, sentAt: .now, realThreadID: realThreadID, sentCopy: sentCopy)
            if let index = allThreads.firstIndex(where: { $0.id == updated.id }) {
                allThreads[index] = updated
            } else {
                allThreads.insert(updated, at: 0)
            }
            return true
        } catch RepositoryError.threadNotFound where realThreadID != nil {
            // Archived or removed while Undo counted down: the server has
            // already sent it, so there's nothing here to update, and
            // saying it wasn't sent would be wrong.
            return true
        } catch {
            errorMessage = String(localized: "Your message couldn't be sent. Nothing was sent. Try again.")
            return false
        }
    }

    /// Drops a thread from view entirely: Archive and Trash both end with
    /// this, once the App layer (`ThreadActionService`) has already told
    /// Gmail, or there was no Gmail account to tell. Not routed through
    /// `mutate`, since that splices an updated `Correspondence` back in and
    /// there is no updated row here, only a removed one.
    ///
    /// Deliberately does NOT manage `pending` itself: its only caller,
    /// `ThreadActionService.perform`, reserves the thread with
    /// `beginPending` *before* the Gmail network call that precedes this,
    /// not just around this method. Archive/Trash go over the network
    /// first and only call this on success (see that method's own doc
    /// comment); guarding `pending` here, after the fact, would leave the
    /// row fully swipeable for the entire round trip, letting a second
    /// swipe fire a second, conflicting Gmail call on the same thread.
    /// Archive and Trash end here once the server has them, a group at a
    /// time: `removed` leave for good, `kept` (the server refused) come
    /// back into view, in one change. One `remove` plus one `unhide` per
    /// conversation rebuilt every list twice each, which on a Select All
    /// meant hundreds of rebuilds while you kept working.
    func finishRemoval(removed: [ThreadID], kept: [ThreadID]) async {
        var gone = Set<ThreadID>()
        let saved = Set(allThreads.map(\.id))
        for id in removed {
            browsed[id] = nil
            // Opened from a mailbox and never saved: nothing to delete.
            guard saved.contains(id) else { continue }
            do {
                try await repository.remove(id)
                gone.insert(id)
            } catch RepositoryError.threadNotFound {
                // A sync got there first and already removed it: done.
                gone.insert(id)
            } catch {
                HangReporter.failure("remove a conversation", error)
                errorMessage = String(localized: "Couldn't update this conversation. Try again.")
            }
        }
        asOneChange {
            if !gone.isEmpty { allThreads.removeAll { gone.contains($0.id) } }
            hiddenIDs.subtract(removed)
            hiddenIDs.subtract(kept)
        }
    }

    func remove(_ id: ThreadID) async {
        if browsed[id] != nil, !allThreads.contains(where: { $0.id == id }) {
            browsed[id] = nil
            return
        }
        browsed[id] = nil
        do {
            try await repository.remove(id)
            allThreads.removeAll { $0.id == id }
        } catch RepositoryError.threadNotFound {
            allThreads.removeAll { $0.id == id }
        } catch {
            HangReporter.failure("remove a conversation", error)
            errorMessage = String(localized: "Couldn't update this conversation. Try again.")
        }
    }

    /// Reserves `id` as in-flight, for a caller (currently only
    /// `ThreadActionService.perform`) that needs the reservation held
    /// across work `mutate`/`remove` don't see themselves — specifically, a
    /// Gmail network call that happens *before* either of those run.
    /// Returns whether the reservation was actually acquired (false if
    /// something else already holds it), the same fail-silent semantics
    /// `mutate`/`remove`'s own internal guards already use. Every caller
    /// must release with `endPending`, success or failure alike.
    @discardableResult
    func beginPending(_ id: ThreadID) -> Bool {
        guard !pending.contains(id) else { return false }
        pending.insert(id)
        return true
    }

    func endPending(_ id: ThreadID) {
        pending.remove(id)
    }

    /// Splices the single returned thread into `threads` in place, the same
    /// pattern `send` already used, instead of re-fetching the entire
    /// mailbox from disk just to find the one row that changed: a pin,
    /// snooze, or attention change is the single most frequent interaction
    /// in the app (every swipe action and every "Mark as" tap), and a full
    /// SwiftData re-fetch on each one was real, measured, avoidable work on
    /// the hot path (see Docs/Architecture.md's performance sweep entry).
    /// Applies a change to a mailbox's conversation, when that's what it
    /// is. Returns whether it was one.
    private func updateBrowsed(_ id: ThreadID, _ change: (inout Correspondence) -> Void) -> Bool {
        guard var item = browsed[id], !allThreads.contains(where: { $0.id == id }) else { return false }
        change(&item)
        browsed[id] = item
        return true
    }

    private func mutate(_ id: ThreadID, _ operation: @escaping () async throws -> Correspondence) async {
        guard !pending.contains(id) else { return }
        pending.insert(id)
        defer { pending.remove(id) }
        do {
            let updated = try await operation()
            if let index = positions[updated.id], allThreads.indices.contains(index), allThreads[index].id == updated.id {
                allThreads[index] = updated
            } else if let index = allThreads.firstIndex(where: { $0.id == updated.id }) {
                allThreads[index] = updated
            }
        } catch RepositoryError.threadNotFound {
            // Removed by a sync while the change was on its way: nothing
            // left to change, and nothing to tell anyone.
            allThreads.removeAll { $0.id == id }
        } catch {
            HangReporter.failure("save a change", error)
            errorMessage = String(localized: "The change couldn't be saved. Your conversation is unchanged. Try again.")
        }
    }
}
