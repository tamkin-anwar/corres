import Foundation
import MailEngine

/// New iCloud mail within a second or two while Corres is open. Apple's own
/// push for iCloud is private to Apple Mail, so each iCloud account keeps
/// one IMAP connection resting in IDLE on its Inbox, separate from the one
/// syncing, and says when something arrives. Started when Corres comes to
/// the front, stopped when it leaves.
@MainActor
final class IMAPWatcher {
    static let shared = IMAPWatcher()

    private var watches: [String: Task<Void, Never>] = [:]
    private var connections: [String: IMAPConnection] = [:]

    /// Watches these accounts (the iCloud ones among them), calling
    /// `changed` with the account whenever its Inbox changes.
    func start(accounts: [String], changed: @escaping @MainActor (String) -> Void) {
        let icloud = Set(accounts.filter { MailAccounts.provider(for: $0).usesIMAP })
        for account in watches.keys where !icloud.contains(account) { stop(account) }
        for account in icloud where watches[account] == nil {
            watches[account] = Task { [weak self] in await self?.watch(account, changed: changed) }
        }
    }

    func stopAll() {
        for account in Array(watches.keys) { stop(account) }
    }

    private func stop(_ account: String) {
        watches.removeValue(forKey: account)?.cancel()
        if let connection = connections.removeValue(forKey: account) { Task { await connection.logout() } }
    }

    private func watch(_ account: String, changed: @escaping @MainActor (String) -> Void) async {
        var pause = Duration.seconds(5)
        while !Task.isCancelled {
            guard let password = IMAPCredentials.password(for: account) else { return }
            let server = IMAPServer.for(account)
            let connection = IMAPConnection(host: server.imapHost, port: server.imapPort)
            connections[account] = connection
            do {
                try await connection.connect()
                try await connection.login(username: server.username ?? account, password: password)
                try await connection.select("INBOX")
                pause = .seconds(5)
                while !Task.isCancelled {
                    // Under iCloud's 29-minute IDLE limit.
                    let changes = try await connection.waitForChanges(wait: .seconds(20 * 60))
                    if !changes.isEmpty, !Task.isCancelled { changed(account) }
                }
            } catch IMAPConnection.ConnectionError.authenticationFailed {
                await connection.logout()
                return // the sync path asks for a new password
            } catch {
                await connection.logout()
                try? await Task.sleep(for: pause)
                pause = min(pause * 2, .seconds(300))
            }
        }
    }
}
