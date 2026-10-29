import Foundation
import Network
import Observation
import os
import UserNotifications

/// Makes Send feel instant: ComposeView dismisses the moment the button is
/// tapped, and the actual work (a real Gmail send whenever an account is
/// connected, whether replying/forwarding or a brand-new compose, plus
/// local bookkeeping either way) happens after a short undo window, matching
/// the pattern real premium mail clients use (queue, don't block; offer
/// undo instead of a confirmation prompt).
///
/// A real Gmail send is attempted before any local state changes, not after:
/// if it fails, nothing here claims the message went out. `failed` surfaces
/// that so the person can retry or give up on it, rather than the thread
/// silently sitting in "Waiting" for a reply that was never actually sent.
///
/// Backed by the durable outbox (`MailRepository.outboxEntries`, ADR 005/007):
/// every queued or failed send is persisted immediately, not only held in
/// this instance's memory, so a force-quit mid-undo-window doesn't silently
/// lose a message the person already asked to send; see `resumeAfterRelaunch`.
///
/// A single send attempt failing no longer means giving up immediately:
/// `sendViaGmailWithRetry` retries a bounded number of times, with
/// exponential backoff and jitter, but only for failures where the request
/// almost certainly never reached or completed on Gmail (see its own doc
/// comment for exactly which). Two real sends never race each other for the
/// same account: this whole type is `@MainActor`, `resumeAfterRelaunch`
/// awaits each queued entry's `commit` one at a time rather than firing
/// them concurrently, and `queueSend` explicitly commits any still-pending
/// send before starting a new one, so per-account serialization already
/// holds structurally rather than needing its own separate queue.
@MainActor @Observable
final class OutboxService {
    struct Pending: Identifiable {
        let id: UUID
        let subjectPreview: String
        var secondsRemaining: Int
    }

    struct FailedSend: Identifiable {
        let id: UUID
        let draft: Draft
    }

    private(set) var pending: Pending?
    /// Every send that didn't go, oldest first, each kept until it's sent
    /// or you discard it. Only one used to be kept, so a second failure
    /// hid the first.
    private(set) var failedSends: [FailedSend] = []
    /// The one the banner shows.
    var failed: FailedSend? { failedSends.first }

    /// An email you stepped away from mid-way, kept like Mail's tucked-away
    /// compose: a pill at the bottom reopens it where you left off, and it's
    /// saved in Gmail's Drafts too, so it's on every device and survives a
    /// restart. Gmail saves as you go; Mail keeps it to hand. Corres does
    /// both.
    struct Shelved: Identifiable {
        var draft: Draft
        var id: UUID { draft.id }
        var isSavedToGmail: Bool { draft.gmailDraftID != nil }
        /// Gmail couldn't be reached (offline, or sample mail): kept here.
        var couldNotSave = false
    }
    private(set) var shelved: Shelved?

    /// Puts an unfinished email aside and saves it to Gmail's Drafts
    /// (updating the same draft if it was saved before).
    func shelve(_ draft: Draft, replyingTo thread: Correspondence?) {
        let draft = Self.keepingReplyHeaders(draft, thread: thread)
        shelved = Shelved(draft: draft)
        autosave(draft, replyingTo: thread)
    }

    /// Each email's Gmail draft, by Corres's own id: reopened from the pill
    /// before its save came back, or saved again while one was in flight,
    /// it still updates (and, once sent, deletes) that one draft instead of
    /// leaving a second behind in Drafts.
    private var gmailDraftIDs: [UUID: String] = [:]
    private var saving: [UUID: Task<Void, Never>] = [:]

    private func gmailDraftID(for draft: Draft) -> String? { draft.gmailDraftID ?? gmailDraftIDs[draft.id] }

    /// Saved to Gmail's Drafts without leaving Compose: as Corres goes to
    /// the background, so nothing written is lost if iOS closes it there.
    func autosave(_ draft: Draft, replyingTo thread: Correspondence?) {
        let previous = saving[draft.id]
        // iOS allows a few seconds more in the background to finish it.
        let background = BackgroundWork.begin("Save draft")
        saving[draft.id] = Task {
            defer { background.end() }
            await previous?.value
            guard let account = resolveSendingAccount(draft: draft, thread: thread), auth.isConnected(account) else {
                if shelved?.id == draft.id { shelved?.couldNotSave = true }
                return
            }
            let from = fromHeader(draft, account: account)
            let existing = gmailDraftID(for: draft)
            let draft = Self.keepingReplyHeaders(draft, thread: thread)
            guard let id = try? await client.saveDraft(attachments: draft.attachments, threadId: Self.threadProviderID(draft, thread: thread, account: account),
                                                       existingID: existing, account: account, compose: { withAttachments in
                GmailMessageComposer.compose(from: from, to: draft.to, cc: draft.cc, bcc: draft.bcc, subject: draft.subject,
                                             body: draft.body, inReplyTo: draft.inReplyTo, rootReference: draft.rootReference,
                                             messageID: Self.rfc822MessageID(for: draft.id),
                                             attachments: withAttachments ? draft.attachments : [], html: draft.bodyHTML, calendar: draft.calendarReply)
            }) else {
                if shelved?.id == draft.id { shelved?.couldNotSave = true }
                return
            }
            gmailDraftIDs[draft.id] = id
            if shelved?.id == draft.id { shelved?.draft.gmailDraftID = id }
        }
    }

