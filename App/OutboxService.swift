import Foundation
import Observation
import os

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
    private(set) var failed: FailedSend?

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
            guard let id = try? await client.saveDraft(attachments: draft.attachments, threadId: thread?.id.providerID,
                                                       existingID: existing, account: account, compose: { withAttachments in
                GmailMessageComposer.compose(from: from, to: draft.to, cc: draft.cc, bcc: draft.bcc, subject: draft.subject,
                                             body: draft.body, inReplyTo: thread?.messageIdHeader, rootReference: Self.rootReference(of: thread),
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
    }

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
                failed = FailedSend(id: entry.id, draft: entry.draft)
            }
        }
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
        let id = asEarlierAttempt ? draft.id : UUID()
        try? await repository.saveOutboxEntry(OutboxRecord(id: id, draft: draft, status: .pending))
        await commit(draft, thread: thread, id: id, checkForExistingSendFirst: asEarlierAttempt)
    }

    /// `reusing`: a retry keeps the failed entry's id, and so its
    /// Message-ID, so a first attempt that did reach the server is found
    /// rather than sent again.
    func queueSend(_ draft: Draft, replyingTo thread: Correspondence?, reusing earlierID: UUID? = nil) {
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
        Task { try? await repository.saveOutboxEntry(OutboxRecord(id: id, draft: draft, status: .pending)) }
        task = Task { [weak self] in
            guard let self else { return }
            for remaining in stride(from: Self.undoWindowSeconds, through: 1, by: -1) {
                if Task.isCancelled { return }
                self.pending?.secondsRemaining = remaining
                try? await Task.sleep(for: .seconds(1))
            }
            if Task.isCancelled { return }
            await self.commit(draft, thread: thread, id: id, checkForExistingSendFirst: checkFirst)
        }
    }

    /// Cancels the pending send entirely; nothing is sent, and the draft is
    /// gone, matching what "undo send" means everywhere else.
    func undo() {
        guard let currentPending = pending else { return }
        task?.cancel()
        task = nil
        pending = nil
        queuedDraft = nil
        queuedThread = nil
        let id = currentPending.id
        Task { try? await repository.removeOutboxEntry(id: id) }
    }

    func retryFailed() {
        guard let failed else { return }
        self.failed = nil
        queueSend(failed.draft, replyingTo: resolveThread(for: failed.draft), reusing: failed.id)
    }

    func discardFailed() {
        guard let failed else { return }
        self.failed = nil
        let id = failed.id
        Task { try? await repository.removeOutboxEntry(id: id) }
    }

    private func commit(_ draft: Draft, thread: Correspondence?, id: UUID, checkForExistingSendFirst: Bool = false) async {
        guard committing.insert(id).inserted else { return }
        defer { committing.remove(id) }
        if pending?.id == id {
            pending = nil
            queuedDraft = nil
            queuedThread = nil
        }
        var realThreadID: ThreadID?
        if shouldSendViaGmail(thread: thread), let account = resolveSendingAccount(draft: draft, thread: thread) {
            do {
                if checkForExistingSendFirst,
                   let existing = try? await client.findMessage(rfc822MessageID: Self.rfc822MessageID(for: id), account: account) {
                    realThreadID = existing
                } else {
                    realThreadID = try await sendViaGmailWithRetry(draft: draft, thread: thread, account: account, id: id)
                }
            } catch {
                // Why it failed, for Console: the banner only says it did.
                Logger(subsystem: "studio.anwarcreative.corres", category: "outbox")
                    .error("Send failed: \(String(describing: error), privacy: .public)")
                failed = FailedSend(id: id, draft: draft)
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
        if thread == nil, let realThreadID,
           let messages = try? await client.fetchThreadMessages(threadId: realThreadID.providerID, account: realThreadID.account) {
            sentCopy = messages.last { $0.isFromAccountOwner } ?? messages.last
        }
        await store.send(draft, realThreadID: realThreadID, sentCopy: sentCopy)
        // Outlook hadn't filed it yet when asked: a stand-in row holds its
        // place, swapped for the real conversation once it's there, or
        // the next sync would add that as a second row.
        if let realThreadID, realThreadID.providerID.hasPrefix("outlook-sent-") {
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
                  let sent = messages.last(where: \.isFromAccountOwner) ?? messages.last else { continue }
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
    private func resolveThread(for draft: Draft) -> Correspondence? {
        draft.threadID.flatMap { id in store.threads.first { $0.id == id } }
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
                // `isRetryable` only admits failures where the request may
                // never have reached Gmail at all *or* Gmail's response
                // itself was lost after accepting it — genuinely ambiguous,
                // not "definitely failed." Checking here, before blindly
                // retrying, is what tells those two apart: if Gmail already
                // has a message with this exact attempt's Message-ID, the
                // earlier try actually landed and this returns its thread
                // instead of sending a real duplicate.
                if let existing = try? await client.findMessage(rfc822MessageID: Self.rfc822MessageID(for: id), account: account) {
                    return existing
                }
                // Exponential backoff, plus jitter so a burst of sends that
                // all failed for the same reason (a brief outage) don't all
                // retry in lockstep and hit Gmail again at the exact same
                // moment.
                let backoffMs = Double(Self.baseBackoffMilliseconds) * pow(2, Double(attempt - 1))
                let jitterMs = Double.random(in: 0...(backoffMs * 0.5))
                try? await Task.sleep(for: .milliseconds(Int(backoffMs + jitterMs)))
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
        let threadId = try await client.send(attachments: draft.attachments, threadId: thread?.id.providerID, account: account) { withAttachments in
            GmailMessageComposer.compose(from: from, to: draft.to, cc: draft.cc, bcc: draft.bcc, subject: draft.subject,
                                         body: draft.body, inReplyTo: thread?.messageIdHeader, rootReference: Self.rootReference(of: thread),
                                         messageID: Self.rfc822MessageID(for: id),
                                         attachments: withAttachments ? draft.attachments : [], html: draft.bodyHTML, calendar: draft.calendarReply)
        }
        return ThreadID(account: account, providerID: threadId)
    }
}
