import Foundation
import GoogleSignIn

/// Raw REST calls against the Gmail API. No third-party HTTP dependency,
/// URLSession + the token GoogleSignIn already manages. This is the only file
/// that speaks Gmail's wire format; it returns plain Correspondence values,
/// never its own DTOs, past this boundary (ADR 002).
struct GmailAPIClient {
    enum ClientError: Error { case notSignedIn, badResponse, decodingFailed, historyExpired }

    /// One fetch, either a first full sync or a cursor-based catch-up; the
    /// caller (GmailSyncService) persists `historyId` and passes it back in
    /// as the starting point for the next call.
    struct SyncResult { let items: [Correspondence]; let historyId: String? }

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
        let token = try await accessToken()
        var ids: Set<String> = []
        for label in Self.syncedLabels {
            ids.formUnion(try await listMessageIDs(token: token, label: label))
        }
        let items = await fetchMessages(ids: Array(ids), token: token, account: account)
        // Best-effort: if the profile call fails, the sync itself still
        // succeeded, just without a cursor for next time. The following
        // sync falls back to another full listing rather than failing.
        let historyId = try? await fetchProfile(token: token).historyId
        return SyncResult(items: items, historyId: historyId)
    }

    /// Gmail's History API: only what changed since `cursor`, not a re-list
    /// of the whole inbox. Throws `.historyExpired` when the cursor is older
    /// than Gmail's retention window (about a week); the caller is expected
    /// to recover by calling `fetchInitialInbox` instead. Queried once per
    /// label (the History API's own `labelId` filter only accepts one at a
    /// time), merged into a single result.
    func fetchIncremental(account: String, since cursor: String) async throws -> SyncResult {
        let token = try await accessToken()
        var ids: Set<String> = []
        var historyId: String?
        for label in Self.syncedLabels {
            let page = try await listHistoryMessageIDs(since: cursor, token: token, label: label)
            ids.formUnion(page.ids)
            historyId = Self.newerHistoryId(historyId, page.historyId)
        }
        let items = await fetchMessages(ids: Array(ids), token: token, account: account)
        return SyncResult(items: items, historyId: historyId ?? cursor)
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
    private func fetchMessages(ids: [String], token: String, account: String) async -> [Correspondence] {
        await withTaskGroup(of: Correspondence?.self) { group in
            var pending = ids[...]
            func addNext() {
                guard let id = pending.popFirst() else { return }
                group.addTask {
                    guard let message = try? await self.fetchMessage(id: id, token: token) else { return nil }
                    return self.map(message, account: account)
                }
            }
            for _ in 0..<Self.messageFetchConcurrency { addNext() }
            var results: [Correspondence] = []
            while let next = await group.next() {
                if let correspondence = next { results.append(correspondence) }
                addNext()
            }
            return results
        }
    }

    private static let messageFetchConcurrency = 8

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
        let token = try await accessToken()
        var components = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages")!
        components.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "maxResults", value: String(searchPageSize)),
        ]
        let (data, response) = try await authorizedRequest(url: components.url!, token: token)
        try validate(response)
        let list = try JSONDecoder().decode(MessageListResponse.self, from: data)
        return await fetchMessages(ids: list.messages?.map(\.id) ?? [], token: token, account: account)
    }

    private func accessToken() async throws -> String {
        guard let user = GIDSignIn.sharedInstance.currentUser else { throw ClientError.notSignedIn }
        try await user.refreshTokensIfNeeded()
        return user.accessToken.tokenString
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
    func send(raw: String, threadId: String?) async throws -> String {
        let token = try await accessToken()
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
    func modifyThread(threadId: String, addLabelIds: [String] = [], removeLabelIds: [String] = []) async throws {
        let token = try await accessToken()
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
    func trashThread(threadId: String) async throws {
        let token = try await accessToken()
        let url = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/threads/\(threadId)/trash")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (_, response) = try await URLSession.shared.data(for: request)
        try validate(response)
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
            throw ClientError.badResponse
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
        return Correspondence(
            id: ThreadID(account: account, providerID: message.threadId ?? message.id),
            sender: sender, senderEmail: senderEmail, organization: organization, subject: subject,
            excerpt: message.snippet ?? "", body: body, htmlBody: htmlBody, messageIdHeader: messageIdHeader,
            latestMessageID: message.id, receivedAt: receivedAt, dueAt: nil,
            reason: isUnread ? "Unread in Gmail." : "Already read in Gmail.",
            attention: isUnread ? .needsYou : .quiet, attachments: attachments, isUnread: isUnread)
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
    func fetchAttachmentData(messageId: String, attachmentId: String) async throws -> Data {
        let token = try await accessToken()
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
    struct Item: Decodable { let id: String }
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
