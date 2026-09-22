import Foundation
import Observation

/// Makes Send feel instant: ComposeView dismisses the moment the button is
/// tapped, and the actual work (a real Gmail send, when replying/forwarding
/// a connected real thread, plus local bookkeeping either way) happens after
/// a short undo window, matching the pattern real premium mail clients use
/// (queue, don't block; offer undo instead of a confirmation prompt).
///
/// A real Gmail send is attempted before any local state changes, not after:
/// if it fails, nothing here claims the message went out. `failed` surfaces
/// that so the person can retry or give up on it, rather than the thread
/// silently sitting in "Waiting" for a reply that was never actually sent.
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
        let thread: Correspondence?
    }

    private(set) var pending: Pending?
    private(set) var failed: FailedSend?

    private let store: MailStore
    private let auth: GoogleAuthService
    private let client = GmailAPIClient()
    private var task: Task<Void, Never>?

    private static let undoWindowSeconds = 6
    private static let sampleAccount = "sample"

    init(store: MailStore, auth: GoogleAuthService) {
        self.store = store
        self.auth = auth
    }

    /// `thread` is the conversation being replied to or forwarded, when
    /// there is one; nil for a brand-new, from-scratch compose, which stays
    /// local-only for now (see ADR 005 — sending a genuinely new message,
    /// not part of any existing Gmail thread, is not yet implemented).
    func queueSend(_ draft: Draft, replyingTo thread: Correspondence?) {
        // Compose is modal, so only one send is ever mid-undo-window at a
        // time; if a second arrives anyway, the first has already had its
        // chance to be undone and commits immediately rather than being lost.
        if let previous = task {
            previous.cancel()
        }
        let id = UUID()
        pending = Pending(id: id, subjectPreview: draft.subject, secondsRemaining: Self.undoWindowSeconds)
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
        guard pending != nil else { return }
        task?.cancel()
        task = nil
        pending = nil
    }

    func retryFailed() {
        guard let failed else { return }
        self.failed = nil
        queueSend(failed.draft, replyingTo: failed.thread)
    }

    func discardFailed() {
        failed = nil
    }

    private func commit(_ draft: Draft, thread: Correspondence?, id: UUID) async {
        guard pending?.id == id else { return }
        pending = nil
        if let thread, thread.id.account != Self.sampleAccount, let account = auth.account?.email {
            do {
                try await sendViaGmail(draft: draft, thread: thread, account: account)
            } catch {
                failed = FailedSend(id: id, draft: draft, thread: thread)
                return
            }
        }
        await store.send(draft)
    }

    private func sendViaGmail(draft: Draft, thread: Correspondence, account: String) async throws {
        guard await auth.ensureSendScope() else { throw GmailAPIClient.ClientError.notSignedIn }
        let raw = GmailMessageComposer.compose(from: account, to: draft.to, subject: draft.subject,
                                                body: draft.body, inReplyTo: thread.messageIdHeader)
        try await client.send(raw: raw, threadId: thread.id.providerID)
    }
}
