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

    /// A full listing of the inbox (paginated), used the first time an
    /// account syncs, or whenever a stored history cursor has expired.
    func fetchInitialInbox(account: String) async throws -> SyncResult {
        let token = try await accessToken()
        let ids = try await listMessageIDs(token: token)
        let items = await fetchMessages(ids: ids, token: token, account: account)
        // Best-effort: if the profile call fails, the sync itself still
        // succeeded, just without a cursor for next time. The following
        // sync falls back to another full listing rather than failing.
        let historyId = try? await fetchProfile(token: token).historyId
        return SyncResult(items: items, historyId: historyId)
    }

    /// Gmail's History API: only what changed since `cursor`, not a re-list
    /// of the whole inbox. Throws `.historyExpired` when the cursor is older
    /// than Gmail's retention window (about a week); the caller is expected
    /// to recover by calling `fetchInitialInbox` instead.
    func fetchIncremental(account: String, since cursor: String) async throws -> SyncResult {
        let token = try await accessToken()
        let (ids, historyId) = try await listHistoryMessageIDs(since: cursor, token: token)
        let items = await fetchMessages(ids: ids, token: token, account: account)
        return SyncResult(items: items, historyId: historyId ?? cursor)
    }

    private func fetchMessages(ids: [String], token: String, account: String) async -> [Correspondence] {
        var results: [Correspondence] = []
        for id in ids {
            if let message = try? await fetchMessage(id: id, token: token) {
                results.append(map(message, account: account))
            }
        }
        return results
    }

    private func accessToken() async throws -> String {
        guard let user = GIDSignIn.sharedInstance.currentUser else { throw ClientError.notSignedIn }
        try await user.refreshTokensIfNeeded()
        return user.accessToken.tokenString
    }

    private func listMessageIDs(token: String) async throws -> [String] {
        var ids: [String] = []
        var pageToken: String?
        var pagesFetched = 0
        repeat {
            var components = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages")!
            var queryItems = [
                URLQueryItem(name: "labelIds", value: "INBOX"),
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
    private func listHistoryMessageIDs(since startHistoryId: String, token: String) async throws -> (ids: [String], historyId: String?) {
        var ids: Set<String> = []
        var pageToken: String?
        var latestHistoryId: String?
        repeat {
            var components = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/history")!
            var queryItems = [
                URLQueryItem(name: "startHistoryId", value: startHistoryId),
                URLQueryItem(name: "historyTypes", value: "messageAdded"),
                URLQueryItem(name: "labelId", value: "INBOX"),
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
    /// rather than starting a new one.
    func send(raw: String, threadId: String?) async throws {
        let token = try await accessToken()
        let url = URL(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/send")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["raw": raw]
        if let threadId { body["threadId"] = threadId }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
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
        return Correspondence(
            id: ThreadID(account: account, providerID: message.threadId ?? message.id),
            sender: sender, senderEmail: senderEmail, organization: organization, subject: subject,
            excerpt: message.snippet ?? "", body: body, htmlBody: htmlBody, messageIdHeader: messageIdHeader,
            receivedAt: receivedAt, dueAt: nil,
            reason: isUnread ? "Unread in Gmail." : "Already read in Gmail.",
            attention: isUnread ? .needsYou : .quiet)
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
    /// MIME parts referenced via "cid:" in the HTML rather than a remote URL
    /// — every mainstream mail client resolves these locally; a browser
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
    let headers: [Header]?
    let body: Body?
    let parts: [GmailMessagePart]?

    struct Header: Decodable { let name: String; let value: String }
    struct Body: Decodable { let data: String? }
}