    /// Drafts saved in the Share sheet with no connection
    /// (`ShareOutbox.addDraft`): saved to their account's Drafts now. One
    /// that still can't be (offline, or the account not back yet) is kept
    /// for next time, never dropped.
    func saveSharedDrafts() async {
        let drafts = ShareOutbox.takeDrafts()
        guard !drafts.isEmpty else { return }
        await waitForAccounts()
        for draft in drafts {
            var saved = false
            if let account = resolveSendingAccount(draft: draft, thread: nil), auth.isConnected(account) {
                let from = fromHeader(draft, account: account)
                saved = (try? await client.saveDraft(attachments: draft.attachments, threadId: nil, existingID: nil, account: account,
                                                     compose: { withAttachments in
                    GmailMessageComposer.compose(from: from, to: draft.to, cc: draft.cc, bcc: draft.bcc, subject: draft.subject,
                                                 body: draft.body, inReplyTo: nil, messageID: Self.rfc822MessageID(for: draft.id),
                                                 attachments: withAttachments ? draft.attachments : [])
                })) != nil
            }
            if !saved { try? ShareOutbox.addDraft(draft) }
        }
    }

    /// Opened again from the pill: it's in Compose now, not on the shelf.
    func takeShelved() -> Draft? {
        defer { shelved = nil }
        guard var draft = shelved?.draft else { return nil }
        draft.gmailDraftID = gmailDraftID(for: draft)
        return draft
    }

    /// Put away for good (the pill's ✕): it stays in Gmail's Drafts.
    func clearShelf() { shelved = nil }

    /// Delete Draft: gone here and from Gmail's Drafts.
    func discard(_ draft: Draft, replyingTo thread: Correspondence?) {
        if shelved?.id == draft.id { shelved = nil }
        removeGmailDraft(of: draft, replyingTo: thread)
    }

    /// From changed to another account: the draft saved in the old
    /// account's Drafts goes, once any save in flight lands, and the next
    /// save starts a new one in the new account. Queued behind that save,
    /// so a later one waits for this instead of racing it.
    func moveDraft(_ draft: Draft, awayFrom oldAccount: String) {
        let previous = saving[draft.id]
        let known = draft.gmailDraftID
        saving[draft.id] = Task {
            await previous?.value
            guard let draftID = known ?? gmailDraftIDs[draft.id] else { return }
            gmailDraftIDs[draft.id] = nil
            if shelved?.id == draft.id { shelved?.draft.gmailDraftID = nil }
            try? await client.deleteDraft(id: draftID, account: oldAccount)
        }
    }

    /// Takes its Gmail draft away, once any save in flight lands: when it's
    /// deleted, and when it's scheduled (Send Later holds it now, and a
    /// copy left in Drafts could be sent from another device as well).
    func removeGmailDraft(of draft: Draft, replyingTo thread: Correspondence?) {
        let inFlight = saving[draft.id]
        Task {
            await inFlight?.value
            saving[draft.id] = nil
            guard let draftID = gmailDraftID(for: draft), let account = resolveSendingAccount(draft: draft, thread: thread) else { return }
            gmailDraftIDs[draft.id] = nil
            try? await client.deleteDraft(id: draftID, account: account)
        }
    }

    /// The server draft saved for this email so far, if any: kept with a
    /// copy on the Mac, so it's updated, not saved twice, after a relaunch.
    func savedDraftID(for draft: Draft) -> String? { gmailDraftID(for: draft) }

