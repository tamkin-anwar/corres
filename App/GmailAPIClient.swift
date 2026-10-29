import Foundation
import Postwright

/// Raw REST calls against the Gmail API. No third-party HTTP dependency,
/// URLSession + a token minted per-account by `GoogleTokenProvider` (Batch
/// 29: every call here now takes the target account's email explicitly,
/// rather than implicitly acting on whichever account GoogleSignIn's own
/// single-slot session currently holds). This is the only file that speaks
/// Gmail's wire format; it returns plain Correspondence values, never its
/// own DTOs, past this boundary (ADR 002).
struct GmailAPIClient {
    /// `badResponse` carries the real HTTP status, not just "it failed":
    /// `OutboxService`'s retry logic needs to tell a transient failure
    /// (429/5xx, worth retrying) apart from one Gmail has already fully
    /// processed and rejected (any other 4xx, retrying just repeats the
    /// same rejection).
    enum ClientError: Error {
        case notSignedIn, badResponse(statusCode: Int), decodingFailed, historyExpired
        /// Gmail refused a change and said why. `reason` is Gmail's own
        /// machine-readable code ("insufficientPermissions",
        /// "rateLimitExceeded", "failedPrecondition"...); `message` its
        /// human text. Kept so a failure is never just "error 403".
        case refused(statusCode: Int, reason: String?, message: String?)
    }

    /// What a sync pass needs to fetch, newest first, without fetching it
    /// yet: `GmailSyncService` pulls these down in batches and saves each
    /// batch the moment it lands, so the first screenful of mail appears
    /// within a round trip instead of after the whole listing downloads.
    ///
    /// Ids that still fail after `fetchMetadata`'s bounded retries come back
    /// from that call as `failedIDs` rather than vanishing: Gmail's history
    /// cursor is one whole-mailbox counter that can't be partially
    /// advanced, so a message dropped once the cursor moves past it would
    /// otherwise be gone for good. `GmailSyncService` persists and retries
    /// those by id on later syncs.
    struct SyncPlan {
        let messageIDs: [String]
        /// Of `messageIDs`, mail older than the last pass that turned up
        /// again (moved back into the Inbox elsewhere, or listed again
        /// under a new id): saved as baseline, never screened as new.
        var baselineMessageIDs: Set<String> = []
        /// Moved back into the Inbox elsewhere (un-archived, restored from
        /// Trash), which Gmail reports as a label change, not a new message.
        var restoredMessageIDs: [String] = []
        let historyId: String?
        /// Read/unread, label, archive, and delete changes made outside
        /// Corres since the last cursor. Always empty for a full listing,
        /// which already reflects current state.
        var remoteChanges: [RemoteMessageChange] = []
        /// Where "load older mail" continues from after a full listing;
        /// nil once the whole Inbox fit.
        var olderInboxPageToken: String? = nil
    }

    /// First sync reaches 500 Inbox and 200 Sent messages deep, up from 200
    /// total: listing metadata in batches makes that fast enough, and the
    /// rest of the Inbox pages in on demand (`listOlderInbox`) as the Mail
    /// tab scrolls. Every later sync is incremental via the history cursor.
    private static let initialInboxLimit = 500
    private static let initialSentLimit = 200
    static let olderPageSize = 100

    private let historyPageSize = 100

    /// Threads that live only in Sent (you started the conversation, no
    /// inbound reply synced yet) are otherwise invisible to Corres, since
    /// everything else only ever looked at INBOX. Listed and fetched
    /// alongside INBOX, not instead of it.
    private static let syncedLabels = ["INBOX", "SENT"]

    /// Google recommends no more than 50 calls per batch. Pacing between
    /// batches is `GmailQuotaGate`'s job, shared across every caller, so
    /// several fetches running at once can't jointly exceed the quota.
    static let batchSize = 50

    /// A full listing of the inbox and sent mail, used the first time an
    /// account syncs, or whenever a stored history cursor has expired.
    /// Inbox ids come first (newest first), so the mail people actually
    /// look at lands before older Sent-only threads.
    func planFullListing(account: String) async throws -> SyncPlan {
        let token = try await accessToken(for: account)
        // Best-effort: if the profile call fails, the sync itself still
        // succeeded, just without a cursor for next time. The following
        // sync falls back to another full listing rather than failing.
        // Read before listing: mail arriving during the listing then comes
        // in on the next sync instead of falling between the two.
        let historyId = try? await fetchProfile(token: token).historyId
        let inbox = try await listMessageIDs(token: token, label: "INBOX", limit: Self.initialInboxLimit)
        let sent = try await listMessageIDs(token: token, label: "SENT", limit: Self.initialSentLimit)
        var seen = Set<String>()
        let ids = (inbox.ids + sent.ids).map(\.id).filter { seen.insert($0).inserted }
        return SyncPlan(messageIDs: ids, historyId: historyId, olderInboxPageToken: inbox.nextPageToken)
    }

    /// Gmail's History API: only what changed since `cursor`, not a re-list
    /// of the whole inbox. Throws `.historyExpired` when the cursor is older
    /// than Gmail's retention window (about a week); the caller is expected
    /// to recover with `planFullListing` instead. New messages are queried
    /// once per label (the History API's `labelId` filter only accepts one
    /// at a time); changes to existing ones in a single unfiltered query.
    func planIncremental(account: String, since cursor: String) async throws -> SyncPlan {
        let token = try await accessToken(for: account)
        var ids: [String] = []
        var seen = Set<String>()
        // The cursor moves only to where the first query stood. Each later
        // query reports a newer point, and mail added between the two (in
        // the Inbox after the Inbox query ran) would sit below the newest
        // one, skipped for good. Going over a few changes twice is harmless.
        var historyId: String?
        for label in Self.syncedLabels {
            let page = try await listHistoryMessageIDs(since: cursor, token: token, label: label)
            ids += page.ids.filter { seen.insert($0).inserted }
            if historyId == nil { historyId = page.historyId }
        }
        let changes = try await listHistoryChanges(since: cursor, token: token, account: account)
        if historyId == nil { historyId = changes.historyId }
        return SyncPlan(messageIDs: ids.reversed(), restoredMessageIDs: changes.restored.filter { !seen.contains($0) },
                        historyId: historyId ?? cursor, remoteChanges: changes.changes)
    }

    /// Your recent sent messages, for filling in Sent once.
    func listRecentSent(account: String) async throws -> [String] {
        let token = try await accessToken(for: account)
        return try await listMessageIDs(token: token, label: "SENT", limit: Self.initialSentLimit).ids.map(\.id)
    }

    /// The next page of older Inbox mail, for the Mail tab's scroll-to-load.
    /// Returns message and thread ids so the caller can skip threads it
    /// already has before spending quota fetching them.
    func listOlderInbox(account: String, pageToken: String?) async throws -> (ids: [(id: String, threadId: String?)], nextPageToken: String?) {
        let token = try await accessToken(for: account)
        return try await listMessageIDs(token: token, label: "INBOX", limit: Self.olderPageSize, pageToken: pageToken)
    }

