import Foundation
import os
import Postwright

/// iCloud Mail behind the same calls as `GmailAPIClient` and `OutlookClient`,
/// over IMAP and SMTP (`Postwright`). Sign-in is the account's address and
/// an app-specific password from account.apple.com, kept in the Keychain;
/// nothing goes through Corres's servers.
///
/// Folders are described in Gmail's labels, as Outlook's are: INBOX, SENT,
/// TRASH, SPAM, DRAFT, read state as UNREAD, flagged as STARRED, and any
/// other folder as "folder:<path>". Archive is "not INBOX".
///
/// Ids:
/// - A message is "<uidvalidity>:<uid>:<folder path>": UIDs only mean
///   something within one folder and one UIDVALIDITY.
/// - A conversation is the Message-ID it started with (the first in
///   References, else In-Reply-To, else its own), so a reply in Sent joins
///   the email it answers.
/// `SMTPHandoffs`, kept with the App Group so a send from the Share
/// extension is known to the outbox too.
enum SMTPHandoffLog {
    private static let key = "corres.smtpHandoffs"
    private static let lock = NSLock()

    static var current: SMTPHandoffs { lock.withLock { read() } }

    static func update(_ change: (inout SMTPHandoffs) -> Void) {
        lock.withLock {
            var handoffs = read().pruned()
            change(&handoffs)
            MailAccounts.groupDefaults.set(try? JSONEncoder().encode(handoffs), forKey: key)
        }
    }

    private static func read() -> SMTPHandoffs {
        MailAccounts.groupDefaults.data(forKey: key).flatMap { try? JSONDecoder().decode(SMTPHandoffs.self, from: $0) } ?? SMTPHandoffs()
    }
}

struct IMAPMailClient: Sendable {
    typealias ClientError = GmailAPIClient.ClientError

    static let firstInboxCount = 200
    static let firstSentCount = 100

    // MARK: Sync

    /// Per-folder state between syncs, plus which conversation each known
    /// message belongs to (to report changes made elsewhere).
    struct Cursor: Codable {
        var folders: [String: FolderSyncState]
        /// Folder path → UID (as text) → conversation id. Newest 500 per folder.
        var known: [String: [String: String]]
        /// Folder path → UID (as text) → read and flagged as last seen
        /// (`FlagChanges.code`), plus `Self.unsubscribeBit`, so a pass
        /// reports only what changed. Nil in cursors saved before it was
        /// kept: those report every known message once.
        var flags: [String: [String: UInt8]]?
        /// When a pass last reported every known message whatever its
        /// flags, to put right anything that drifted from the server (a
        /// change made here that the server refused).
        var flagsReportedAt: Date?
        /// When this cursor was made. Nil in cursors saved before it was kept.
        var at: Date?
    }

    /// New in a folder but dated well before the last pass: moved back
    /// into the Inbox elsewhere, not just received. An hour's margin, for
    /// a sender whose clock runs behind (the date is the sender's).
    static let returnedMargin: TimeInterval = 60 * 60

    /// The last cursor each account's sync was handed back, this launch
    /// (a hash: only compared). A pass starting from any other may have
    /// reported changes its flags don't know about.
    private actor IssuedCursors {
        static let shared = IssuedCursors()
        private var last: [String: Int] = [:]
        func issue(_ cursor: String?, for account: String) { last[account] = cursor?.hashValue }
        func isLatest(_ cursor: String, for account: String) -> Bool { last[account] == cursor.hashValue }
    }

    /// How often every known message is reported, changed or not.
    static let flagReportInterval: TimeInterval = 30 * 60
    /// Kept with the flags: the message has a List-Unsubscribe header, so
    /// a change reported for it keeps it in Promotions.
    static let unsubscribeBit: UInt8 = 4