    /// Waits for the draft saves in flight, for up to `timeout`, so quitting
    /// doesn't cut one off halfway. False if some were still going.
    func finishDraftSaves(timeout: Duration) async -> Bool {
        let inFlight = Array(saving.values)
        guard !inFlight.isEmpty else { return true }
        @MainActor final class Done { var value = false }
        let done = Done()
        let waiter = Task { for task in inFlight { await task.value }; done.value = true }
        let deadline = ContinuousClock.now + timeout
        while !done.value, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        if !done.value { waiter.cancel() }
        return done.value
    }

    private let store: MailStore
    private let auth: GoogleAuthService
    private let repository: any MailRepository
    private let client = MailClient()
    private var task: Task<Void, Never>?
    /// The draft/thread behind the current `pending`, kept alongside it so a
    /// second `queueSend` while one is still mid-undo-window can commit the
    /// first for real (matching "the first has already had its chance to be
    /// undone") instead of just cancelling its timer and losing it, which is
    /// what merely cancelling the Task alone would otherwise do.
    private var queuedDraft: Draft?
    private var queuedThread: Correspondence?

    /// Settings → Composing → Undo Send.
    private static var undoWindowSeconds: Int { CorresSettings.undoSendSeconds }
    private static let sampleAccount = "sample"
    /// Bounded, not unlimited: a flaky connection gets three real chances
    /// before the person sees a failure, not an endless silent retry loop.
    private static let maxSendAttempts = 3
    private static let baseBackoffMilliseconds = 2000

    /// Sends going out right now, so the same entry never goes twice: a
    /// resume at launch and a live Undo timer used to both send it.
    private var committing: Set<UUID> = []
    /// Only entries saved before this launch are leftovers to resume.
    private let launchedAt = Date.now

    init(store: MailStore, auth: GoogleAuthService, repository: any MailRepository) {
        self.store = store
        self.auth = auth
        self.repository = repository
        // Back online: what failed for want of a connection goes, without
        // asking (Mail leaves it in the Outbox for you to tap).
        network.pathUpdateHandler = { path in
            guard path.status == .satisfied else { return }
            Task { @MainActor in await self.retryFailedQuietly() }
        }
        network.start(queue: DispatchQueue(label: "studio.anwarcreative.corres.outbox"))
    }

    @ObservationIgnored private let network = NWPathMonitor()
    @ObservationIgnored private var retryingQuietly = false

    /// Called once at app launch. A record still `pending` means the app was
    /// force-quit before its undo window ever finished or was cancelled; the
    /// safest resolution is to finish sending it now, not silently drop a
    /// message the person already asked to send (there is no window left to
    /// re-offer undo for, since the moment to cancel has already passed). A
    /// `failed` record is restored so its Retry/Discard banner reappears
    /// instead of the earlier failure vanishing unexplained.
    func resumeAfterRelaunch() async {
        guard let entries = try? await repository.outboxEntries(), !entries.isEmpty else { return }
        for entry in entries.sorted(by: { $0.createdAt < $1.createdAt }) {
            // Saved during this launch: a send still in its Undo window, or
            // one already on its way. Its own task finishes it.
            guard entry.createdAt < launchedAt, entry.id != pending?.id, !committing.contains(entry.id) else { continue }
            switch entry.status {
            case .pending:
                // A `.pending` record surviving to the next launch means the
                // app was force-quit before this entry's send ever resolved
                // locally — genuinely ambiguous, not just "never sent": the
                // real Gmail send could have gone out and been accepted
                // moments before the process died, with only the local
                // bookkeeping after it lost. `checkForExistingSendFirst`
                // resolves that the same way a mid-retry ambiguous failure
                // does, before this ever calls `sendViaGmailWithRetry` fresh
                // and risks a real duplicate.
                await commit(entry.draft, thread: resolveThread(for: entry.draft), id: entry.id, checkForExistingSendFirst: true)
            case .failed:
                markFailed(entry.id, entry.draft)
            }
        }
        // Tried again once now: most failures were a lost connection.
        await retryFailedQuietly()
    }

    /// Each failed send tried again, quietly: the Message-ID it kept means
    /// Gmail is asked first, so one that did go out is never sent twice.
    /// Whatever still can't go stays listed.
    func retryFailedQuietly() async {
        guard !retryingQuietly, !failedSends.isEmpty, auth.hasRestored else { return }
        retryingQuietly = true
        defer { retryingQuietly = false }
        for failedSend in failedSends {
            // Discarded or retried by hand while an earlier one was going.
            guard failedSends.contains(where: { $0.id == failedSend.id }) else { continue }
            failedSends.removeAll { $0.id == failedSend.id }
            await commit(failedSend.draft, thread: resolveThread(for: failedSend.draft), id: failedSend.id,
                         checkForExistingSendFirst: true, quietly: true)
        }
    }

