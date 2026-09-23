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
    private(set) var isSearchingRemote = false
    var errorMessage: String?

    init(repository: any MailRepository) {
        self.repository = repository
    }

    /// Reaches past what's already synced locally (see
    /// `GmailAPIClient.searchMessages`'s doc comment) and merges any
    /// matches into the store via the same `upsert` every ordinary sync
    /// uses, so a found result is not just shown once and forgotten: it's
    /// now part of the account's local mail like anything else synced.
    /// Silent on failure, deliberately: a search that came up empty because
    /// of a network hiccup while the person was mid-keystroke does not
    /// deserve the same error banner a failed full sync does; whatever
    /// local results already existed remain valid regardless.
    /// Returns whether anything was actually merged in, so the caller only
    /// pays for refreshing `MailStore.threads` when there is something new
    /// to show.
    @discardableResult
    func search(_ query: String, accounts: [String]) async -> Bool {
        guard !accounts.isEmpty else { return false }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= Self.minSearchQueryLength else { return false }
        isSearchingRemote = true
        defer { isSearchingRemote = false }
        var anyInserted = false
        // Gmail's search endpoint is scoped to whichever account authorized
        // the call ("me"); reaching every connected account means one call
        // per account, merged into the same local store the same way an
        // ordinary sync would.
        for account in accounts {
            guard let matches = try? await client.searchMessages(query: trimmed, account: account), !matches.isEmpty else { continue }
            let inserted = (try? await repository.upsert(matches, isInitialSync: false)) ?? 0
            anyInserted = anyInserted || inserted > 0
        }
        return anyInserted
    }

    private static let minSearchQueryLength = 3

    /// Syncs every connected account, one after another (not concurrently:
    /// `isSyncing` guards the whole pass, matching the old single-account
    /// behavior of never overlapping two syncs). Returns whether any account
    /// actually pulled in new data, the same signal `syncOne` already gave
    /// for a single account.
    @discardableResult
    func syncAll(accounts: [String]) async -> Bool {
        guard !accounts.isEmpty, !isSyncing else { return false }
        isSyncing = true
        defer { isSyncing = false }
        var anySucceeded = false
        for account in accounts {
            if await syncOneLocked(account: account) { anySucceeded = true }
        }
        return anySucceeded
    }

    @discardableResult
    func syncIfConnected(account: String?) async -> Bool {
        guard let account, !account.isEmpty, !isSyncing else { return false }
        isSyncing = true
        defer { isSyncing = false }
        return await syncOneLocked(account: account)
    }

    /// Shared body for both entry points above; assumes `isSyncing` is
    /// already set by the caller (both callers above are the only ones
    /// allowed to set it, so this never double-guards or double-clears it).
    private func syncOneLocked(account: String) async -> Bool {
        do {
            let (result, isFullListing) = try await fetch(account: account)
            // Deliberately ordered, not merely convenient: upsert (SwiftData)
            // and the cursor write (UserDefaults) are two different stores
            // and can't share one real transaction without moving the
            // cursor into SwiftData, reversing ADR 005's choice to keep
            // Gmail sync mechanics out of the Core domain schema. Writing
            // the cursor first would risk real data loss if the app died
            // before upsert ran: the next sync would start from the
            // advanced cursor and never re-fetch the messages that were
            // never actually saved. Writing it after, as here, only risks
            // redundant work (re-fetching and re-upserting messages that
            // already made it in, which upsert already treats as a no-op)
            // if the app dies between the two, never data loss.
            try await repository.upsert(result.items, isInitialSync: isFullListing)
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

    /// The second value is true whenever this fetch was a full inbox
    /// listing, whether because it's the account's first ever sync or
    /// because a stored cursor expired and forced a resync, both the
    /// Screener's baseline case: every sender already in the inbox is
    /// established relationship, not a new arrival to be screened.
    private func fetch(account: String) async throws -> (result: GmailAPIClient.SyncResult, isFullListing: Bool) {
        guard let cursor = historyCursor(for: account) else {
            return (try await client.fetchInitialInbox(account: account), true)
        }
        do {
            return (try await client.fetchIncremental(account: account, since: cursor), false)
        } catch GmailAPIClient.ClientError.historyExpired {
            return (try await client.fetchInitialInbox(account: account), true)
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