    func planFullListing(account: String) async throws -> GmailAPIClient.SyncPlan {
        try await IMAPSessions.shared.with(account) { session in
            let folders = try await session.folders()
            // Everything listed is stored with the flags it has now, so
            // there's nothing older to report.
            var cursor = Cursor(folders: [:], known: [:], flags: [:], flagsReportedAt: .now, at: .now)
            var all: [MessageSummary] = []
            for (path, count) in [(folders.inbox, Self.firstInboxCount), (folders.sent, Self.firstSentCount)] {
                guard let path else { continue }
                let selected = try await session.connection.select(path)
                let messages = try await session.connection.fetchNewestSummaries(count: count, of: selected.exists)
                all += messages
                cursor.folders[path] = FolderSyncState(uidValidity: selected.uidValidity, uidNext: selected.uidNext,
                                                       highestModSeq: selected.highestModSeq,
                                                       oldestFetchedUID: messages.map(\.uid).min(),
                                                       exists: selected.exists)
                let known = Self.known(messages, keeping: [:])
                cursor.known[path] = known
                cursor.flags?[path] = Self.flagCodes(messages, keeping: [:], known: known)
                await IMAPCache.shared.keep(messages, uidValidity: selected.uidValidity, account: account)
            }
            all.sort { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
            let ids = all.map { Self.key($0, uidValidity: cursor.folders[$0.folder]?.uidValidity ?? 0) }
            let encoded = try Self.encode(cursor)
            await IssuedCursors.shared.issue(encoded, for: account)
            return GmailAPIClient.SyncPlan(messageIDs: ids, historyId: encoded,
                                           olderInboxPageToken: folders.inbox.map { "\($0)|\(max(0, (cursor.folders[$0]?.oldestFetchedUID ?? 1) - 1))" })
        }
    }

    func planIncremental(account: String, since cursorString: String) async throws -> GmailAPIClient.SyncPlan {
        guard let data = cursorString.data(using: .utf8), let start = try? JSONDecoder().decode(Cursor.self, from: data) else {
            throw ClientError.historyExpired
        }
        return try await IMAPSessions.shared.with(account) { session in
            // A folder synced from the start that this cursor never saw
            // (Sent, when the folder list once came back empty): list again.
            let folders = try await session.folders()
            if let sent = folders.sent, start.folders[sent] == nil { throw ClientError.historyExpired }
            var cursor = start
            var newIDs: [String] = []
            var returnedIDs = Set<String>()
            var changes: [RemoteMessageChange] = []
            // Every known message is reported whatever it has, and every
            // folder looked at even if its counter says nothing moved:
            // every half hour; for a cursor that kept no flags; and when
            // this isn't the last cursor handed out (a new launch, or one
            // that wasn't saved), since what was reported after it may
            // be in the mailbox without being in its flags.
            let latest = await IssuedCursors.shared.isLatest(cursorString, for: account)
            let reportAll = !latest
                || start.flagsReportedAt.map { Date.now.timeIntervalSince($0) >= Self.flagReportInterval } ?? true
            if cursor.flags == nil { cursor.flags = [:] }
            for (path, stored) in cursor.folders {
                let selected = try await session.connection.select(path)
                let caps = await session.connection.capabilities
                var plan = SyncPlanner.plan(stored: stored, selected: selected, capabilities: caps)
                if reportAll, plan == .upToDate { plan = .incremental(newFrom: nil, changedSince: nil, checkFlagsOfKnown: true) }
                switch plan {
                case .full:
                    // The folder was renumbered: start over from a full listing.
                    throw ClientError.historyExpired
                case .upToDate:
                    continue
                case .incremental(let newFrom, _, _):
                    var known = cursor.known[path] ?? [:]
                    var kept = cursor.flags?[path] ?? [:]
                    if let newFrom, newFrom <= selected.uidNext {
                        let fresh = try await session.connection.fetchSummaries(uids: newFrom...UInt32.max)
                            .filter { $0.uid >= newFrom }
                        await IMAPCache.shared.keep(fresh, uidValidity: selected.uidValidity, account: account)
                        newIDs += fresh.map { Self.key($0, uidValidity: selected.uidValidity) }
                        // A new UID for mail you already had (moved back
                        // from the Archive or a folder): baseline, as
                        // Gmail's restored mail is, never a new sender.
                        if let last = start.at {
                            returnedIDs.formUnion(fresh.filter { ($0.date ?? .now) < last.addingTimeInterval(-Self.returnedMargin) }
                                .map { Self.key($0, uidValidity: selected.uidValidity) })
                        }
                        known = Self.known(fresh, keeping: known)
                        // Stored just now with these flags: nothing to
                        // report for them unless they change.
                        kept = Self.flagCodes(fresh, keeping: kept, known: known)
                    }
                    // Read, flagged or removed elsewhere: the flags of every
                    // known message, compared with what was kept. Even with
                    // CONDSTORE's CHANGEDSINCE on offer: without QRESYNC
                    // only this shows what was removed, and the comparison
                    // keeps the report to what changed.
                    let uids = known.keys.compactMap(UInt32.init)
                    if let low = uids.min(), let high = uids.max() {
                        let flags = try await session.connection.fetchFlags(uids: low...high)
                        let previous = Dictionary(kept.compactMap { key, code in UInt32(key).map { ($0, code) } },
                                                  uniquingKeysWith: { first, _ in first })
                        let result = FlagChanges.compare(known: uids, previous: previous, current: flags)
                        for uid in reportAll ? result.codes.keys.sorted() : result.changed {
                            guard let conversation = known[String(uid)], let current = flags[uid] else { continue }
                            let code = result.codes[uid] ?? 0
                            changes.append(RemoteMessageChange(
                                threadID: ThreadID(account: account, providerID: conversation),
                                messageID: "\(selected.uidValidity):\(uid):\(path)",
                                currentLabelIds: Self.labels(flags: current, folder: path, folders: session.cachedFolders,
                                                             hasUnsubscribe: code & Self.unsubscribeBit != 0),
                                removed: false))
                        }
                        var codes = Dictionary(uniqueKeysWithValues: result.codes.map { (String($0.key), $0.value) })
                        for uid in result.vanished {
                            guard path == session.cachedFolders.inbox else {
                                // Gone from another folder: still known, as
                                // before, with what was last seen for it.
                                codes[String(uid)] = kept[String(uid)]
                                continue
                            }
                            guard let conversation = known[String(uid)] else { continue }
                            changes.append(RemoteMessageChange(threadID: ThreadID(account: account, providerID: conversation),
                                                               messageID: "\(selected.uidValidity):\(uid):\(path)",
                                                               currentLabelIds: nil, removed: true))
                            known[String(uid)] = nil
                        }
                        kept = codes
                    }
                    cursor.known[path] = known
                    cursor.flags?[path] = kept.filter { known[$0.key] != nil }
                    cursor.folders[path] = FolderSyncState(uidValidity: selected.uidValidity, uidNext: selected.uidNext,
                                                           highestModSeq: selected.highestModSeq,
                                                           oldestFetchedUID: stored.oldestFetchedUID,
                                                           exists: selected.exists)
                }
            }
            if reportAll { cursor.flagsReportedAt = .now }
            // Moved on only when something came in: a pass that changed
            // nothing gives back the same cursor, so it isn't saved again.
            if !newIDs.isEmpty || start.at == nil { cursor.at = .now }
            let encoded = try Self.encode(cursor)
            await IssuedCursors.shared.issue(encoded, for: account)
            return GmailAPIClient.SyncPlan(messageIDs: newIDs, baselineMessageIDs: returnedIDs, historyId: encoded, remoteChanges: changes)
        }
    }

    func listRecentSent(account: String) async throws -> [String] { [] }

    /// Older Inbox mail, a page at a time. The page token is
    /// "<folder>|<highest UID still to load>".
    func listOlderInbox(account: String, pageToken: String?) async throws -> (ids: [(id: String, threadId: String?)], nextPageToken: String?) {
        guard let pageToken, let bar = pageToken.lastIndex(of: "|"), let below = UInt32(pageToken[pageToken.index(after: bar)...]),
              below > 0 else { return ([], nil) }
        let path = String(pageToken[..<bar])
        return try await IMAPSessions.shared.with(account) { session in
            let selected = try await session.connection.select(path)
            let low = below > 300 ? below - 300 : 1
            let messages = try await session.connection.fetchSummaries(uids: low...below)
                .sorted { $0.uid > $1.uid }.prefix(GmailAPIClient.olderPageSize)
            await IMAPCache.shared.keep(Array(messages), uidValidity: selected.uidValidity, account: account)
            let ids = messages.map { (Self.key($0, uidValidity: selected.uidValidity), Optional(Self.conversation(for: $0))) }
            let next = (messages.map(\.uid).min() ?? low) > 1 ? "\(path)|\((messages.map(\.uid).min() ?? low) - 1)" : nil
            return (ids, messages.isEmpty && low == 1 ? nil : next)
        }
    }

    // MARK: Messages

    func fetchMetadata(ids: [String], account: String) async throws -> (items: [Correspondence], failedIDs: [String]) {
        let cached = await IMAPCache.shared.summaries(for: ids, account: account)
        var found = cached
        let missing = ids.filter { cached[$0] == nil }
        if !missing.isEmpty {
            let fetched: [String: MessageSummary] = try await IMAPSessions.shared.with(account) { session in
                var found: [String: MessageSummary] = [:]
                for (path, keys) in Dictionary(grouping: missing.compactMap(Self.parse), by: \.path) {
                    let selected = try await session.connection.select(path)
                    let uids = keys.filter { $0.uidValidity == selected.uidValidity }.map(\.uid)
                    guard !uids.isEmpty else { continue }
                    let messages = try await session.connection.fetchSummaries(uids: uids)
                    await IMAPCache.shared.keep(messages, uidValidity: selected.uidValidity, account: account)
                    for m in messages { found[Self.key(m, uidValidity: selected.uidValidity)] = m }
                }
                return found
            }
            found.merge(fetched) { a, _ in a }
        }
        let folders = await IMAPSessions.shared.folders(for: account)
        let items = ids.compactMap { id in found[id].map { map($0, key: id, account: account, folders: folders, body: nil) } }
        // Every folder answered, so a message not among the answers is gone
        // (expunged, moved, or its folder renumbered), not failed: retried,
        // it would fail on every pass forever.
        return (items, [])
    }

    func fetchSummary(ids: [String], account: String) async throws -> [Correspondence] {
        try await fetchMetadata(ids: ids, account: account).items
    }

    func fetchFull(ids: [String], account: String) async throws -> (items: [Correspondence], failedIDs: [String]) {
        try await fetchMessages(ids: ids, account: account)
    }

    func fetchMessages(ids: [String], account: String) async throws -> (items: [Correspondence], failedIDs: [String]) {
        let summaries = try await fetchMetadataSummaries(ids: ids, account: account)
        return try await IMAPSessions.shared.with(account) { session in
            var items: [Correspondence] = []
            for (path, keys) in Dictionary(grouping: ids.compactMap(Self.parse), by: \.path) {
                let selected = try await session.connection.select(path)
                // A key from before the folder was renumbered is gone, not
                // failed: it could never be fetched by that number again.
                let current = keys.filter { $0.uidValidity == selected.uidValidity }
                // Twenty to a command: one round trip a batch, and short
                // enough that an archive or an open waits a moment at most.
                for batch in current.chunked(into: 20) {
                    let raws = try await session.connection.fetchMessages(uids: batch.map(\.uid))
                    for key in batch {
                        // Not returned: the server no longer has it.
                        guard let summary = summaries[key.raw], let raw = raws[key.uid] else { continue }
                        let parsed = MIMEParser.parse(raw)
                        await IMAPCache.shared.keepBody(parsed, for: key.raw, account: account)
                        items.append(map(summary, key: key.raw, account: account, folders: session.cachedFolders, body: parsed))
                    }
                }
            }
            return (items, [])
        }
    }

    private func fetchMetadataSummaries(ids: [String], account: String) async throws -> [String: MessageSummary] {
        _ = try await fetchMetadata(ids: ids, account: account)
        return await IMAPCache.shared.summaries(for: ids, account: account)
    }

    func fetchThreadMessages(threadId: String, account: String) async throws -> [Correspondence] {
        let keys = try await Self.messageKeys(inConversation: threadId, account: account).map(\.raw)
        guard !keys.isEmpty else { return [] }
        return try await fetchMessages(ids: keys, account: account).items.sorted { $0.receivedAt < $1.receivedAt }
    }

    /// The whole mailbox, as Gmail's and Outlook's search are: Inbox, Sent
    /// and Archive, newest first.
    /// The page token is how many of each folder's matches came before.
    func searchPage(query: String, account: String, pageToken: String?) async throws -> (items: [Correspondence], nextPageToken: String?) {
        let skip = pageToken.flatMap(Int.init) ?? 0
        let page: (keys: [String], more: Bool) = try await IMAPSessions.shared.with(account) { session in
            let folders = try await session.folders()
            var found: [String] = []
            var more = false
            for path in [folders.inbox, folders.sent, folders.archive].compactMap({ $0 }) {
                let selected = try await session.connection.select(path)
                let all = try await session.connection.search(text: query).sorted(by: >)
                let uids = all.dropFirst(skip).prefix(50)
                more = more || all.count > skip + 50
                found += uids.map { "\(selected.uidValidity):\($0):\(path)" }
            }
            return (found, more)
        }
        let items = try await fetchMetadata(ids: page.keys, account: account).items.sorted { $0.receivedAt > $1.receivedAt }
        return (items, page.more ? String(skip + 50) : nil)
    }

    #if DEBUG
    func exportCorpus(account: String, limit: Int) async throws -> (items: [Correspondence], missing: Int) { ([], 0) }
    #endif

    /// Who you write to, from Sent Messages: what suggests people as you
    /// address an email, as Gmail's and Outlook's Sent do.
    func sentAddressing(account: String, limit: Int) async throws -> [GmailAPIClient.Addressing] {
        try await IMAPSessions.shared.with(account) { session in
            guard let sent = try await session.folders().sent else { return [] }
            let selected = try await session.connection.select(sent)
            return try await session.connection.fetchNewestSummaries(count: min(limit, 500), of: selected.exists).map(Self.addressing)
        }
    }

    /// Mail to or from someone by name, in Inbox and Sent.
    func addressing(matching name: String, account: String) async throws -> [GmailAPIClient.Addressing] {
        try await IMAPSessions.shared.with(account) { session in
            let folders = try await session.folders()
            var found: [GmailAPIClient.Addressing] = []
            for path in [folders.inbox, folders.sent].compactMap({ $0 }) {
                try await session.connection.select(path)
                let uids = Array(try await session.connection.search(person: name).sorted(by: >).prefix(25))
                found += try await session.connection.fetchSummaries(uids: uids).map(Self.addressing)
            }
            return found
        }
    }

    private static func addressing(_ m: MessageSummary) -> GmailAPIClient.Addressing {
        func formatted(_ a: Address) -> String { a.name.map { "\($0) <\(a.email)>" } ?? a.email }
        return GmailAPIClient.Addressing(from: m.from.map(formatted) ?? "", recipients: (m.to + m.cc).map(formatted),
                                         subject: m.subject, date: m.date ?? .now)
    }

    func findMessage(rfc822MessageID: String, account: String) async throws -> ThreadID? {
        let id = rfc822MessageID.trimmingCharacters(in: CharacterSet(charactersIn: "<> "))
        if let conversation = await IMAPCache.shared.conversation(forMessageID: id, account: account) {
            return ThreadID(account: account, providerID: conversation)
        }
        // Not fetched this session (Corres restarted mid-send): ask iCloud.
        // Sent is where a send that went through lands.
        let found: ThreadID? = try await IMAPSessions.shared.with(account) { session in
            let folders = try await session.folders()
            for path in [folders.sent, folders.inbox].compactMap({ $0 }) {
                let selected = try await session.connection.select(path)
                let uids = try await session.connection.search(messageID: id)
                guard !uids.isEmpty else { continue }
                let found = try await session.connection.fetchSummaries(uids: uids)
                await IMAPCache.shared.keep(found, uidValidity: selected.uidValidity, account: account)
                if let summary = found.first { return ThreadID(account: account, providerID: Self.conversation(for: summary)) }
            }
            return nil
        }
        // No copy is no answer on its own: iCloud's SMTP files nothing in
        // Sent, Corres does once the server says it took the email. What
        // Corres saw when it handed the email over decides.
        switch SMTPHandoffLog.current.verdict(for: id, account: account, foundIn: found?.providerID) {
        case .sent(let conversation): return found ?? ThreadID(account: account, providerID: conversation)
        case .notSent: return nil
        case .unknown: throw Self.unconfirmed
        }
    }

    /// The server may have taken it, and nothing can say whether it did.
    /// A check that throws is no answer, so the outbox never sends it again
    /// on its own; Retry, by hand, does (`allowSendingAgain`).
    static let unconfirmed = ClientError.refused(statusCode: 0, reason: "sendUnconfirmed",
                                                 message: "The mail server didn't say whether it took this email.")

    /// Retry tapped on a failed send: you've decided to send it again, so
    /// "may have gone" no longer holds it back. Sent is still checked first.
    func allowSendingAgain(rfc822MessageID: String, account: String) {
        SMTPHandoffLog.update { $0.forget(rfc822MessageID, account: account) }
    }

    /// Handed over and no answer seen: Retry says so before it sends.
    func mayHaveSent(rfc822MessageID: String, account: String) -> Bool {
        SMTPHandoffLog.current.state(of: rfc822MessageID, account: account) == .unconfirmed
    }

    /// The error `send` throws when the server may have taken the email.
    static func isUnconfirmed(_ error: Error) -> Bool {
        guard case .refused(_, let reason, _)? = error as? ClientError else { return false }
        return reason == "sendUnconfirmed"
    }

    // MARK: Sending

    /// Sends through iCloud's SMTP (STARTTLS on 587), then files a copy in
    /// Sent, which iCloud's SMTP doesn't do itself. Bcc is read from the
    /// message and removed before it goes out.
    @discardableResult
    func send(raw: String, threadId: String?, account: String) async throws -> String {
        guard let password = IMAPCredentials.password(for: account) else { throw ClientError.notSignedIn }
        let message = Self.mime(fromRaw: raw)
        let (recipients, outgoing) = Self.envelope(of: message)
        guard !recipients.isEmpty else { throw ClientError.refused(statusCode: 0, reason: nil, message: "This email has no recipients.") }
        let server = IMAPServer.for(account)
        let smtp = SMTPClient(host: server.smtpHost, port: server.smtpPort, security: server.smtpSecurity == .tls ? .tls : .startTLS)
        let messageID = Self.messageID(ofMessage: outgoing)
        // From here it may go. Noted before it's handed over, so Corres
        // closing mid-send, or an answer lost on the way back, reads as
        // "may have gone" and never as "not sent" (`findMessage`).
        if let messageID { SMTPHandoffLog.update { $0.handOver(messageID, account: account) } }
        do {
            try await smtp.send(Data(outgoing.utf8), from: account, to: recipients, username: server.username ?? account, password: password)
        } catch SMTPClient.SMTPError.unconfirmed {
            // The whole email went and no answer came back. It stays
            // "may have gone": never sent again without you.
            throw Self.unconfirmed
        } catch {
            // Anything else means the server never took it: it refused, or
            // never got the end of the email (RFC 5321 4.1.1.10).
            if let messageID { SMTPHandoffLog.update { $0.forget(messageID, account: account) } }
            switch error as? SMTPClient.SMTPError {
            case .authenticationFailed?: throw ClientError.notSignedIn
            case .recipientRejected(let address, let why)?:
                throw ClientError.refused(statusCode: 550, reason: "recipientRejected", message: "\(address): \(why)")
            case .rejected(let code, let why)?: throw ClientError.refused(statusCode: code, reason: nil, message: why)
            default: throw error
            }
        }
        let conversation = threadId ?? Self.conversation(ofMessage: outgoing) ?? ""
        if let messageID { SMTPHandoffLog.update { $0.accepted(messageID, account: account, conversation: conversation) } }
        // Sent now; what follows is filing, and must never turn a delivered
        // email into a "Couldn't send". Done before returning, not left to
        // run on its own: the Share extension and a send from a notification
        // end moments after this returns, and a copy never filed can't be
        // found again (a retry would send twice, and the conversation would
        // be looked for in every folder on each sync).
        await Self.fileInSent(Data(outgoing.utf8), messageID: messageID, account: account)
        // The conversation it belongs to, the same id sync gives it.
        return conversation
    }

    /// Files a copy of a sent email in Sent. Some services (Yahoo, AOL)
    /// file mail sent through them themselves, a moment later; iCloud and
    /// most others don't. So iCloud's copy goes in at once, and for any
    /// other server Sent is checked again after a moment before Corres adds
    /// one, so it never shows twice. A try that fails goes once more.
    private static func fileInSent(_ copy: Data, messageID: String?, account: String) async {
        let serverMayFile = MailAccounts.provider(for: account) != .icloud
        for attempt in 0..<2 {
            do {
                try await IMAPSessions.shared.with(account) { session in
                    guard let sent = try await session.folders().sent else { return }
                    // A second try asks too: the first may have filed it
                    // before its answer was lost.
                    if let messageID, serverMayFile || attempt > 0 {
                        for pause in serverMayFile ? [0.0, 1.0] : [0.0] {
                            if pause > 0 { try await Task.sleep(for: .seconds(pause)) }
                            try await session.connection.select(sent)
                            if try await !session.connection.search(messageID: messageID).isEmpty { return }
                        }
                    }
                    _ = try await session.connection.append(copy, to: sent, flags: ["\\Seen"])
                }
                return
            } catch {
                IMAPSessions.log.error("Sent, but not filed in Sent: \(String(describing: error), privacy: .public)")
                if attempt == 0 { try? await Task.sleep(for: .milliseconds(500)) }
            }
        }
    }

    /// A raw message's conversation, by the rule `conversation(for:)` uses
    /// on synced mail: the first References id, else In-Reply-To, else its
    /// own Message-ID.
    /// A raw message's own Message-ID, without angle brackets.
    static func messageID(ofMessage message: String) -> String? {
        let header = message.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n\n").first ?? ""
        guard let line = header.components(separatedBy: "\n").first(where: { $0.lowercased().hasPrefix("message-id:") }),
              let open = line.firstIndex(of: "<"), let close = line[open...].firstIndex(of: ">") else { return nil }
        let id = String(line[line.index(after: open)..<close])
        return id.isEmpty ? nil : id
    }

    static func conversation(ofMessage message: String) -> String? {
        let normalized = message.replacingOccurrences(of: "\r\n", with: "\n")
        let headerText = normalized.components(separatedBy: "\n\n").first ?? normalized
        var headers: [String: String] = [:]
        var current: String?
        for line in headerText.components(separatedBy: "\n") {
            if let first = line.first, first == " " || first == "\t", let name = current {
                headers[name, default: ""] += " " + line.trimmingCharacters(in: .whitespaces)
            } else if let colon = line.firstIndex(of: ":") {
                let name = line[..<colon].lowercased()
                current = name
                if headers[name] == nil { headers[name] = String(line[line.index(after: colon)...]) }
            }
        }
        func firstID(_ value: String?) -> String? {
            guard let value, let open = value.firstIndex(of: "<"), let close = value[open...].firstIndex(of: ">") else { return nil }
            let id = String(value[value.index(after: open)..<close])
            return id.isEmpty ? nil : id
        }
        return firstID(headers["references"]) ?? firstID(headers["in-reply-to"]) ?? firstID(headers["message-id"])
    }

    func saveDraft(raw: String, threadId: String?, existingID: String?, account: String) async throws -> String {
        let message = Data(Self.mime(fromRaw: raw).replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n", with: "\r\n").utf8)
        return try await IMAPSessions.shared.with(account) { session in
            guard let drafts = session.cachedFolders.drafts else { throw ClientError.refused(statusCode: 0, reason: nil, message: "No Drafts folder.") }
            // The new copy first, then the old one goes: if saving fails,
            // the last saved draft is still there.
            var uid = try await session.connection.append(message, to: drafts, flags: ["\\Draft", "\\Seen"])
            let selected = try await session.connection.select(drafts)
            // Servers without UIDPLUS don't say where it went: find it by
            // its Message-ID, or the draft could never be replaced or
            // cleared after sending.
            if uid == nil, let messageID = Self.messageID(ofMessage: Self.mime(fromRaw: raw)) {
                uid = try await session.connection.search(messageID: messageID).max()
            }
            // Only by the number it had then: after the folder was
            // renumbered (a new UIDVALIDITY) that UID is another message.
            if let existingID, let old = Self.parse(existingID), old.uid != uid || old.path != drafts,
               (try? await session.connection.select(old.path))?.uidValidity == old.uidValidity {
                try? await session.connection.setFlags(["\\Deleted"], uids: [old.uid], add: true)
                try? await session.connection.expungeIfPossible(uids: [old.uid])
            }
            return uid.map { "\(selected.uidValidity):\($0):\(drafts)" } ?? ""
        }
    }

    func deleteDraft(id: String, account: String) async throws {
        guard let key = Self.parse(id) else { return }
        try await IMAPSessions.shared.with(account) { session in
            // Renumbered since (a new UIDVALIDITY): that UID is another
            // message now, and the draft can't be found by it.
            guard try await session.connection.select(key.path).uidValidity == key.uidValidity else { return }
            try await session.connection.setFlags(["\\Deleted"], uids: [key.uid], add: true)
            try await session.connection.expungeIfPossible(uids: [key.uid])
        }
    }

    // MARK: Changes

    /// Read, flagged, archive, spam and back to Inbox, on every message of
    /// the conversation Corres has seen.
    func modifyThread(threadId: String, addLabelIds: [String], removeLabelIds: [String], account: String) async throws {
        // Read and flag changes touch what's on screen, which is loaded:
        // no need to search four folders each time an email is opened.
        // Moves need every message, wherever it is.
        let flagsOnly = (addLabelIds + removeLabelIds).allSatisfy { $0 == "UNREAD" || $0 == "STARRED" }
        let keys = try await Self.messageKeys(inConversation: threadId, account: account, preferLoaded: flagsOnly)
        guard !keys.isEmpty else { return }
        try await IMAPSessions.shared.with(account) { session in
            let folders = session.cachedFolders
            for (path, group) in Dictionary(grouping: keys, by: \.path) {
                let selected = try await session.connection.select(path)
                let uids = group.filter { $0.uidValidity == selected.uidValidity }.map(\.uid)
                guard !uids.isEmpty else { continue }
                if removeLabelIds.contains("UNREAD") { try await session.connection.setFlags(["\\Seen"], uids: uids, add: true) }
                if addLabelIds.contains("UNREAD") { try await session.connection.setFlags(["\\Seen"], uids: uids, add: false) }
                if addLabelIds.contains("STARRED") { try await session.connection.setFlags(["\\Flagged"], uids: uids, add: true) }
                if removeLabelIds.contains("STARRED") { try await session.connection.setFlags(["\\Flagged"], uids: uids, add: false) }
                var destination: String?
                // Your own copies stay put, as in Outlook: marking a
                // conversation spam or filing it doesn't empty Sent.
                let isYours = path == folders.sent || path == folders.drafts
                if isYours { destination = nil }
                else if addLabelIds.contains("SPAM") { destination = folders.junk }
                else if let folder = addLabelIds.first(where: { $0.hasPrefix("folder:") }) { destination = String(folder.dropFirst(7)) }
                else if removeLabelIds.contains("INBOX"), path == folders.inbox { destination = folders.archive }
                if let destination, destination != path {
                    try await session.connection.move(uids: uids, to: destination)
                    await IMAPCache.shared.forget(group.map(\.raw), account: account)
                }
            }
            if addLabelIds.contains("INBOX") {
                // From wherever it went: the Archive, Trash, Junk, or one of
                // your own folders.
                let own = session.allFolders.filter { $0.isSelectable && $0.role == nil && $0.path != "Notes" }.map(\.path)
                let sources = [folders.archive, folders.trash, folders.junk].compactMap { $0 } + own
                try await Self.bringBack(conversation: threadId, from: sources, to: folders.inbox, session: session, account: account)
            }
        }
    }

    func trashThread(threadId: String, account: String) async throws {
        let keys = try await Self.messageKeys(inConversation: threadId, account: account)
        try await IMAPSessions.shared.with(account) { session in
            guard let trash = session.cachedFolders.trash else { return }
            for (path, group) in Dictionary(grouping: keys, by: \.path) where path != trash {
                let selected = try await session.connection.select(path)
                let uids = group.filter { $0.uidValidity == selected.uidValidity }.map(\.uid)
                if !uids.isEmpty { try await session.connection.move(uids: uids, to: trash) }
                await IMAPCache.shared.forget(group.map(\.raw), account: account)
            }
        }
    }

    func untrashThread(threadId: String, account: String) async throws {
        try await IMAPSessions.shared.with(account) { session in
            let folders = session.cachedFolders
            try await Self.bringBack(conversation: threadId, from: [folders.trash].compactMap { $0 }, to: folders.inbox,
                                     session: session, account: account)
        }
    }

    /// A conversation's messages, asked of the server each time and joined
    /// with what's been fetched this session. The cache alone missed older
    /// messages in the Archive, so opening showed part of a conversation
    /// and archiving left the rest behind.
    static func messageKeys(inConversation conversation: String, account: String, preferLoaded: Bool = false) async throws -> [Key] {
        let known = await IMAPCache.shared.keys(inConversation: conversation, account: account).compactMap(parse)
        if preferLoaded, !known.isEmpty { return known }
        let searched = try await searchConversation(conversation, account: account)
        var seen = Set(searched.map(\.raw))
        return searched + known.filter { seen.insert($0.raw).inserted }
    }

    private static func searchConversation(_ conversation: String, account: String) async throws -> [Key] {
        try await IMAPSessions.shared.with(account) { session in
            let folders = try await session.folders()
            var found: [Key] = []
            for path in [folders.inbox, folders.sent, folders.archive, folders.junk].compactMap({ $0 }) {
                let selected = try await session.connection.select(path)
                let uids = try await session.connection.search(conversation: conversation)
                guard !uids.isEmpty else { continue }
                let summaries = try await session.connection.fetchSummaries(uids: uids)
                await IMAPCache.shared.keep(summaries, uidValidity: selected.uidValidity, account: account)
                found += summaries.compactMap { parse(key($0, uidValidity: selected.uidValidity)) }
            }
            return found
        }
    }

    /// Finds a conversation's messages in other folders by Message-ID (their
    /// UIDs changed when they moved) and moves them to the Inbox.
    private static func bringBack(conversation: String, from sources: [String], to inbox: String?,
                                  session: IMAPSessions.Session, account: String) async throws {
        guard let inbox else { return }
        let messageIDs = await IMAPCache.shared.messageIDs(inConversation: conversation, account: account)
        for source in sources where source != inbox {
            try await session.connection.select(source)
            // By the conversation too: after a restart nothing is cached.
            var matched = Set(try await session.connection.search(conversation: conversation))
            for id in messageIDs { matched.formUnion(try await session.connection.search(messageID: id)) }
            guard !matched.isEmpty else { continue }
            let uids = Array(matched)
            // Out of Junk: tell iCloud's filter it was wrong, as Apple Mail does.
            if source == session.cachedFolders.junk { try? await session.connection.setFlags(["$NotJunk"], uids: uids, add: true) }
            try await session.connection.move(uids: uids, to: inbox)
        }
        // Their old places are gone; the next action asks the server again.
        let stale = await IMAPCache.shared.keys(inConversation: conversation, account: account)
            .filter { parse($0)?.path != inbox }
        await IMAPCache.shared.forget(stale, account: account)
    }

    // MARK: Settings and folders

    /// The account's addresses: the main one, plus every alias and custom-
    /// domain address it has sent from. iCloud gives apps no list of
    /// aliases, but Sent Messages shows each one in use, with its name.
    func sendAs(account: String) async throws -> [GmailAPIClient.SendAs] {
        let fromSent: [Address] = try await IMAPSessions.shared.with(account) { session in
            guard let sent = try await session.folders().sent else { return [] }
            let selected = try await session.connection.select(sent)
            return try await session.connection.fetchNewestSummaries(count: 300, of: selected.exists).compactMap(\.from)
        }
        return Self.addresses(primary: account, sentFrom: fromSent)
    }

    static func addresses(primary: String, sentFrom: [Address]) -> [GmailAPIClient.SendAs] {
        var names: [String: String] = [:]
        var order: [String] = []
        for address in sentFrom {
            let email = address.email.lowercased()
            if names[email] == nil { order.append(email) }
            if let name = address.name, !name.isEmpty, (names[email] ?? "").isEmpty { names[email] = name }
            else if names[email] == nil { names[email] = "" }
        }
        let main = primary.lowercased()
        var result = [GmailAPIClient.SendAs(email: main, name: names[main] ?? names.values.first { !$0.isEmpty } ?? "",
                                            isDefault: true, isPrimary: true)]
        for email in order where email != main {
            result.append(GmailAPIClient.SendAs(email: email, name: names[email] ?? "", isDefault: false, isPrimary: false))
        }
        return result
    }

    func vacation(account: String) async throws -> GmailAPIClient.Vacation {
        throw ClientError.refused(statusCode: 0, reason: "unsupported", message: "iCloud sets Out of Office at icloud.com/mail, not through apps.")
    }

    func setVacation(_ vacation: GmailAPIClient.Vacation, account: String) async throws {
        throw ClientError.refused(statusCode: 0, reason: "unsupported", message: "iCloud sets Out of Office at icloud.com/mail, not through apps.")
    }

    /// A folder's mail, newest first, a page at a time. The page token is
    /// the newest position still to load.
    func listMailbox(labelId: String?, account: String, pageToken: String?, pageSize: Int) async throws -> (items: [Correspondence], nextPageToken: String?) {
        let page: (keys: [String], next: String?) = try await IMAPSessions.shared.with(account) { session in
            // Asked for, not just read from the cache: on a fresh connection
            // the cache is still empty, and every mailbox came back empty.
            let folders = try await session.folders()
            // Flagged is a flag, not a folder: the newest flagged mail in
            // the Inbox and the Archive, where you'd have left it.
            if labelId == "STARRED" {
                var keys: [String] = []
                for path in [folders.inbox, folders.archive].compactMap({ $0 }) {
                    let selected = try await session.connection.select(path)
                    let uids = try await session.connection.searchFlagged().sorted(by: >).prefix(pageSize)
                    guard !uids.isEmpty else { continue }
                    let messages = try await session.connection.fetchSummaries(uids: Array(uids))
                    await IMAPCache.shared.keep(messages, uidValidity: selected.uidValidity, account: account)
                    keys += messages.map { Self.key($0, uidValidity: selected.uidValidity) }
                }
                return (keys, nil)
            }
            let path: String? = switch labelId {
            case "INBOX": folders.inbox
            // All Mail: what you've archived (the Inbox is Mail itself).
            case nil: folders.archive ?? folders.inbox
            case "SENT": folders.sent
            case "TRASH": folders.trash
            case "SPAM": folders.junk
            case "DRAFT": folders.drafts
            case let id? where id.hasPrefix("folder:"): String(id.dropFirst(7))
            default: folders.archive
            }
            guard let path else { return ([], nil) }
            let selected = try await session.connection.select(path)
            let end = pageToken.flatMap(Int.init) ?? selected.exists
            let messages = try await session.connection.fetchNewestSummaries(count: pageSize, of: selected.exists, endingAt: end)
            await IMAPCache.shared.keep(messages, uidValidity: selected.uidValidity, account: account)
            let keys = messages.sorted { $0.uid > $1.uid }.map { Self.key($0, uidValidity: selected.uidValidity) }
            let nextEnd = end - pageSize
            return (keys, nextEnd >= 1 ? String(nextEnd) : nil)
        }
        let fetched = try await fetchMetadata(ids: page.keys, account: account)
        if fetched.items.count < page.keys.count {
            Logger(subsystem: "studio.anwarcreative.corres", category: "imap")
                .error("Mailbox page: \(page.keys.count) listed, \(fetched.items.count) read")
        }
        return (fetched.items.sorted { $0.receivedAt > $1.receivedAt }, page.next)
    }

    func listDrafts(account: String, pageToken: String?, pageSize: Int) async throws -> (items: [(draftID: String, message: Correspondence)], nextPageToken: String?) {
        let page = try await listMailbox(labelId: "DRAFT", account: account, pageToken: pageToken, pageSize: pageSize)
        return (page.items.map { ($0.latestMessageID ?? "", $0) }, page.nextPageToken)
    }

    func watch(topicName: String, account: String) async throws -> String? { nil }
    func stopWatching(account: String) async throws {}

    /// The person's own folders, for Mailboxes and "Move to".
    func fetchUserLabels(account: String) async throws -> [GmailUserLabel] {
        try await IMAPSessions.shared.with(account) { session in
            try await session.refreshFolders()
            return session.allFolders
                // "Notes" is where iCloud kept notes before the Notes app
                // moved them; Apple Mail hides it too.
                .filter { $0.role == nil && $0.isSelectable && $0.path != "Notes" }
                .map { GmailUserLabel(id: "folder:\($0.path)", name: $0.displayPath.replacingOccurrences(of: String($0.delimiter ?? "/"), with: " / ")) }
        }
    }

    func fetchAttachmentData(messageId: String, attachmentId: String, account: String) async throws -> Data {
        if let parsed = await IMAPCache.shared.body(for: messageId, account: account),
           let index = Int(attachmentId), parsed.attachments.indices.contains(index) {
            return parsed.attachments[index].data
        }
        _ = try await fetchMessages(ids: [messageId], account: account)
        guard let parsed = await IMAPCache.shared.body(for: messageId, account: account),
              let index = Int(attachmentId), parsed.attachments.indices.contains(index) else { throw ClientError.decodingFailed }
        return parsed.attachments[index].data
    }

    // MARK: Mapping

    private func map(_ m: MessageSummary, key: String, account: String, folders: IMAPSessions.FolderPaths, body: ParsedMessage?) -> Correspondence {
        let senderEmail = m.from?.email ?? ""
        let sender = m.from?.name ?? senderEmail
        let (mailto, url) = GmailAPIClient.parseListUnsubscribe(m.listUnsubscribe ?? "")
        var html = body?.html
        if let h = html, let attachments = body?.attachments {
            for a in attachments where a.contentID != nil {
                html = (html ?? h).replacingOccurrences(of: "cid:\(a.contentID!)", with: "data:\(a.mimeType);base64,\(a.data.base64EncodedString())")
            }
        }
        let plain = body.map { $0.plainText ?? MailDigest.readableText(body: "", html: $0.html ?? "") } ?? ""
        let excerpt = String(plain.replacingPattern(#"\s+"#, with: " ").prefix(160))
        let attachments = (body?.attachments ?? []).enumerated().filter { !$0.element.isInline }.map {
            MailAttachment(id: String($0.offset), filename: $0.element.filename, mimeType: $0.element.mimeType, sizeBytes: $0.element.size)
        }
        return GmailAPIClient.build(
            account: account, threadID: Self.conversation(for: m), messageID: key,
            sender: sender, senderEmail: senderEmail, organization: GmailAPIClient.organization(fromEmail: senderEmail),
            subject: m.subject.isEmpty ? String(localized: "(no subject)") : m.subject, excerpt: excerpt,
            body: plain, htmlBody: html, messageIdHeader: m.messageID,
            receivedAt: m.date ?? .now, isUnread: !m.isSeen,
            labelIds: Self.labels(flags: m.flags, folder: m.folder, folders: folders, hasUnsubscribe: mailto != nil || url != nil),
            attachments: attachments,
            toRecipients: m.to.map(Self.formatted), ccRecipients: m.cc.map(Self.formatted), replyTo: m.replyTo.map(Self.formatted),
            listUnsubscribeMailto: mailto, listUnsubscribeURL: url,
            listUnsubscribeOneClick: url != nil && (m.listUnsubscribePost?.lowercased().contains("one-click") ?? false),
            bodyLoaded: body != nil)
    }

    static func labels(flags: Set<String>, folder: String, folders: IMAPSessions.FolderPaths, hasUnsubscribe: Bool = false) -> [String] {
        var labels: [String] = []
        switch folder {
        case folders.inbox: labels.append("INBOX")
        case folders.sent: labels.append("SENT")
        case folders.trash: labels.append("TRASH")
        case folders.junk: labels.append("SPAM")
        case folders.drafts: labels.append("DRAFT")
        case folders.archive: break
        default: labels.append("folder:\(folder)")
        }
        if !flags.contains("\\seen") { labels.append("UNREAD") }
        if flags.contains("\\flagged") { labels.append("STARRED") }
        // iCloud has no tabs; Corres's own sorting decides, with the
        // unsubscribe header as its first hint.
        if folder == folders.inbox, hasUnsubscribe { labels.append("CATEGORY_PROMOTIONS") }
        return labels
    }

    static func conversation(for m: MessageSummary) -> String {
        m.references.first ?? m.inReplyTo ?? m.messageID ?? "uid:\(m.folder)/\(m.uid)"
    }

    static func key(_ m: MessageSummary, uidValidity: UInt32) -> String { "\(uidValidity):\(m.uid):\(m.folder)" }

    struct Key { let raw: String; let uidValidity: UInt32; let uid: UInt32; let path: String }

    static func parse(_ raw: String) -> Key? {
        let parts = raw.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, let v = UInt32(parts[0]), let u = UInt32(parts[1]) else { return nil }
        return Key(raw: raw, uidValidity: v, uid: u, path: String(parts[2]))
    }

    static func known(_ messages: [MessageSummary], keeping old: [String: String]) -> [String: String] {
        var all = old
        for m in messages { all[String(m.uid)] = conversation(for: m) }
        let newest = all.keys.compactMap(UInt32.init).sorted(by: >).prefix(500).map(String.init)
        // Never trusts the keys to round-trip: a stored "07" next to "7"
        // would be a duplicate key, and a crash.
        return Dictionary(newest.compactMap { key in all[key].map { (key, $0) } }, uniquingKeysWith: { first, _ in first })
    }

    /// `known`'s flags as kept in the cursor (see `Cursor.flags`): these
    /// messages' read and flagged state as fetched, on top of `old`, for
    /// the UIDs still in `known`.
    static func flagCodes(_ messages: [MessageSummary], keeping old: [String: UInt8], known: [String: String]) -> [String: UInt8] {
        var all = old
        for m in messages {
            let (mailto, url) = GmailAPIClient.parseListUnsubscribe(m.listUnsubscribe ?? "")
            all[String(m.uid)] = FlagChanges.code(m.flags) | (mailto != nil || url != nil ? unsubscribeBit : 0)
        }
        return all.filter { known[$0.key] != nil }
    }

    static func formatted(_ a: Address) -> String {
        guard let name = a.name, !name.isEmpty else { return a.email }
        return "\(name) <\(a.email)>"
    }

    /// Keys in order, so a pass that changed nothing gives the same text
    /// back and the cursor isn't saved again.
    static func encode(_ cursor: Cursor) throws -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return String(data: try encoder.encode(cursor), encoding: .utf8)
    }

    /// Every recipient address (To, Cc, Bcc) and the message to send, with
    /// the Bcc line removed so recipients don't see it.
    /// Corres builds every outgoing email as base64url, the form Gmail's
    /// API takes; IMAP and SMTP want the message itself.
    static func mime(fromRaw raw: String) -> String {
        var base64 = raw.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        guard let data = Data(base64Encoded: base64) else { return raw }
        return String(decoding: data, as: UTF8.self)
    }

    static func envelope(of raw: String) -> (recipients: [String], message: String) {
        let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n")
        guard let split = normalized.range(of: "\n\n") else { return ([], raw) }
        let headerText = String(normalized[..<split.lowerBound])
        // Each header with its continuation lines. Read unfolded, but sent
        // folded as written: unfolded, a long subject in Japanese or a long
        // References line ran past SMTP's 998-character line limit, and
        // servers turned the email away.
        var fields: [[String]] = []
        for line in headerText.components(separatedBy: "\n") {
            if let first = line.first, first == " " || first == "\t", !fields.isEmpty { fields[fields.count - 1].append(line) }
            else { fields.append([line]) }
        }
        var recipients: [String] = []
        var kept: [String] = []
        for field in fields {
            let line = field.map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
            let lower = line.lowercased()
            if lower.hasPrefix("to:") || lower.hasPrefix("cc:") || lower.hasPrefix("bcc:") {
                let value = line[line.index(after: line.firstIndex(of: ":")!)...]
                let pattern = #"[A-Za-z0-9._%+'-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#
                recipients += value.matches(of: try! Regex(pattern)).map { String(value[$0.range]).lowercased() }
            }
            if !lower.hasPrefix("bcc:") { kept += field }
        }
        var seen = Set<String>()
        let unique = recipients.filter { seen.insert($0).inserted }
        let body = String(normalized[split.upperBound...])
        let message = (kept.joined(separator: "\n") + "\n\n" + body).replacingOccurrences(of: "\n", with: "\r\n")
        return (unique, message)
    }
}
