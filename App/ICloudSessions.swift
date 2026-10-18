import Foundation
import MailEngine
import os

/// One signed-in IMAP connection per iCloud account, reused across calls
/// and opened again if it drops. Commands run strictly one at a time per
/// account: an IMAP connection has one selected folder, and two callers
/// interleaving SELECTs would read the wrong one.
actor ICloudSessions {
    static let shared = ICloudSessions()

    struct FolderPaths: Sendable {
        var inbox: String? = "INBOX"
        var sent: String?
        var drafts: String?
        var trash: String?
        var junk: String?
        var archive: String?
    }

    final class Session: @unchecked Sendable {
        let connection: IMAPConnection
        var allFolders: [Folder] = []
        var cachedFolders = FolderPaths()
        init(connection: IMAPConnection) { self.connection = connection }

        func folders() async throws -> FolderPaths {
            if allFolders.isEmpty { try await refreshFolders() }
            return cachedFolders
        }

        func refreshFolders() async throws {
            allFolders = try await connection.listFolders()
            cachedFolders = FolderPaths(
                inbox: allFolders.folder(for: .inbox)?.path ?? "INBOX",
                sent: allFolders.folder(for: .sent)?.path,
                drafts: allFolders.folder(for: .drafts)?.path,
                trash: allFolders.folder(for: .trash)?.path,
                junk: allFolders.folder(for: .junk)?.path,
                archive: allFolders.folder(for: .archive)?.path)
        }
    }

    static let log = Logger(subsystem: "studio.anwarcreative.corres", category: "icloud")
    private var sessions: [String: Session] = [:]
    private var busy: Set<String> = []
    private var waiting: [String: [CheckedContinuation<Void, Never>]] = [:]

    /// Runs `body` with this account's connection, opening and signing in
    /// first if needed. A failure that looks like a dropped connection closes
    /// it, so the next call starts fresh.
    func with<T: Sendable>(_ account: String, _ body: @Sendable (Session) async throws -> T) async throws -> T {
        await acquire(account)
        defer { release(account) }
        let session: Session
        do {
            session = try await self.session(for: account)
        } catch {
            Self.log.error("iCloud sign-in failed: \(String(describing: error), privacy: .public)")
            throw error
        }
        do {
            return try await body(session)
        } catch let error as IMAPConnection.ConnectionError {
            Self.log.error("iCloud command failed: \(String(describing: error), privacy: .public)")
            switch error {
            case .disconnected, .timedOut, .notConnected:
                sessions[account] = nil
                await session.connection.logout()
                throw GmailAPIClient.ClientError.badResponse(statusCode: 0)
            case .authenticationFailed:
                sessions[account] = nil
                throw GmailAPIClient.ClientError.notSignedIn
            case .commandFailed(let message):
                throw GmailAPIClient.ClientError.refused(statusCode: 0, reason: nil, message: message)
            }
        }
    }

    /// The account's folders as last listed (INBOX only before the first).
    func folders(for account: String) -> FolderPaths {
        sessions[account]?.cachedFolders ?? FolderPaths()
    }

    /// Checks an address and app-specific password by signing in, without
    /// keeping the connection. Throws `notSignedIn` for a wrong password.
    static func verify(email: String, password: String) async throws {
        let connection = IMAPConnection(host: ICloudClient.imapHost, timeout: .seconds(20))
        defer { Task { await connection.logout() } }
        try await connection.connect()
        do {
            try await connection.login(username: email, password: password)
        } catch IMAPConnection.ConnectionError.authenticationFailed {
            throw GmailAPIClient.ClientError.notSignedIn
        }
    }

    func forget(_ account: String) async {
        if let session = sessions.removeValue(forKey: account) { await session.connection.logout() }
    }

    private func session(for account: String) async throws -> Session {
        if let existing = sessions[account] { return existing }
        guard let password = ICloudCredentials.password(for: account) else { throw GmailAPIClient.ClientError.notSignedIn }
        let connection = IMAPConnection(host: ICloudClient.imapHost)
        try await connection.connect()
        try await connection.login(username: account, password: password)
        let session = Session(connection: connection)
        try await session.refreshFolders()
        sessions[account] = session
        return session
    }

    private func acquire(_ account: String) async {
        if !busy.contains(account) { busy.insert(account); return }
        await withCheckedContinuation { waiting[account, default: []].append($0) }
    }

    private func release(_ account: String) {
        if var queue = waiting[account], !queue.isEmpty {
            let next = queue.removeFirst()
            waiting[account] = queue
            next.resume()
        } else {
            busy.remove(account)
        }
    }
}

/// What's been fetched for each iCloud account: list rows (so a sync's
/// listing and fetch don't ask twice), opened bodies (for attachments),
/// and which conversation each message belongs to (for actions on a whole
/// conversation). In memory; rebuilt from the server as needed.
actor ICloudCache {
    static let shared = ICloudCache()

    private var summaries: [String: [String: MessageSummary]] = [:]
    private var bodies: [String: [String: ParsedMessage]] = [:]

    func keep(_ messages: [MessageSummary], uidValidity: UInt32, account: String) {
        for m in messages { summaries[account, default: [:]][ICloudClient.key(m, uidValidity: uidValidity)] = m }
    }

    func summaries(for keys: [String], account: String) -> [String: MessageSummary] {
        let all = summaries[account] ?? [:]
        return Dictionary(uniqueKeysWithValues: keys.compactMap { k in all[k].map { (k, $0) } })
    }

    func keepBody(_ parsed: ParsedMessage, for key: String, account: String) {
        var forAccount = bodies[account] ?? [:]
        if forAccount.count > 40 { forAccount.removeAll() }
        forAccount[key] = parsed
        bodies[account] = forAccount
    }

    func body(for key: String, account: String) -> ParsedMessage? { bodies[account]?[key] }

    func keys(inConversation conversation: String, account: String) -> [String] {
        (summaries[account] ?? [:]).filter { ICloudClient.conversation(for: $0.value) == conversation }.map(\.key)
    }

    func messageIDs(inConversation conversation: String, account: String) -> [String] {
        (summaries[account] ?? [:]).values.filter { ICloudClient.conversation(for: $0) == conversation }.compactMap(\.messageID)
            + [conversation]
    }

    func conversation(forMessageID id: String, account: String) -> String? {
        (summaries[account] ?? [:]).values.first { $0.messageID == id }.map(ICloudClient.conversation(for:))
    }

    func forget(_ keys: [String], account: String) {
        for k in keys { summaries[account]?[k] = nil }
    }

    func forgetAccount(_ account: String) {
        summaries[account] = nil
        bodies[account] = nil
    }
}

/// An iCloud account's app-specific password, in the Keychain shared with
/// Corres's extensions. Never leaves the device.
enum ICloudCredentials {
    private static func key(_ account: String) -> String { "corres.icloud.password.\(account.lowercased())" }
    static func password(for account: String) -> String? { Keychain.get(key: key(account)) }
    static func save(_ password: String, for account: String) { Keychain.set(password, key: key(account)) }
    static func remove(_ account: String) { Keychain.delete(key: key(account)) }
}
