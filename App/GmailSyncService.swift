import Foundation
import Observation

/// Orchestrates a Gmail sync pass: fetch via GmailAPIClient, merge via the
/// repository's upsert. Deliberately does not touch MailStore directly;
/// callers reload MailStore themselves after a sync completes, keeping this
/// and MailStore decoupled and each independently testable.
@MainActor @Observable
final class GmailSyncService {
    private let repository: any MailRepository
    private let client = GmailAPIClient()
    private(set) var isSyncing = false
    var errorMessage: String?

    init(repository: any MailRepository) {
        self.repository = repository
    }

    @discardableResult
    func syncIfConnected(account: String?) async -> Bool {
        guard let account, !account.isEmpty, !isSyncing else { return false }
        isSyncing = true
        defer { isSyncing = false }
        do {
            let fetched = try await client.fetchRecentInbox(account: account)
            try await repository.upsert(fetched)
            return true
        } catch {
            errorMessage = "Could not sync Gmail. Please check your connection and try again."
            return false
        }
    }
}
