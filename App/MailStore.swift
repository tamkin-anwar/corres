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

    /// Returns whether the send succeeded, so the compose sheet knows whether
    /// it is safe to dismiss. A failure never discards the draft.
    @discardableResult
    func send(_ draft: Draft) async -> Bool {
        guard !sending.contains(draft.id) else { return false }
        sending.insert(draft.id)
        defer { sending.remove(draft.id) }
        do {
            let updated = try await repository.send(draft, sentAt: .now)
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
