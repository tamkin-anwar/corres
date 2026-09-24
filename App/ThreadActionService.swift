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
            var labelIds = self.store.threads.first { $0.id == thread.id }?.labelIds ?? thread.labelIds
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
            try await gmailCall()
        } catch {
            errorMessage = failureMessage
            await revert()
        }
    }
}
