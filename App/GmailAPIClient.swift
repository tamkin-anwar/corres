import Foundation

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
    enum ClientError: Error { case notSignedIn, badResponse(statusCode: Int), decodingFailed, historyExpired }

    /// One fetch, either a first full sync or a cursor-based catch-up; the
    /// caller (GmailSyncService) persists `historyId` and passes it back in
    /// as the starting point for the next call.
    ///
    /// `failedMessageIDs`: individual `users.messages.get` calls that still
    /// failed after `fetchMessages`'s own bounded retries — a real, found
    /// gap (not hypothetical): `historyId` advances for the whole batch
    /// regardless of which individual messages actually came back, since
    /// Gmail's history cursor is a single whole-mailbox counter with no way
    /// to partially advance it. Silently dropping these here, the way this
    /// used to, meant a message caught in a transient failure during sync
    /// was gone for good the moment the cursor moved past it — the next
    /// incremental sync only asks Gmail what changed *after* that point,
    /// never re-offering something already inside the window just
    /// consumed. `GmailSyncService` is what actually closes the loop: it
    /// persists these ids and retries fetching them by id directly on every
    /// later sync, independent of the cursor, until they succeed.
    struct SyncResult { let items: [Correspondence]; let historyId: String?; let failedMessageIDs: [String] }

    /// Caps the very first sync at a couple hundred messages, not a full
    /// mailbox import: matches "do not attempt to support every... immediately,"
    /// and gives a fast first real result to look at. Every sync after this
    /// one is incremental via the history cursor and has no such cap.
    private let initialSyncPageSize = 100
    private let initialSyncMaxPages = 2

    private let historyPageSize = 100

    /// Threads that live only in Sent (you started the conversation, no
    /// inbound reply synced yet) are otherwise invisible to Corres, since
    /// everything else only ever looked at INBOX. Listed and fetched
    /// alongside INBOX, not instead of it.
    private static let syncedLabels = ["INBOX", "SENT"]

    /// A full listing of the inbox and sent mail (paginated per label), used
    /// the first time an account syncs, or whenever a stored history cursor
    /// has expired.
    func fetchInitialInbox(account: String) async throws -> SyncResult {
        let token = try await accessToken(for: account)
        var ids: Set<String> = []
        for label in Self.syncedLabels {
            ids.formUnion(try await listMessageIDs(token: token, label: label))
        }
        let (items, failedIDs) = await fetchMessages(ids: Array(ids), token: token, account: account)
        // Best-effort: if the profile call fails, the sync itself still
        // succeeded, just without a cursor for next time. The following
        // sync falls back to another full listing rather than failing.
        let historyId = try? await fetchProfile(token: token).historyId
        return SyncResult(items: items, historyId: historyId, failedMessageIDs: failedIDs)
    }

    /// Gmail's History API: only what changed since `cursor`, not a re-list
    /// of the whole inbox. Throws `.historyExpired` when the cursor is older
    /// than Gmail's retention window (about a week); the caller is expected
    /// to recover by calling `fetchInitialInbox` instead. Queried once per
    /// label (the History API's own `labelId` filter only accepts one at a
    /// time), merged into a single result.
    func fetchIncremental(account: String, since cursor: String) async throws -> SyncResult {
        let token = try await accessToken(for: account)
        var ids: Set<String> = []
        var historyId: String?
        for label in Self.syncedLabels {
            let page = try await listHistoryMessageIDs(since: cursor, token: token, label: label)
            ids.formUnion(page.ids)
            historyId = Self.newerHistoryId(historyId, page.historyId)
        }
        let (items, failedIDs) = await fetchMessages(ids: Array(ids), token: token, account: account)
        return SyncResult(items: items, historyId: historyId ?? cursor, failedMessageIDs: failedIDs)
    }

    /// Re-attempts specific message ids directly, independent of the
    /// history cursor or any label listing — the retry path
    /// `GmailSyncService` uses for ids a previous sync's `failedMessageIDs`
    /// already reported, since by the time it tries again the cursor has
    /// long since moved past the point where the ordinary sync path would
    /// ever offer them again.
    func fetchMessages(ids: [String], account: String) async throws -> (items: [Correspondence], failedIDs: [String]) {
        guard !ids.isEmpty else { return ([], []) }
        let token = try await accessToken(for: account)
        return await fetchMessages(ids: ids, token: token, account: account)
    }

    /// Gmail's own `historyId` is a single, whole-mailbox-wide counter (the
    /// per-label query only filters which history *records* come back, not
    /// which counter is used), so the two label queries should normally
    /// agree; comparing numerically (not lexicographically: "100" < "99" as
    /// strings) picks the more advanced one if they ever don't.
    private static func newerHistoryId(_ a: String?, _ b: String?) -> String? {
        guard let a else { return b }
        guard let b else { return a }
        guard let ai = UInt64(a), let bi = UInt64(b) else { return a }
        return bi > ai ? b : a
    }

    /// Fetches up to `messageFetchConcurrency` messages at once instead of
    /// one at a time. A full sync can mean a couple hundred individual
    /// `users.messages.get` calls (see `initialSyncMaxPages` x 2 labels);
    /// awaiting them sequentially means a real network round trip per
    /// message, one after another, which is the actual reason a sync could
    /// take a long time and make the app feel like it's dragging while it
    /// runs, not anything about SwiftUI rendering. A bounded pool, not
    /// unbounded concurrency, avoids firing hundreds of requests at once
    /// against Gmail's per-user rate limits.
    ///
    /// A single message's own `fetchMessage` gets a couple of real retries
    /// before this gives up on it (`messageFetchAttempts`, a short fixed
    /// delay rather than `OutboxService`'s longer exponential backoff —
    /// this runs for every message in a sync, not once for a person
    /// waiting on a send, so it needs to stay cheap even though it's the
    /// same class of transient-failure problem). Whatever's still failing
    /// after that comes back in `failedIDs` instead of silently vanishing;
    /// see `SyncResult.failedMessageIDs`'s doc comment for why that
    /// distinction matters here specifically.
    private func fetchMessages(ids: [String], token: String, account: String) async -> (items: [Correspondence], failedIDs: [String]) {
        await withTaskGroup(of: (Correspondence?, String).self) { group in
            var pending = ids[...]
            func addNext() {
                guard let id = pending.popFirst() else { return }
                group.addTask {
                    for attempt in 1...Self.messageFetchAttempts {
                        if let message = try? await self.fetchMessage(id: id, token: token) {
                            return (self.map(message, account: account), id)
                        }
                        if attempt < Self.messageFetchAttempts {
                            try? await Task.sleep(for: .milliseconds(Self.messageFetchRetryDelayMs))
                        }
                    }
                    return (nil, id)
                }
            }
            for _ in 0..<Self.messageFetchConcurrency { addNext() }
            var results: [Correspondence] = []
            var failedIDs: [String] = []
            while let (correspondence, id) = await group.next() {
                if let correspondence { results.append(correspondence) } else { failedIDs.append(id) }
                addNext()
            }
            return (results, failedIDs)
        }
    }

    private static let messageFetchConcurrency = 8
    private static let messageFetchAttempts = 3
    private static let messageFetchRetryDelayMs = 400

    /// Local search (`MailQuery.filter`) only ever sees what's already
    /// synced, capped at a couple hundred recent messages; typing in an
    /// older subject or a sender from months ago silently finds nothing,
    /// which is exactly the kind of "wait, my email app can't find my own
    /// email" moment that erodes trust in a mail client. Gmail's own search
    /// (`q=`, its full query syntax, not just a substring match) covers the
    /// whole real mailbox instead. Capped, not exhaustive: a search result
    /// list is for finding the one thing you're after, not a second full
    /// sync of the account.
    private let searchPageSize = 25

    func searchMessages(query: String, account: String) async throws -> [Correspondence] {
        let token = try await accessToken(for: account)
        var components = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages")!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "maxResults", value: String(searchPageSize)),
        ]
        let (data, response) = try await authorizedRequest(url: components.url!, token: token)
        try validate(response)
        let list = try JSONDecoder().decode(MessageListResponse.self, from: data)
        return await fetchMessages(ids: list.messages?.map(\.id) ?? [], token: token, account: account).items
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

    private func searchByRFC822MessageID(_ value: String, account: String) async throws -> ThreadID? {
        let token = try await accessToken(for: account)
        var components = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages")!
        components.queryItems = [URLQueryItem(name: "q", value: "rfc822msgid:\(value)")]
        let (data, response) = try await authorizedRequest(url: components.url!, token: token)
        try validate(response)
        let list = try JSONDecoder().decode(MessageListResponse.self, from: data)
        guard let match = list.messages?.first, let threadId = match.threadId else { return nil }
        return ThreadID(account: account, providerID: threadId)
    }

    private func accessToken(for account: String) async throws -> String {
        do {
            return try await GoogleTokenProvider.shared.accessToken(for: account)
        } catch {
            throw ClientError.notSignedIn
        }
    }

    private func listMessageIDs(token: String, label: String) async throws -> [String] {
        var ids: [String] = []
        var pageToken: String?
        var pagesFetched = 0
        repeat {
            var components = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages")!
            var queryItems = [
                URLQueryItem(name: "labelIds", value: label),
                URLQueryItem(name: "maxResults", value: String(initialSyncPageSize)),
            ]
            if let pageToken { queryItems.append(URLQueryItem(name: "pageToken", value: pageToken)) }
            components.queryItems = queryItems
            let (data, response) = try await authorizedRequest(url: components.url!, token: token)
            try validate(response)
            let list = try JSONDecoder().decode(MessageListResponse.self, from: data)
            ids.append(contentsOf: list.messages?.map(\.id) ?? [])
            pageToken = list.nextPageToken
            pagesFetched += 1
        } while pageToken != nil && pagesFetched < initialSyncMaxPages
        return ids
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
        let token = try await accessToken(for: account)
        let url = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/threads/\(threadId)/modify")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: [String]] = [:]
        if !addLabelIds.isEmpty { body["addLabelIds"] = addLabelIds }
        if !removeLabelIds.isEmpty { body["removeLabelIds"] = removeLabelIds }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (_, response) = try await URLSession.shared.data(for: request)
        try validate(response)
    }

    /// Gmail's dedicated Trash endpoint, distinct from `modify`: it moves the
    /// whole thread to Trash (auto-deleted by Gmail after 30 days), rather
    /// than just changing which labels it carries.
    func trashThread(threadId: String, account: String) async throws {
        let token = try await accessToken(for: account)
        let url = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/threads/\(threadId)/trash")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (_, response) = try await URLSession.shared.data(for: request)
        try validate(response)
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

    private func fetchMessage(id: String, token: String) async throws -> GmailMessage {
        let url = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/\(id)?format=full")!
        let (data, response) = try await authorizedRequest(url: url, token: token)
        try validate(response)
        return try JSONDecoder().decode(GmailMessage.self, from: data)
    }

    private func authorizedRequest(url: URL, token: String) async throws -> (Data, URLResponse) {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return try await URLSession.shared.data(for: request)
    }

    private func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw ClientError.badResponse(statusCode: statusCode)
        }
    }

    private func map(_ message: GmailMessage, account: String) -> Correspondence {
        // Real messages routinely repeat headers (every mail-server hop adds
        // its own "Received" header), and uniqueKeysWithValues crashes on any
        // duplicate, which duplicate headers always are. Keep the first.
        let headers = Dictionary((message.payload?.headers ?? []).map { ($0.name.lowercased(), $0.value) },
                                  uniquingKeysWith: { first, _ in first })
        let (sender, senderEmail) = Self.parseFrom(headers["from"] ?? "")
        let subject = headers["subject"] ?? "(no subject)"
        let organization = Self.organization(fromEmail: senderEmail)
        let receivedAt = message.internalDate.flatMap { Double($0) }.map { Date(timeIntervalSince1970: $0 / 1000) } ?? .now
        let isUnread = (message.labelIds ?? []).contains("UNREAD")
        let plainText = Self.bodyPart(mimeType: "text/plain", from: message.payload)
        let rawHTML = Self.bodyPart(mimeType: "text/html", from: message.payload)
        let htmlBody = rawHTML.map { Self.inlineCIDImages(in: $0, from: message.payload) }
        let body = plainText ?? message.snippet ?? ""
        let messageIdHeader = headers["message-id"]?.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
        var attachments: [MailAttachment] = []
        Self.collectAttachments(from: message.payload, into: &attachments)
        // Who else was actually on this message: without this, "Reply All"
        // has no way to know who to include besides the sender, and would
        // silently behave exactly like a plain "Reply" (a real, reported
        // bug, not a hypothetical).
        let toRecipients = Self.parseAddressList(headers["to"] ?? "")
        let ccRecipients = Self.parseAddressList(headers["cc"] ?? "")
        let (listUnsubscribeMailto, listUnsubscribeURL) = Self.parseListUnsubscribe(headers["list-unsubscribe"] ?? "")
        // RFC 8058: present only when the sender is explicitly vouching the
        // https URL above is safe to POST to automatically, no page visit
        // needed. The header's value is literally the string
        // "List-Unsubscribe=One-Click"; case folded defensively since
        // nothing in the RFC guarantees senders get the casing exactly
        // right.
        let listUnsubscribeOneClick = listUnsubscribeURL != nil
            && (headers["list-unsubscribe-post"]?.lowercased().contains("one-click") ?? false)
        let automated = Correspondence.isAutomated(listUnsubscribeMailto: listUnsubscribeMailto,
                                                   listUnsubscribeURL: listUnsubscribeURL, senderEmail: senderEmail)
        let (attention, reason) = InboxClassifier.initialAttention(isUnread: isUnread, labelIds: message.labelIds ?? [],
                                                                  looksAutomated: automated)
        return Correspondence(
            id: ThreadID(account: account, providerID: message.threadId ?? message.id),
            sender: sender, senderEmail: senderEmail, organization: organization, subject: subject,
            excerpt: (message.snippet ?? "").decodingHTMLEntities, body: body, htmlBody: htmlBody, messageIdHeader: messageIdHeader,
            latestMessageID: message.id, receivedAt: receivedAt, dueAt: nil,
            reason: reason, attention: attention, attachments: attachments, isUnread: isUnread,
            labelIds: message.labelIds ?? [],
            toRecipients: toRecipients, ccRecipients: ccRecipients,
            listUnsubscribeMailto: listUnsubscribeMailto, listUnsubscribeURL: listUnsubscribeURL,
            listUnsubscribeOneClick: listUnsubscribeOneClick)
    }

    /// A real attachment (something to download) versus an inline image
    /// already rendered by `inlineCIDImages` are both MIME parts with a
    /// `body.attachmentId`, distinguished by whether the part carries a
    /// `Content-ID` header: an inline image always does (that's how the
    /// HTML's `cid:` reference finds it) and a real attachment never does.
    /// Filtering those out here is what stops every embedded logo/signature
    /// image from also showing up as a downloadable attachment underneath.
    private static func collectAttachments(from part: GmailMessagePart?, into result: inout [MailAttachment]) {
        guard let part else { return }
        let hasContentID = part.headers?.contains { $0.name.lowercased() == "content-id" } ?? false
        if let filename = part.filename, !filename.isEmpty, !hasContentID,
           let attachmentId = part.body?.attachmentId {
            result.append(MailAttachment(id: attachmentId, filename: filename,
                                          mimeType: part.mimeType ?? "application/octet-stream",
                                          sizeBytes: part.body?.size ?? 0))
        }
        for child in part.parts ?? [] {
            collectAttachments(from: child, into: &result)
        }
    }

    /// Attachment content is never included in `users.messages.get`'s
    /// response for anything but the smallest parts; this is Gmail's
    /// dedicated endpoint for fetching the actual bytes, called on demand
    /// (a tap on the attachment) rather than as part of every sync.
    func fetchAttachmentData(messageId: String, attachmentId: String, account: String) async throws -> Data {
        let token = try await accessToken(for: account)
        let url = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/\(messageId)/attachments/\(attachmentId)")!
        let (data, response) = try await authorizedRequest(url: url, token: token)
        try validate(response)
        let attachment = try JSONDecoder().decode(AttachmentDataResponse.self, from: data)
        guard let decoded = Data(base64URLEncoded: attachment.data) else { throw ClientError.decodingFailed }
        return decoded
    }

    /// "Name" <email@domain.com> or a bare address.
    private static func parseFrom(_ raw: String) -> (name: String, email: String) {
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
    private static func parseAddressList(_ raw: String) -> [String] {
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

    private static func parseListUnsubscribe(_ raw: String) -> (mailto: String?, url: String?) {
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

    private static func organization(fromEmail email: String) -> String {
        guard let domain = email.split(separator: "@").last else { return "" }
        let name = domain.split(separator: ".").first.map(String.init) ?? String(domain)
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    /// Depth-first search for the first part matching `mimeType`; multipart
    /// messages nest arbitrarily (plain/html alternatives, inline attachments).
    private static func bodyPart(mimeType: String, from part: GmailMessagePart?) -> String? {
        guard let part else { return nil }
        if part.mimeType == mimeType, let data = part.body?.data { return decodeBase64URL(data) }
        for child in part.parts ?? [] {
            if let found = bodyPart(mimeType: mimeType, from: child) { return found }
        }
        return nil
    }

    private static func decodeBase64URL(_ value: String) -> String? {
        guard let data = Data(base64URLEncoded: value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Many real emails (marketing templates, signatures) embed images as
    /// MIME parts referenced via "cid:" in the HTML rather than a remote URL.
    /// Every mainstream mail client resolves these locally; a browser
    /// never sees a bare "cid:" scheme and cannot load it. Without this, any
    /// inline-embedded image renders as a broken image, which was the
    /// reported bug. Replaces each cid: reference with a self-contained
    /// data: URI, so no network fetch is needed for these at all.
    private static func inlineCIDImages(in html: String, from root: GmailMessagePart?) -> String {
        var cidParts: [String: (mimeType: String, data: String)] = [:]
        collectCIDParts(from: root, into: &cidParts)
        guard !cidParts.isEmpty else { return html }
        var result = html
        for (cid, part) in cidParts {
            guard let base64 = base64URLToStandardBase64(part.data) else { continue }
            result = result.replacingOccurrences(of: "cid:\(cid)", with: "data:\(part.mimeType);base64,\(base64)")
        }
        return result
    }

    private static func collectCIDParts(from part: GmailMessagePart?, into map: inout [String: (mimeType: String, data: String)]) {
        guard let part else { return }
        if let contentID = part.headers?.first(where: { $0.name.lowercased() == "content-id" })?.value,
           let data = part.body?.data, let mimeType = part.mimeType {
            map[contentID.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))] = (mimeType, data)
        }
        for child in part.parts ?? [] {
            collectCIDParts(from: child, into: &map)
        }
    }

    private static func base64URLToStandardBase64(_ value: String) -> String? {
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

private struct MessageListResponse: Decodable {
    struct Item: Decodable { let id: String; let threadId: String? }
    let messages: [Item]?
    let nextPageToken: String?
}

private struct HistoryListResponse: Decodable {
    struct HistoryRecord: Decodable {
        struct MessageAdded: Decodable {
            struct MessageRef: Decodable { let id: String }
            let message: MessageRef
        }
        let messagesAdded: [MessageAdded]?
    }
    let history: [HistoryRecord]?
    let historyId: String?
    let nextPageToken: String?
}

private struct Profile: Decodable { let historyId: String? }

private struct SentMessage: Decodable { let threadId: String }

private struct AttachmentDataResponse: Decodable { let data: String }

private struct WatchResponse: Decodable { let historyId: String? }

/// A real, user-created Gmail label: `id` is what `Correspondence.labelIds`
/// and `GmailAPIClient.modifyThread` both traffic in, `name` is what a
/// person actually recognizes.
struct GmailUserLabel: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
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
    let payload: GmailMessagePart?
}

private struct GmailMessagePart: Decodable {
    let mimeType: String?
    let filename: String?
    let headers: [Header]?
    let body: Body?
    let parts: [GmailMessagePart]?

    struct Header: Decodable { let name: String; let value: String }
    struct Body: Decodable { let data: String?; let attachmentId: String?; let size: Int? }
}
