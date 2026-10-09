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
    private let client = GmailAPIClient()
    private static let sampleAccount = "sample"

    init(store: MailStore, auth: GoogleAuthService) {
        self.store = store
        self.auth = auth
    }

    enum RemovalKind {
        case archive, trash, spam
        var systemImage: String {
            switch self { case .archive: "archivebox"; case .trash: "trash"; case .spam: "xmark.bin" }
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
            case .archive: return threads.count == 1 ? "Archived" : "Archived \(threads.count)"
            case .trash: return threads.count == 1 ? "Moved to Trash" : "Deleted \(threads.count)"
            case .spam: return threads.count == 1 ? "Reported as spam" : "Reported \(threads.count) as spam"
            }
        }
    }

    private(set) var pendingRemoval: PendingRemoval?
    private var removalTask: Task<Void, Never>?
    static let undoSeconds = 5

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
        removalTask?.cancel()
        pendingRemoval = nil
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
        pendingRemoval = pending
        // One sleep, not a per-second countdown: the pill shows no timer,
        // and ticking `pendingRemoval` every second redrew the list and the
        // whole shell every second while you were triaging.
        removalTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.undoSeconds))
            guard !Task.isCancelled, let self, self.pendingRemoval?.id == pending.id else { return }
            self.pendingRemoval = nil
            self.enqueue(pending)
        }
    }

    /// The tail of the removals already on their way to Gmail.
    private var commitQueue: Task<Void, Never>?

    /// Queues a removal behind any already going to Gmail, without anyone
    /// waiting on it: the list moves on at once, and Gmail gets the
    /// changes one at a time rather than as a burst, which is what tripped
    /// its per-user rate limit when several rows were swiped in a row.
    private func enqueue(_ pending: PendingRemoval) {
        let previous = commitQueue
        commitQueue = Task { [weak self] in
            await previous?.value
            await self?.commit(pending)
        }
    }

    private func commit(_ pending: PendingRemoval) async {
        if pendingRemoval?.id == pending.id { pendingRemoval = nil }
        // One at a time, even from Select: a burst of changes is what Gmail
        // rate-limits, and nobody is waiting on these.
        for thread in pending.threads {
            await commitOne(thread, kind: pending.kind)
        }
    }

    private func commitOne(_ thread: Correspondence, kind: RemovalKind) async {
        switch kind {
        case .archive:
            await perform(thread, failureMessage: "Could not archive this conversation. Please try again.", gmailCall: {
                try await self.client.modifyThread(threadId: thread.id.providerID, removeLabelIds: ["INBOX"], account: thread.id.account)
            }, local: { await self.store.remove(thread.id) })
        case .trash:
            await perform(thread, failureMessage: "Could not move this conversation to Trash. Please try again.", gmailCall: {
                try await self.client.trashThread(threadId: thread.id.providerID, account: thread.id.account)
            }, local: { await self.store.remove(thread.id) })
        case .spam:
            await perform(thread, failureMessage: "Could not report this conversation as spam. Please try again.", gmailCall: {
                try await self.client.modifyThread(threadId: thread.id.providerID, addLabelIds: ["SPAM"],
                                                   removeLabelIds: ["INBOX"], account: thread.id.account)
            }, local: { await self.store.remove(thread.id) })
        }
        // Removed for good on success; back in view if Gmail refused.
        store.unhide(thread.id)
    }

    // MARK: Mailboxes

    /// Out of Trash or Spam, or back from the archive or a label: into the
    /// Inbox, and into Corres's lists.
    func moveToInbox(_ thread: Correspondence) async {
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
        } catch {
            store.errorMessage = "Could not move this conversation to the Inbox. Please try again."
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
        let failureMessage = "Could not mark this conversation as \(isUnread ? "unread" : "read"). Please try again."
        await performOptimistic(thread, failureMessage: failureMessage, gmailCall: {
            if isUnread {
                try await self.client.modifyThread(threadId: thread.id.providerID, addLabelIds: ["UNREAD"], account: thread.id.account)
            } else {
                try await self.client.modifyThread(threadId: thread.id.providerID, removeLabelIds: ["UNREAD"], account: thread.id.account)
            }
        }, local: { await self.store.setUnread(isUnread, for: thread.id) },
           revert: { await self.store.setUnread(!isUnread, for: thread.id) })
    }

    /// Flag here, flagged in iOS Mail and starred in Gmail: all three are
    /// Gmail's `STARRED` label, so this is just that label, optimistic like
    /// any other, and the same label arriving from elsewhere via sync is
    /// what shows a flag set in another app.
    func setFlagged(_ isFlagged: Bool, for thread: Correspondence) async {
        await toggleLabel("STARRED", isOn: isFlagged, for: thread)
    }

    /// Fetches the full message for a thread synced metadata-first, the
    /// moment it's opened, rather than waiting for background backfill to
    /// reach it. Silent on failure: the snippet is already showing, and
    /// the next open or backfill pass simply tries again.
    func loadContent(for thread: Correspondence) async {
        guard !thread.isBodyLoaded, thread.id.account != Self.sampleAccount,
              let messageID = thread.latestMessageID,
              let fetched = try? await client.fetchFull(ids: [messageID], account: thread.id.account) else { return }
        await store.applyLoadedContent(fetched.items)
    }

    /// Every message in a conversation, oldest first, keyed by thread and
    /// refreshed whenever a new message lands in it. In memory only: the
    /// conversation view needs it while open, and Gmail stays the record.
    private(set) var history: [ThreadID: (latest: String?, messages: [Correspondence])] = [:]

    func messages(in thread: Correspondence) -> [Correspondence]? {
        guard let entry = history[thread.id], entry.latest == thread.latestMessageID else { return nil }
        return entry.messages
    }

    func loadHistory(for thread: Correspondence) async {
        guard thread.id.account != Self.sampleAccount, messages(in: thread) == nil,
              let messages = try? await client.fetchThreadMessages(threadId: thread.id.providerID, account: thread.id.account)
        else { return }
        history[thread.id] = (thread.latestMessageID, messages)
    }

    /// Adds or removes a single real Gmail label (from `LabelDirectory`),
    /// optimistic for the same reason `setUnread` is: a chip toggling back
    /// off on a rare failure is a trivial correction, not a lost row.
    /// `labelIds(isOn:)` recomputes the thread's full label set from
    /// whatever's already known rather than trusting a stale copy from
    /// before this call, since another toggle could have raced ahead of it
    /// locally; called once for the optimistic apply and, if needed, again
    /// with the opposite `isOn` to compute the revert.
    func toggleLabel(_ labelId: String, isOn: Bool, for thread: Correspondence) async {
        let failureMessage = "Could not update this label. Please try again."
        func labelIds(isOn: Bool) -> [String] {
            var labelIds = self.store.thread(thread.id)?.labelIds ?? thread.labelIds
            if isOn {
                if !labelIds.contains(labelId) { labelIds.append(labelId) }
            } else {
                labelIds.removeAll { $0 == labelId }
            }
            return labelIds
        }
        await performOptimistic(thread, failureMessage: failureMessage, gmailCall: {
            if isOn {
                try await self.client.modifyThread(threadId: thread.id.providerID, addLabelIds: [labelId], account: thread.id.account)
            } else {
                try await self.client.modifyThread(threadId: thread.id.providerID, removeLabelIds: [labelId], account: thread.id.account)
            }
        }, local: { await self.store.setLabelIds(labelIds(isOn: isOn), for: thread.id) },
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
                         gmailCall: () async throws -> Void, local: () async -> Void) async {
        guard store.beginPending(thread.id) else { return }
        defer { store.endPending(thread.id) }
        if thread.id.account != Self.sampleAccount {
            guard auth.isConnected(thread.id.account) else {
                errorMessage = failureMessage
                return
            }
            do {
                try await guardModifyPermission(for: thread.id.account)
                try await gmailCall()
            } catch {
                await report(error, failureMessage: failureMessage, account: thread.id.account)
                return
            }
        }
        await local()
    }

    /// Applies `local` immediately, then confirms with a real Gmail call in
    /// the background; on failure (or no connected account for a real
    /// thread), calls `revert` and surfaces the same error alert `perform`
    /// already uses. Only used where undoing the optimistic change is a
    /// trivial, non-destructive correction (`setUnread`/`toggleLabel`), never
    /// for Archive/Trash.
    private func performOptimistic(_ thread: Correspondence, failureMessage: String,
                                   gmailCall: () async throws -> Void, local: () async -> Void,
                                   revert: () async -> Void) async {
        await local()
        guard thread.id.account != Self.sampleAccount else { return }
        guard auth.isConnected(thread.id.account) else {
            errorMessage = failureMessage
            await revert()
            return
        }
        do {
            try await guardModifyPermission(for: thread.id.account)
            try await gmailCall()
        } catch {
            await report(error, failureMessage: failureMessage, account: thread.id.account)
            await revert()
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
    private func report(_ error: Error, failureMessage: String, account: String) async {
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
            } else if let reason, GmailAPIClient.rateLimitReasons.contains(reason) {
                errorMessage = "Gmail is limiting how fast changes can be made right now. Give it a moment and try again."
            } else {
                // Unexplained: show Gmail's own words, and offer Reconnect
                // for any 403, the one thing within the person's reach.
                if status == 403 { reconnectAccount = account }
                let detail = [message, reason.map { "(\($0), \(status))" } ?? "(\(status))"].compactMap { $0 }.joined(separator: " ")
                errorMessage = "\(failureMessage)\n\nGmail said: \(detail)"
            }
        case GmailAPIClient.ClientError.badResponse(let status) where status == 403 && hasModify != true:
            askToReconnect(account)
        case GmailAPIClient.ClientError.notSignedIn:
            reconnectAccount = account
            errorMessage = "\(account) needs to sign in again before Corres can change its mail."
        case GmailAPIClient.ClientError.badResponse(let status):
            errorMessage = "\(failureMessage) (Gmail error \(status))"
        default:
            errorMessage = failureMessage
        }
    }

    private func askToReconnect(_ account: String) {
        reconnectAccount = account
        errorMessage = "Corres can read \(account) but doesn't have permission to change it, so marking read, archiving, and flagging can't go through. Reconnect it and leave every Gmail permission checked."
    }
}
