import Foundation
import Observation

@MainActor @Observable
final class MailStore {
    enum LoadState: Equatable { case idle, loading, loaded, failed }
    private(set) var threads: [Correspondence] = []
    private(set) var state = LoadState.idle
    private(set) var pending: Set<ThreadID> = []
    private(set) var sending: Set<UUID> = []
    var errorMessage: String?
    private let repository: any MailRepository

    init(repository: any MailRepository) { self.repository = repository }

    func load() async {
        guard state != .loading else { return }
        state = .loading
        do {
            try await repository.seedIfNeeded(now: .now)
            threads = try await repository.threads()
            state = .loaded
        } catch is CancellationError {
            state = .idle
        } catch {
            state = .failed
        }
    }

    func resetSampleData() async {
        do {
            try await repository.resetToSampleData(now: .now)
            threads = try await repository.threads()
        } catch {
            errorMessage = "Could not reset sample data. Please try again."
        }
    }

    func update(_ id: ThreadID, to attention: Attention) async {
        await mutate(id) { try await self.repository.setAttention(attention, for: id) }
    }

    func setPinned(_ isPinned: Bool, for id: ThreadID) async {
        await mutate(id) { try await self.repository.setPinned(isPinned, for: id) }
    }

    func snooze(_ id: ThreadID, until: Date?) async {
        await mutate(id) { try await self.repository.snooze(id, until: until) }
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

    private func setSenderDecision(_ decision: SenderDecision, senderEmail: String, account: String) async {
        do {
            try await repository.setSenderDecision(decision, forSenderEmail: senderEmail, account: account)
            threads = try await repository.threads()
        } catch {
            errorMessage = "Could not update this sender. Please try again."
        }
    }

    /// Returns whether the send succeeded. `realThreadID` is the real Gmail
    /// identity OutboxService already established by actually sending via
    /// Gmail (nil when the draft stayed local-only); see MailRepository.send.
    @discardableResult
    func send(_ draft: Draft, realThreadID: ThreadID? = nil) async -> Bool {
        guard !sending.contains(draft.id) else { return false }
        sending.insert(draft.id)
        defer { sending.remove(draft.id) }
        do {
            let updated = try await repository.send(draft, sentAt: .now, realThreadID: realThreadID)
            if let index = threads.firstIndex(where: { $0.id == updated.id }) {
                threads[index] = updated
            } else {
                threads.insert(updated, at: 0)
            }
            return true
        } catch {
            errorMessage = "Your message could not be sent. Nothing was sent. Please try again."
            return false
        }
    }

    private func mutate(_ id: ThreadID, _ operation: @escaping () async throws -> Void) async {
        guard !pending.contains(id) else { return }
        pending.insert(id)
        defer { pending.remove(id) }
        do {
            try await operation()
            threads = try await repository.threads()
        } catch {
            errorMessage = "The change could not be saved. Your conversation is unchanged. Please try again."
        }
    }
}
