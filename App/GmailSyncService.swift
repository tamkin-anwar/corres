import Foundation
import os
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
    private let client = MailClient()
    private let defaults = UserDefaults.standard
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
                    // Approved, not screened: these are older messages you
                    // went looking for, not someone writing to you for the
                    // first time.
                    let inserted = (try? await self.repository.upsert(matches, isInitialSync: true)) ?? 0
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
    /// reason. Each account still runs one pass at a time (see
    /// `sync(account:)`). `repository` is a
    /// `@ModelActor`: concurrent `upsert` calls from different accounts
    /// queue on it safely rather than racing. Returns whether any account
    /// actually pulled in new data.
    @discardableResult
    func syncAll(accounts: [String]) async -> Bool {
        guard !accounts.isEmpty else { return false }
        let anySucceeded = await withTaskGroup(of: Bool.self) { group in
            for account in accounts {
                group.addTask { await self.sync(account: account) }
            }
            var anySucceeded = false
            for await succeeded in group where succeeded { anySucceeded = true }
            return anySucceeded
        }
        return anySucceeded
    }

    /// For a sync someone asked for (Sync Now): a failed attempt gets one
    /// more try before saying so.
    @discardableResult
    func syncNow(account: String) async -> Bool {
        if await sync(account: account) { return true }
        try? await Task.sleep(for: .seconds(1))
        return await sync(account: account)
    }

    func syncIfConnected(account: String?) async -> Bool {
        guard let account, !account.isEmpty else { return false }
        return await sync(account: account)
    }

    /// True while any account is syncing.
    var isSyncing: Bool { !running.isEmpty }

    /// One sync per account at a time. A caller arriving while one runs
    /// joins it, and one more pass follows, since the running pass may
    /// have read its cursor before whatever brought the caller here (a
    /// push for new mail, Sync Now). It used to return false instead,
    /// which dropped the push and made Sync Now say the server didn't
    /// answer. Unstructured, so leaving the app mid-command doesn't cancel
    /// a sync halfway through a server exchange.
    private var running: [String: Task<Bool, Never>] = [:]
    private var wantsAnotherPass: Set<String> = []

    private func sync(account: String) async -> Bool {
        if let current = running[account] {
            wantsAnotherPass.insert(account)
            return await current.value
        }
        let task = Task { @MainActor () -> Bool in
            var succeeded = await self.syncOneLocked(account: account)
            while self.wantsAnotherPass.remove(account) != nil {
                succeeded = await self.syncOneLocked(account: account) || succeeded
            }
            // No suspension between the last check above and this, so a
            // caller can't join a pass that has already finished.
            self.running[account] = nil
            // Removed while this ran: whatever it saved goes, and the flag
            // doesn't outlive it to trip up the account added back later.
            if self.retired.remove(account) != nil { self.dropCursor(for: account) }
            if succeeded { self.lastCompletedSync = .now }
            return succeeded
        }
        running[account] = task
        return await task.value
    }

    /// One pass for one account; `sync(account:)` makes sure only one runs
    /// per account at a time.
    ///
    /// Metadata first, newest first, in batches of `GmailAPIClient.batchSize`,
    /// each saved the moment it lands (`syncProgress` tells the UI to
    /// refresh): the first screenful appears after one round trip instead
    /// of after the whole listing, which on a first sync is the difference
    /// between about a second and the better part of a minute. Bodies are
    /// filled in afterwards by `backfillContent`, off this path, so a
    /// silent-push sync inside iOS's short background window never waits on
    /// them.
    private func syncOneLocked(account: String) async -> Bool {
        do {
            let (plan, isFullListing) = try await planSync(account: account)
            var stillMissing = Set<String>()
            var listed: [Correspondence] = []

            for chunk in plan.messageIDs.chunked(into: GmailAPIClient.batchSize) {
                let fetched = try await client.fetchMetadata(ids: chunk, account: account)
                stillMissing.formUnion(fetched.failedIDs)
                try await repository.upsert(fetched.items, isInitialSync: isFullListing)
                if isFullListing { listed += fetched.items }
                syncProgress += 1
            }

            // Moved back into the Inbox elsewhere. Upserted as baseline
            // (`isInitialSync: true`): restoring mail you already had isn't
            // a new sender arriving, so it never lands in the Screener.
            if !plan.restoredMessageIDs.isEmpty {
                let restored = try await client.fetchMessages(ids: plan.restoredMessageIDs, account: account)
                stillMissing.formUnion(restored.failedIDs)
                try await repository.upsert(restored.items, isInitialSync: true)
            }

            // After upsert, so a message that arrived and was then archived
            // elsewhere within the same window ends up removed, not re-added.
            try await repository.applyRemoteChanges(plan.remoteChanges)
            // Every listed message accounted for, or a missing one would
            // look deleted.
            if isFullListing, stillMissing.isEmpty { try await reconcile(account: account, listed: listed) }

            // Ids a previous sync couldn't fetch, retried here independent
            // of the cursor/history window: by now the cursor has already
            // moved past the point where the ordinary sync path would ever
            // offer them again (see `GmailAPIClient.SyncPlan`).
            let previouslyMissed = missedMessageIDs(for: account)
            if !previouslyMissed.isEmpty {
                if let retried = try? await client.fetchMessages(ids: previouslyMissed, account: account) {
                    try await repository.upsert(retried.items, isInitialSync: isFullListing)
                    stillMissing.formUnion(retried.failedIDs)
                } else {
                    // The retry call itself failed outright (e.g. a token
                    // refresh failure) — keep every previously-missed id
                    // exactly as missing as it already was.
                    stillMissing.formUnion(previouslyMissed)
                }
            }

            // Deliberately last: upsert (SwiftData) and the cursor write
            // (UserDefaults) are two different stores and can't share one
            // transaction without moving Gmail sync mechanics into the Core
            // schema (ADR 005). Writing the cursor first would risk real
            // data loss if the app died before every batch was saved: the
            // next sync would start past messages never stored. Writing it
            // after only risks redundant work (a re-fetch upsert treats as
            // a no-op), never data loss.
            //
            // The same goes for a rate-limited pass that left more failed
            // ids than the retry list holds: moving the cursor would drop
            // the overflow for good, so the cursor stays put and the next
            // sync plans the same window again.
            if retired.remove(account) != nil {
                dropCursor(for: account)
                return false
            }
            let missedOverflow = stillMissing.count > Self.maxTrackedMissedIDs
            if let historyId = plan.historyId, !missedOverflow {
                setHistoryCursor(historyId, for: account)
            }
            if isFullListing, !missedOverflow {
                setOlderInboxPageToken(plan.olderInboxPageToken, for: account)
            }
            setMissedMessageIDs(stillMissing, for: account)
            if !isFullListing { await backfillSentIfNeeded(account: account) }
            else { defaults.set(true, forKey: Self.sentBackfillKey(for: account)) }
            await repairSentPlaceholders(account: account)
            errorMessage = nil
            return true
        } catch {
            Logger(subsystem: "studio.anwarcreative.corres", category: "sync")
                .error("Sync failed: \(String(describing: error), privacy: .public)")
            // Google turned down a token it had issued (revoked, or expired
            // early): forget it, so the next pass gets a fresh one instead
            // of failing the same way until the cached one runs out.
            if case GmailAPIClient.ClientError.badResponse(statusCode: 401) = error,
               MailAccounts.provider(for: account) == .google {
                await GoogleTokenProvider.shared.invalidateAccessToken(for: account)
            }
            errorMessage = "Couldn't sync your mail. Check your connection and try again."
            return false
        }
    }

    /// A full listing (first sync, or history the server no longer keeps)
    /// carries no list of changes, and upsert leaves mail it already has
    /// alone. So mail read, archived or deleted elsewhere while the cursor
    /// was too old stayed as it was. Brings what's stored in line with the
    /// listing, but only between its oldest and newest Inbox mail: older
    /// mail wasn't listed, and newer mail arrived after it.
    private func reconcile(account: String, listed: [Correspondence]) async throws {
        try await repository.applyRemoteChanges(listed.compactMap { item in
            item.latestMessageID.map { RemoteMessageChange(threadID: item.id, messageID: $0, currentLabelIds: item.labelIds, removed: false) }
        })
        let inboxDates = listed.filter { $0.labelIds.contains("INBOX") }.map(\.receivedAt)
        guard let oldest = inboxDates.min(), let newest = inboxDates.max() else { return }
        let listedIDs = Set(listed.map(\.id))
        let gone = try await repository.threads().filter { thread in
            thread.id.account == account && thread.labelIds.contains("INBOX") && !listedIDs.contains(thread.id)
                && thread.receivedAt >= oldest && thread.receivedAt <= newest
        }
        for thread in gone { try await repository.remove(thread.id) }
        if !gone.isEmpty {
            Logger(subsystem: "studio.anwarcreative.corres", category: "sync")
                .info("Full listing removed \(gone.count) conversations gone elsewhere")
        }
    }

    /// Increments after every batch a sync or older-mail load saves;
    /// `CorresApp` observes it to refresh the visible lists progressively.
    private(set) var syncProgress = 0
    private(set) var isLoadingOlder = false

    /// Fills in real bodies for the newest `backfillLimit` threads synced
    /// metadata-first, in paced batches, so they read offline just as every
    /// synced message did before metadata-first sync existed. Anything
    /// older loads the moment it's opened (`ThreadActionService.loadContent`).
    /// Runs in the foreground after a sync, never inside a silent-push window.
    func backfillContent() async {
        guard let threads = try? await repository.threads() else { return }
        let pending = threads
            .filter { !$0.isBodyLoaded && $0.latestMessageID != nil && $0.id.account != "sample" }
            .sorted { $0.receivedAt > $1.receivedAt }
            .prefix(Self.backfillLimit)
        for (account, accountThreads) in Dictionary(grouping: pending, by: \.id.account) {
            let ids = accountThreads.compactMap(\.latestMessageID)
            for chunk in ids.chunked(into: GmailAPIClient.batchSize) {
                guard let fetched = try? await client.fetchFull(ids: chunk, account: account) else { break }
                if (try? await repository.applyLoadedContent(fetched.items)) ?? 0 > 0 { syncProgress += 1 }
            }
        }
    }

    private static let backfillLimit = 200

    /// The Mail tab's scroll-to-load: pages older Inbox mail in from where
    /// the first sync stopped. Skips threads already stored before spending
    /// quota fetching them, which also lets an account synced before this
    /// existed (no stored page token) page from the top without
    /// re-downloading what it has. Returns whether anything new arrived.
    @discardableResult
    func loadOlder(accounts: [String]) async -> Bool {
        guard !isLoadingOlder, !accounts.isEmpty else { return false }
        isLoadingOlder = true
        defer { isLoadingOlder = false }
        let known = Set(((try? await repository.threads()) ?? []).map { "\($0.id.account)|\($0.id.providerID)" })
        var anyLoaded = false
        for account in accounts where !isOlderInboxExhausted(for: account) {
            var pageToken = olderInboxPageToken(for: account)
            var newIDs: [String] = []
            var pagesScanned = 0
            do {
                repeat {
                    let page = try await client.listOlderInbox(account: account, pageToken: pageToken)
                    newIDs += page.ids.filter { !known.contains("\(account)|\($0.threadId ?? $0.id)") }.map(\.id)
                    pageToken = page.nextPageToken
                    pagesScanned += 1
                } while newIDs.isEmpty && pageToken != nil && pagesScanned < Self.maxOlderPagesScanned
                for chunk in newIDs.chunked(into: GmailAPIClient.batchSize) {
                    let fetched = try await client.fetchMetadata(ids: chunk, account: account)
                    // Older mail predates anything the Screener should hold.
                    try await repository.upsert(fetched.items, isInitialSync: true)
                    anyLoaded = anyLoaded || !fetched.items.isEmpty
                    syncProgress += 1
                }
                setOlderInboxPageToken(pageToken, for: account)
            } catch {
                continue
            }
        }
        return anyLoaded
    }

    private static let maxOlderPagesScanned = 10

    func hasOlderMail(accounts: [String]) -> Bool {
        accounts.contains { !isOlderInboxExhausted(for: $0) }
    }

    /// Forgets the stored cursor so the next connected account starts with a
    /// full sync rather than resuming a previous account's history.
    func clearCursor(for account: String?) {
        guard let account else { return }
        // Removed mid-sync: that pass mustn't save its cursor afterwards,
        // or adding the account back would start past mail it no longer has.
        if running[account] != nil { retired.insert(account) }
        dropCursor(for: account)
    }

    private var retired: Set<String> = []

    private func dropCursor(for account: String) {
        defaults.removeObject(forKey: Self.cursorKey(for: account))
        defaults.removeObject(forKey: Self.missedIDsKey(for: account))
        defaults.removeObject(forKey: Self.olderTokenKey(for: account))
        defaults.removeObject(forKey: Self.olderExhaustedKey(for: account))
    }

    /// The second value is true whenever this was a full inbox listing,
    /// whether because it's the account's first ever sync or because a
    /// stored cursor expired and forced a resync, both the Screener's
    /// baseline case: every sender already in the inbox is established
    /// relationship, not a new arrival to be screened.
    /// One full listing per account after Sent arrived, so conversations
    /// you wrote in before they replied show up there too. Re-listing is
    /// metadata only, and re-fetches of mail already stored are no-ops.
    private static func sentBackfillKey(for account: String) -> String { "corres.gmail.sentBackfill.\(account)" }

    /// Reads your recent sent messages once, so a conversation you wrote in
    /// before they replied (Gmail keeps only their reply as the latest)
    /// still shows in Sent. Sent messages are from you, so this can never
    /// put anyone in the Screener; marked done only once it succeeds.
    /// Conversations you started that Corres recorded before it kept
    /// Gmail's own copy: no message id, and (in builds before 5) the
    /// recipient shown as the sender. Each is replaced by the real message,
    /// once; upsert always lets the real copy replace a placeholder.
    private func repairSentPlaceholders(account: String) async {
        guard let threads = try? await repository.threads() else { return }
        let broken = threads.filter { $0.id.account == account && $0.latestMessageID == nil && $0.lastSentAt != nil }
        for thread in broken.prefix(20) {
            guard let messages = try? await client.fetchThreadMessages(threadId: thread.id.providerID, account: account),
                  let latest = messages.last else { continue }
            _ = try? await repository.upsert([latest], isInitialSync: true)
        }
    }

    private func backfillSentIfNeeded(account: String) async {
        guard !defaults.bool(forKey: Self.sentBackfillKey(for: account)),
              let ids = try? await client.listRecentSent(account: account) else { return }
        for chunk in ids.chunked(into: GmailAPIClient.batchSize) {
            guard let fetched = try? await client.fetchMetadata(ids: chunk, account: account),
                  (try? await repository.upsert(fetched.items, isInitialSync: true)) != nil else { return }
        }
        defaults.set(true, forKey: Self.sentBackfillKey(for: account))
        syncProgress += 1
    }

    private func planSync(account: String) async throws -> (plan: GmailAPIClient.SyncPlan, isFullListing: Bool) {
        guard let cursor = historyCursor(for: account) else {
            return (try await client.planFullListing(account: account), true)
        }
        do {
            return (try await client.planIncremental(account: account, since: cursor), false)
        } catch GmailAPIClient.ClientError.historyExpired {
            return (try await client.planFullListing(account: account), true)
        }
    }

    private func olderInboxPageToken(for account: String) -> String? {
        defaults.string(forKey: Self.olderTokenKey(for: account))
    }

    private func isOlderInboxExhausted(for account: String) -> Bool {
        defaults.bool(forKey: Self.olderExhaustedKey(for: account))
    }

    /// A nil token after a load means Gmail has nothing older: remembered,
    /// so scrolling to the bottom again doesn't re-scan the whole Inbox.
    private func setOlderInboxPageToken(_ token: String?, for account: String) {
        if let token {
            defaults.set(token, forKey: Self.olderTokenKey(for: account))
            defaults.set(false, forKey: Self.olderExhaustedKey(for: account))
        } else {
            defaults.removeObject(forKey: Self.olderTokenKey(for: account))
            defaults.set(true, forKey: Self.olderExhaustedKey(for: account))
        }
    }

    private static func olderTokenKey(for account: String) -> String { "corres.gmail.olderInboxPageToken.\(account)" }
    private static func olderExhaustedKey(for account: String) -> String { "corres.gmail.olderInboxExhausted.\(account)" }

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
