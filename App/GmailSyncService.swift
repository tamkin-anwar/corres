import Foundation
import Observation

/// Orchestrates a Gmail sync pass: fetch via GmailAPIClient, merge via the
/// repository's upsert. Deliberately does not touch MailStore directly;
/// callers reload MailStore themselves after a sync completes, keeping this
/// and MailStore decoupled and each independently testable.
///
/// The Gmail history cursor lives here, in UserDefaults, not in the SwiftData
/// schema: it is a Gmail-specific sync detail, and ADR 002 keeps provider
/// specifics out of the Core domain layer that MailRepository belongs to.
@MainActor @Observable
final class GmailSyncService {
    private let repository: any MailRepository
    private let client = GmailAPIClient()
    private let defaults = UserDefaults.standard
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
            let result = try await fetch(account: account)
            try await repository.upsert(result.items)
            if let historyId = result.historyId {
                setHistoryCursor(historyId, for: account)
            }
            return true
        } catch {
            errorMessage = "Could not sync Gmail. Please check your connection and try again."
            return false
        }
    }

    /// Forgets the stored cursor so the next connected account starts with a
    /// full sync rather than resuming a previous account's history.
    func clearCursor(for account: String?) {
        guard let account else { return }
        defaults.removeObject(forKey: Self.cursorKey(for: account))
    }

    private func fetch(account: String) async throws -> GmailAPIClient.SyncResult {
        guard let cursor = historyCursor(for: account) else {
            return try await client.fetchInitialInbox(account: account)
        }
        do {
            return try await client.fetchIncremental(account: account, since: cursor)
        } catch GmailAPIClient.ClientError.historyExpired {
            return try await client.fetchInitialInbox(account: account)
        }
    }

    private func historyCursor(for account: String) -> String? {
        defaults.string(forKey: Self.cursorKey(for: account))
    }

    private func setHistoryCursor(_ value: String, for account: String) {
        defaults.set(value, forKey: Self.cursorKey(for: account))
    }

    private static func cursorKey(for account: String) -> String { "corres.gmail.historyId.\(account)" }
}
