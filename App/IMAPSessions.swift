import Foundation
import Postwright
import os

/// One signed-in IMAP connection per iCloud account, reused across calls
/// and opened again if it drops. Commands run strictly one at a time per
/// account: an IMAP connection has one selected folder, and two callers
/// interleaving SELECTs would read the wrong one.
actor IMAPSessions {
    static let shared = IMAPSessions()

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
        /// When this connection last did something. iCloud closes ones left
        /// quiet for long, and the next command would fail once.
        var lastUsed = Date.now
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
            // Archive has to go somewhere. Servers without an Archive folder
            // get one, beside Sent ("INBOX.Archive" where folders live
            // under INBOX), as Apple Mail does.
            if cachedFolders.archive == nil {
                let sent = allFolders.folder(for: .sent)
                let path: String
                if let sent, let delimiter = sent.delimiter, sent.path.contains(delimiter) {
                    path = sent.path.split(separator: delimiter).dropLast().joined(separator: String(delimiter)) + String(delimiter) + "Archive"
                } else {
                    path = "Archive"
                }
                if (try? await connection.createFolder(path)) != nil {
                    cachedFolders.archive = path
                    allFolders = (try? await connection.listFolders()) ?? allFolders
                }
            }
        }
    }

    /// Posted, with the address as its object, when iCloud turns a saved
    /// password away.
    static let passwordRejected = Notification.Name("corres.icloud.passwordRejected")

    private static func announceRejected(_ account: String) {
        Task { @MainActor in NotificationCenter.default.post(name: passwordRejected, object: account) }
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
            if case IMAPConnection.ConnectionError.authenticationFailed = error {
                Self.announceRejected(account)
                throw GmailAPIClient.ClientError.notSignedIn
            }
            throw error
        }
        do {
            // Every command reads which folder is the Inbox, Sent and the
            // rest. On a new connection that list wasn't loaded yet, and
            // Inbox mail fetched then was labelled as some other folder.
            // Once per connection; cached after.
            _ = try await session.folders()
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
                Self.announceRejected(account)
                throw GmailAPIClient.ClientError.notSignedIn
            case .commandFailed(let message):
                throw GmailAPIClient.ClientError.refused(statusCode: 0, reason: nil, message: message)
            }
        } catch let error as GmailAPIClient.ClientError {
            throw error
        } catch is CancellationError {
            // Stopped partway through a command, its reply may still be
            // arriving, and the next command would read it as its own
            // (wrong flags, mail treated as gone). This session is done.
            sessions[account] = nil
            await session.connection.logout()
            throw CancellationError()
        } catch {
            // Anything else from the network layer (a write on a closed
            // connection): this session is spent, so the next call opens
            // a fresh one instead of failing forever.
            Self.log.error("iCloud connection error: \(String(describing: error), privacy: .public)")
            sessions[account] = nil
            await session.connection.logout()
            throw GmailAPIClient.ClientError.badResponse(statusCode: 0)
        }
    }

    /// The account's folders as last listed (INBOX only before the first).
    func folders(for account: String) -> FolderPaths {
        sessions[account]?.cachedFolders ?? FolderPaths()
    }

    /// Checks an address and app-specific password by signing in, without
    /// keeping the connection. Throws `notSignedIn` for a wrong password.
    static func verify(email: String, password: String, server: IMAPServer = .icloud) async throws {
        let connection = IMAPConnection(host: server.imapHost, port: server.imapPort, timeout: .seconds(20))
        defer { Task { await connection.logout() } }
        try await connection.connect()
        do {
            try await connection.login(username: server.username ?? email, password: password)
        } catch IMAPConnection.ConnectionError.authenticationFailed {
            throw GmailAPIClient.ClientError.notSignedIn
        }
        // And the outgoing server, so a wrong one shows now, not on the
        // first send.
        let smtp = SMTPClient(host: server.smtpHost, port: server.smtpPort, security: server.smtpSecurity == .tls ? .tls : .startTLS)
        do {
            try await smtp.verify(username: server.username ?? email, password: password)
        } catch SMTPClient.SMTPError.authenticationFailed {
            throw GmailAPIClient.ClientError.notSignedIn
        }
    }

    func forget(_ account: String) async {
        if let session = sessions.removeValue(forKey: account) { await session.connection.logout() }
    }

    private func session(for account: String) async throws -> Session {
        if let existing = sessions[account] {
            // Quiet for over ten minutes: start fresh rather than find out
            // the hard way, mid-archive, that iCloud closed it.
            if Date.now.timeIntervalSince(existing.lastUsed) < 600 { existing.lastUsed = .now; return existing }
            sessions[account] = nil
            await existing.connection.logout()
        }
        guard let password = IMAPCredentials.password(for: account) else { throw GmailAPIClient.ClientError.notSignedIn }
        let server = IMAPServer.for(account)
        let connection = IMAPConnection(host: server.imapHost, port: server.imapPort)
        try await connection.connect()
        try await connection.login(username: server.username ?? account, password: password)
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
actor IMAPCache {
    static let shared = IMAPCache()

    private var summaries: [String: [String: MessageSummary]] = [:]
    private var bodies: [String: [String: ParsedMessage]] = [:]

    func keep(_ messages: [MessageSummary], uidValidity: UInt32, account: String) {
        // Bounded, so a long session paging through years of mail doesn't
        // grow without end; anything dropped is looked up on iCloud again.
        if (summaries[account]?.count ?? 0) > 5_000 { summaries[account] = [:] }
        for m in messages { summaries[account, default: [:]][IMAPMailClient.key(m, uidValidity: uidValidity)] = m }
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
        (summaries[account] ?? [:]).filter { IMAPMailClient.conversation(for: $0.value) == conversation }.map(\.key)
    }

    func messageIDs(inConversation conversation: String, account: String) -> [String] {
        (summaries[account] ?? [:]).values.filter { IMAPMailClient.conversation(for: $0) == conversation }.compactMap(\.messageID)
            + [conversation]
    }

    func conversation(forMessageID id: String, account: String) -> String? {
        (summaries[account] ?? [:]).values.first { $0.messageID == id }.map(IMAPMailClient.conversation(for:))
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
enum IMAPCredentials {
    private static func key(_ account: String) -> String { "corres.icloud.password.\(account.lowercased())" }
    static func password(for account: String) -> String? { Keychain.get(key: key(account)) }
    static func save(_ password: String, for account: String) { Keychain.set(password, key: key(account)) }
    static func remove(_ account: String) { Keychain.delete(key: key(account)) }
}
