import SwiftUI
import Foundation
import Observation

/// Actions that touch a thread's real Gmail state: Archive, Trash, and
/// marking it read/unread. Same shape as `OutboxService`: a real Gmail call
/// is attempted first for any non-sample thread, and only on success does
/// the local change happen, the same "network before any local state
/// change" rule `OutboxService` already follows for sending. Archive/Trash
/// began this file (Batch 18); read/unread (Batch 23) reused its exact
/// Gmail-call-then-local-change shape rather than inventing a new one.
/// Every Gmail call is scoped to `thread.id.account` (Batch 29): a thread
/// always already knows which connected account it belongs to, so no
/// "current account" concept is needed here at all.
@MainActor @Observable
final class ThreadActionService {
    var errorMessage: String?

    private let store: MailStore
    private let auth: GoogleAuthService
    private let client = MailClient()
    private static let sampleAccount = "sample"

    init(store: MailStore, auth: GoogleAuthService) {
        self.store = store
        self.auth = auth
        // A change saved while offline that the server then refused: the
        // conversation comes back, and you're told why.
        ActionQueue.shared.onRefused = { [weak self] action, error in
            // Its account was removed meanwhile: nothing to bring back.
            guard let self, self.auth.isConnected(action.account) else { return }
            HangReporter.failure("a waiting change", error)
            if let snapshot = action.snapshot { await self.store.putBack(snapshot) }
            // A read or a flag that didn't take settles with the next sync;
            // only a conversation coming back needs saying.
            await self.report(error, failureMessage: String(localized: "A change you made while offline couldn't be saved."), account: action.account,
                              quietly: action.snapshot == nil)
        }
    }

    enum RemovalKind: Equatable {
        case archive, trash, spam
        /// Move to a label or folder, out of the Inbox.
        case move(labelId: String, name: String)
        var systemImage: String {
            switch self { case .archive: "archivebox"; case .trash: "trash"; case .spam: "xmark.bin"; case .move: "folder" }
        }
    }

    /// An Archive or Trash waiting out its Undo window. The conversation is
    /// already gone from view; Gmail hears about it only once the window
    /// closes, so Undo is instant and never needs a second round trip.
    struct PendingRemoval: Identifiable, Equatable {
        let id = UUID()
        /// One conversation from a swipe; several from Select.
        let threads: [Correspondence]
        let kind: RemovalKind
        var thread: Correspondence { threads[0] }
        var title: String {
            switch kind {
            case .archive: return threads.count == 1 ? String(localized: "Archived") : String(localized: "Archived \(threads.count)")
            case .trash: return threads.count == 1 ? String(localized: "Moved to Trash") : String(localized: "Deleted \(threads.count)")
            case .spam: return threads.count == 1 ? String(localized: "Reported as spam") : String(localized: "Reported \(threads.count) as spam")
            case .move(_, let name): return name.isEmpty ? String(localized: "Moved") : String(localized: "Moved to \(name)")
            }
        }
    }

    private(set) var pendingRemoval: PendingRemoval?
    private var removalTask: Task<Void, Never>?
    static let undoSeconds = 5

    /// The last change you made by hand that isn't a removal (Handled,
    /// Needs You, read, flag, pin), offered back for a few seconds the way
    /// Archive is. Gmail offers Undo only for some actions; here every
    /// swipe and menu choice can be taken back.
    struct UndoableChange: Identifiable {
        let id = UUID()
        let title: String
        let systemImage: String
        let undo: @MainActor () async -> Void
    }

    private(set) var lastChange: UndoableChange?
    private var changeTask: Task<Void, Never>?