    /// Changes to messages Corres already has, made somewhere else: read in
    /// Gmail's own app, archived on the web, deleted in Apple Mail. Used to
    /// be missing entirely — sync only ever asked for `messageAdded`, so a
    /// message read or archived elsewhere stayed unread and in Needs You
    /// here indefinitely. Queried once without a `labelId` filter, unlike
    /// `listHistoryMessageIDs`: filtering on INBOX would drop exactly the
    /// events that matter most, since an archived message no longer
    /// carries INBOX. Records come back oldest first, so the last one seen
    /// for a message reflects its current state. `restored` is anything
    /// moved back into the Inbox, which the caller fetches like new mail
    /// since Corres removed it when it was archived or trashed.
    private func listHistoryChanges(since startHistoryId: String, token: String,
                                    account: String) async throws -> (changes: [RemoteMessageChange], restored: [String], historyId: String?) {
        var latest: [String: RemoteMessageChange] = [:]
        var order: [String] = []
        var restored: [String: Bool] = [:]
        var pageToken: String?
        var latestHistoryId: String?
        func record(_ ref: HistoryListResponse.HistoryRecord.MessageRef, removed: Bool) {
            guard let threadId = ref.threadId else { return }
            if latest[ref.id] == nil { order.append(ref.id) }
            let labels = Set(ref.labelIds ?? [])
            // Out of the Inbox earlier in this window stays out until a
            // record shows it back: archived on the web and then starred,
            // the star's record alone said "still here".
            let wasRemoved = latest[ref.id]?.removed == true && !labels.contains("INBOX")
            latest[ref.id] = RemoteMessageChange(threadID: ThreadID(account: account, providerID: threadId),
                                                 messageID: ref.id, currentLabelIds: ref.labelIds, removed: removed || wasRemoved)
            restored[ref.id] = !removed && labels.contains("INBOX")
        }
        repeat {
            var components = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/history")!
            var queryItems = [
                URLQueryItem(name: "startHistoryId", value: startHistoryId),
                URLQueryItem(name: "historyTypes", value: "labelAdded"),
                URLQueryItem(name: "historyTypes", value: "labelRemoved"),
                URLQueryItem(name: "historyTypes", value: "messageDeleted"),
                URLQueryItem(name: "maxResults", value: String(historyPageSize)),
            ]
            if let pageToken { queryItems.append(URLQueryItem(name: "pageToken", value: pageToken)) }
            components.queryItems = queryItems
            let (data, response) = try await authorizedRequest(url: components.url!, token: token)
            if let http = response as? HTTPURLResponse, http.statusCode == 404 {
                throw ClientError.historyExpired
            }
            try validate(response)
            let page = try JSONDecoder().decode(HistoryListResponse.self, from: data)
            for entry in page.history ?? [] {
                for change in entry.labelsAdded ?? [] {
                    let labels = Set(change.message.labelIds ?? [])
                    let trashed = labels.contains("TRASH") || labels.contains("SPAM")
                    // Moved back earlier in this window: a star or a label
                    // added after doesn't undo that. It used to, so mail
                    // moved back to the Inbox and then starred never returned.
                    let wasRestored = restored[change.message.id] == true
                    record(change.message, removed: trashed)
                    // Only an explicit move *into* the Inbox counts as a
                    // restore, not any label added to a message already there.
                    if !(change.labelIds ?? []).contains("INBOX") {
                        restored[change.message.id] = wasRestored && labels.contains("INBOX") && !trashed
                    }
                }
                for change in entry.labelsRemoved ?? [] {
                    let labels = Set(change.message.labelIds ?? [])
                    let taken = Set(change.labelIds ?? [])
                    let removedFromInbox = taken.contains("INBOX")
                        && !labels.contains("INBOX") && !labels.contains("SENT")
                    let trashed = labels.contains("TRASH") || labels.contains("SPAM")
                    let wasRestored = restored[change.message.id] == true
                    record(change.message, removed: removedFromInbox || trashed)
                    // Out of Trash or Spam into the Inbox is a restore too.
                    // Read (UNREAD taken off) after moving it back is not
                    // a reason to forget the move: moved back and opened
                    // on the web, it never came back here.
                    let untrashed = (taken.contains("TRASH") || taken.contains("SPAM")) && labels.contains("INBOX")
                    restored[change.message.id] = !trashed && !removedFromInbox && labels.contains("INBOX") && (wasRestored || untrashed)
                }
                for deleted in entry.messagesDeleted ?? [] {
                    record(deleted.message, removed: true)
                }
            }
            latestHistoryId = page.historyId ?? latestHistoryId
            pageToken = page.nextPageToken
        } while pageToken != nil
        return (order.compactMap { latest[$0] }, order.filter { restored[$0] == true }, latestHistoryId)
    }

    /// Only the headers Corres actually reads: sender, recipients (Reply
    /// All, correspondent signal), subject, threading, unsubscribe, and
    /// Gmail's own Authentication-Results (a company logo needs DMARC to
    /// pass; a few hundred bytes, in the same request).
    /// Metadata plus Gmail's own snippet is everything a row, triage, a
    /// notification, and local search need; the body comes later.
    private static let metadataHeaders = ["From", "To", "Cc", "Reply-To", "Subject", "Message-ID", "List-Unsubscribe", "List-Unsubscribe-Post",
                                          "Authentication-Results"]

    /// Sender, subject, snippet, labels, and headers for up to `batchSize`
    /// messages in one HTTP round trip. Returned threads have
    /// `isBodyLoaded == false`; see `fetchFull`.
    func fetchMetadata(ids: [String], account: String) async throws -> (items: [Correspondence], failedIDs: [String]) {
        let query = "format=metadata" + Self.metadataHeaders.map { "&metadataHeaders=\($0)" }.joined()
        return try await batchFetch(ids: ids, query: query, account: account) { map($0, account: account, bodyLoaded: false) }
    }

    /// The complete message (body, HTML, attachment list), for filling in
    /// threads synced metadata-first, or loading one the moment it's opened.
    /// Parts Gmail leaves out of `format=full` (a long text, the pictures
    /// an Outlook email carries) are fetched before it's kept, so it reads
    /// whole offline too. One whose text couldn't be had counts as failed.
    func fetchFull(ids: [String], account: String) async throws -> (items: [Correspondence], failedIDs: [String]) {
        let fetched = try await batchFetch(ids: ids, query: "format=full", account: account) { $0 }
        var imageBytes = Self.inlineImageLimit.perFetch
        var items: [Correspondence] = []
        var failed = fetched.failedIDs
        for message in fetched.items {
            let completed = await completing(message, account: account, imageBytes: &imageBytes)
            guard completed.isWhole else {
                failed.append(message.id)
                continue
            }
            items.append(map(completed.message, account: account, bodyLoaded: true))
        }
        return (items, failed)
    }

    #if DEBUG
    /// The most recent mail, archived included, whole, for testing Corres's
    /// reading against real mail on the developer's own Mac (Settings →
    /// Developer). Never in a release build.
    func exportCorpus(account: String, limit: Int) async throws -> (items: [Correspondence], missing: Int) {
        // The real reason a token can't be had, not just "not signed in".
        let token = try await GoogleTokenProvider.shared.accessToken(for: account)
        let ids = try await listMessageIDs(token: token, label: "", limit: limit).ids.map(\.id)
        var items: [Correspondence] = []
        // Gmail answers a busy batch with some messages missing; those are
        // asked for again, a few times, so the corpus is the whole Inbox.
        var pending = ids
        for _ in 1...4 where !pending.isEmpty {
            var failed: [String] = []
            for chunk in pending.chunked(into: Self.batchSize) {
                let result = try await fetchFull(ids: chunk, account: account)
                items += result.items
                failed += result.failedIDs
            }
            pending = failed
            if !pending.isEmpty { try? await Task.sleep(for: .seconds(5)) }
        }
        return (items, pending.count)
    }
    #endif

    /// Every message in a conversation, oldest first, with full bodies:
    /// what the conversation view shows above the latest message. Fetched
    /// when a thread is opened, never during sync, so it costs nothing
    /// until someone actually reads the conversation.
    func fetchThreadMessages(threadId: String, account: String) async throws -> [Correspondence] {
        let token = try await accessToken(for: account)
        await GmailQuotaGate.shared.reserve(10, for: account)
        let url = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/threads/\(threadId)?format=full")!
        let (data, response) = try await authorizedRequest(url: url, token: token)
        try validate(response)
        struct ThreadResponse: Decodable { let messages: [GmailMessage]? }
        let decoded = try JSONDecoder().decode(ThreadResponse.self, from: data)
        var imageBytes = Self.inlineImageLimit.perFetch
        var messages: [Correspondence] = []
        // Newest first, so the message being read gets the pictures first.
        for message in (decoded.messages ?? []).reversed() where !(message.labelIds ?? []).contains("DRAFT") {
            let completed = await completing(message, account: account, imageBytes: &imageBytes)
            messages.append(map(completed.message, account: account, bodyLoaded: completed.isWhole))
        }
        return messages.sorted { $0.receivedAt < $1.receivedAt }
    }

    /// Re-attempts specific message ids directly, independent of the
    /// history cursor — the path `GmailSyncService` uses for ids a previous
    /// sync reported as failed. Paced across batches like any other fetch.
    func fetchMessages(ids: [String], account: String) async throws -> (items: [Correspondence], failedIDs: [String]) {
        var items: [Correspondence] = []
        var failed: [String] = []
        for chunk in ids.chunked(into: Self.batchSize) {
            let result = try await fetchMetadata(ids: chunk, account: account)
            items += result.items
            failed += result.failedIDs
        }
        return (items, failed)
    }

    private static let batchAttempts = 3

    /// One Gmail batch request, retried for whatever parts didn't come back
    /// 200: a transient 429/5xx on one message shouldn't cost the rest of
    /// the batch, and a whole-request network failure retries everything.
    /// A 404 part means the message was deleted in the meantime; it's
    /// dropped rather than retried forever.
    private func batchFetch<Item>(ids: [String], query: String, account: String,
                                  transform: (GmailMessage) -> Item) async throws -> (items: [Item], failedIDs: [String]) {
        guard !ids.isEmpty else { return ([], []) }
        // More than one batch holds, a batch at a time. Only the first 50
        // used to be asked for, and the rest were dropped without being
        // counted as failed: a mailbox page of 50 conversations (Mac
        // mailboxes, the search index, the Inbox check) lists up to 100
        // messages, so up to half of each page never arrived.
        guard ids.count <= Self.batchSize else {
            var items: [Item] = []
            var failed: [String] = []
            for chunk in ids.chunked(into: Self.batchSize) {
                let result = try await batchFetch(ids: chunk, query: query, account: account, transform: transform)
                items += result.items
                failed += result.failedIDs
            }
            return (items, failed)
        }
        let token = try await accessToken(for: account)
        var pending = ids
        var items: [Item] = []
        for attempt in 1...Self.batchAttempts {
            guard !pending.isEmpty else { break }
            await GmailQuotaGate.shared.reserve(pending.count * GmailQuotaGate.unitsPerMessageFetch, for: account)
            let boundary = "corres_batch_\(UUID().uuidString)"
            var request = URLRequest(url: URL(string: "https://gmail.googleapis.com/batch/gmail/v1")!)
            request.httpMethod = "POST"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("multipart/mixed; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            request.httpBody = HTTPBatch.body(paths: pending.map { "/gmail/v1/users/me/messages/\($0)?\(query)" },
                                              boundary: boundary)
            var retry: [String] = []
            if let (data, response) = try? await URLSession.shared.data(for: request),
               let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode,
               let contentType = http.value(forHTTPHeaderField: "Content-Type"),
               let responseBoundary = HTTPBatch.boundary(fromContentType: contentType) {
                let parts = HTTPBatch.parse(data, boundary: responseBoundary)
                for (index, id) in pending.enumerated() {
                    guard let part = parts[index] else { retry.append(id); continue }
                    if part.status == 404 { continue }
                    guard part.status == 200, let message = try? JSONDecoder().decode(GmailMessage.self, from: part.body) else {
                        retry.append(id)
                        continue
                    }
                    items.append(transform(message))
                }
            } else {
                retry = pending
            }
            pending = retry
            if !pending.isEmpty && attempt < Self.batchAttempts {
                try? await Task.sleep(for: .seconds(attempt))
            }
        }
        return (items, pending)
    }