    /// A send that failed after you'd left Corres: said in a notification,
    /// since there's no banner to see.
    /// Set by the app as it leaves the screen and comes back (the
    /// extensions that share this file can't ask).
    static var isAway = false

    private func tellIfAway(_ draft: Draft) {
        guard Self.isAway else { return }
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Couldn't send")
        content.body = String(localized: "\u{201C}\(draft.subject)\u{201D} is waiting in Corres. It goes as soon as you're back online, or open Corres to try again.")
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "corres.sendFailed." + UUID().uuidString, content: content, trigger: nil))
    }

    private func markFailed(_ id: UUID, _ draft: Draft) {
        failedSends.removeAll { $0.id == id }
        failedSends.append(FailedSend(id: id, draft: draft))
    }

    /// `thread` is the conversation being replied to or forwarded, when
    /// there is one; nil for a brand-new, from-scratch compose. Both send
    /// via Gmail when an account is connected (a new compose has no
    /// existing thread to join, so it's simply sent without a `threadId`
    /// or In-Reply-To/References; Gmail assigns it a fresh one).
    /// Straight out, no Undo window, awaited to the end: a reply typed in a
    /// notification, where iOS gives Corres only seconds in the background.
    /// Still through the durable outbox, so a lost connection retries.
    ///
    /// `asEarlierAttempt`: this draft may have been tried before under its
    /// own id (the Share sheet, before it lost its connection), so it keeps
    /// that Message-ID and Gmail is asked first, and it never goes twice.
    func sendNow(_ draft: Draft, replyingTo thread: Correspondence?, asEarlierAttempt: Bool = false) async {
        let draft = Self.keepingReplyHeaders(draft, thread: thread)
        let id = asEarlierAttempt ? draft.id : UUID()
        try? await repository.saveOutboxEntry(OutboxRecord(id: id, draft: draft, status: .pending))
        await commit(draft, thread: thread, id: id, checkForExistingSendFirst: asEarlierAttempt)
    }

    /// `reusing`: a retry keeps the failed entry's id, and so its
    /// Message-ID, so a first attempt that did reach the server is found
    /// rather than sent again.
    func queueSend(_ draft: Draft, replyingTo thread: Correspondence?, reusing earlierID: UUID? = nil) {
        // Saved with the reply's headers, so a retry or a resume after a
        // restart still threads it, found or not.
        let draft = Self.keepingReplyHeaders(draft, thread: thread)
        // Compose is modal, so only one send is ever mid-undo-window at a
        // time; if a second arrives anyway, the first has already had its
        // chance to be undone and commits for real right now.
        if let previousTask = task, let previousDraft = queuedDraft, let previousID = pending?.id {
            previousTask.cancel()
            let previousThread = queuedThread
            Task { await self.commit(previousDraft, thread: previousThread, id: previousID) }
        }
        let id = earlierID ?? UUID()
        let checkFirst = earlierID != nil
        // Undo Send off: straight out, still through the durable outbox.
        guard Self.undoWindowSeconds > 0 else {
            Task {
                try? await repository.saveOutboxEntry(OutboxRecord(id: id, draft: draft, status: .pending))
                await self.commit(draft, thread: thread, id: id, checkForExistingSendFirst: checkFirst)
            }
            return
        }
        queuedDraft = draft
        queuedThread = thread
        pending = Pending(id: id, subjectPreview: draft.subject, secondsRemaining: Self.undoWindowSeconds)
        Assistive.announce(String(localized: "Sending. Undo available."))
        Task { try? await repository.saveOutboxEntry(OutboxRecord(id: id, draft: draft, status: .pending)) }
        task = Task { [weak self] in
            guard let self else { return }
            for remaining in stride(from: Self.undoWindowSeconds, through: 1, by: -1) {
                if Task.isCancelled { return }
                self.pending?.secondsRemaining = remaining
                try? await Task.sleep(for: .seconds(1))
            }
            if Task.isCancelled { return }
            self.task = nil
            await self.commit(draft, thread: thread, id: id, checkForExistingSendFirst: checkFirst)
        }
    }

    /// Cancels the pending send: nothing is sent, and the email is put
    /// aside (the pill) to open again and change, as Gmail and Mail bring
    /// it back. It used to be lost.
    func undo() {
        guard let currentPending = pending else { return }
        let draft = queuedDraft
        let thread = queuedThread
        task?.cancel()
        task = nil
        pending = nil
        queuedDraft = nil
        queuedThread = nil
        let id = currentPending.id
        Task { try? await repository.removeOutboxEntry(id: id) }
        if let draft { shelve(draft, replyingTo: thread) }
    }

    func waitForAccounts() async { await auth.waitUntilRestored() }

    /// Leaving Corres while Undo counts down: it goes now. Leaving means you
    /// meant it, and iOS would otherwise pause the countdown, and the email
    /// with it, until Corres was opened again.
    func sendPendingNow() async {
        guard let current = pending, let draft = queuedDraft else { return }
        let thread = queuedThread
        task?.cancel()
        task = nil
        await commit(draft, thread: thread, id: current.id)
    }

    /// The account was removed: its unsent and failed emails go with it,
    /// rather than being sent if it's ever added back.
    func forget(account: String) {
        var gone = failedSends.filter { ($0.draft.fromAccount ?? $0.draft.threadID?.account) == account }.map(\.id)
        failedSends.removeAll { gone.contains($0.id) }
        // Still counting down for Undo: stopped, or it would go out from
        // an account that's gone, fail, and come back every launch.
        if let current = pending, let draft = queuedDraft, (draft.fromAccount ?? draft.threadID?.account) == account {
            task?.cancel()
            task = nil
            pending = nil
            queuedDraft = nil
            queuedThread = nil
            gone.append(current.id)
        }
        Task {
            // And any still saved as unsent (Corres closed mid-send), which
            // the next launch would otherwise try, fail and show again.
            let saved = (try? await repository.outboxEntries()) ?? []
            let unsent = saved.filter { ($0.draft.fromAccount ?? $0.draft.threadID?.account) == account }.map(\.id)
            for id in Set(gone + unsent) { try? await repository.removeOutboxEntry(id: id) }
        }
    }

    /// The one the banner shows went to the mail server and no answer came
    /// back, so it may have gone: Retry says so before sending it again.
    var failedMayHaveSent: Bool {
        guard let failed, let account = resolveSendingAccount(draft: failed.draft, thread: resolveThread(for: failed.draft)) else { return false }
        return client.mayHaveSent(rfc822MessageID: Self.rfc822MessageID(for: failed.id), account: account)
    }

    func retryFailed() {
        guard let failed, !committing.contains(failed.id) else { return }
        failedSends.removeFirst()
        let thread = resolveThread(for: failed.draft)
        // Retry by hand is your choice to send it again, even one the mail
        // server never said it took. The quiet retries never do that.
        if let account = resolveSendingAccount(draft: failed.draft, thread: thread) {
            client.allowSendingAgain(rfc822MessageID: Self.rfc822MessageID(for: failed.id), account: account)
        }
        queueSend(failed.draft, replyingTo: thread, reusing: failed.id)
    }

    func discardFailed() {
        guard let failed, !committing.contains(failed.id) else { return }
        failedSends.removeFirst()
        let id = failed.id
        Task { try? await repository.removeOutboxEntry(id: id) }
    }

    private func commit(_ draft: Draft, thread: Correspondence?, id: UUID, checkForExistingSendFirst: Bool = false, quietly: Bool = false) async {
        guard committing.insert(id).inserted else { return }
        // Time to finish if Corres is left mid-send: without it iOS paused
        // the send until Corres was next opened, a day later for some.
        let work = BackgroundWork.begin("Sending")
        defer { committing.remove(id); work.end() }
        if pending?.id == id {
            // A countdown still running for it (a retry by hand) stops; the
            // countdown that ended clears itself before it gets here.
            task?.cancel()
            task = nil
            pending = nil
            queuedDraft = nil
            queuedThread = nil
        }
        // A cold launch (a scheduled send, a Watch reply) can get here
        // before the accounts are back.
        await auth.waitUntilRestored()
        var realThreadID: ThreadID?
        // From a real account: it goes out or stays as a failed send, never
        // recorded as sent on this device alone.
        let isReal = (draft.fromAccount ?? draft.threadID?.account).map { $0 != Self.sampleAccount } ?? false
        let sendingAccount = shouldSendViaGmail(thread: thread) ? resolveSendingAccount(draft: draft, thread: thread) : nil
        if isReal, sendingAccount == nil {
            Logger(subsystem: "studio.anwarcreative.corres", category: "outbox")
                .error("Send failed: no connected account to send from")
            markFailed(id, draft)
            if !quietly {
                Assistive.announce(String(localized: "Couldn't send \u{201C}\(draft.subject)\u{201D}. Retry or Discard."))
                tellIfAway(draft)
            }
            try? await repository.saveOutboxEntry(OutboxRecord(id: id, draft: draft, status: .failed))
            return
        }
        if let account = sendingAccount {
            do {
                // An earlier attempt may have gone. A check that couldn't be
                // made isn't "not sent": it throws, and the email stays
                // failed rather than risk going twice.
                if checkForExistingSendFirst,
                   let existing = try await client.findMessage(rfc822MessageID: Self.rfc822MessageID(for: id), account: account) {
                    realThreadID = existing
                } else {
                    realThreadID = try await sendViaGmailWithRetry(draft: draft, thread: thread, account: account, id: id)
                }
            } catch {
                // Why it failed, for Console: the banner only says it did.
                Logger(subsystem: "studio.anwarcreative.corres", category: "outbox")
                    .error("Send failed: \(String(describing: error), privacy: .public)")
                markFailed(id, draft)
                if !quietly {
                Assistive.announce(String(localized: "Couldn't send \u{201C}\(draft.subject)\u{201D}. Retry or Discard."))
                tellIfAway(draft)
            }
                try? await repository.saveOutboxEntry(OutboxRecord(id: id, draft: draft, status: .failed))
                return
            }
            // Gone out: the entry goes now, before the follow-up work
            // below, so the app ending here can't lead to a second send.
            try? await repository.removeOutboxEntry(id: id)
        }
        // A new conversation is recorded as Gmail's own copy of what was
        // sent: the real sender, recipients and message id (see
        // `Correspondence.started`).
        var sentCopy: Correspondence?
        let isPlaceholder = realThreadID?.providerID.hasPrefix("outlook-sent-") == true
        if thread == nil, let realThreadID, !isPlaceholder,
           let messages = try? await client.fetchThreadMessages(threadId: realThreadID.providerID, account: realThreadID.account) {
            sentCopy = Correspondence.sentCopy(in: messages, messageID: Self.rfc822MessageID(for: id))
        }
        // A stand-in keeps the Message-ID it went with, so a sync can find
        // the real copy and swap it in, even if Corres quits before the
        // swap below (`GmailSyncService.repairSentPlaceholders`).
        if thread == nil, let realThreadID, isPlaceholder {
            sentCopy = Correspondence.started(by: draft, id: realThreadID, sentAt: .now, sentCopy: nil, attention: .quiet, reason: "",
                                              messageIdHeader: Self.rfc822MessageID(for: id))
        }
        await store.send(draft, realThreadID: realThreadID, sentCopy: sentCopy)
        // Outlook hadn't filed it yet when asked: a stand-in row holds its
        // place, swapped for the real conversation once it's there, or
        // the next sync would add that as a second row.
        if let realThreadID, isPlaceholder {
            let messageID = Self.rfc822MessageID(for: id)
            Task { await self.replacePlaceholder(realThreadID, messageID: messageID) }
        }
        if let after = draft.followUpAfter, let threadID = realThreadID ?? thread?.id {
            let first = PeopleIndex.entries(in: draft.to).first.flatMap(PeopleIndex.parse)
            let recipient = first.map { $0.name.isEmpty ? $0.email : Person.readable($0.name) } ?? "them"
            FollowUps.shared.add(threadID, after: after, recipient: recipient, subject: draft.subject)
        }
        if realThreadID != nil, let thread, draft.kind == .reply || draft.kind == .replyAll {
            HabitWatcher.shared.replied(to: thread)
        }
        try? await repository.removeOutboxEntry(id: id)
        // Sent in place of a Gmail draft: the draft goes.
        if realThreadID != nil {
            await saving[draft.id]?.value
            saving[draft.id] = nil
            if let draftID = gmailDraftID(for: draft), let account = resolveSendingAccount(draft: draft, thread: thread) {
                gmailDraftIDs[draft.id] = nil
                try? await client.deleteDraft(id: draftID, account: account)
            }
        }
    }

    private func replacePlaceholder(_ placeholder: ThreadID, messageID: String) async {
        for delay in [8, 30, 120] {
            try? await Task.sleep(for: .seconds(delay))
            guard let real = try? await client.findMessage(rfc822MessageID: messageID, account: placeholder.account),
                  let messages = try? await client.fetchThreadMessages(threadId: real.providerID, account: real.account),
                  let sent = Correspondence.sentCopy(in: messages, messageID: messageID) else { continue }
            _ = try? await repository.upsert([sent], isInitialSync: true)
            await store.remove(placeholder)
            await store.refresh()
            return
        }
    }

    /// An IMAP conversation is known by its first message's Message-ID,
    /// which replies carry in References so they stay in it. Gmail and
    /// Outlook thread by their own ids.
    nonisolated private static func rootReference(of thread: Correspondence?) -> String? {
        guard let thread, MailAccounts.provider(for: thread.id.account).usesIMAP,
              !thread.id.providerID.hasPrefix("uid:") else { return nil }
        return thread.id.providerID
    }

    /// Stable for the lifetime of one outbox entry — derived from its own
    /// `id`, not regenerated per attempt — so a retry, or a resume after a
    /// relaunch, is asking Gmail about the exact same `Message-ID` an
    /// earlier attempt for this same entry would have stamped on the
    /// message it sent, not a fresh one Gmail could never have seen before.
    nonisolated private static func rfc822MessageID(for id: UUID) -> String { "\(id.uuidString)@corres.app" }

    /// Re-derives the source thread from a persisted draft's `threadID`
    /// (the durable outbox only stores the `Draft`, not a `Correspondence`
    /// snapshot, since the thread it refers to is already the repository's
    /// own source of truth and could otherwise drift out of date between
    /// when it was queued and when it's resumed).
    /// Any conversation the store has (archived, or opened from a mailbox),
    /// not only those listed in Mail. Not found, the draft's own reply
    /// headers still thread it (`keepingReplyHeaders`).
    private func resolveThread(for draft: Draft) -> Correspondence? {
        draft.threadID.flatMap { store.thread($0) }
    }

    /// The reply's In-Reply-To and References, taken from the thread while
    /// it's to hand (its latest message) and kept on the draft.
    nonisolated static func keepingReplyHeaders(_ draft: Draft, thread: Correspondence?) -> Draft {
        guard let thread else { return draft }
        var draft = draft
        if let header = thread.messageIdHeader { draft.inReplyTo = header }
        if let root = rootReference(of: thread) { draft.rootReference = root }
        return draft
    }

    /// The conversation to send into: the thread's, or, when it couldn't
    /// be found, the one the draft was written in, on the same account.
    nonisolated private static func threadProviderID(_ draft: Draft, thread: Correspondence?, account: String) -> String? {
        if let thread { return thread.id.providerID }
        guard draft.kind != .new, let id = draft.threadID, id.account == account else { return nil }
        return id.providerID
    }

    /// A reply/forward to a real (non-sample) thread always sends via Gmail
    /// when connected. A brand-new compose (no thread) also sends via Gmail
    /// whenever an account is connected: there is no local-only reason to
    /// hold it back now that a fresh message has somewhere real to go.
    private func shouldSendViaGmail(thread: Correspondence?) -> Bool {
        if let thread { return thread.id.account != Self.sampleAccount }
        return !auth.accounts.isEmpty
    }

    /// A reply/forward always sends as the thread's own account, regardless
    /// of `draft.fromAccount` (which only ever matters for a brand-new
    /// compose): joining an existing Gmail thread as a different account
    /// than the one that received it isn't a real option. A brand-new
    /// compose uses whichever account was actually chosen in ComposeView's
    /// "From" picker (`draft.fromAccount`), falling back to the first
    /// connected account for anyone with just one, where there was never a
    /// picker to begin with.
    /// Who it's from: the send-as address picked in Compose (or the
    /// account's own), with its Gmail display name.
    private func fromHeader(_ draft: Draft, account: String) -> String {
        let directory = SendAsDirectory.shared
        let address = draft.fromAddress ?? account
        // Settings → the account → Your Name, for the account's own address.
        let ownName = address.lowercased() == account.lowercased() ? AccountPreferences.senderName(for: account) : nil
        var name = draft.fromName ?? ownName ?? directory.addresses(for: account).first { $0.email == address.lowercased() }?.name ?? ""
        // An account with no name of its own (iCloud gives apps none) goes
        // out under the name you use on your others, not a bare address.
        if name.isEmpty {
            name = auth.profile(for: account)?.name
                ?? auth.accounts.lazy.compactMap { AccountPreferences.senderName(for: $0.email) ?? self.auth.profile(for: $0.email)?.name }.first
                ?? ""
        }
        guard !name.isEmpty else { return address }
        return "\(name) <\(address)>"
    }

    private func resolveSendingAccount(draft: Draft, thread: Correspondence?) -> String? {
        if let thread, thread.id.account != Self.sampleAccount { return thread.id.account }
        return draft.fromAccount ?? auth.primaryAccount?.email
    }

    /// Retries only failures where the request almost certainly never
    /// completed on Gmail's side: a connection-level failure before any
    /// response arrived, or Gmail's own response explicitly saying "try
    /// again" (429, or a 5xx). Failing fast on anything Gmail has already
    /// processed and explicitly rejected (any other 4xx, where retrying
    /// only repeats the identical rejection) is still the right call.
    ///
    /// Gmail's send endpoint has no idempotency-key mechanism of its own,
    /// but a self-generated one does exist now: `GmailMessageComposer`
    /// stamps a stable `Message-ID` (`rfc822MessageID(for:)`, derived from
    /// this entry's own `id`) onto every attempt for the same outbox entry,
    /// and this now checks `GmailAPIClient.findMessage` for that exact id
    /// before actually retrying — if Gmail already has it, the earlier
    /// attempt's response was lost, not the send itself, and this returns
    /// that thread instead of sending a real duplicate. Not a platform
    /// guarantee the way a server-issued idempotency key would be (Gmail
    /// could theoretically be slow to index a just-sent message before the
    /// very next `findMessage` call runs), but a real, working mitigation
    /// for the exact class of failure this retry logic exists to handle,
    /// not just a bound on how many times it can go wrong.
    private func sendViaGmailWithRetry(draft: Draft, thread: Correspondence?, account: String, id: UUID) async throws -> ThreadID {
        var lastError: Error = GmailAPIClient.ClientError.badResponse(statusCode: -1)
        for attempt in 1...Self.maxSendAttempts {
            do {
                return try await sendViaGmail(draft: draft, thread: thread, account: account, id: id)
            } catch {
                lastError = error
                guard Self.isRetryable(error), attempt < Self.maxSendAttempts else { throw error }
                // Exponential backoff, plus jitter so a burst of sends that
                // all failed for the same reason (a brief outage) don't all
                // retry in lockstep and hit Gmail again at the exact same
                // moment.
                let backoffMs = Double(Self.baseBackoffMilliseconds) * pow(2, Double(attempt - 1))
                let jitterMs = Double.random(in: 0...(backoffMs * 0.5))
                try? await Task.sleep(for: .milliseconds(Int(backoffMs + jitterMs)))
                // `isRetryable` only admits failures where the request may
                // never have reached Gmail at all *or* Gmail's response
                // itself was lost after accepting it — genuinely ambiguous,
                // not "definitely failed." Checking here, before blindly
                // retrying, is what tells those two apart: if Gmail already
                // has a message with this exact attempt's Message-ID, the
                // earlier try actually landed and this returns its thread
                // instead of sending a real duplicate.
                // Asked after the wait, just before sending again: asked
                // the moment the try failed, a server still finishing it
                // (Outlook after a 504, Gmail's search catching up) said
                // "not here", and the wait then ended in a second send.
                // A check that fails is no answer: the earlier try may have
                // gone, so it stays failed instead of going again.
                let existing: ThreadID?
                do {
                    existing = try await client.findMessage(rfc822MessageID: Self.rfc822MessageID(for: id), account: account)
                } catch {
                    throw lastError
                }
                if let existing { return existing }
            }
        }
        throw lastError
    }

    private static func isRetryable(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut, .cannotConnectToHost, .networkConnectionLost,
                 .notConnectedToInternet, .dnsLookupFailed, .cannotFindHost,
                 .dataNotAllowed, .internationalRoamingOff:
                return true
            default:
                return false
            }
        }
        if case GmailAPIClient.ClientError.badResponse(let statusCode) = error {
            return statusCode == 429 || (500...599).contains(statusCode)
        }
        return false
    }

    /// Returns the real Gmail thread id the sent message belongs to (a
    /// freshly created one for a brand-new compose), so `commit` can file
    /// the local record under Gmail's actual identity instead of inventing
    /// one.
    private func sendViaGmail(draft: Draft, thread: Correspondence?, account: String, id: UUID) async throws -> ThreadID {
        guard auth.isConnected(account) else { throw GmailAPIClient.ClientError.notSignedIn }
        let from = fromHeader(draft, account: account)
        let draft = Self.keepingReplyHeaders(draft, thread: thread)
        let threadId = try await client.send(attachments: draft.attachments, threadId: Self.threadProviderID(draft, thread: thread, account: account),
                                             account: account) { withAttachments in
            GmailMessageComposer.compose(from: from, to: draft.to, cc: draft.cc, bcc: draft.bcc, subject: draft.subject,
                                         body: draft.body, inReplyTo: draft.inReplyTo, rootReference: draft.rootReference,
                                         messageID: Self.rfc822MessageID(for: id),
                                         attachments: withAttachments ? draft.attachments : [], html: draft.bodyHTML, calendar: draft.calendarReply)
        }
        return ThreadID(account: account, providerID: threadId)
    }
}
