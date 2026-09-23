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

    func archive(_ thread: Correspondence) async {
        await perform(thread, failureMessage: "Could not archive this conversation. Please try again.", gmailCall: {
            try await self.client.modifyThread(threadId: thread.id.providerID, removeLabelIds: ["INBOX"], account: thread.id.account)
        }, local: { await self.store.remove(thread.id) })
    }

    func trash(_ thread: Correspondence) async {
        await perform(thread, failureMessage: "Could not move this conversation to Trash. Please try again.", gmailCall: {
            try await self.client.trashThread(threadId: thread.id.providerID, account: thread.id.account)
        }, local: { await self.store.remove(thread.id) })
    }

    /// Orthogonal to Archive/Trash: this never removes the thread, only
    /// flips `Correspondence.isUnread` (see its doc comment). Same
    /// Gmail-call-before-local-change shape either way, via the shared
    /// `UNREAD` label `modifyThread` already supports.
    func setUnread(_ isUnread: Bool, for thread: Correspondence) async {
        let failureMessage = "Could not mark this conversation as \(isUnread ? "unread" : "read"). Please try again."
        await perform(thread, failureMessage: failureMessage, gmailCall: {
            if isUnread {
                try await self.client.modifyThread(threadId: thread.id.providerID, addLabelIds: ["UNREAD"], account: thread.id.account)
            } else {
                try await self.client.modifyThread(threadId: thread.id.providerID, removeLabelIds: ["UNREAD"], account: thread.id.account)
            }
        }, local: { await self.store.setUnread(isUnread, for: thread.id) })
    }

    /// Adds or removes a single real Gmail label (from `LabelDirectory`),
    /// same Gmail-call-then-local-change shape as everything else here.
    /// `local` recomputes the thread's full label set from what's already
    /// known rather than trusting a stale copy from before the Gmail call,
    /// since another toggle could have raced ahead of this one locally.
    func toggleLabel(_ labelId: String, isOn: Bool, for thread: Correspondence) async {
        let failureMessage = "Could not update this label. Please try again."
        await perform(thread, failureMessage: failureMessage, gmailCall: {
            if isOn {
                try await self.client.modifyThread(threadId: thread.id.providerID, addLabelIds: [labelId], account: thread.id.account)
            } else {
                try await self.client.modifyThread(threadId: thread.id.providerID, removeLabelIds: [labelId], account: thread.id.account)
            }
        }, local: {
            var labelIds = self.store.threads.first { $0.id == thread.id }?.labelIds ?? thread.labelIds
            if isOn {
                if !labelIds.contains(labelId) { labelIds.append(labelId) }
            } else {
                labelIds.removeAll { $0 == labelId }
            }
            await self.store.setLabelIds(labelIds, for: thread.id)
        })
    }

    private func perform(_ thread: Correspondence, failureMessage: String,
                         gmailCall: () async throws -> Void, local: () async -> Void) async {
        if thread.id.account != Self.sampleAccount {
            guard auth.isConnected(thread.id.account) else {
                errorMessage = failureMessage
                return
            }
            do {
                try await gmailCall()
            } catch {
                errorMessage = failureMessage
                return
            }
        }
        await local()
    }
}
