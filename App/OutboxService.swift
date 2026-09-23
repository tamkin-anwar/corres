import Foundation
import Observation

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

    private let store: MailStore
    private let auth: GoogleAuthService
    private let repository: any MailRepository
    private let client = GmailAPIClient()
    private var task: Task<Void, Never>?
    /// The draft/thread behind the current `pending`, kept alongside it so a
    /// second `queueSend` while one is still mid-undo-window can commit the
    /// first for real (matching "the first has already had its chance to be
    /// undone") instead of just cancelling its timer and losing it, which is
    /// what merely cancelling the Task alone would otherwise do.
    private var queuedDraft: Draft?
    private var queuedThread: Correspondence?

    private static let undoWindowSeconds = 6
    private static let sampleAccount = "sample"
    /// Bounded, not unlimited: a flaky connection gets three real chances
    /// before the person sees a failure, not an endless silent retry loop.
    private static let maxSendAttempts = 3
    private static let baseBackoffMilliseconds = 2000

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
            switch entry.status {
            case .pending:
                await commit(entry.draft, thread: resolveThread(for: entry.draft), id: entry.id)
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
    func queueSend(_ draft: Draft, replyingTo thread: Correspondence?) {
        // Compose is modal, so only one send is ever mid-undo-window at a
        // time; if a second arrives anyway, the first has already had its
        // chance to be undone and commits for real right now.
        if let previousTask = task, let previousDraft = queuedDraft, let previousID = pending?.id {
            previousTask.cancel()
            let previousThread = queuedThread
            Task { await self.commit(previousDraft, thread: previousThread, id: previousID) }
        }
        let id = UUID()
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
            await self.commit(draft, thread: thread, id: id)
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
        queueSend(failed.draft, replyingTo: resolveThread(for: failed.draft))
    }

    func discardFailed() {
        guard let failed else { return }
        self.failed = nil
        let id = failed.id
        Task { try? await repository.removeOutboxEntry(id: id) }
    }

    private func commit(_ draft: Draft, thread: Correspondence?, id: UUID) async {
        if pending?.id == id {
            pending = nil
            queuedDraft = nil
            queuedThread = nil
        }
        var realThreadID: ThreadID?
        if shouldSendViaGmail(thread: thread), let account = auth.account?.email {
            do {
                realThreadID = try await sendViaGmailWithRetry(draft: draft, thread: thread, account: account)
            } catch {
                failed = FailedSend(id: id, draft: draft)
                try? await repository.saveOutboxEntry(OutboxRecord(id: id, draft: draft, status: .failed))
                return
            }
        }
        await store.send(draft, realThreadID: realThreadID)
        try? await repository.removeOutboxEntry(id: id)
    }

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
        return auth.account != nil
    }

    /// Retries only failures where the request almost certainly never
    /// completed on Gmail's side: a connection-level failure before any
    /// response arrived, or Gmail's own response explicitly saying "try
    /// again" (429, or a 5xx). Gmail's send endpoint has no idempotency-key
    /// mechanism of its own, so there is no way to guarantee a retry can
    /// never double-send; restricting retries to genuinely
    /// ambiguous-or-transient failures, and failing fast on anything Gmail
    /// has already processed and explicitly rejected (any other 4xx,
    /// where retrying only repeats the identical rejection), is the
    /// honest, bounded version of safety actually available here, not a
    /// claim of true exactly-once delivery.
    private func sendViaGmailWithRetry(draft: Draft, thread: Correspondence?, account: String) async throws -> ThreadID {
        var lastError: Error = GmailAPIClient.ClientError.badResponse(statusCode: -1)
        for attempt in 1...Self.maxSendAttempts {
            do {
                return try await sendViaGmail(draft: draft, thread: thread, account: account)
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
    private func sendViaGmail(draft: Draft, thread: Correspondence?, account: String) async throws -> ThreadID {
        guard await auth.ensureSendScope() else { throw GmailAPIClient.ClientError.notSignedIn }
        let raw = GmailMessageComposer.compose(from: account, to: draft.to, subject: draft.subject,
                                                body: draft.body, inReplyTo: thread?.messageIdHeader,
                                                attachments: draft.attachments)
        let threadId = try await client.send(raw: raw, threadId: thread?.id.providerID)
        return ThreadID(account: account, providerID: threadId)
    }
}
