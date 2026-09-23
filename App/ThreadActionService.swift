import Foundation
import Observation

/// Archive and Trash: the two most basic "make this go away" actions any
/// mail client needs, and until now Corres had neither, one of the biggest
/// real gaps between it and an actual daily-driver premium mail app. Same
/// shape as `OutboxService`: a real Gmail call is attempted first for any
/// non-sample thread, and only on success does the thread disappear locally.
/// If the Gmail call fails, nothing here claims the conversation was
/// archived or trashed, the same "network before any local state changes"
/// rule `OutboxService` already follows for sending.
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
        await perform(thread, failureMessage: "Could not archive this conversation. Please try again.") {
            try await self.client.modifyThread(threadId: thread.id.providerID, removeLabelIds: ["INBOX"])
        }
    }

    func trash(_ thread: Correspondence) async {
        await perform(thread, failureMessage: "Could not move this conversation to Trash. Please try again.") {
            try await self.client.trashThread(threadId: thread.id.providerID)
        }
    }

    private func perform(_ thread: Correspondence, failureMessage: String, gmailCall: () async throws -> Void) async {
        if thread.id.account != Self.sampleAccount {
            guard await auth.ensureModifyScope() else {
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
        await store.remove(thread.id)
    }
}
