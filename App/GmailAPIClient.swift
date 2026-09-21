import Foundation
import GoogleSignIn

/// Raw REST calls against the Gmail API. No third-party HTTP dependency,
/// URLSession + the token GoogleSignIn already manages. This is the only file
/// that speaks Gmail's wire format; it returns plain Correspondence values,
/// never its own DTOs, past this boundary (ADR 002).
struct GmailAPIClient {
    enum ClientError: Error { case notSignedIn, badResponse, decodingFailed }

    /// Deliberately small and recent-only for this first sync pass, not a
    /// full mailbox import: matches "do not attempt to support every...
    /// immediately," and gives a fast first real result to look at.
    private let maxResults = 25

    func fetchRecentInbox(account: String) async throws -> [Correspondence] {
        let token = try await accessToken()
        let ids = try await listMessageIDs(token: token)
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
        var components = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages")!
        components.queryItems = [
            URLQueryItem(name: "labelIds", value: "INBOX"),
            URLQueryItem(name: "maxResults", value: String(maxResults)),
        ]
        let (data, response) = try await authorizedRequest(url: components.url!, token: token)
        try validate(response)
        let list = try JSONDecoder().decode(MessageListResponse.self, from: data)
        return list.messages?.map(\.id) ?? []
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
        return Correspondence(
            id: ThreadID(account: account, providerID: message.threadId ?? message.id),
            sender: sender, organization: organization, subject: subject,
            excerpt: message.snippet ?? "", body: body, htmlBody: htmlBody, receivedAt: receivedAt, dueAt: nil,
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
    let headers: [Header]?
    let body: Body?
    let parts: [GmailMessagePart]?

    struct Header: Decodable { let name: String; let value: String }
    struct Body: Decodable { let data: String? }
}
