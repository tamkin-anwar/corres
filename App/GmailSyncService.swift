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
    /// Bumped whenever a sync pass pulls in data, from any entry point.
    /// `CorresApp` observes it to run on-device triage after *every* sync
    /// (pull-to-refresh, connecting an account), not just the launch and
    /// push paths that used to be the only ones calling it — new mail from
    /// a manual refresh otherwise sat untriaged until the next cold launch.
    private(set) var lastCompletedSync: Date?
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
        // Gmail's search endpoint is scoped to whichever account authorized
        // the call ("me"); reaching every connected account means one call
        // per account. Fired concurrently, not one after another: with more
        // than one connected account, waiting on each account's round trip
        // in turn means someone with three accounts waits three times as
        // long for a search that could otherwise finish in the time of the
        // slowest single account. `repository` is a `@ModelActor`, already
        // safe to call concurrently from multiple tasks (calls queue on the
        // actor rather than racing).
        return await withTaskGroup(of: Bool.self) { group in
            for account in accounts {
                group.addTask {
                    guard let matches = try? await self.client.searchMessages(query: trimmed, account: account), !matches.isEmpty else { return false }
                    let inserted = (try? await self.repository.upsert(matches, isInitialSync: false)) ?? 0
                    return inserted > 0
                }
            }
            var anyInserted = false
            for await inserted in group where inserted { anyInserted = true }
            return anyInserted
        }
    }

    private static let minSearchQueryLength = 3

    /// Syncs every connected account concurrently, not one after another:
    /// each account's sync is its own independent Gmail round trip (its own
    /// history cursor, its own `fetchMessages` call with its own bounded
    /// concurrency pool), so waiting on them in turn meant someone with
    /// three connected accounts waited three times as long as someone with
    /// one for a pull-to-refresh or a launch sync to finish, for no real
    /// reason. `isSyncing` still guards the whole pass as a single unit
    /// (never overlapping a second `syncAll`/`syncIfConnected` call while
    /// one is already running), matching the old single-account behavior;
    /// only what happens *inside* one pass changed. `repository` is a
    /// `@ModelActor`: concurrent `upsert` calls from different accounts
    /// queue on it safely rather than racing. Returns whether any account
    /// actually pulled in new data.
    @discardableResult
    func syncAll(accounts: [String]) async -> Bool {
        guard !accounts.isEmpty, !isSyncing else { return false }
        isSyncing = true
        defer { isSyncing = false }
        let anySucceeded = await withTaskGroup(of: Bool.self) { group in
            for account in accounts {
                group.addTask { await self.syncOneLocked(account: account) }
            }
            var anySucceeded = false
            for await succeeded in group where succeeded { anySucceeded = true }
            return anySucceeded
        }
        if anySucceeded { lastCompletedSync = .now }
        return anySucceeded
    }

    @discardableResult
    func syncIfConnected(account: String?) async -> Bool {
        guard let account, !account.isEmpty, !isSyncing else { return false }
        isSyncing = true
        defer { isSyncing = false }
        let succeeded = await syncOneLocked(account: account)
        if succeeded { lastCompletedSync = .now }
        return succeeded
    }

    /// Shared body for both entry points above; assumes `isSyncing` is
    /// already set by the caller (both callers above are the only ones
    /// allowed to set it, so this never double-guards or double-clears it).
    private func syncOneLocked(account: String) async -> Bool {
        do {
            let (result, isFullListing) = try await fetch(account: account)
            var items = result.items
            var stillMissing = Set(result.failedMessageIDs)

            // Ids a previous sync's own `failedMessageIDs` couldn't fetch,
            // retried here independent of the cursor/history window: by now
            // the cursor has already moved past the point where the
            // ordinary sync path above would ever offer them again (see
            // `SyncResult.failedMessageIDs`'s doc comment for why that
            // matters). This is what actually closes the loop rather than
            // just shrinking the window a single message can be lost in.
            let previouslyMissed = missedMessageIDs(for: account)
            if !previouslyMissed.isEmpty {
                if let retried = try? await client.fetchMessages(ids: previouslyMissed, account: account) {
                    items.append(contentsOf: retried.items)
                    stillMissing.formUnion(retried.failedIDs)
                } else {
                    // The retry call itself failed outright (e.g. a token
                    // refresh failure), not just individual messages within
                    // it — keep every previously-missed id exactly as
                    // missing as it already was, rather than assuming
                    // success or silently losing track of them.
                    stillMissing.formUnion(previouslyMissed)
                }
            }

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
            try await repository.upsert(items, isInitialSync: isFullListing)
            // After upsert, so a message that arrived and was then archived
            // elsewhere within the same window ends up removed, not re-added.
            try await repository.applyRemoteChanges(result.remoteChanges)
            if let historyId = result.historyId {
                setHistoryCursor(historyId, for: account)
            }
            setMissedMessageIDs(stillMissing, for: account)
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
        defaults.removeObject(forKey: Self.missedIDsKey(for: account))
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

    private func missedMessageIDs(for account: String) -> [String] {
        defaults.stringArray(forKey: Self.missedIDsKey(for: account)) ?? []
    }

    /// Bounded, not unlimited: a message that's still failing after many
    /// syncs in a row (a real Gmail-side 404, say — deleted before this
    /// ever managed to fetch it, not just unlucky timing) would otherwise
    /// be retried forever, at the cost of one wasted API call per sync
    /// indefinitely. `Set` has no defined iteration order, so this can't
    /// honestly claim to drop the *oldest* entries past the cap — only
    /// that the set never grows past a hard ceiling regardless of which
    /// ids that leaves in it; anything genuinely still recoverable
    /// succeeds within the first few retries anyway, well under this cap.
    private static let maxTrackedMissedIDs = 200

    private func setMissedMessageIDs(_ ids: Set<String>, for account: String) {
        let key = Self.missedIDsKey(for: account)
        guard !ids.isEmpty else {
            defaults.removeObject(forKey: key)
            return
        }
        defaults.set(Array(ids.prefix(Self.maxTrackedMissedIDs)), forKey: key)
    }

    private static func missedIDsKey(for account: String) -> String { "corres.gmail.missedMessageIDs.\(account)" }
}