    /// Local search (`MailQuery.filter`) only ever sees what's already
    /// synced; typing in an older subject or a sender from months ago
    /// silently finds nothing, which is exactly the kind of "wait, my email
    /// app can't find my own email" moment that erodes trust in a mail
    /// client. Gmail's own search (`q=`, its full query syntax, not just a
    /// substring match) covers the whole real mailbox instead. Capped, not
    /// exhaustive: a search result list is for finding the one thing you're
    /// after, not a second full sync of the account.
    private let searchPageSize = 50

    func searchPage(query: String, account: String, pageToken: String?) async throws -> (items: [Correspondence], nextPageToken: String?) {
        let token = try await accessToken(for: account)
        var components = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages")!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "maxResults", value: String(searchPageSize)),
        ] + (pageToken.map { [URLQueryItem(name: "pageToken", value: $0)] } ?? [])
        let (data, response) = try await authorizedRequest(url: components.url!, token: token)
        try validate(response)
        let list = try JSONDecoder().decode(MessageListResponse.self, from: data)
        return (try await fetchMetadata(ids: list.messages?.map(\.id) ?? [], account: account).items, list.nextPageToken)
    }

    // MARK: - People

    /// Who one message was from and to, as written ("Sara Wiltshire
    /// <sara@…>"), names kept, for suggesting recipients. Synced mail keeps
    /// only bare addresses.
    struct Addressing: Sendable {
        let from: String
        let recipients: [String]
        let subject: String
        let date: Date
    }

    /// Your recent Sent mail's recipients: who you write to, the strongest
    /// sign of who you'll write to next. Headers only, a few bytes each.
    func sentAddressing(account: String, limit: Int) async throws -> [Addressing] {
        let token = try await accessToken(for: account)
        let ids = try await listMessageIDs(token: token, label: "SENT", limit: limit).ids.map(\.id)
        return try await addressing(ids: ids, account: account)
    }

    /// Mail from or to someone matching `name` anywhere in the mailbox, for
    /// finding a person who isn't in synced mail (archived years ago).
    func addressing(matching name: String, account: String) async throws -> [Addressing] {
        let token = try await accessToken(for: account)
        let term = name.replacingOccurrences(of: "\"", with: "")
        var components = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages")!
        components.queryItems = [
            URLQueryItem(name: "q", value: "{from:\"\(term)\" to:\"\(term)\" cc:\"\(term)\"}"),
            URLQueryItem(name: "maxResults", value: "15"),
        ]
        let (data, response) = try await authorizedRequest(url: components.url!, token: token)
        try validate(response)
        let list = try JSONDecoder().decode(MessageListResponse.self, from: data)
        return try await addressing(ids: list.messages?.map(\.id) ?? [], account: account)
    }

    private func addressing(ids: [String], account: String) async throws -> [Addressing] {
        let query = "format=metadata&metadataHeaders=From&metadataHeaders=To&metadataHeaders=Cc&metadataHeaders=Bcc&metadataHeaders=Subject"
        var found: [Addressing] = []
        for chunk in ids.chunked(into: Self.batchSize) {
            found += try await batchFetch(ids: chunk, query: query, account: account) { message in
                let headers = Dictionary((message.payload?.headers ?? []).map { ($0.name.lowercased(), $0.value) },
                                         uniquingKeysWith: { first, _ in first })
                let date = message.internalDate.flatMap { Double($0) }.map { Date(timeIntervalSince1970: $0 / 1000) } ?? .now
                return Addressing(from: headers["from"] ?? "",
                                  recipients: PeopleIndex.entries(in: headers["to"] ?? "") + PeopleIndex.entries(in: headers["cc"] ?? "")
                                    + PeopleIndex.entries(in: headers["bcc"] ?? ""),
                                  subject: headers["subject"] ?? "", date: date)
            }.items
        }
        return found
    }

    /// Looks up a message this client itself composed, by the `Message-ID`
    /// header `GmailMessageComposer` stamped onto it (see `OutboxService`'s
    /// own doc comment on why: Gmail's send endpoint has no idempotency-key
    /// mechanism, so a send whose HTTP response was lost to a timeout or a
    /// dropped connection is genuinely ambiguous — it may have gone through
    /// anyway. This is how a caller resolves that ambiguity before deciding
    /// whether to retry, instead of guessing. Returns the thread it landed
    /// in if Gmail has it, nil if it genuinely never arrived.
    ///
    /// Gmail's own documentation examples for `rfc822msgid:` show the value
    /// without angle brackets, but not every source agrees; tried
    /// bracket-less first (matching every other place this codebase already
    /// stores a Message-ID, see `Correspondence.messageIdHeader`) and falls
    /// back to the bracketed form rather than assuming one is definitely
    /// right and silently missing a real match.
    func findMessage(rfc822MessageID: String, account: String) async throws -> ThreadID? {
        if let found = try await searchByRFC822MessageID(rfc822MessageID, account: account) { return found }
        return try await searchByRFC822MessageID("<\(rfc822MessageID)>", account: account)
    }

    /// Drafts left out: a saved draft carries the same Message-ID as the
    /// email it becomes, and must never count as sent.
    private func searchByRFC822MessageID(_ value: String, account: String) async throws -> ThreadID? {
        let token = try await accessToken(for: account)
        var components = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages")!
        components.queryItems = [URLQueryItem(name: "q", value: "rfc822msgid:\(value) -in:drafts")]
        let (data, response) = try await authorizedRequest(url: components.url!, token: token)
        try validate(response)
        let list = try JSONDecoder().decode(MessageListResponse.self, from: data)
        guard let match = list.messages?.first, let threadId = match.threadId else { return nil }
        return ThreadID(account: account, providerID: threadId)
    }

    private func accessToken(for account: String) async throws -> String {
        do {
            return try await GoogleTokenProvider.shared.accessToken(for: account)
        } catch let error as URLError {
            // Offline is not signed out: sends retry, and sync doesn't ask
            // you to sign in again.
            throw error
        } catch GoogleTokenProvider.TokenError.unavailable(let statusCode) {
            throw ClientError.badResponse(statusCode: statusCode)
        } catch {
            throw ClientError.notSignedIn
        }
    }

    /// Newest first, up to `limit`, continuing from `pageToken` when given.
    /// Gmail allows up to 500 per page.
    private func listMessageIDs(token: String, label: String, limit: Int,
                                pageToken startToken: String? = nil) async throws -> (ids: [(id: String, threadId: String?)], nextPageToken: String?) {
        var ids: [(id: String, threadId: String?)] = []
        var pageToken = startToken
        repeat {
            var components = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages")!
            // An empty label lists All Mail (Spam and Trash left out).
            var queryItems = [URLQueryItem(name: "maxResults", value: String(min(limit - ids.count, 500)))]
            if !label.isEmpty { queryItems.append(URLQueryItem(name: "labelIds", value: label)) }
            if let pageToken { queryItems.append(URLQueryItem(name: "pageToken", value: pageToken)) }
            components.queryItems = queryItems
            let (data, response) = try await authorizedRequest(url: components.url!, token: token)
            try validate(response)
            let list = try JSONDecoder().decode(MessageListResponse.self, from: data)
            ids += (list.messages ?? []).map { (id: $0.id, threadId: $0.threadId) }
            pageToken = list.nextPageToken
        } while pageToken != nil && ids.count < limit
        return (ids, pageToken)
    }

    /// New Inbox mail since a Gmail history point, for the notification
    /// extension when a Gmail push arrives: which messages, and where to
    /// look from next time.
    func newInboxMessageIDs(since startHistoryId: String, account: String) async throws -> (ids: [String], historyId: String?) {
        let token = try await accessToken(for: account)
        return try await listHistoryMessageIDs(since: startHistoryId, token: token, label: "INBOX")
    }

    /// Gmail discards history IDs older than roughly a week; a `startHistoryId`
    /// outside that window 404s, which is the specific, expected signal to
    /// fall back to a full resync rather than a generic failure.
    private func listHistoryMessageIDs(since startHistoryId: String, token: String, label: String) async throws -> (ids: [String], historyId: String?) {
        var ids: Set<String> = []
        var pageToken: String?
        var latestHistoryId: String?
        repeat {
            var components = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/history")!
            var queryItems = [
                URLQueryItem(name: "startHistoryId", value: startHistoryId),
                URLQueryItem(name: "historyTypes", value: "messageAdded"),
                URLQueryItem(name: "labelId", value: label),
                URLQueryItem(name: "maxResults", value: String(historyPageSize)),
            ]
            if let pageToken { queryItems.append(URLQueryItem(name: "pageToken", value: pageToken)) }
            components.queryItems = queryItems
            let (data, response) = try await authorizedRequest(url: components.url!, token: token)
            if let http = response as? HTTPURLResponse, http.statusCode == 404 {
                throw ClientError.historyExpired
            }
            try validate(response)
            let page = try JSONDecoder().decode(HistoryListResponse.self, from: data)
            for record in page.history ?? [] {
                for added in record.messagesAdded ?? [] {
                    ids.insert(added.message.id)
                }
            }
            latestHistoryId = page.historyId ?? latestHistoryId
            pageToken = page.nextPageToken
        } while pageToken != nil
        return (Array(ids), latestHistoryId)
    }

    /// `raw` is an RFC 5322 message, base64url-encoded (see
    /// GmailMessageComposer); `threadId` is Gmail's own thread id
    /// (`ThreadID.providerID` for a real account) and, together with the
    /// message's In-Reply-To/References headers and a matching Subject, is
    /// what makes Gmail group this send into the existing conversation
    /// rather than starting a new one. Pass nil for a brand-new message with
    /// no existing thread to join. Returns the real thread id Gmail assigned
    /// the sent message (a freshly created one when `threadId` was nil), so
    /// the caller can file its own local record under Gmail's real identity
    /// instead of inventing one: a later sync then recognizes the same
    /// thread instead of creating a duplicate.
    @discardableResult
    func send(raw: String, threadId: String?, account: String) async throws -> String {
        let token = try await accessToken(for: account)
        let url = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/send")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["raw": raw]
        if let threadId { body["threadId"] = threadId }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response)
        let sent = try JSONDecoder().decode(SentMessage.self, from: data)
        return sent.threadId
    }

    /// Archive is just removing the `INBOX` label (Gmail's own model: a
    /// message never really leaves the account, it leaves the Inbox view).
    /// Marking read/unread is the same call with `UNREAD` instead. One
    /// shared entry point since both are the same Gmail endpoint.
    func modifyThread(threadId: String, addLabelIds: [String] = [], removeLabelIds: [String] = [], account: String) async throws {
        var body: [String: [String]] = [:]
        if !addLabelIds.isEmpty { body["addLabelIds"] = addLabelIds }
        if !removeLabelIds.isEmpty { body["removeLabelIds"] = removeLabelIds }
        let payload = try JSONSerialization.data(withJSONObject: body)
        try await performChange(path: "threads/\(threadId)/modify", body: payload, account: account)
    }

    /// Gmail's dedicated Trash endpoint, distinct from `modify`: it moves the
    /// whole thread to Trash (auto-deleted by Gmail after 30 days), rather
    /// than just changing which labels it carries.
    func trashThread(threadId: String, account: String) async throws {
        try await performChange(path: "threads/\(threadId)/trash", body: nil, account: account)
    }

    /// The same changes on some of a conversation's messages only: those
    /// there when a change that waited was made (`ActionQueue.runWaiting`).
    func modifyMessages(ids: [String], addLabelIds: [String], removeLabelIds: [String], account: String) async throws {
        // Gmail takes up to 1,000 ids at once.
        for chunk in ids.chunked(into: 1_000) {
            var body: [String: [String]] = ["ids": chunk]
            if !addLabelIds.isEmpty { body["addLabelIds"] = addLabelIds }
            if !removeLabelIds.isEmpty { body["removeLabelIds"] = removeLabelIds }
            try await performChange(path: "messages/batchModify", body: try JSONSerialization.data(withJSONObject: body), account: account)
        }
    }

    func trashMessages(ids: [String], account: String) async throws {
        for id in ids { try await performChange(path: "messages/\(id)/trash", body: nil, account: account) }
    }

    /// Out of Trash, back where it was (Gmail restores its labels, so
    /// mail that was in the Inbox returns there).
    func untrashThread(threadId: String, account: String) async throws {
        try await performChange(path: "threads/\(threadId)/untrash", body: nil, account: account)
    }

    /// An address this account can send as (Gmail → Settings → Accounts →
    /// Send mail as), verified.
    struct SendAs: Codable, Hashable, Sendable {
        let email: String
        let name: String
        let isDefault: Bool
        let isPrimary: Bool
    }

    func sendAs(account: String) async throws -> [SendAs] {
        let token = try await accessToken(for: account)
        let url = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/settings/sendAs")!
        let (data, response) = try await authorizedRequest(url: url, token: token)
        try validate(response)
        struct List: Decodable {
            struct Item: Decodable {
                let sendAsEmail: String
                let displayName: String?
                let isDefault: Bool?
                let isPrimary: Bool?
                let verificationStatus: String?
            }
            let sendAs: [Item]?
        }
        return (try JSONDecoder().decode(List.self, from: data).sendAs ?? [])
            .filter { $0.isPrimary == true || $0.verificationStatus == nil || $0.verificationStatus == "accepted" }
            .map { SendAs(email: $0.sendAsEmail.lowercased(), name: $0.displayName ?? "", isDefault: $0.isDefault ?? false, isPrimary: $0.isPrimary ?? false) }
    }

    /// Gmail's vacation reply (Out of Office). Times are milliseconds since
    /// 1970, as Gmail keeps them.
    struct Vacation: Codable, Equatable, Sendable {
        var enableAutoReply: Bool
        var responseSubject: String?
        var responseBodyPlainText: String?
        /// Set on Gmail's website (formatted). Kept as it is unless the
        /// message is changed here; Gmail sends this one when both exist.
        var responseBodyHtml: String?
        var restrictToContacts: Bool?
        var restrictToDomain: Bool?
        var startTime: String?
        var endTime: String?
    }

    func vacation(account: String) async throws -> Vacation {
        let token = try await accessToken(for: account)
        let (data, response) = try await authorizedRequest(
            url: URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/settings/vacation")!, token: token)
        try validate(response)
        return try JSONDecoder().decode(Vacation.self, from: data)
    }

    func setVacation(_ vacation: Vacation, account: String) async throws {
        let token = try await accessToken(for: account)
        var request = URLRequest(url: URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/settings/vacation")!)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(vacation)
        let (_, response) = try await URLSession.shared.data(for: request)
        try validate(response)
    }

    // MARK: Filters

    /// A Gmail filter as the API describes it.
    struct Filter: Codable, Sendable {
        struct Criteria: Codable, Sendable { var query: String? }
        struct Action: Codable, Sendable { var addLabelIds: [String]?; var removeLabelIds: [String]? }
        var id: String?
        var criteria: Criteria
        var action: Action
    }

    /// The account's filters (Settings › Filters in Gmail).
    func filters(account: String) async throws -> [Filter] {
        struct Page: Decodable { let filter: [Filter]? }
        let token = try await accessToken(for: account)
        let (data, response) = try await authorizedRequest(
            url: URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/settings/filters")!, token: token)
        try validate(response)
        return (try JSONDecoder().decode(Page.self, from: data)).filter ?? []
    }

    /// Creates a filter; returns its id. Gmail only acts on mail that
    /// arrives after, as Corres's rules do.
    func createFilter(query: String, addLabelIds: [String], removeLabelIds: [String], account: String) async throws -> String {
        let token = try await accessToken(for: account)
        var request = URLRequest(url: URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/settings/filters")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let filter = Filter(criteria: .init(query: query),
                            action: .init(addLabelIds: addLabelIds.isEmpty ? nil : addLabelIds,
                                          removeLabelIds: removeLabelIds.isEmpty ? nil : removeLabelIds))
        request.httpBody = try JSONEncoder().encode(filter)
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response)
        guard let id = try JSONDecoder().decode(Filter.self, from: data).id else { throw ClientError.decodingFailed }
        return id
    }

    /// Removes a filter. Already gone counts as done.
    func deleteFilter(id: String, account: String) async throws {
        let token = try await accessToken(for: account)
        var request = URLRequest(url: URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/settings/filters/\(id)")!)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (_, response) = try await URLSession.shared.data(for: request)
        if (response as? HTTPURLResponse)?.statusCode == 404 { return }
        try validate(response)
    }

    /// Saves a draft in Gmail's Drafts, so it's there on every device:
    /// creates one, or updates `existingID` in place. Returns the draft's id.
    func saveDraft(raw: String, threadId: String?, existingID: String?, account: String) async throws -> String {
        let token = try await accessToken(for: account)
        let path = existingID.map { "drafts/\($0)" } ?? "drafts"
        var request = URLRequest(url: URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/\(path)")!)
        request.httpMethod = existingID == nil ? "POST" : "PUT"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var message: [String: Any] = ["raw": raw]
        if let threadId { message["threadId"] = threadId }
        request.httpBody = try JSONSerialization.data(withJSONObject: ["message": message])
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response)
        return try JSONDecoder().decode(SavedDraft.self, from: data).id
    }

    /// A draft written anywhere (Gmail on the web, another app), deleted
    /// once Corres has sent it in its place.
    func deleteDraft(id: String, account: String) async throws {
        try await performChange(path: "drafts/\(id)", body: nil, account: account, method: "DELETE")
    }

    // MARK: Mailboxes

    /// A page of any mailbox: a system one (`SPAM`, `TRASH`, `STARRED`,
    /// `SENT`), a label, or All Mail (no label). One row per conversation,
    /// its newest message in that mailbox, the way Gmail lists them. Listed
    /// by message, not by thread: one call, where fetching each thread to
    /// find its newest message cost a call per row and ran into Gmail's
    /// rate limit.
    func listMailbox(labelId: String?, account: String, pageToken: String?,
                     pageSize: Int = 25) async throws -> (items: [Correspondence], nextPageToken: String?) {
        let token = try await accessToken(for: account)
        var components = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages")!
        var queryItems = [URLQueryItem(name: "maxResults", value: String(pageSize * 2))]
        if let labelId { queryItems.append(URLQueryItem(name: "labelIds", value: labelId)) }
        if labelId == "SPAM" || labelId == "TRASH" { queryItems.append(URLQueryItem(name: "includeSpamTrash", value: "true")) }
        if let pageToken { queryItems.append(URLQueryItem(name: "pageToken", value: pageToken)) }
        components.queryItems = queryItems
        let (data, response) = try await authorizedRequest(url: components.url!, token: token)
        try validate(response)
        let list = try JSONDecoder().decode(MessageListResponse.self, from: data)
        // Newest first, so the first message seen for a thread is its newest.
        var seen = Set<String>()
        let ids = (list.messages ?? []).filter { seen.insert($0.threadId ?? $0.id).inserted }.map(\.id)
        let fetched = try await fetchMetadata(ids: ids, account: account).items
        // Listed but none of it came: Gmail held back (rate limit). Said
        // as a failure, so the caller asks for this page again, rather than
        // taking it as an empty mailbox.
        if !ids.isEmpty && fetched.isEmpty { throw ClientError.badResponse(statusCode: 429) }
        let order = Dictionary(ids.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return (fetched.sorted { (order[$0.latestMessageID ?? ""] ?? 0) < (order[$1.latestMessageID ?? ""] ?? 0) },
                list.nextPageToken)
    }

    /// Drafts, newest first, with the draft id Gmail needs to delete one.
    func listDrafts(account: String, pageToken: String?,
                    pageSize: Int = 25) async throws -> (items: [(draftID: String, message: Correspondence)], nextPageToken: String?) {
        let token = try await accessToken(for: account)
        var components = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/drafts")!
        var queryItems = [URLQueryItem(name: "maxResults", value: String(pageSize))]
        if let pageToken { queryItems.append(URLQueryItem(name: "pageToken", value: pageToken)) }
        components.queryItems = queryItems
        let (data, response) = try await authorizedRequest(url: components.url!, token: token)
        try validate(response)
        let list = try JSONDecoder().decode(DraftListResponse.self, from: data)
        let drafts = list.drafts ?? []
        let fetched = try await fetchFull(ids: drafts.map(\.message.id), account: account).items
        let byMessage = Dictionary(fetched.compactMap { item in item.latestMessageID.map { ($0, item) } },
                                   uniquingKeysWith: { first, _ in first })
        return (drafts.compactMap { draft in byMessage[draft.message.id].map { (draft.id, $0) } }, list.nextPageToken)
    }

    /// Every change Corres makes to a mailbox goes through here, so each
    /// one recovers the same way from the two refusals that aren't really
    /// the person's problem, instead of surfacing "Gmail error 403":
    /// - a stale access token (minted before a permission was granted, or
    ///   revoked and re-granted since): drop it and try once with a fresh one;
    /// - Gmail's per-user rate limit, which it also reports as 403 (or 429):
    ///   wait as long as Gmail asks and try again, for up to about 90 seconds.
    /// Anything else is thrown with Gmail's own reason and message.
    private func performChange(path: String, body: Data?, account: String, method: String = "POST") async throws {
        let url = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/\(path)")!
        var refreshedToken = false
        var rateLimitRetries = 0
        while true {
            let token = try await accessToken(for: account)
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            if let body {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = body
            }
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            if 200..<300 ~= status { return }
            let refusal = Self.refusal(from: data)
            let reason = refusal.reason ?? ""
            if Self.rateLimitReasons.contains(reason) || status == 429, rateLimitRetries < Self.changeRetryDelays.count {
                // Wait as long as Gmail asks (never less than the backoff
                // step), and hold background fetching for that long too, so
                // the change isn't competing with sync for the same quota.
                let backoff = Self.changeRetryDelays[rateLimitRetries]
                let asked = Self.retryAfter(response: response, message: refusal.message) ?? 0
                let wait = min(max(backoff, asked), 60)
                rateLimitRetries += 1
                await GmailQuotaGate.shared.pause(account, for: wait)
                try await Task.sleep(for: .milliseconds(Int(wait * 1000)))
                continue
            }
            if (status == 401 || (status == 403 && Self.permissionReasons.contains(reason))) && !refreshedToken {
                refreshedToken = true
                await GoogleTokenProvider.shared.invalidateAccessToken(for: account)
                continue
            }
            throw ClientError.refused(statusCode: status, reason: refusal.reason, message: refusal.message)
        }
    }

    static let permissionReasons: Set<String> = ["insufficientPermissions", "ACCESS_TOKEN_SCOPE_INSUFFICIENT",
                                                 "authError", "forbidden", "PERMISSION_DENIED"]
    static let rateLimitReasons: Set<String> = ["rateLimitExceeded", "userRateLimitExceeded", "RATE_LIMIT_EXCEEDED"]

    /// Seconds between attempts at a change Gmail refused for rate: about
    /// a minute and a half in all, enough to outlast the usual per-minute
    /// window, where three quick tries (8 seconds) often weren't.
    static let changeRetryDelays: [Double] = [1, 2, 4, 8, 15, 30, 30]

    /// How long Gmail asked to wait: the `Retry-After` header (seconds), or
    /// the "Retry after 2026-09-29T22:10:31.123Z" its 429 message carries.
    static func retryAfter(response: URLResponse?, message: String?, now: Date = .now) -> Double? {
        if let header = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After"),
           let seconds = Double(header.trimmingCharacters(in: .whitespaces)) {
            return max(0, seconds)
        }
        guard let message, let range = message.patternRange(#"Retry after (\S+)"#) else { return nil }
        let stamp = message[range].dropFirst("Retry after ".count).trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: stamp) ?? ISO8601DateFormatter().date(from: stamp) else { return nil }
        return max(0, date.timeIntervalSince(now))
    }

    /// Gmail's error body: `{"error": {"code", "message", "status",
    /// "errors": [{"reason", "message"}], "details": [{"reason"}]}}`.
    private static func refusal(from data: Data) -> (reason: String?, message: String?) {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = json["error"] as? [String: Any] else { return (nil, nil) }
        let errors = error["errors"] as? [[String: Any]]
        let details = error["details"] as? [[String: Any]]
        let reason = (errors?.first?["reason"] as? String)
            ?? (details?.compactMap { $0["reason"] as? String }.first)
            ?? (error["status"] as? String)
        return (reason, error["message"] as? String)
    }

    /// Subscribes this account to real-time push: Gmail publishes a
    /// contentless `{emailAddress, historyId}` notification to `topicName`
    /// (a Google Cloud Pub/Sub topic the push relay owns, see
    /// Server/push-relay) whenever the mailbox changes. The token this uses
    /// is the same one every other call here already has; no separate
    /// credential or server-side OAuth flow is needed, and no token ever
    /// leaves the device (the relay never receives it). Expires after about
    /// 7 days per Gmail's own documented limit; the caller (App layer)
    /// renews it at launch rather than this client tracking expiry itself.
    /// Returns the historyId `watch` was established at, mirroring
    /// `fetchInitialInbox`.
    @discardableResult
    func watch(topicName: String, account: String) async throws -> String? {
        let token = try await accessToken(for: account)
        let url = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/watch")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["topicName": topicName, "labelIds": Self.syncedLabels])
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response)
        return try? JSONDecoder().decode(WatchResponse.self, from: data).historyId
    }

    /// Unsubscribes from push for this account (sign-out, or notifications
    /// turned off in Preferences): without this, Gmail keeps notifying the
    /// relay for an account nothing local is listening for anymore until
    /// the subscription's own 7-day expiry.
    func stopWatching(account: String) async throws {
        let token = try await accessToken(for: account)
        let url = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/stop")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (_, response) = try await URLSession.shared.data(for: request)
        try validate(response)
    }

    /// Gmail's label catalog, filtered to user-created labels only (Gmail's
    /// own system ones like INBOX/UNREAD/SENT/CATEGORY_* are excluded via
    /// their own `type: "system"`, since a per-message `labelIds` list, all
    /// `Correspondence.labelIds` ever carries, has no type info to tell
    /// these apart on its own). This is the only place that distinction
    /// exists; the App layer's label directory is built from this.
    func fetchUserLabels(account: String) async throws -> [GmailUserLabel] {
        let token = try await accessToken(for: account)
        let url = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/labels")!
        let (data, response) = try await authorizedRequest(url: url, token: token)
        try validate(response)
        let list = try JSONDecoder().decode(LabelListResponse.self, from: data)
        return (list.labels ?? []).filter { $0.type == "user" }.map { GmailUserLabel(id: $0.id, name: $0.name) }
    }

    private func fetchProfile(token: String) async throws -> Profile {
        let url = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/profile")!
        let (data, response) = try await authorizedRequest(url: url, token: token)
        try validate(response)
        return try JSONDecoder().decode(Profile.self, from: data)
    }

    private func authorizedRequest(url: URL, token: String) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        // Gmail's per-user limit is shared by every device on the account
        // (an iPhone and a Mac both catching up on a year of mail can reach
        // it), and it answers 403 or 429 "rateLimitExceeded" for a minute.
        // Reads wait as long as it asks and try again, as changes do; if it
        // still says no, the refusal carries its reason, so sync treats it
        // as a pause, not as mail that can't be read.
        for (attempt, delay) in Self.readRetryDelays.enumerated() {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard status == 403 || status == 429 else { return (data, response) }
            let refusal = Self.refusal(from: data)
            guard status == 429 || Self.rateLimitReasons.contains(refusal.reason ?? "") else { return (data, response) }
            guard attempt < Self.readRetryDelays.count - 1 else {
                throw ClientError.refused(statusCode: status, reason: refusal.reason ?? "rateLimitExceeded", message: refusal.message)
            }
            let asked = Self.retryAfter(response: response, message: refusal.message) ?? 0
            try await Task.sleep(for: .seconds(min(max(delay, asked), 30)))
        }
        return try await URLSession.shared.data(for: request)
    }

    /// Waits between reads Gmail turned down for rate, then one last try.
    static let readRetryDelays: [Double] = [2, 6, 15, 0]

    private func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw ClientError.badResponse(statusCode: statusCode)
        }
    }

    private func map(_ message: GmailMessage, account: String, bodyLoaded: Bool) -> Correspondence {
        // Real messages routinely repeat headers (every mail-server hop adds
        // its own "Received" header), and uniqueKeysWithValues crashes on any
        // duplicate, which duplicate headers always are. Keep the first.
        let headers = Dictionary((message.payload?.headers ?? []).map { ($0.name.lowercased(), $0.value) },
                                  uniquingKeysWith: { first, _ in first })
        let (sender, senderEmail) = Self.parseFrom(headers["from"] ?? "")
        let subject = headers["subject"] ?? String(localized: "(no subject)")
        let organization = Self.organization(fromEmail: senderEmail)
        let receivedAt = message.internalDate.flatMap { Double($0) }.map { Date(timeIntervalSince1970: $0 / 1000) } ?? .now
        let isUnread = (message.labelIds ?? []).contains("UNREAD")
        let content = Self.content(of: message.payload)
        let htmlBody = content.html
        let body = content.plain ?? message.snippet ?? ""
        let messageIdHeader = headers["message-id"]?.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
        let attachments = content.attachments
        // Who else was actually on this message: without this, "Reply All"
        // has no way to know who to include besides the sender, and would
        // silently behave exactly like a plain "Reply" (a real, reported
        // bug, not a hypothetical).
        let toRecipients = Self.parseAddressList(headers["to"] ?? "")
        let ccRecipients = Self.parseAddressList(headers["cc"] ?? "")
        // Where replies are meant to go, when not to the sender (support
        // desks, booking systems and lists send from no-reply addresses).
        let replyTo = Self.parseAddressList(headers["reply-to"] ?? "")
        let (listUnsubscribeMailto, listUnsubscribeURL) = Self.parseListUnsubscribe(headers["list-unsubscribe"] ?? "")
        // RFC 8058: present only when the sender is explicitly vouching the
        // https URL above is safe to POST to automatically, no page visit
        // needed. The header's value is literally the string
        // "List-Unsubscribe=One-Click"; case folded defensively since
        // nothing in the RFC guarantees senders get the casing exactly
        // right.
        let listUnsubscribeOneClick = listUnsubscribeURL != nil
            && (headers["list-unsubscribe-post"]?.lowercased().contains("one-click") ?? false)
        // Every Authentication-Results, in the message's order: Gmail's
        // own (mx.google.com) is the first.
        let authenticationResults = (message.payload?.headers ?? [])
            .filter { $0.name.caseInsensitiveCompare("Authentication-Results") == .orderedSame }.map(\.value)
        return Self.build(account: account, threadID: message.threadId ?? message.id, messageID: message.id,
                          sender: sender, senderEmail: senderEmail, organization: organization, subject: subject,
                          excerpt: (message.snippet ?? "").previewText, body: body, htmlBody: htmlBody,
                          messageIdHeader: messageIdHeader, receivedAt: receivedAt, isUnread: isUnread,
                          labelIds: message.labelIds ?? [], attachments: attachments, toRecipients: toRecipients,
                          ccRecipients: ccRecipients, replyTo: replyTo, listUnsubscribeMailto: listUnsubscribeMailto,
                          listUnsubscribeURL: listUnsubscribeURL, listUnsubscribeOneClick: listUnsubscribeOneClick,
                          bodyLoaded: bodyLoaded)
            .with(fromDomainVerified: MailAuthentication.dmarcPasses(headers: authenticationResults, receiver: .google,
                                                                     fromAddress: senderEmail))
    }

    /// One email as Corres keeps it, and where it starts (Needs You, Waiting,
    /// or quiet), decided the same way whichever service it came from:
    /// Gmail here, Outlook in `OutlookClient`.
    static func build(account: String, threadID: String, messageID: String, sender: String, senderEmail: String,
                      organization: String, subject: String, excerpt: String, body: String, htmlBody: String?,
                      messageIdHeader: String?, receivedAt: Date, isUnread: Bool, labelIds: [String],
                      attachments: [MailAttachment], toRecipients: [String], ccRecipients: [String], replyTo: [String],
                      listUnsubscribeMailto: String?, listUnsubscribeURL: String?, listUnsubscribeOneClick: Bool,
                      bodyLoaded: Bool) -> Correspondence {
        let automated = Correspondence.isAutomated(listUnsubscribeMailto: listUnsubscribeMailto,
                                                   listUnsubscribeURL: listUnsubscribeURL, senderEmail: senderEmail,
                                                   senderName: sender, body: bodyLoaded ? body : nil, html: htmlBody)
        // What the message itself says: the subject plus the full text
        // when it's here, or the service's snippet (the opening) until it is.
        let text = subject + "\n" + body
        let asks = MailSignals.asksSomething(text)
        let fromYou = senderEmail.lowercased() == account.lowercased()
        let bulk = InboxClassifier.bulkKind(labelIds: labelIds, looksAutomated: automated)
        let deadline = fromYou ? nil
            : (bulk?.isPromotable == true ? MailSignals.timeSensitiveDate(in: text, senderEmail: senderEmail, receivedAt: receivedAt)
               : bulk == nil ? MailSignals.deadline(in: text, senderEmail: senderEmail, receivedAt: receivedAt) : nil)
        var (attention, reason) = InboxClassifier.initialAttention(
            isUnread: isUnread, labelIds: labelIds, looksAutomated: automated, receivedAt: receivedAt,
            isCopiedOnly: Correspondence.isCopiedOnly(account: account, to: toRecipients, cc: ccRecipients),
            asksSomething: asks, deadline: deadline, text: text, isVIP: InboxClassifier.isVIP(senderEmail))
        if fromYou {
            (attention, reason) = InboxClassifier.afterYouWrote(
                asksSomething: asks, toPeople: MailSignals.hasPersonRecipient(toRecipients + ccRecipients, account: account),
                sentAt: receivedAt)
        } else if attention == .needsYou, InboxClassifier.ownAddresses.contains(senderEmail.lowercased()) {
            // From another of your own accounts: a note to yourself.
            (attention, reason) = (.quiet, InboxClassifier.fromYouReason)
        }
        return Correspondence(
            id: ThreadID(account: account, providerID: threadID),
            sender: sender, senderEmail: senderEmail, organization: organization, subject: subject,
            excerpt: excerpt, body: body, htmlBody: htmlBody, messageIdHeader: messageIdHeader,
            latestMessageID: messageID, receivedAt: receivedAt, dueAt: attention == .needsYou ? deadline : nil,
            reason: reason, attention: attention, attachments: attachments, isUnread: isUnread,
            labelIds: labelIds,
            toRecipients: toRecipients, ccRecipients: ccRecipients, replyTo: replyTo,
            listUnsubscribeMailto: listUnsubscribeMailto, listUnsubscribeURL: listUnsubscribeURL,
            listUnsubscribeOneClick: listUnsubscribeOneClick, isBodyLoaded: bodyLoaded,
            waitingSince: attention == .waiting ? receivedAt : nil)
    }

    /// Every part that's a file to download, as Gmail lists them: not the
    /// text being shown, and not a picture the HTML shows in place (a logo,
    /// a signature). A part with a Content-ID the HTML never refers to is
    /// still a file: Mail on an iPhone gives every attachment one, and
    /// hiding those (as was done for any part with a Content-ID) lost the
    /// PDF or photo altogether. A part with no name (an invitation's
    /// calendar part, an unnamed picture) is listed under a made-up one.
    private static func collectAttachments(from part: GmailMessagePart, path: [Int], shown: Set<[Int]>, references: [String],
                                           named: inout [MailAttachment], unnamed: inout [MailAttachment]) {
        let type = (part.mimeType ?? "").lowercased()
        if let attachmentId = part.body?.attachmentId, !type.hasPrefix("multipart/"), !shown.contains(path),
           !InlineImages.isReferenced(contentID: part.contentID, filename: part.filename, in: references) {
            let mimeType = part.mimeType ?? "application/octet-stream"
            if let filename = part.filename, !filename.isEmpty {
                named.append(MailAttachment(id: attachmentId, filename: filename, mimeType: mimeType, sizeBytes: part.body?.size ?? 0))
            } else if type != "text/plain", type != "text/html" {
                // Unnamed text is an alternative that isn't shown (the
                // plain text beside the HTML), not a file.
                unnamed.append(MailAttachment(id: attachmentId, filename: fallbackName(for: type), mimeType: mimeType,
                                              sizeBytes: part.body?.size ?? 0))
            }
        }
        for (index, child) in (part.parts ?? []).enumerated() {
            collectAttachments(from: child, path: path + [index], shown: shown, references: references, named: &named, unnamed: &unnamed)
        }
    }

    private static func fallbackName(for mimeType: String) -> String {
        if mimeType.hasPrefix("text/calendar") || mimeType == "application/ics" { return "invite.ics" }
        if mimeType == "message/rfc822" { return "Message.eml" }
        if mimeType.hasPrefix("image/") {
            let subtype = mimeType.dropFirst("image/".count)
            return "Image." + (subtype == "jpeg" ? "jpg" : subtype.replacingOccurrences(of: "svg+xml", with: "svg"))
        }
        return "Attachment"
    }

    /// Attachment content is never included in `users.messages.get`'s
    /// response for anything but the smallest parts; this is Gmail's
    /// dedicated endpoint for fetching the actual bytes, called on demand
    /// (a tap on the attachment) rather than as part of every sync.
    func fetchAttachmentData(messageId: String, attachmentId: String, account: String) async throws -> Data {
        let data = try await fetchPartData(messageId: messageId, attachmentId: attachmentId, account: account)
        guard let decoded = Data(base64URLEncoded: data) else { throw ClientError.decodingFailed }
        return decoded
    }

    /// A part's bytes as Gmail sends them (base64url).
    private func fetchPartData(messageId: String, attachmentId: String, account: String) async throws -> String {
        let token = try await accessToken(for: account)
        await GmailQuotaGate.shared.reserve(GmailQuotaGate.unitsPerMessageFetch, for: account)
        let url = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/\(messageId)/attachments/\(attachmentId)")!
        let (data, response) = try await authorizedRequest(url: url, token: token)
        try validate(response)
        return try JSONDecoder().decode(AttachmentDataResponse.self, from: data).data
    }

    /// "Name" <email@domain.com> or a bare address.
    static func parseFrom(_ raw: String) -> (name: String, email: String) {
        if let ltIndex = raw.firstIndex(of: "<"), let gtIndex = raw.firstIndex(of: ">"), ltIndex < gtIndex {
            let email = String(raw[raw.index(after: ltIndex)..<gtIndex]).trimmingCharacters(in: .whitespaces)
            var name = String(raw[..<ltIndex]).trimmingCharacters(in: .whitespaces)
            name = name.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            return (name.isEmpty ? email : name, email)
        }
        let email = raw.trimmingCharacters(in: .whitespaces)
        return (email, email)
    }

    /// A `To`/`Cc` header is a comma-separated list of the same
    /// "Name" <email> / bare-address entries `parseFrom` already handles
    /// one at a time; splits on top-level commas only (a display name can
    /// legally contain one inside quotes, e.g. `"Doe, Jane" <jane@x.com>`,
    /// which a naive `.split(separator: ",")` would wrongly treat as two
    /// entries), then reuses `parseFrom` per entry. Returns bare, lowercased
    /// addresses, ready for direct use in a `To`/`Cc` field.
    static func parseAddressList(_ raw: String) -> [String] {
        guard !raw.isEmpty else { return [] }
        var entries: [String] = []
        var current = ""
        var insideQuotes = false
        for character in raw {
            if character == "\"" { insideQuotes.toggle() }
            if character == "," && !insideQuotes {
                entries.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        if !current.trimmingCharacters(in: .whitespaces).isEmpty { entries.append(current) }
        return entries.compactMap { entry in
            let email = parseFrom(entry).email.trimmingCharacters(in: .whitespaces).lowercased()
            return email.isEmpty ? nil : email
        }
    }

    /// `List-Unsubscribe` (RFC 2369): one or more comma-separated URIs, each
    /// wrapped in angle brackets, e.g. `<mailto:x@y.com?subject=unsub>,
    /// <https://y.com/unsub?id=1>`. Extracted via the angle brackets
    /// themselves rather than a naive comma-split: a URI's own query string
    /// can legally contain a comma, which a plain split would wrongly treat
    /// as a second entry.
    private static let angleBracketURIRegex = try? NSRegularExpression(pattern: #"<([^>]+)>"#)

    static func parseListUnsubscribe(_ raw: String) -> (mailto: String?, url: String?) {
        guard let regex = angleBracketURIRegex, !raw.isEmpty else { return (nil, nil) }
        let range = NSRange(raw.startIndex..., in: raw)
        var mailto: String?
        var url: String?
        for match in regex.matches(in: raw, range: range) {
            guard let uriRange = Range(match.range(at: 1), in: raw) else { continue }
            let uri = String(raw[uriRange]).trimmingCharacters(in: .whitespaces)
            let lowercased = uri.lowercased()
            if mailto == nil, lowercased.hasPrefix("mailto:") {
                mailto = uri
            } else if url == nil, lowercased.hasPrefix("https://") || lowercased.hasPrefix("http://") {
                url = uri
            }
        }
        return (mailto, url)
    }

    static func organization(fromEmail email: String) -> String {
        guard let domain = email.split(separator: "@").last else { return "" }
        let name = domain.split(separator: ".").first.map(String.init) ?? String(domain)
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    /// Depth-first search for the first part matching `mimeType`; multipart
    /// messages nest arbitrarily (plain/html alternatives, inline attachments).
    private static func bodyPart(mimeType: String, from part: GmailMessagePart?) -> String? {
        guard let part else { return nil }
        if part.mimeType == mimeType, part.body?.data != nil { return text(of: part) }
        for child in part.parts ?? [] {
            if let found = bodyPart(mimeType: mimeType, from: child) { return found }
        }
        return nil
    }

    private static func text(of part: GmailMessagePart) -> String? {
        guard let data = part.body?.data else { return nil }
        return decodeBase64URL(data, charset: part.header("Content-Type").flatMap(charset(inContentType:)),
                               isHTML: part.mimeType?.lowercased() == "text/html")
    }

    /// Gmail hands back a part's bytes in the charset the sender wrote it
    /// in (Shift_JIS, GB2312, Windows-1252…), not converted to UTF-8.
    /// Read only as UTF-8, those bodies failed and the email showed just
    /// its snippet; read as labelled, as IMAP mail already is. HTML that
    /// doesn't say in its header says in its own `<meta>` tag, as a
    /// browser reads it. Never nothing: bytes that fit no charset are read
    /// as UTF-8 with the odd character replaced, as Gmail shows them, not
    /// dropped along with the whole email.
    private static func decodeBase64URL(_ value: String, charset: String?, isHTML: Bool = false) -> String? {
        guard let data = Data(base64URLEncoded: value) else { return nil }
        let declared = charset ?? (isHTML ? MessageLayout.metaCharset(in: data) : nil)
        if let declared, let encoding = Charset.encoding(named: declared), encoding != .utf8,
           let text = String(data: data, encoding: encoding) {
            return text
        }
        if let text = String(data: data, encoding: .utf8) { return text }
        // Labelled UTF-8 with a stray byte: the rest is still UTF-8.
        if let declared, Charset.encoding(named: declared) == .utf8 { return String(decoding: data, as: UTF8.self) }
        return String(data: data, encoding: .windowsCP1252) ?? String(decoding: data, as: UTF8.self)
    }

    /// The `charset` parameter of a Content-Type header value.
    static func charset(inContentType value: String) -> String? {
        for piece in value.split(separator: ";").dropFirst() {
            let pair = piece.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard pair.count == 2, pair[0].lowercased() == "charset" else { continue }
            let name = pair[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            return name.isEmpty ? nil : name
        }
        return nil
    }

    /// The message's text parts (`MessageLayout`), and its HTML as sent,
    /// before its pictures are put in.
    private static func layout(of payload: GmailMessagePart) -> (pieces: [MessageLayout.Piece], texts: [(kind: MessageLayout.Kind, text: String)], html: String?) {
        let pieces = MessageLayout.pieces(of: payload.outline)
        let texts = pieces.compactMap { piece in
            payload.part(at: piece.path).flatMap(text(of:)).map { (kind: piece.kind, text: $0) }
        }
        return (pieces, texts, MessageLayout.html(joining: texts))
    }

    /// What a message shows: its HTML, with the pictures it carries put in
    /// place as data: URIs (a web view can't load "cid:"), its text, and
    /// its attachments. Pictures Gmail sends only as an id are fetched
    /// first (`completing`); one still missing keeps its "cid:" reference.
    private static func content(of payload: GmailMessagePart?) -> (html: String?, plain: String?, attachments: [MailAttachment]) {
        guard let payload else { return (nil, nil, []) }
        let (pieces, texts, sentHTML) = layout(of: payload)
        let references = sentHTML.map(InlineImages.references(in:)) ?? []
        var html = sentHTML
        if let sentHTML, !references.isEmpty {
            let images = payload.all.compactMap { part -> InlineImages.Image? in
                guard (part.parts ?? []).isEmpty, let data = part.body?.data,
                      InlineImages.isReferenced(contentID: part.contentID, filename: part.filename, in: references) else { return nil }
                return InlineImages.Image(contentID: part.contentID, filename: part.filename,
                                          dataURI: InlineImages.dataURI(base64: base64URLToStandardBase64(data),
                                                                        mimeType: part.mimeType, filename: part.filename))
            }
            html = InlineImages.resolving(sentHTML, with: images)
        }
        // The text for search, summaries and replies: the plain part, or
        // the HTML read as text. Gmail's snippet (its first line or two)
        // stood in when there was no plain part, as if it were the email.
        let plain = sentHTML == nil ? MessageLayout.plain(joining: texts)
            : bodyPart(mimeType: "text/plain", from: payload) ?? MailDigest.readableText(body: "", html: sentHTML)
        var named: [MailAttachment] = []
        var unnamed: [MailAttachment] = []
        collectAttachments(from: payload, path: [], shown: Set(pieces.map(\.path)), references: references,
                           named: &named, unnamed: &unnamed)
        // An invitation's own calendar part is unnamed, usually beside a
        // named invite.ics: listed only when it's the only one.
        let hasCalendar = named.contains { AttachmentKind(filename: $0.filename, mimeType: $0.mimeType) == .calendar }
        let extra = unnamed.filter { !hasCalendar || AttachmentKind(filename: $0.filename, mimeType: $0.mimeType) != .calendar }
        return (html, plain, named + extra)
    }

    /// The parts `format=full` sent only as an id that the email needs to
    /// be read: its text (a long one), then the pictures its HTML refers
    /// to, within `imageBytes` (what's left of this fetch's allowance).
    /// Not whole when its text couldn't be had: the caller doesn't save it
    /// as loaded, so it's asked for again rather than showing part of it.
    private func completing(_ message: GmailMessage, account: String, imageBytes: inout Int) async -> (message: GmailMessage, isWhole: Bool) {
        guard var payload = message.payload else { return (message, true) }
        var message = message
        var isWhole = true
        let missingText = Set(MessageLayout.pieces(of: payload.outline).compactMap { payload.part(at: $0.path) }
            .filter(\.isOnlyAnID).compactMap(\.body?.attachmentId))
        if !missingText.isEmpty {
            let fetched = await fetchParts(Array(missingText), messageId: message.id, account: account)
            isWhole = missingText.allSatisfy { fetched[$0] != nil }
            payload = payload.filling(fetched)
            message.payload = payload
        }
        guard let html = Self.layout(of: payload).html else { return (message, isWhole) }
        let references = InlineImages.references(in: html)
        guard !references.isEmpty else { return (message, isWhole) }
        var allowance = min(Self.inlineImageLimit.perMessage, imageBytes)
        var wanted: [String] = []
        for part in payload.all where (part.parts ?? []).isEmpty && part.isOnlyAnID
            && InlineImages.isReferenced(contentID: part.contentID, filename: part.filename, in: references) {
            let size = part.body?.size ?? 0
            guard let id = part.body?.attachmentId, wanted.count < Self.inlineImageLimit.parts, size <= allowance else { continue }
            allowance -= size
            imageBytes -= size
            wanted.append(id)
        }
        guard !wanted.isEmpty else { return (message, isWhole) }
        message.payload = payload.filling(await fetchParts(wanted, messageId: message.id, account: account))
        return (message, isWhole)
    }

    /// How much of an email's pictures are fetched with it, and of a whole
    /// fetch's (a background fill asks for fifty emails at once). What's
    /// over waits until the email is opened (`ThreadActionService.loadContent`).
    /// A logo or a signature picture is a few KB; a pasted photo, a few MB.
    private static let inlineImageLimit = (perMessage: 6_000_000, perFetch: 15_000_000, parts: 24)

    /// Parts by attachment id, four at a time. One that fails is left out
    /// of the answer.
    private func fetchParts(_ ids: [String], messageId: String, account: String) async -> [String: String] {
        var fetched: [String: String] = [:]
        for chunk in ids.chunked(into: 4) {
            await withTaskGroup(of: (String, String?).self) { group in
                for id in chunk {
                    group.addTask { (id, try? await self.fetchPartData(messageId: messageId, attachmentId: id, account: account)) }
                }
                for await (id, data) in group {
                    if let data { fetched[id] = data }
                }
            }
        }
        return fetched
    }

    private static func base64URLToStandardBase64(_ value: String) -> String {
        var base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        return base64
    }
}

private extension Data {
    init?(base64URLEncoded value: String) {
        var base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        self.init(base64Encoded: base64)
    }
}

private struct DraftListResponse: Decodable {
    struct Item: Decodable {
        struct Message: Decodable { let id: String; let threadId: String? }
        let id: String
        let message: Message
    }
    let drafts: [Item]?
    let nextPageToken: String?
}

private struct MessageListResponse: Decodable {
    struct Item: Decodable { let id: String; let threadId: String? }
    let messages: [Item]?
    let nextPageToken: String?
}

private struct HistoryListResponse: Decodable {
    struct HistoryRecord: Decodable {
        struct MessageRef: Decodable { let id: String; let threadId: String?; let labelIds: [String]? }
        struct MessageAdded: Decodable { let message: MessageRef }
        struct LabelChange: Decodable { let message: MessageRef; let labelIds: [String]? }
        let messagesAdded: [MessageAdded]?
        let labelsAdded: [LabelChange]?
        let labelsRemoved: [LabelChange]?
        let messagesDeleted: [MessageAdded]?
    }
    let history: [HistoryRecord]?
    let historyId: String?
    let nextPageToken: String?
}

private struct Profile: Decodable { let historyId: String? }

private struct SentMessage: Decodable { let threadId: String }

private struct SavedDraft: Decodable { let id: String }

private struct AttachmentDataResponse: Decodable { let data: String }

private struct WatchResponse: Decodable { let historyId: String? }

/// A real, user-created Gmail label: `id` is what `Correspondence.labelIds`
/// and `GmailAPIClient.modifyThread` both traffic in, `name` is what a
/// person actually recognizes.
struct GmailUserLabel: Identifiable, Hashable, Sendable {
    let id: String
    let name: String

    /// An Outlook folder: mail is moved into it, never tagged with it.
    var isFolder: Bool { id.hasPrefix("folder:") }
    /// An Outlook category: a tag, never a place to move mail.
    var isCategory: Bool { id.hasPrefix("cat:") }
}

private struct LabelListResponse: Decodable {
    struct Label: Decodable { let id: String; let name: String; let type: String? }
    let labels: [Label]?
}

private struct GmailMessage: Decodable {
    let id: String
    let threadId: String?
    let snippet: String?
    let internalDate: String?
    let labelIds: [String]?
    var payload: GmailMessagePart?
}

private struct GmailMessagePart: Decodable {
    let mimeType: String?
    let filename: String?
    let headers: [Header]?
    var body: Body?
    var parts: [GmailMessagePart]?

    struct Header: Decodable { let name: String; let value: String }
    struct Body: Decodable { var data: String?; let attachmentId: String?; let size: Int? }

    func header(_ name: String) -> String? {
        headers?.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    var contentID: String? { header("Content-ID") }

    var outline: MIMEOutline {
        MIMEOutline(mimeType: mimeType ?? "", disposition: header("Content-Disposition"), filename: filename,
                    children: (parts ?? []).map(\.outline))
    }

    func part(at path: [Int]) -> GmailMessagePart? {
        guard let first = path.first else { return self }
        guard let parts, parts.indices.contains(first) else { return nil }
        return parts[first].part(at: Array(path.dropFirst()))
    }

    /// This part and every part inside it, depth first.
    var all: [GmailMessagePart] { [self] + (parts ?? []).flatMap(\.all) }

    /// Only here as an id to ask for separately (`format=full` leaves out
    /// anything with a file name, and large parts).
    var isOnlyAnID: Bool { body?.data == nil && body?.attachmentId != nil }

    /// With the bytes fetched separately put in place, by attachment id.
    func filling(_ fetched: [String: String]) -> GmailMessagePart {
        var copy = self
        if let id = body?.attachmentId, body?.data == nil, let data = fetched[id] { copy.body?.data = data }
        copy.parts = parts?.map { $0.filling(fetched) }
        return copy
    }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