    func offerUndo(_ title: String, systemImage: String, undo: @escaping @MainActor () async -> Void) {
        let change = UndoableChange(title: title, systemImage: systemImage, undo: undo)
        lastChange = change
        Assistive.announce(String(localized: "\(title). Undo available."))
        changeTask?.cancel()
        changeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Assistive.undoSeconds(Self.undoSeconds)))
            guard !Task.isCancelled, let self, self.lastChange?.id == change.id else { return }
            self.lastChange = nil
        }
    }

    /// Counts each Undo, for the tap felt in the hand (`CorresShell`).
    private(set) var undoCount = 0

    func undoLastChange() {
        guard let change = lastChange else { return }
        changeTask?.cancel()
        lastChange = nil
        undoCount &+= 1
        Task { await change.undo() }
    }

    func dismissLastChange() {
        changeTask?.cancel()
        lastChange = nil
    }

    /// Moves conversations to Needs You, Waiting or Handled, with Undo.
    func setAttention(_ attention: Attention, for thread: Correspondence) async {
        await setAttention(attention, for: [thread])
    }

    func setAttention(_ attention: Attention, for threads: [Correspondence]) async {
        let moving = threads.filter { $0.attention != attention }
        let before = moving.map { ($0.id, $0.attention) }
        guard !before.isEmpty else { return }
        // What the move teaches (SenderLessons), learned before the move so
        // the thread still shows how it got where it was.
        let lessonsBefore = SenderLessons.all
        let learned = moving.compactMap { SenderLessons.learn(from: $0, was: $0.attention, now: attention) }
        await store.asOneChange { for (id, _) in before { await store.update(id, to: attention) } }
        // "No action needed" on a sender's mail the model brought in takes
        // back the rest of what it brought in from them, too.
        var alsoQuieted: [(ThreadID, String)] = []
        if attention == .quiet, !learned.isEmpty {
            let movedIDs = Set(before.map(\.0))
            for other in store.threads where !movedIDs.contains(other.id) && other.wasPromotedByIntelligence
                && SenderLessons.isQuieted(other) {
                guard let messageID = other.latestMessageID else { continue }
                alsoQuieted.append((other.id, other.reason))
                await store.applySemanticTriage(other.id, from: .needsYou, to: .quiet,
                                                reason: InboxClassifier.lessonReason, messageID: messageID)
            }
        }
        let n = before.count
        let moved = switch attention {
        case .handled: n == 1 ? String(localized: "Marked Handled") : String(localized: "Marked \(n) Handled")
        case .quiet: n == 1 ? String(localized: "Marked as no action needed") : String(localized: "Marked \(n) as no action needed")
        default: n == 1 ? String(localized: "Moved to \(attention.title)") : String(localized: "Moved \(n) to \(attention.title)")
        }
        let title = learned.count == 1 && before.count == 1 ? learned[0] : moved
        let icon = !learned.isEmpty ? "brain" : attention == .handled ? "checkmark.circle" : "arrow.right.circle"
        offerUndo(title, systemImage: icon) { [store] in
            SenderLessons.all = lessonsBefore
            for (id, was) in before { await store.update(id, to: was) }
            for (id, reason) in alsoQuieted {
                guard let messageID = store.thread(id)?.latestMessageID else { continue }
                await store.applySemanticTriage(id, from: .quiet, to: .needsYou, reason: reason, messageID: messageID)
            }
        }
    }

    /// Into Primary, Promotions, Social or Updates: this email, this kind of
    /// the sender's mail, or everything they send (Gmail and Mail only
    /// offer the sender). The emails already here move now, and Gmail's
    /// own category changes too, so Gmail learns it as well; later mail is
    /// placed by the rule as it arrives. Said, with Undo.
    func setCategory(_ category: InboxCategory, for thread: Correspondence, scope: SenderLessons.CategoryScope) async {
        let (said, undoRule) = SenderLessons.setCategory(category, for: thread, scope: scope)
        let moving: [Correspondence] = scope == .thisEmail ? [thread]
            : Array(store.threads.filter { $0.senderEmail?.lowercased() == thread.senderEmail?.lowercased()
                && SenderLessons.category(for: $0) == category }.prefix(50))
        // Here at once, with Undo; Gmail follows behind, one email at a
        // time (up to 50 round trips, too slow to wait on before saying so).
        var before: [(ThreadID, [String])] = []
        for item in moving where item.id.account != Self.sampleAccount {
            before.append((item.id, item.labelIds))
            await store.setLabelIds(item.labelIds.filter { !InboxCategory.gmailLabels.contains($0) } + [category.gmailLabel], for: item.id)
        }
        store.listsShouldRebuild()
        let client = client
        let forward = Task {
            for (id, _) in before {
                try? await client.modifyThread(threadId: id.providerID, addLabelIds: [category.gmailLabel],
                                               removeLabelIds: Array(InboxCategory.gmailLabels.subtracting([category.gmailLabel])),
                                               account: id.account)
            }
        }
        offerUndo(said, systemImage: "tray.and.arrow.down") { [store] in
            undoRule()
            for (id, labels) in before { await store.setLabelIds(labels, for: id) }
            store.listsShouldRebuild()
            // After the move has reached Gmail, so Gmail ends where it began.
            await forward.value
            for (id, labels) in before {
                let added = labels.filter(InboxCategory.gmailLabels.contains)
                try? await client.modifyThread(threadId: id.providerID, addLabelIds: added,
                                               removeLabelIds: Array(InboxCategory.gmailLabels.subtracting(added)), account: id.account)
            }
        }
    }

    /// Read/unread from a swipe, a menu or Select, with Undo. (Opening an
    /// email marks it read through `setUnread` directly, with no Undo.)
    func toggleUnread(_ isUnread: Bool, for threads: [Correspondence]) async {
        let before = threads.map { ($0, $0.isUnread) }
        await store.asOneChange { for thread in threads { await setUnread(isUnread, for: thread) } }
        let n = threads.count
        let said = switch (isUnread, n == 1) {
        case (true, true): String(localized: "Marked as unread")
        case (true, false): String(localized: "Marked \(n) as unread")
        case (false, true): String(localized: "Marked as read")
        case (false, false): String(localized: "Marked \(n) as read")
        }
        offerUndo(said, systemImage: isUnread ? "envelope.badge" : "envelope.open") { [weak self] in
            for (thread, was) in before { await self?.setUnread(was, for: thread) }
        }
    }

    func toggleFlagged(_ isFlagged: Bool, for threads: [Correspondence]) async {
        let before = threads.map { ($0, $0.isFlagged) }
        await store.asOneChange { for thread in threads { await setFlagged(isFlagged, for: thread) } }
        offerUndo(isFlagged ? String(localized: "Flagged") : String(localized: "Unflagged"), systemImage: isFlagged ? "flag" : "flag.slash") { [weak self] in
            for (thread, was) in before { await self?.setFlagged(was, for: thread) }
        }
    }

    func togglePinned(_ thread: Correspondence) async {
        let was = thread.isPinned
        await store.setPinned(!was, for: thread.id)
        offerUndo(was ? String(localized: "Unpinned") : String(localized: "Pinned"), systemImage: was ? "pin.slash" : "pin") { [store] in
            await store.setPinned(was, for: thread.id)
        }
    }

    /// `animated: false` from inside a conversation: the list underneath
    /// isn't on screen, so it should already be settled when you go back,
    /// rather than animating the row away as it comes into view.
    func archive(_ thread: Correspondence, animated: Bool = true) async { await queueRemoval([thread], kind: .archive, animated: animated) }
    func trash(_ thread: Correspondence, animated: Bool = true) async { await queueRemoval([thread], kind: .trash, animated: animated) }
    func archive(_ threads: [Correspondence]) async { await queueRemoval(threads, kind: .archive) }
    func trash(_ threads: [Correspondence]) async { await queueRemoval(threads, kind: .trash) }
    /// Out of the inbox and into Spam, which also teaches the provider's
    /// filter. Undo works like Archive's.
    func reportSpam(_ thread: Correspondence, animated: Bool = true) async { await queueRemoval([thread], kind: .spam, animated: animated) }

    /// Undo puts the conversation back exactly where it was.
    func undoRemoval() {
        guard let pending = pendingRemoval else { return }
        HangReporter.note("undo \(pending.kind)")
        removalTask?.cancel()
        pendingRemoval = nil
        undoCount &+= 1
        withAnimation(.snappy(duration: 0.3)) { for thread in pending.threads { store.unhide(thread.id) } }
    }

    /// Sends a waiting removal now: when the app leaves the foreground, or
    /// another removal starts, rather than losing it.
    func commitPendingRemoval() async {
        if let pending = pendingRemoval {
            removalTask?.cancel()
            pendingRemoval = nil
            enqueue(pending)
        }
        await commitQueue?.value
    }

    private func queueRemoval(_ threads: [Correspondence], kind: RemovalKind, animated: Bool = true) async {
        guard !threads.isEmpty else { return }
        HangReporter.note("\(kind) \(threads.count) thread(s), animated: \(animated)")
        // The previous removal goes to Gmail in the background rather than
        // being awaited: waiting on its round trip is what left a second
        // swiped row stuck off screen for a beat before it collapsed.
        if let previous = pendingRemoval {
            removalTask?.cancel()
            pendingRemoval = nil
            enqueue(previous)
        }
        if animated {
            withAnimation(.snappy(duration: 0.3)) { for thread in threads { store.hide(thread.id) } }
        } else {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { for thread in threads { store.hide(thread.id) } }
        }
        let pending = PendingRemoval(threads: threads, kind: kind)
        dismissLastChange()
        pendingRemoval = pending
        Assistive.announce(String(localized: "\(pending.title). Undo available."))
        // One sleep, not a per-second countdown: the pill shows no timer,
        // and ticking `pendingRemoval` every second redrew the list and the
        // whole shell every second while you were triaging.
        removalTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Assistive.undoSeconds(Self.undoSeconds)))
            guard !Task.isCancelled, let self, self.pendingRemoval?.id == pending.id else { return }
            self.pendingRemoval = nil
            self.enqueue(pending)
        }
    }

    /// Archived for you by a rule or a muted conversation: out of the
    /// lists at once, to the server in turn, with no Undo pill and nothing
    /// counted as a habit of yours.
    func archiveQuietly(_ threads: [Correspondence]) {
        guard !threads.isEmpty else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { for thread in threads { store.hide(thread.id) } }
        let pending = PendingRemoval(threads: threads, kind: .archive)
        let previous = commitQueue
        commitQueue = Task { [weak self] in
            await previous?.value
            await self?.commit(pending)
        }
    }

    /// Into a category for one email, said nowhere: a rule did it. Gmail's
    /// own tab follows, as when you move it yourself.
    func applyCategoryQuietly(_ category: InboxCategory, to thread: Correspondence) async {
        guard thread.id.account != Self.sampleAccount else { return }
        await store.setLabelIds(thread.labelIds.filter { !InboxCategory.gmailLabels.contains($0) } + [category.gmailLabel], for: thread.id)
        store.listsShouldRebuild()
        try? await client.modifyThread(threadId: thread.id.providerID, addLabelIds: [category.gmailLabel],
                                       removeLabelIds: Array(InboxCategory.gmailLabels.subtracting([category.gmailLabel])),
                                       account: thread.id.account)
    }

    /// The tail of the removals already on their way to Gmail.
    private var commitQueue: Task<Void, Never>?

    /// Queues a removal behind any already going to Gmail, without anyone
    /// waiting on it: the list moves on at once, and Gmail gets the
    /// changes one at a time rather than as a burst, which is what tripped
    /// its per-user rate limit when several rows were swiped in a row.
    private func enqueue(_ pending: PendingRemoval) {
        // Counted once Undo has passed: an undone archive says nothing.
        if pending.kind == .archive || pending.kind == .trash { HabitWatcher.shared.removed(pending.threads) }
        let previous = commitQueue
        commitQueue = Task { [weak self] in
            await previous?.value
            await self?.commit(pending)
        }
    }

    private func commit(_ pending: PendingRemoval) async {
        if pendingRemoval?.id == pending.id { pendingRemoval = nil }
        // One at a time, even from Select: a burst of changes is what Gmail
        // rate-limits, and nobody is waiting on these. The store hears
        // about them in groups, so the lists rebuild once per group.
        var removed: [ThreadID] = [], kept: [ThreadID] = []
        for (index, thread) in pending.threads.enumerated() {
            if await commitOne(thread, kind: pending.kind) { removed.append(thread.id) } else { kept.append(thread.id) }
            if removed.count + kept.count >= 25 || index == pending.threads.count - 1 {
                await store.finishRemoval(removed: removed, kept: kept)
                removed = []
                kept = []
            }
        }
    }

    /// Whether the server took it (or there was no server to tell).
    private func commitOne(_ thread: Correspondence, kind: RemovalKind) async -> Bool {
        var done = false
        switch kind {
        case .archive:
            await perform(thread, failureMessage: String(localized: "Couldn't archive this conversation. Try again."),
                          change: .modify(add: [], remove: ["INBOX"]), local: { done = true })
        case .trash:
            await perform(thread, failureMessage: String(localized: "Couldn't move this conversation to Trash. Try again."),
                          change: .trash, local: { done = true })
        case .spam:
            await perform(thread, failureMessage: String(localized: "Couldn't report this conversation as spam. Try again."),
                          change: .modify(add: ["SPAM"], remove: ["INBOX"]), local: { done = true })
        case .move(let labelId, _):
            await perform(thread, failureMessage: String(localized: "Couldn't move this conversation. Try again."),
                          change: .modify(add: [labelId], remove: ["INBOX"]), local: { done = true })
        }
        return done
    }

    // MARK: Mailboxes

    /// Move to: the label on and out of the Inbox in one change, sent once
    /// the Undo window closes like Archive. It used to move straight away,
    /// so Undo brought the row back here while the server had already
    /// filed it (Outlook and iCloud), and the next sync took it away again.
    func moveToLabel(_ labelId: String, named name: String = "", _ thread: Correspondence) async {
        await queueRemoval([thread], kind: .move(labelId: labelId, name: name), animated: false)
    }

    /// Out of Trash or Spam, or back from the archive or a label: into the
    /// Inbox, and into Corres's lists. Whether the server took it.
    @discardableResult
    func moveToInbox(_ thread: Correspondence) async -> Bool {
        let labels = store.thread(thread.id)?.labelIds ?? thread.labelIds
        let account = thread.id.account, id = thread.id.providerID
        do {
            if labels.contains("TRASH") {
                try await client.untrashThread(threadId: id, account: account)
                try await client.modifyThread(threadId: id, addLabelIds: ["INBOX"], account: account)
            } else if labels.contains("SPAM") {
                try await client.modifyThread(threadId: id, addLabelIds: ["INBOX"], removeLabelIds: ["SPAM"], account: account)
            } else {
                try await client.modifyThread(threadId: id, addLabelIds: ["INBOX"], account: account)
            }
            await store.adoptIntoInbox(thread)
            return true
        } catch {
            store.errorMessage = String(localized: "Couldn't move this conversation to the Inbox. Try again.")
            return false
        }
    }

    /// Orthogonal to Archive/Trash: this never removes the thread, only
    /// flips `Correspondence.isUnread` (see its doc comment), via the shared
    /// `UNREAD` label `modifyThread` already supports. Optimistic, unlike
    /// Archive/Trash: the dot flips the instant this is tapped, not after a
    /// Gmail round trip, since flipping it back on a rare failure is a
    /// trivial, harmless correction, nothing like re-inserting a removed
    /// row into a screen the person has already navigated away from.
    func setUnread(_ isUnread: Bool, for thread: Correspondence) async {
        let failureMessage = isUnread ? String(localized: "Couldn't mark this conversation as unread. Try again.")
            : String(localized: "Couldn't mark this conversation as read. Try again.")
        // Read state is never worth an alert, as in Mail and Gmail: a
        // failure is retried or settles with the next sync. Only a login
        // that can't change mail at all is said, since Reconnect fixes it.
        await performOptimistic(thread, failureMessage: failureMessage, quietly: true,
                                change: isUnread ? .modify(add: ["UNREAD"], remove: []) : .modify(add: [], remove: ["UNREAD"]),
                                local: { await self.store.setUnread(isUnread, for: thread.id) },
           revert: { await self.store.setUnread(!isUnread, for: thread.id) })
    }

    /// Flag here, flagged in iOS Mail and starred in Gmail: all three are
    /// Gmail's `STARRED` label, so this is just that label, optimistic like
    /// any other, and the same label arriving from elsewhere via sync is
    /// what shows a flag set in another app.
    @discardableResult
    func setFlagged(_ isFlagged: Bool, for thread: Correspondence) async -> Bool {
        await toggleLabel("STARRED", isOn: isFlagged, for: thread)
    }

    /// Conversations whose full message couldn't be loaded when opened:
    /// the conversation says so and offers Try Again, instead of
    /// "Loading the full message…" for good.
    private(set) var contentFailures: Set<ThreadID> = []

    /// Fetches the full message for a thread synced metadata-first, the
    /// moment it's opened, rather than waiting for background backfill to
    /// reach it. When the message alone doesn't come back, the whole
    /// conversation is asked for instead; when neither does in time, the
    /// thread joins `contentFailures`.
    func loadContent(for thread: Correspondence) async {
        guard !thread.isBodyLoaded, thread.id.account != Self.sampleAccount,
              let messageID = thread.latestMessageID else { return }
        contentFailures.remove(thread.id)
        let account = thread.id.account, threadID = thread.id.providerID
        let client = client
        // Its own task: leaving the conversation shouldn't throw away a
        // message that's nearly here, and the next open finds it loaded.
        let work = Task { () throws -> [Correspondence] in
            var failure: Error?
            do {
                let fetched = try await client.fetchFull(ids: [messageID], account: account)
                if !fetched.items.isEmpty { return fetched.items }
            } catch { failure = error }
            // A message the batch kept failing on (a very large one, or
            // Gmail busy) usually comes back with its conversation.
            do {
                let messages = try await client.fetchThreadMessages(threadId: threadID, account: account)
                if let latest = messages.last(where: { $0.latestMessageID == messageID }), latest.isBodyLoaded {
                    return [latest]
                }
            } catch { failure = error }
            throw failure ?? MessageNotLoaded()
        }
        let timeout = Task {
            try await Task.sleep(for: .seconds(45))
            work.cancel()
        }
        defer { timeout.cancel() }
        do {
            let items = try await work.value
            await store.applyLoadedContent(items)
        } catch {
            guard !Task.isCancelled else { return }
            HangReporter.failure("load a message", error)
            if store.thread(thread.id)?.isBodyLoaded != true { contentFailures.insert(thread.id) }
        }
    }

    private struct MessageNotLoaded: Error {}

    /// Every message in a conversation, oldest first, keyed by thread and
    /// refreshed whenever a new message lands in it. In memory only: the
    /// conversation view needs it while open, and Gmail stays the record.
    private(set) var history: [ThreadID: (latest: String?, messages: [Correspondence])] = [:]

    func messages(in thread: Correspondence) -> [Correspondence]? {
        guard let entry = history[thread.id], entry.latest == Self.historyKey(thread) else { return nil }
        return entry.messages
    }

    /// Changes when a message arrives or you send one, so a reply you just
    /// sent shows in the conversation (your reply isn't its latest message
    /// until Gmail's copy syncs).
    private static func historyKey(_ thread: Correspondence) -> String {
        "\(thread.latestMessageID ?? "")|\(thread.lastSentAt?.timeIntervalSince1970 ?? 0)"
    }

    func loadHistory(for thread: Correspondence) async {
        guard thread.id.account != Self.sampleAccount, messages(in: thread) == nil,
              let messages = try? await client.fetchThreadMessages(threadId: thread.id.providerID, account: thread.id.account)
        else { return }
        history[thread.id] = (Self.historyKey(thread), messages)
    }

    /// Adds or removes a single real Gmail label (from `LabelDirectory`),
    /// optimistic for the same reason `setUnread` is: a chip toggling back
    /// off on a rare failure is a trivial correction, not a lost row.
    /// `labelIds(isOn:)` recomputes the thread's full label set from
    /// whatever's already known rather than trusting a stale copy from
    /// before this call, since another toggle could have raced ahead of it
    /// locally; called once for the optimistic apply and, if needed, again
    /// with the opposite `isOn` to compute the revert.
    @discardableResult
    func toggleLabel(_ labelId: String, isOn: Bool, for thread: Correspondence) async -> Bool {
        let failureMessage = String(localized: "Couldn't update this label. Try again.")
        func labelIds(isOn: Bool) -> [String] {
            var labelIds = self.store.thread(thread.id)?.labelIds ?? thread.labelIds
            if isOn {
                if !labelIds.contains(labelId) { labelIds.append(labelId) }
            } else {
                labelIds.removeAll { $0 == labelId }
            }
            return labelIds
        }
        return await performOptimistic(thread, failureMessage: failureMessage,
                                change: isOn ? .modify(add: [labelId], remove: []) : .modify(add: [], remove: [labelId]),
                                local: { await self.store.setLabelIds(labelIds(isOn: isOn), for: thread.id) },
           revert: { await self.store.setLabelIds(labelIds(isOn: !isOn), for: thread.id) })
    }

    /// Archive/Trash: real Gmail call attempted first, local change (a row
    /// disappearing entirely) only on success. Deliberately not optimistic:
    /// reverting a wrongly-optimistic removal means re-inserting a row into
    /// a list the person may have already navigated away from, which is a
    /// far worse correction than a chip or a dot flipping back. `ConversationView`
    /// still makes the *screen transition* feel instant by dismissing before
    /// this resolves; this method's own ordering is unchanged.
    ///
    /// Reserves the thread with `store.beginPending` for the *entire*
    /// call, network round trip included, not just the `local()` write at
    /// the end. Found in a swipe-gesture sweep: `local` (`store.remove`)
    /// used to be the only thing that set `pending`, which meant a row
    /// stayed fully swipeable for as long as the Gmail call was in flight
    /// — real dead air a fast second swipe (or an impatient second try
    /// after a slow network) could land in, firing a second, conflicting
    /// Archive/Trash call on the same thread. Native Mail's own swipe
    /// buttons lock the row the instant a swipe commits, not once a
    /// network call happens to finish; this matches that.
    private func perform(_ thread: Correspondence, failureMessage: String,
                         change: ActionQueue.Action.Kind, local: () async -> Void) async {
        guard store.beginPending(thread.id) else { return }
        defer { store.endPending(thread.id) }
        #if DEBUG
        // A stress-test run (`-stressThreads`) swipes freely without
        // touching the real mailbox it was padded from.
        if ProcessInfo.processInfo.arguments.contains("-stressThreads") {
            await local()
            return
        }
        #endif
        if thread.id.account != Self.sampleAccount {
            guard auth.isConnected(thread.id.account) else {
                errorMessage = failureMessage
                return
            }
            do {
                try await guardModifyPermission(for: thread.id.account)
                try await send(change, for: thread, keeping: thread)
            } catch {
                await report(error, failureMessage: failureMessage, account: thread.id.account)
                return
            }
        }
        await local()
    }

    /// Straight to the server when it can go, or into `ActionQueue` when
    /// it can't yet (offline, the server busy) or when this conversation
    /// already has changes waiting, so they arrive in order. Throws only
    /// when the server refused for good. `keeping`: for a removal, what to
    /// put back if a waiting change is refused later.
    private func send(_ change: ActionQueue.Action.Kind, for thread: Correspondence, keeping snapshot: Correspondence? = nil) async throws {
        let account = thread.id.account, id = thread.id.providerID
        let action = ActionQueue.Action(account: account, threadID: id, kind: change, snapshot: snapshot)
        if ActionQueue.shared.hasWaiting(account: account, threadID: id) {
            ActionQueue.shared.enqueue(action)
            return
        }
        do {
            try await ActionQueue.run(action, client: client)
        } catch where ActionQueue.isTransient(error) {
            ActionQueue.shared.enqueue(action)
        } catch where ActionQueue.isGone(error) {
            // Deleted elsewhere already: the change has nothing left to do.
        }
    }

    /// Applies `local` immediately, then confirms with a real Gmail call in
    /// the background; on failure (or no connected account for a real
    /// thread), calls `revert` and surfaces the same error alert `perform`
    /// already uses. Only used where undoing the optimistic change is a
    /// trivial, non-destructive correction (`setUnread`/`toggleLabel`), never
    /// for Archive/Trash.
    /// Whether the change stands: false once it was refused and reverted.
    @discardableResult
    private func performOptimistic(_ thread: Correspondence, failureMessage: String, quietly: Bool = false,
                                   change: ActionQueue.Action.Kind, local: () async -> Void,
                                   revert: () async -> Void) async -> Bool {
        await local()
        guard thread.id.account != Self.sampleAccount else { return true }
        guard auth.isConnected(thread.id.account) else {
            // Still signing in (just launched, or opened from a
            // notification): the change waits for it rather than failing.
            ActionQueue.shared.enqueue(ActionQueue.Action(account: thread.id.account, threadID: thread.id.providerID, kind: change))
            return true
        }
        do {
            try await guardModifyPermission(for: thread.id.account)
            // Its own task, so leaving the conversation doesn't cut it off:
            // a mark-as-read cancelled halfway used to come back as an
            // error and put the unread dot back.
            try await Task { try await self.send(change, for: thread) }.value
            return true
        } catch {
            HangReporter.failure(failureMessage, error)
            await report(error, failureMessage: failureMessage, account: thread.id.account, quietly: quietly)
            await revert()
            return false
        }
    }

    /// Set when Gmail refused a change because this account's login lacks
    /// permission to modify mail; `CorresShell`'s alert offers Reconnect.
    var reconnectAccount: String?

    private struct MissingModifyPermission: Error {}

    /// Skips a call already known to fail: if the last token refresh
    /// reported this login's scopes and `gmail.modify` isn't among them,
    /// every read/archive/flag/label change will be refused.
    private func guardModifyPermission(for account: String) async throws {
        if let scopes = await GoogleTokenProvider.shared.grantedScopes(for: account),
           !scopes.contains(GoogleAuthService.modifyScope) {
            throw MissingModifyPermission()
        }
    }

    /// Replaces a single generic "please try again" with something that
    /// points at the cause. Found live: mark-read failed on every open for
    /// an account whose login could read mail but not change it, and
    /// "try again" could never succeed. A 403 is treated as missing
    /// permission unless the login is known to have it (Gmail also uses
    /// 403 for rate limits); anything else keeps the plain message plus
    /// Gmail's status code, so the next unexplained failure is diagnosable.
    private func report(_ error: Error, failureMessage: String, account: String, quietly: Bool = false) async {
        // Quiet: only a login that needs reconnecting is said.
        var errorMessage: String? {
            get { self.errorMessage }
            set { if !quietly { self.errorMessage = newValue } }
        }
        let scopes = await GoogleTokenProvider.shared.grantedScopes(for: account)
        let hasModify = scopes?.contains(GoogleAuthService.modifyScope)
        switch error {
        case is MissingModifyPermission:
            askToReconnect(account)
        case GmailAPIClient.ClientError.refused(let status, let reason, let message):
            if let reason, GmailAPIClient.permissionReasons.contains(reason) {
                askToReconnect(account)
            } else if status == 403 && reason == nil && hasModify != true {
                askToReconnect(account)
            } else if status == 403 && quietly {
                askToReconnect(account)
            } else if let reason, GmailAPIClient.rateLimitReasons.contains(reason) {
                errorMessage = String(localized: "\(MailAccounts.provider(for: account).title) is limiting how fast changes can be made right now. Give it a moment and try again.")
            } else {
                // Unexplained: show Gmail's own words, and offer Reconnect
                // for any 403, the one thing within the person's reach.
                if status == 403 { reconnectAccount = account }
                let detail = [message, reason.map { "(\($0), \(status))" } ?? "(\(status))"].compactMap { $0 }.joined(separator: " ")
                errorMessage = String(localized: "\(failureMessage)\n\n\(MailAccounts.provider(for: account).title) said: \(detail)")
            }
        case GmailAPIClient.ClientError.badResponse(let status) where status == 403 && hasModify != true:
            askToReconnect(account)
        case GmailAPIClient.ClientError.notSignedIn:
            if !quietly { reconnectAccount = account }
            errorMessage = String(localized: "\(account) needs to sign in again before Corres can change its mail.")
        case GmailAPIClient.ClientError.badResponse(let status):
            errorMessage = String(localized: "\(failureMessage) (\(MailAccounts.provider(for: account).title) error \(status))")
        default:
            errorMessage = failureMessage
        }
    }

    private func askToReconnect(_ account: String) {
        reconnectAccount = account
        errorMessage = String(localized: "Corres can read \(account) but doesn't have permission to change it, so marking read, archiving, and flagging can't go through. Reconnect it and allow every permission it asks for.")
    }
}
