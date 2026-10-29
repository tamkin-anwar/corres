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
                let removal = removalCount(page.account)
                group.addTask {
                    guard let result = try? await self.client.searchPage(query: page.query, account: page.account, pageToken: page.token) else {
                        return (page.account, page.query, nil, [], false)
                    }
                    // Approved, not screened: these are older messages you
                    // went looking for, not someone writing to you for the
                    // first time.
                    let inserted = result.items.isEmpty ? 0
                        : (try? await self.upsert(result.items, isInitialSync: true, account: page.account, removal: removal)) ?? 0
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
        #if DEBUG
        if SampleAccounts.isSample(account) { return false }
        #endif
        if let current = running[account] {
            wantsAnotherPass.insert(account)
            return await current.value
        }
        let removal = removalCount(account)
        let task = Task { @MainActor () -> Bool in
            var succeeded = await self.syncOneLocked(account: account, removal: removal)
            // Removed meanwhile: no further pass, which would list its mail
            // again and save a cursor for an account that's gone.
            while self.isCurrent(account, removal), self.wantsAnotherPass.remove(account) != nil {
                succeeded = await self.syncOneLocked(account: account, removal: removal) || succeeded
            }
            // No suspension between the last check above and this, so a
            // caller can't join a pass that has already finished.
            self.running[account] = nil
            // Removed while this ran: whatever cursor it saved goes.
            if !self.isCurrent(account, removal) {
                self.dropCursor(for: account)
                self.changedAccounts.remove(account)
                return false
            }
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
    private func syncOneLocked(account: String, removal: Int) async -> Bool {
        // The service, never the address: diagnostics carry no mail.
        HangReporter.note("sync \(MailAccounts.provider(for: account))")
        do {
            let (plan, isFullListing) = try await planSync(account: account)
            var stillMissing = Set<String>()
            var listed: [Correspondence] = []

            for chunk in plan.messageIDs.chunked(into: GmailAPIClient.batchSize) {
                let fetched = try await client.fetchMetadata(ids: chunk, account: account)
                stillMissing.formUnion(fetched.failedIDs)
                // Older mail that turned up again (moved back into the
                // Inbox elsewhere) is baseline, as restored mail is below.
                let isReturned = { (item: Correspondence) in item.latestMessageID.map { plan.baselineMessageIDs.contains($0) } ?? false }
                let returned = fetched.items.filter(isReturned)
                let arrived = returned.isEmpty ? fetched.items : fetched.items.filter { !isReturned($0) }
                try await upsert(arrived, isInitialSync: isFullListing, account: account, removal: removal)
                if !returned.isEmpty { try await upsert(returned, isInitialSync: true, account: account, removal: removal) }
                if isFullListing { listed += fetched.items }
                syncProgress += 1
            }

            // Moved back into the Inbox elsewhere. Upserted as baseline
            // (`isInitialSync: true`): restoring mail you already had isn't
            // a new sender arriving, so it never lands in the Screener.
            if !plan.restoredMessageIDs.isEmpty {
                let restored = try await client.fetchMessages(ids: plan.restoredMessageIDs, account: account)
                stillMissing.formUnion(restored.failedIDs)
                try await upsert(restored.items, isInitialSync: true, account: account, removal: removal)
            }

            // After upsert, so a message that arrived and was then archived
            // elsewhere within the same window ends up removed, not re-added.
            try ensureCurrent(account, removal)
            // IMAP reports the flags it read, which can be from before a
            // change of yours reached the server; it reports them again.
            let reported = MailAccounts.provider(for: account).usesIMAP ? Self.leavingYourChanges(plan.remoteChanges) : plan.remoteChanges
            try await repository.applyRemoteChanges(reported)
            await removeArchivedBehindYourReply(plan.remoteChanges, account: account, removal: removal)
            // Every listed message accounted for, or a missing one would
            // look deleted.
            if isFullListing, stillMissing.isEmpty {
                try ensureCurrent(account, removal)
                if MailAccounts.provider(for: account).usesIMAP {
                    // An IMAP listing is the newest by arrival, but dated
                    // by the sender's clock: one email dated years back
                    // (spam, a wrong clock, mail moved back to the Inbox)
                    // stretched the window over mail it never listed,
                    // and all of that was removed here while still in the
                    // Inbox. Each is asked about first instead.
                    try await confirmAgainstInbox(account: account, listed: listed, removal: removal)
                } else {
                    try await reconcile(account: account, listed: listed)
                }
            }

            // Ids a previous sync couldn't fetch, retried here independent
            // of the cursor/history window: by now the cursor has already
            // moved past the point where the ordinary sync path would ever
            // offer them again (see `GmailAPIClient.SyncPlan`).
            let missed = missedMessages(for: account)
            let previouslyMissed = missed.ids
            var tried = Set<String>()
            if isFullListing || !plan.messageIDs.isEmpty || !plan.restoredMessageIDs.isEmpty || !plan.remoteChanges.isEmpty {
                changedAccounts.insert(account)
            }
            if !previouslyMissed.isEmpty {
                try ensureCurrent(account, removal)
                if let retried = try? await client.fetchMessages(ids: previouslyMissed, account: account) {
                    try await upsert(retried.items, isInitialSync: isFullListing, account: account, removal: removal)
                    stillMissing.formUnion(retried.failedIDs)
                    tried = Set(previouslyMissed)
                    // Only a retry that brought something in is a change;
                    // one that found nothing again isn't worth a reload.
                    if !retried.items.isEmpty { changedAccounts.insert(account) }
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
            try ensureCurrent(account, removal)
            let missedOverflow = stillMissing.count > MissedMessages.maxTracked
            if let historyId = plan.historyId, !missedOverflow {
                setHistoryCursor(historyId, for: account)
            }
            if isFullListing, !missedOverflow {
                setOlderInboxPageToken(plan.olderInboxPageToken, for: account)
            }
            setMissedMessages(missed.after(failed: stillMissing, tried: tried, now: .now), for: account)
            if !isFullListing { await backfillSentIfNeeded(account: account, removal: removal) }
            else { defaults.set(true, forKey: Self.sentBackfillKey(for: account)) }
            await repairSentPlaceholders(account: account, removal: removal)
            errorMessage = nil
            health[account] = AccountHealth(lastSuccess: .now, problem: nil)
            return true
        } catch is AccountRemoved {
            // Removed mid-pass: nothing to report, and nothing more saved.
            return false
        } catch {
            Logger(subsystem: "studio.anwarcreative.corres", category: "sync")
                .error("Sync failed (\(MailAccounts.provider(for: account).title, privacy: .public)): \(error.logKind, privacy: .public) \(String(describing: error), privacy: .private)")
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
            errorMessage = String(localized: "Couldn't sync your mail. Check your connection and try again.")
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

    /// Labels read from the server for conversations you've just changed
    /// here (or whose change is still waiting): the listing may be from
    /// before it, and would put the dot or flag back for a moment. Left
    /// for a later pass; removals still go.
    private static func leavingYourChanges(_ changes: [RemoteMessageChange]) -> [RemoteMessageChange] {
        changes.filter { $0.removed || !ActionQueue.shared.isChanging(account: $0.threadID.account, threadID: $0.threadID.providerID) }
    }

    /// A full listing (first sync, or history the server no longer keeps)
    /// carries no list of changes, and upsert leaves mail it already has
    /// alone. So mail read, archived or deleted elsewhere while the cursor
    /// was too old stayed as it was. Brings what's stored in line with the
    /// listing, but only between its oldest and newest Inbox mail: older
    /// mail wasn't listed, and newer mail arrived after it.
    private func reconcile(account: String, listed: [Correspondence]) async throws {
        try await repository.applyRemoteChanges(Self.leavingYourChanges(listed.compactMap { item in
            item.latestMessageID.map { RemoteMessageChange(threadID: item.id, messageID: $0, currentLabelIds: item.labelIds, removed: false) }
        }))
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
        let now = Date.now
        for (account, accountThreads) in Dictionary(grouping: pending, by: \.id.account) {
            let removal = removalCount(account)
            // One the server no longer has (deleted, or moved elsewhere)
            // never loads: asked again after a while, not on every
            // 20-second check.
            let ids = accountThreads.compactMap(\.latestMessageID).filter {
                now.timeIntervalSince(backfillTried[account + "|" + $0] ?? .distantPast) > Self.backfillRetry
            }
            for chunk in ids.chunked(into: GmailAPIClient.batchSize) {
                guard let fetched = try? await client.fetchFull(ids: chunk, account: account), isCurrent(account, removal) else { break }
                for id in chunk { backfillTried[account + "|" + id] = now }
                if (try? await repository.applyLoadedContent(fetched.items)) ?? 0 > 0 { syncProgress += 1 }
            }
        }
        if backfillTried.count > 2_000 { backfillTried = backfillTried.filter { now.timeIntervalSince($0.value) <= Self.backfillRetry } }
    }

    private static let backfillLimit = 200
    private static let backfillRetry: TimeInterval = 30 * 60
    private var isBackfilling = false
    private var backfillTried: [String: Date] = [:]

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
            let removal = removalCount(account)
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
            guard complete, !listed.isEmpty, isCurrent(account, removal) else { continue }
            do {
                try await confirmAgainstInbox(account: account, listed: listed, removal: removal)
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
    private func confirmAgainstInbox(account: String, listed: [Correspondence], removal: Int) async throws {
        try await repository.applyRemoteChanges(Self.leavingYourChanges(listed.compactMap { item in
            item.latestMessageID.map { RemoteMessageChange(threadID: item.id, messageID: $0, currentLabelIds: item.labelIds, removed: false) }
        }))
        let inboxDates = listed.filter { $0.labelIds.contains("INBOX") }.map(\.receivedAt)
        guard let oldest = inboxDates.min(), let newest = inboxDates.max() else { return }
        let listedIDs = Set(listed.map(\.id))
        let suspects = try await repository.threads(account: account, receivedFrom: oldest, to: newest).filter { thread in
            thread.labelIds.contains("INBOX") && !listedIDs.contains(thread.id) && thread.latestMessageID != nil
        }
        guard !suspects.isEmpty else { return }
        var changes: [RemoteMessageChange] = []
        var asked = Set<String>(), answered = Set<String>()
        for chunk in suspects.compactMap(\.latestMessageID).chunked(into: GmailAPIClient.batchSize) {
            guard let fetched = try? await client.fetchMetadata(ids: chunk, account: account) else { continue }
            asked.formUnion(chunk)
            answered.formUnion(fetched.items.compactMap(\.latestMessageID))
            for item in fetched.items {
                guard let messageID = item.latestMessageID, !item.labelIds.contains("INBOX"),
                      let thread = suspects.first(where: { $0.latestMessageID == messageID }) else { continue }
                let discarded = item.labelIds.contains("TRASH") || item.labelIds.contains("SPAM")
                changes.append(RemoteMessageChange(threadID: thread.id, messageID: messageID,
                                                   currentLabelIds: discarded ? nil : item.labelIds, removed: discarded))
            }
        }
        // An IMAP server has nothing to say about a message that left a
        // folder: it's known by the folder, the folder's numbering
        // (UIDVALIDITY) and its UID there, and asked for, it simply isn't
        // in the answer. One not answered for, in a folder numbered as the
        // listing's, was moved or deleted elsewhere; in a renumbered one,
        // nothing can be said. Without this, nothing was ever removed here.
        if MailAccounts.provider(for: account).usesIMAP {
            let numbering = Set(listed.compactMap { $0.latestMessageID.flatMap(IMAPMailClient.parse) }.map { "\($0.uidValidity):\($0.path)" })
            for thread in suspects {
                guard let messageID = thread.latestMessageID, asked.contains(messageID), !answered.contains(messageID),
                      let key = IMAPMailClient.parse(messageID), numbering.contains("\(key.uidValidity):\(key.path)") else { continue }
                changes.append(RemoteMessageChange(threadID: thread.id, messageID: messageID, currentLabelIds: nil, removed: true))
            }
        }
        try ensureCurrent(account, removal)
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
        let started = Dictionary(accounts.map { ($0, removalCount($0)) }, uniquingKeysWith: { first, _ in first })
        let saved = await MailIndexer.shared.run(accounts: accounts, repository: repository) { [weak self] account in
            guard let self, let removal = started[account] else { return false }
            return self.isCurrent(account, removal)
        }
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
        // Every account at once: one after another, three accounts kept the
        // spinner at the end of the list three times as long.
        return await withTaskGroup(of: Bool.self) { group in
            for account in accounts where !isOlderInboxExhausted(for: account) {
                group.addTask { await self.loadOlder(account: account, known: known) }
            }
            var anyLoaded = false
            for await loaded in group where loaded { anyLoaded = true }
            return anyLoaded
        }
    }

    private func loadOlder(account: String, known: Set<String>) async -> Bool {
        let removal = removalCount(account)
        var pageToken = olderInboxPageToken(for: account)
        var newIDs: [String] = []
        var pagesScanned = 0
        var anyLoaded = false
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
                try await upsert(fetched.items, isInitialSync: true, account: account, removal: removal)
                anyLoaded = anyLoaded || !fetched.items.isEmpty
                syncProgress += 1
            }
            try ensureCurrent(account, removal)
            setOlderInboxPageToken(pageToken, for: account)
        } catch {
            return anyLoaded
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
        // Removed mid-sync (or mid older mail, bodies, search, Inbox check):
        // that work stops before saving anything more, and no further pass
        // follows, or its mail would come back and adding the account back
        // would start past mail it no longer has.
        removals[account, default: 0] += 1
        wantsAnotherPass.remove(account)
        dropCursor(for: account)
    }

    /// How many times each account has been removed this launch. Work for
    /// an account notes it when it starts, and stops once it changes.
    private var removals: [String: Int] = [:]
    private struct AccountRemoved: Error {}

    private func removalCount(_ account: String) -> Int { removals[account, default: 0] }
    private func isCurrent(_ account: String, _ removal: Int) -> Bool { removals[account, default: 0] == removal }

    private func ensureCurrent(_ account: String, _ removal: Int) throws {
        guard isCurrent(account, removal) else { throw AccountRemoved() }
    }

    /// Saves mail for an account that's still here. The check and the save
    /// go together on the main actor, so a removal can't slip between them
    /// and have this put the mail back after it was deleted.
    @discardableResult
    private func upsert(_ items: [Correspondence], isInitialSync: Bool, account: String, removal: Int) async throws -> Int {
        try ensureCurrent(account, removal)
        guard !items.isEmpty else { return 0 }
        return try await repository.upsert(items, isInitialSync: isInitialSync)
    }

    private func dropCursor(for account: String) {
        defaults.removeObject(forKey: Self.cursorKey(for: account))
        // Whatever the provider: it may already be forgotten.
        fileCursors[account] = nil
        fileCursorsRead.insert(account)
        CursorFiles.remove(account)
        defaults.removeObject(forKey: Self.missedIDsKey(for: account))
        defaults.removeObject(forKey: Self.missedKey(for: account))
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
    ///
    /// A new Outlook email Graph hadn't filed when asked keeps a stand-in
    /// ("outlook-sent-…") with the Message-ID Corres stamped on it. That's
    /// looked up here, so the stand-in gives way even after Corres quit
    /// before the outbox could swap it.
    ///
    /// Each is tried at most every few minutes, and given up after a few
    /// days, so a copy that never turns up isn't asked about forever.
    private func repairSentPlaceholders(account: String, removal: Int) async {
        guard let threads = try? await repository.threadsWithoutMessageID(account: account) else { return }
        let now = Date.now
        let broken = threads.filter { thread in
            guard let sent = thread.lastSentAt, now.timeIntervalSince(sent) < Self.placeholderGiveUp else { return false }
            return now.timeIntervalSince(placeholderTried[thread.id] ?? .distantPast) > Self.placeholderRetry
        }
        for thread in broken.prefix(20) {
            guard isCurrent(account, removal) else { return }
            placeholderTried[thread.id] = now
            if thread.id.providerID.hasPrefix("outlook-sent-") {
                guard let messageID = thread.messageIdHeader,
                      let real = try? await client.findMessage(rfc822MessageID: messageID, account: account),
                      let messages = try? await client.fetchThreadMessages(threadId: real.providerID, account: account),
                      let sent = Correspondence.sentCopy(in: messages, messageID: messageID),
                      (try? await upsert([sent], isInitialSync: true, account: account, removal: removal)) != nil else { continue }
                try? await repository.remove(thread.id)
                placeholderTried[thread.id] = nil
                changedAccounts.insert(account)
                continue
            }
            guard let messages = try? await client.fetchThreadMessages(threadId: thread.id.providerID, account: account),
                  let latest = messages.last else { continue }
            _ = try? await upsert([latest], isInitialSync: true, account: account, removal: removal)
        }
    }

    /// Archived on the web after you replied: Gmail takes the Inbox label
    /// off their messages, and your reply, the one Corres keeps for the
    /// conversation, never had it, so no change named it and the
    /// conversation stayed. Each one is asked about first and leaves only
    /// when nothing in it is still in the Inbox (one message moved by
    /// another app isn't the whole conversation archived).
    private func removeArchivedBehindYourReply(_ changes: [RemoteMessageChange], account: String, removal: Int) async {
        let named = Set(changes.filter { $0.leftInbox && !$0.threadID.providerID.isEmpty }.map(\.threadID))
        guard !named.isEmpty else { return }
        var stored: [Correspondence] = []
        for id in named.prefix(20) {
            if let thread = try? await repository.thread(id) { stored.append(thread) }
        }
        var removals: [RemoteMessageChange] = []
        for id in RemoteMessageChange.archivedBehindLatest(changes, stored: stored) {
            guard isCurrent(account, removal),
                  let latest = stored.first(where: { $0.id == id })?.latestMessageID,
                  let messages = try? await client.fetchThreadMessages(threadId: id.providerID, account: account),
                  !messages.isEmpty, !RemoteMessageChange.stillInInbox(messages.map(\.labelIds)) else { continue }
            removals.append(RemoteMessageChange(threadID: id, messageID: latest, currentLabelIds: nil, removed: true))
        }
        guard !removals.isEmpty, isCurrent(account, removal) else { return }
        _ = try? await repository.applyRemoteChanges(removals)
    }

    private static let placeholderRetry: TimeInterval = 5 * 60
    private static let placeholderGiveUp: TimeInterval = 7 * 86_400
    private var placeholderTried: [ThreadID: Date] = [:]

    private func backfillSentIfNeeded(account: String, removal: Int) async {
        guard !defaults.bool(forKey: Self.sentBackfillKey(for: account)),
              let ids = try? await client.listRecentSent(account: account) else { return }
        for chunk in ids.chunked(into: GmailAPIClient.batchSize) {
            guard let fetched = try? await client.fetchMetadata(ids: chunk, account: account),
                  (try? await upsert(fetched.items, isInitialSync: true, account: account, removal: removal)) != nil else { return }
        }
        guard isCurrent(account, removal) else { return }
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
        guard MailAccounts.provider(for: account).usesIMAP else { return defaults.string(forKey: Self.cursorKey(for: account)) }
        if fileCursorsRead.contains(account) { return fileCursors[account] }
        // First read this launch, after any write still waiting.
        var value = CursorFiles.queue.sync { CursorFiles.read(account) }
        if value == nil, let old = defaults.string(forKey: Self.cursorKey(for: account)) {
            // Kept in UserDefaults by an earlier build: moved to its file, once.
            value = old
            CursorFiles.write(old, for: account, thenRemoveDefault: Self.cursorKey(for: account))
        }
        fileCursorsRead.insert(account)
        fileCursors[account] = value
        return value
    }

    private func setHistoryCursor(_ value: String, for account: String) {
        guard MailAccounts.provider(for: account).usesIMAP else {
            defaults.set(value, forKey: Self.cursorKey(for: account))
            return
        }
        // A pass that changed nothing gives back the same cursor.
        if fileCursorsRead.contains(account), fileCursors[account] == value { return }
        fileCursorsRead.insert(account)
        fileCursors[account] = value
        CursorFiles.write(value, for: account)
    }

    private static func cursorKey(for account: String) -> String { "corres.gmail.historyId.\(account)" }

    /// An IMAP account's cursor (iCloud's, any other server's) holds each
    /// synced folder's state and its newest messages, tens of KB: kept in
    /// a file of its own, written off the main thread and only when it
    /// changed, instead of rewriting UserDefaults every 20 seconds.
    /// Gmail's and Outlook's are small and stay in UserDefaults. What was
    /// last read or written is kept here, so only a launch reads the file.
    private var fileCursors: [String: String] = [:]
    private var fileCursorsRead: Set<String> = []

    private enum CursorFiles {
        /// One at a time, in order: a later cursor never lands before an
        /// earlier one, and a read waits for the writes before it.
        static let queue = DispatchQueue(label: "studio.anwarcreative.corres.cursors", qos: .utility)
        static var directory: URL { URL.applicationSupportDirectory.appending(path: "sync-cursors", directoryHint: .isDirectory) }

        static func url(for account: String) -> URL {
            let name = account.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? account
            return directory.appending(path: "\(name).json")
        }

        /// Call on `queue`.
        static func read(_ account: String) -> String? {
            (try? Data(contentsOf: url(for: account))).flatMap { String(data: $0, encoding: .utf8) }
        }

        /// Written whole or not at all. If the app ends before it lands,
        /// the next sync starts from the cursor before: work done twice,
        /// nothing missed.
        static func write(_ value: String, for account: String, thenRemoveDefault key: String? = nil) {
            queue.async {
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                do {
                    try Data(value.utf8).write(to: url(for: account), options: .atomic)
                    if let key { UserDefaults.standard.removeObject(forKey: key) }
                } catch {
                    Logger(subsystem: "studio.anwarcreative.corres", category: "sync")
                        .error("Saving the sync cursor failed: \(error.logKind, privacy: .public) \(String(describing: error), privacy: .private)")
                }
            }
        }

        static func remove(_ account: String) {
            queue.async { try? FileManager.default.removeItem(at: url(for: account)) }
        }
    }

    /// The ids a pass couldn't fetch, with how often each was tried (see
    /// `MissedMessages`). A plain list saved by an earlier build counts as
    /// tried once, from now.
    private func missedMessages(for account: String) -> MissedMessages {
        if let data = defaults.data(forKey: Self.missedKey(for: account)),
           let saved = try? JSONDecoder().decode(MissedMessages.self, from: data) {
            return saved
        }
        let old = defaults.stringArray(forKey: Self.missedIDsKey(for: account)) ?? []
        return MissedMessages(entries: Dictionary(old.map { ($0, MissedMessages.Entry(attempts: 1, since: .now)) },
                                                  uniquingKeysWith: { first, _ in first }))
    }

    /// Written only when it changed: every write tells the whole app
    /// settings changed, and this runs every 20 seconds.
    private func setMissedMessages(_ missed: MissedMessages, for account: String) {
        if defaults.object(forKey: Self.missedIDsKey(for: account)) != nil { defaults.removeObject(forKey: Self.missedIDsKey(for: account)) }
        let key = Self.missedKey(for: account)
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard !missed.isEmpty, let data = try? encoder.encode(missed) else {
            if defaults.object(forKey: key) != nil { defaults.removeObject(forKey: key) }
            return
        }
        if defaults.data(forKey: key) != data { defaults.set(data, forKey: key) }
    }

    private static func missedKey(for account: String) -> String { "corres.sync.missedMessages.\(account)" }
    private static func missedIDsKey(for account: String) -> String { "corres.gmail.missedMessageIDs.\(account)" }
}
