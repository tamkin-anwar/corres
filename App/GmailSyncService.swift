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
    /// Where each account's server results continue for the current
    /// search, for "Show More Results". Empty when every account has
    /// shown all it has, or nothing was searched.
    private(set) var moreResults: [String: (query: String, token: String)] = [:]
    /// The search `moreResults` and `serverMatches` belong to.
    private(set) var moreResultsQuery = ""
    /// What the providers' own search found for it, shown even when the
    /// words are only in a part of the message not on the device.
    private(set) var serverMatches: Set<ThreadID> = []
    private var searchGeneration = 0
    /// Bumped whenever a sync pass pulls in data, from any entry point.
    /// `CorresApp` observes it to run on-device triage after *every* sync
    /// (pull-to-refresh, connecting an account), not just the launch and
    /// push paths that used to be the only ones calling it — new mail from
    /// a manual refresh otherwise sat untriaged until the next cold launch.
    private(set) var lastCompletedSync: Date?
    /// When a pass last brought something in or changed something. The
    /// work over the whole mailbox (iCloud marks, people, triage) follows
    /// this, not every 20-second check that found nothing.
    private(set) var lastChange: Date?
    private var changedAccounts: Set<String> = []
    var errorMessage: String?

    /// Each account's last good sync, and what's wrong when it isn't
    /// syncing, said plainly in Settings: a sign-in that lapsed or a
    /// service refusing shouldn't fail quietly while mail stops arriving.
    struct AccountHealth: Equatable {
        var lastSuccess: Date?
        var problem: String?
    }
    private(set) var health: [String: AccountHealth] = [:]

    init(repository: any MailRepository) {
        self.repository = repository
    }

    /// Reaches past what's already synced locally (see
    /// `MailClient.searchPage`) and merges any
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
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        searchGeneration += 1
        let generation = searchGeneration
        moreResults = [:]
        serverMatches = []
        moreResultsQuery = trimmed
        isSearchingRemote = false
        guard !accounts.isEmpty else { return false }
        guard trimmed.count >= Self.minSearchQueryLength else { return false }
        isSearchingRemote = true
        defer { if generation == searchGeneration { isSearchingRemote = false } }
        // Gmail's search endpoint is scoped to whichever account authorized
        // the call ("me"); reaching every connected account means one call
        // per account. Fired concurrently, not one after another: with more
        // than one connected account, waiting on each account's round trip
        // in turn means someone with three accounts waits three times as
        // long for a search that could otherwise finish in the time of the
        // slowest single account. `repository` is a `@ModelActor`, already
        // safe to call concurrently from multiple tasks (calls queue on the
        // actor rather than racing).
        var pages: [(account: String, query: String)] = []
        for account in accounts {
            // Gmail reads its own filters (from:, has:attachment); the
            // others are searched for the words, and the filters apply
            // to what comes back.
            let terms = MailQuery.SearchTerms(trimmed)
            // Filters alone ("is:unread") narrow what's here; asking the
            // server would pull in every unread email you ever archived.
            guard !terms.words.isEmpty || !terms.from.isEmpty || !terms.to.isEmpty else { continue }
            let query = MailAccounts.provider(for: account) == .google ? trimmed
                : ([terms.words] + terms.from + terms.to).filter { !$0.isEmpty }.joined(separator: " ")
            guard !query.isEmpty else { continue }
            pages.append((account, query))
        }
        return await searchPages(pages.map { ($0.account, $0.query, nil) }, generation: generation)
    }

    /// The next page from every account that has more for the current
    /// search: what "Show More Results" at the end of the results asks for.
    @discardableResult
    func searchMore() async -> Bool {
        guard !moreResults.isEmpty, !isSearchingRemote else { return false }
        let pages = moreResults.map { ($0.key, $0.value.query, Optional($0.value.token)) }
        moreResults = [:]
        isSearchingRemote = true
        let generation = searchGeneration
        defer { if generation == searchGeneration { isSearchingRemote = false } }
        return await searchPages(pages, generation: generation)
    }

    /// One page of server results from each account, merged into the store,
    /// remembering where each continues. Pages that land after a newer
    /// search started are still saved, but don't offer "more" for it.
    private func searchPages(_ pages: [(account: String, query: String, token: String?)], generation: Int) async -> Bool {
        await withTaskGroup(of: (account: String, query: String, next: String?, found: [ThreadID], inserted: Bool).self) { group in
            for page in pages {
                group.addTask {
                    guard let result = try? await self.client.searchPage(query: page.query, account: page.account, pageToken: page.token) else {
                        return (page.account, page.query, nil, [], false)
                    }
                    // Approved, not screened: these are older messages you
                    // went looking for, not someone writing to you for the
                    // first time.
                    let inserted = result.items.isEmpty ? 0 : (try? await self.repository.upsert(result.items, isInitialSync: true)) ?? 0
                    return (page.account, page.query, result.nextPageToken, result.items.map(\.id), inserted > 0)
                }
            }
            var anyInserted = false
            for await result in group {
                anyInserted = anyInserted || result.inserted
                guard generation == searchGeneration else { continue }
                serverMatches.formUnion(result.found)
                if let next = result.next { moreResults[result.account] = (result.query, next) }
            }
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
            if succeeded {
                if self.changedAccounts.remove(account) != nil { self.lastChange = .now }
                self.lastCompletedSync = .now
            }
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
            if isFullListing || !plan.messageIDs.isEmpty || !plan.restoredMessageIDs.isEmpty
                || !plan.remoteChanges.isEmpty || !previouslyMissed.isEmpty {
                changedAccounts.insert(account)
            }
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
            health[account] = AccountHealth(lastSuccess: .now, problem: nil)
            return true
        } catch {
            Logger(subsystem: "studio.anwarcreative.corres", category: "sync")
                .error("Sync failed (\(MailAccounts.provider(for: account).title, privacy: .public)): \(String(describing: error), privacy: .public)")
            // Google turned down a token it had issued (revoked, or expired
            // early): forget it, so the next pass gets a fresh one instead
            // of failing the same way until the cached one runs out.
            if case GmailAPIClient.ClientError.badResponse(statusCode: 401) = error,
               MailAccounts.provider(for: account) == .google {
                await GoogleTokenProvider.shared.invalidateAccessToken(for: account)
            }
            // Gmail asking for a pause (its per-user limit, shared by every
            // device) is no problem of yours: the next pass catches up.
            if case GmailAPIClient.ClientError.refused(_, let reason?, _) = error, GmailAPIClient.rateLimitReasons.contains(reason) {
                return false
            }
            errorMessage = "Couldn't sync your mail. Check your connection and try again."
            health[account, default: AccountHealth()].problem = Self.describe(error, account: account)
            return false
        }
    }

    /// What went wrong, in words, with what to do about it.
    static func describe(_ error: Error, account: String) -> String {
        let service = MailAccounts.serviceTitle(for: account)
        if (error as NSError).domain == NSURLErrorDomain {
            return String(localized: "Can't reach \(service) right now. Corres keeps trying.")
        }
        switch error {
        case GmailAPIClient.ClientError.notSignedIn:
            return String(localized: "Signed out of \(service). Sign in again to keep getting mail.")
        case GmailAPIClient.ClientError.badResponse(let status) where status == 401 || status == 403:
            return String(localized: "\(service) turned down Corres's access. Reconnect below.")
        case GmailAPIClient.ClientError.badResponse(let status) where status == 429 || status >= 500:
            return String(localized: "\(service) is busy. Corres tries again in a moment.")
        case GmailAPIClient.ClientError.refused(_, _, let message?):
            return String(localized: "\(service) said: \(message)")
        default:
            return String(localized: "\(service) didn't answer the last check. Corres keeps trying.")
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
        let gone = try await repository.threads(account: account, receivedFrom: oldest, to: newest).filter { thread in
            thread.labelIds.contains("INBOX") && !listedIDs.contains(thread.id)
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
        // Every sync asks for this; one at a time, or two close syncs
        // fetched the same bodies twice.
        guard !isBackfilling else { return }
        isBackfilling = true
        defer { isBackfilling = false }
        guard let pending = try? await repository.threadsAwaitingContent(limit: Self.backfillLimit) else { return }
        for (account, accountThreads) in Dictionary(grouping: pending, by: \.id.account) {
            let ids = accountThreads.compactMap(\.latestMessageID)
            for chunk in ids.chunked(into: GmailAPIClient.batchSize) {
                guard let fetched = try? await client.fetchFull(ids: chunk, account: account) else { break }
                if (try? await repository.applyLoadedContent(fetched.items)) ?? 0 > 0 { syncProgress += 1 }
            }
        }
    }

    private static let backfillLimit = 200
    private var isBackfilling = false

    /// Every few hours, each account's Inbox as the server has it now (the
    /// newest 500 conversations) is compared with what's here: read state
    /// brought in line, and anything archived or deleted elsewhere that a
    /// change feed didn't report (older mail, Outlook's 60-day window, an
    /// IMAP server's newest-500 window) removed. A check, not a re-sync:
    /// metadata only, and only between the newest and oldest it listed.
    func verifyInboxes(accounts: [String]) async {
        for account in accounts where account != "sample" {
            let key = "corres.inboxVerified.\(account.lowercased())"
            let last = defaults.object(forKey: key) as? Date ?? .distantPast
            guard Date.now.timeIntervalSince(last) > Self.verifyInterval, running[account] == nil else { continue }
            var listed: [Correspondence] = []
            var token: String?
            var complete = true
            for _ in 0..<Self.verifyPages {
                guard let page = try? await client.listMailbox(labelId: "INBOX", account: account, pageToken: token, pageSize: 50) else {
                    complete = false
                    break
                }
                listed += page.items
                token = page.nextPageToken
                if token == nil { break }
            }
            // Only what was read in one go: a page missing in the middle
            // would make the mail on it look gone.
            guard complete, !listed.isEmpty else { continue }
            do {
                try await confirmAgainstInbox(account: account, listed: listed)
                defaults.set(Date.now, forKey: key)
                syncProgress += 1
            } catch {
                continue
            }
        }
    }

    /// Read state from the listing, then each conversation that looks gone
    /// asked about by its newest message before anything changes: moved
    /// out of the Inbox elsewhere, it stays as archived mail Search finds;
    /// in Trash or Spam, it goes; no clear answer, it stays as it is. A
    /// listing can come back short (a message the server failed to send),
    /// and that mustn't remove mail you still have.
    private func confirmAgainstInbox(account: String, listed: [Correspondence]) async throws {
        try await repository.applyRemoteChanges(listed.compactMap { item in
            item.latestMessageID.map { RemoteMessageChange(threadID: item.id, messageID: $0, currentLabelIds: item.labelIds, removed: false) }
        })
        let inboxDates = listed.filter { $0.labelIds.contains("INBOX") }.map(\.receivedAt)
        guard let oldest = inboxDates.min(), let newest = inboxDates.max() else { return }
        let listedIDs = Set(listed.map(\.id))
        let suspects = try await repository.threads(account: account, receivedFrom: oldest, to: newest).filter { thread in
            thread.labelIds.contains("INBOX") && !listedIDs.contains(thread.id) && thread.latestMessageID != nil
        }
        guard !suspects.isEmpty else { return }
        var changes: [RemoteMessageChange] = []
        for chunk in suspects.compactMap(\.latestMessageID).chunked(into: GmailAPIClient.batchSize) {
            guard let fetched = try? await client.fetchMetadata(ids: chunk, account: account) else { continue }
            for item in fetched.items {
                guard let messageID = item.latestMessageID, !item.labelIds.contains("INBOX"),
                      let thread = suspects.first(where: { $0.latestMessageID == messageID }) else { continue }
                let discarded = item.labelIds.contains("TRASH") || item.labelIds.contains("SPAM")
                changes.append(RemoteMessageChange(threadID: thread.id, messageID: messageID,
                                                   currentLabelIds: discarded ? nil : item.labelIds, removed: discarded))
            }
        }
        try await repository.applyRemoteChanges(changes)
        if !changes.isEmpty {
            Logger(subsystem: "studio.anwarcreative.corres", category: "sync")
                .info("Inbox check: \(changes.count) conversations moved or deleted elsewhere, confirmed")
        }
    }

    private static let verifyInterval: TimeInterval = 6 * 3_600
    private static let verifyPages = 10

    /// The rest of each mailbox, a page at a time in the background (see
    /// `MailIndexer`), so Search covers your mail without asking the
    /// server. Returns whether anything new was saved.
    @discardableResult
    func indexOlderMail(accounts: [String]) async -> Bool {
        let saved = await MailIndexer.shared.run(accounts: accounts, repository: repository)
        if saved { syncProgress += 1 }
        return saved
    }

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
        let known = (try? await repository.storedIDs()) ?? []
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
        guard let threads = try? await repository.threadsWithoutMessageID(account: account) else { return }
        let broken = threads.filter { $0.lastSentAt != nil }
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
