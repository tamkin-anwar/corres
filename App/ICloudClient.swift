import Foundation
import MailEngine

/// iCloud Mail behind the same calls as `GmailAPIClient` and `OutlookClient`,
/// over IMAP and SMTP (`MailEngine`). Sign-in is the account's address and
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
struct ICloudClient: Sendable {
    typealias ClientError = GmailAPIClient.ClientError

    static let imapHost = "imap.mail.me.com"
    static let smtpHost = "smtp.mail.me.com"
    static let firstInboxCount = 200
    static let firstSentCount = 100

    // MARK: Sync

    /// Per-folder state between syncs, plus which conversation each known
    /// message belongs to (to report changes made elsewhere).
    struct Cursor: Codable {
        var folders: [String: FolderSyncState]
        /// Folder path → UID (as text) → conversation id. Newest 500 per folder.
        var known: [String: [String: String]]
    }

    func planFullListing(account: String) async throws -> GmailAPIClient.SyncPlan {
        try await ICloudSessions.shared.with(account) { session in
            let folders = try await session.folders()
            var cursor = Cursor(folders: [:], known: [:])
            var all: [MessageSummary] = []
            for (path, count) in [(folders.inbox, Self.firstInboxCount), (folders.sent, Self.firstSentCount)] {
                guard let path else { continue }
                let selected = try await session.connection.select(path)
                let messages = try await session.connection.fetchNewestSummaries(count: count, of: selected.exists)
                all += messages
                cursor.folders[path] = FolderSyncState(uidValidity: selected.uidValidity, uidNext: selected.uidNext,
                                                       highestModSeq: selected.highestModSeq,
                                                       oldestFetchedUID: messages.map(\.uid).min())
                cursor.known[path] = Self.known(messages, keeping: [:])
                await ICloudCache.shared.keep(messages, uidValidity: selected.uidValidity, account: account)
            }
            all.sort { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
            let ids = all.map { Self.key($0, uidValidity: cursor.folders[$0.folder]?.uidValidity ?? 0) }
            return GmailAPIClient.SyncPlan(messageIDs: ids, historyId: try Self.encode(cursor),
                                           olderInboxPageToken: folders.inbox.map { "\($0)|\(max(0, (cursor.folders[$0]?.oldestFetchedUID ?? 1) - 1))" })
        }
    }

    func planIncremental(account: String, since cursorString: String) async throws -> GmailAPIClient.SyncPlan {
        guard let data = cursorString.data(using: .utf8), let start = try? JSONDecoder().decode(Cursor.self, from: data) else {
            throw ClientError.historyExpired
        }
        return try await ICloudSessions.shared.with(account) { session in
            // A folder synced from the start that this cursor never saw
            // (Sent, when the folder list once came back empty): list again.
            let folders = try await session.folders()
            if let sent = folders.sent, start.folders[sent] == nil { throw ClientError.historyExpired }
            var cursor = start
            var newIDs: [String] = []
            var changes: [RemoteMessageChange] = []
            for (path, stored) in cursor.folders {
                let selected = try await session.connection.select(path)
                let caps = await session.connection.capabilities
                switch SyncPlanner.plan(stored: stored, selected: selected, capabilities: caps) {
                case .full:
                    // The folder was renumbered: start over from a full listing.
                    throw ClientError.historyExpired
                case .upToDate:
                    continue
                case .incremental(let newFrom, _, _):
                    var known = cursor.known[path] ?? [:]
                    if let newFrom, newFrom <= selected.uidNext {
                        let fresh = try await session.connection.fetchSummaries(uids: newFrom...UInt32.max)
                            .filter { $0.uid >= newFrom }
                        await ICloudCache.shared.keep(fresh, uidValidity: selected.uidValidity, account: account)
                        newIDs += fresh.map { Self.key($0, uidValidity: selected.uidValidity) }
                        known = Self.known(fresh, keeping: known)
                    }
                    // Read, flagged or removed elsewhere: compare what's known.
                    let uids = known.keys.compactMap(UInt32.init)
                    if let low = uids.min(), let high = uids.max() {
                        let flags = try await session.connection.fetchFlags(uids: low...high)
                        for uid in uids {
                            guard let conversation = known[String(uid)] else { continue }
                            let key = "\(selected.uidValidity):\(uid):\(path)"
                            let thread = ThreadID(account: account, providerID: conversation)
                            if let current = flags[uid] {
                                changes.append(RemoteMessageChange(threadID: thread, messageID: key,
                                                                   currentLabelIds: Self.labels(flags: current, folder: path, folders: session.cachedFolders),
                                                                   removed: false))
                            } else if path == session.cachedFolders.inbox {
                                changes.append(RemoteMessageChange(threadID: thread, messageID: key, currentLabelIds: nil, removed: true))
                                known[String(uid)] = nil
                            }
                        }
                    }
                    cursor.known[path] = known
                    cursor.folders[path] = FolderSyncState(uidValidity: selected.uidValidity, uidNext: selected.uidNext,
                                                           highestModSeq: selected.highestModSeq,
                                                           oldestFetchedUID: stored.oldestFetchedUID)
                }
            }
            return GmailAPIClient.SyncPlan(messageIDs: newIDs, historyId: try Self.encode(cursor), remoteChanges: changes)
        }
    }

    func listRecentSent(account: String) async throws -> [String] { [] }

    /// Older Inbox mail, a page at a time. The page token is
    /// "<folder>|<highest UID still to load>".
    func listOlderInbox(account: String, pageToken: String?) async throws -> (ids: [(id: String, threadId: String?)], nextPageToken: String?) {
        guard let pageToken, let bar = pageToken.lastIndex(of: "|"), let below = UInt32(pageToken[pageToken.index(after: bar)...]),
              below > 0 else { return ([], nil) }
        let path = String(pageToken[..<bar])
        return try await ICloudSessions.shared.with(account) { session in
            let selected = try await session.connection.select(path)
            let low = below > 300 ? below - 300 : 1
            let messages = try await session.connection.fetchSummaries(uids: low...below)
                .sorted { $0.uid > $1.uid }.prefix(GmailAPIClient.olderPageSize)
            await ICloudCache.shared.keep(Array(messages), uidValidity: selected.uidValidity, account: account)
            let ids = messages.map { (Self.key($0, uidValidity: selected.uidValidity), Optional(Self.conversation(for: $0))) }
            let next = (messages.map(\.uid).min() ?? low) > 1 ? "\(path)|\((messages.map(\.uid).min() ?? low) - 1)" : nil
            return (ids, messages.isEmpty && low == 1 ? nil : next)
        }
    }

    // MARK: Messages

    func fetchMetadata(ids: [String], account: String) async throws -> (items: [Correspondence], failedIDs: [String]) {
        let cached = await ICloudCache.shared.summaries(for: ids, account: account)
        var found = cached
        let missing = ids.filter { cached[$0] == nil }
        if !missing.isEmpty {
            let fetched: [String: MessageSummary] = try await ICloudSessions.shared.with(account) { session in
                var found: [String: MessageSummary] = [:]
                for (path, keys) in Dictionary(grouping: missing.compactMap(Self.parse), by: \.path) {
                    let selected = try await session.connection.select(path)
                    let uids = keys.filter { $0.uidValidity == selected.uidValidity }.map(\.uid)
                    guard !uids.isEmpty else { continue }
                    let messages = try await session.connection.fetchSummaries(uids: uids)
                    await ICloudCache.shared.keep(messages, uidValidity: selected.uidValidity, account: account)
                    for m in messages { found[Self.key(m, uidValidity: selected.uidValidity)] = m }
                }
                return found
            }
            found.merge(fetched) { a, _ in a }
        }
        let folders = await ICloudSessions.shared.folders(for: account)
        let items = ids.compactMap { id in found[id].map { map($0, key: id, account: account, folders: folders, body: nil) } }
        return (items, ids.filter { found[$0] == nil })
    }

    func fetchSummary(ids: [String], account: String) async throws -> [Correspondence] {
        try await fetchMetadata(ids: ids, account: account).items
    }

    func fetchFull(ids: [String], account: String) async throws -> (items: [Correspondence], failedIDs: [String]) {
        try await fetchMessages(ids: ids, account: account)
    }

    func fetchMessages(ids: [String], account: String) async throws -> (items: [Correspondence], failedIDs: [String]) {
        let summaries = try await fetchMetadataSummaries(ids: ids, account: account)
        return try await ICloudSessions.shared.with(account) { session in
            var items: [Correspondence] = []
            var failed: [String] = []
            for (path, keys) in Dictionary(grouping: ids.compactMap(Self.parse), by: \.path) {
                let selected = try await session.connection.select(path)
                let current = keys.filter { $0.uidValidity == selected.uidValidity }
                failed += keys.filter { $0.uidValidity != selected.uidValidity }.map(\.raw)
                // Twenty to a command: one round trip a batch, and short
                // enough that an archive or an open waits a moment at most.
                for batch in current.chunked(into: 20) {
                    let raws = try await session.connection.fetchMessages(uids: batch.map(\.uid))
                    for key in batch {
                        guard let summary = summaries[key.raw], let raw = raws[key.uid] else { failed.append(key.raw); continue }
                        let parsed = MIMEParser.parse(raw)
                        await ICloudCache.shared.keepBody(parsed, for: key.raw, account: account)
                        items.append(map(summary, key: key.raw, account: account, folders: session.cachedFolders, body: parsed))
                    }
                }
            }
            return (items, failed)
        }
    }

    private func fetchMetadataSummaries(ids: [String], account: String) async throws -> [String: MessageSummary] {
        _ = try await fetchMetadata(ids: ids, account: account)
        return await ICloudCache.shared.summaries(for: ids, account: account)
    }

    func fetchThreadMessages(threadId: String, account: String) async throws -> [Correspondence] {
        let keys = try await Self.messageKeys(inConversation: threadId, account: account).map(\.raw)
        guard !keys.isEmpty else { return [] }
        return try await fetchMessages(ids: keys, account: account).items.sorted { $0.receivedAt < $1.receivedAt }
    }

    /// The whole mailbox, as Gmail's and Outlook's search are: Inbox, Sent
    /// and Archive, newest first.
    func searchMessages(query: String, account: String) async throws -> [Correspondence] {
        let keys: [String] = try await ICloudSessions.shared.with(account) { session in
            let folders = try await session.folders()
            var found: [String] = []
            for path in [folders.inbox, folders.sent, folders.archive].compactMap({ $0 }) {
                let selected = try await session.connection.select(path)
                let uids = try await session.connection.search(text: query).sorted(by: >).prefix(25)
                found += uids.map { "\(selected.uidValidity):\($0):\(path)" }
            }
            return found
        }
        return try await fetchMetadata(ids: keys, account: account).items.sorted { $0.receivedAt > $1.receivedAt }
    }

    #if DEBUG
    func exportCorpus(account: String, limit: Int) async throws -> (items: [Correspondence], missing: Int) { ([], 0) }
    #endif

    /// Who you write to, from Sent Messages: what suggests people as you
    /// address an email, as Gmail's and Outlook's Sent do.
    func sentAddressing(account: String, limit: Int) async throws -> [GmailAPIClient.Addressing] {
        try await ICloudSessions.shared.with(account) { session in
            guard let sent = try await session.folders().sent else { return [] }
            let selected = try await session.connection.select(sent)
            return try await session.connection.fetchNewestSummaries(count: min(limit, 500), of: selected.exists).map(Self.addressing)
        }
    }

    /// Mail to or from someone by name, in Inbox and Sent.
    func addressing(matching name: String, account: String) async throws -> [GmailAPIClient.Addressing] {
        try await ICloudSessions.shared.with(account) { session in
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
        if let conversation = await ICloudCache.shared.conversation(forMessageID: id, account: account) {
            return ThreadID(account: account, providerID: conversation)
        }
        // Not fetched this session (Corres restarted mid-send): ask iCloud.
        // Sent is where a send that went through lands.
        return try await ICloudSessions.shared.with(account) { session in
            let folders = try await session.folders()
            for path in [folders.sent, folders.inbox].compactMap({ $0 }) {
                let selected = try await session.connection.select(path)
                let uids = try await session.connection.search(messageID: id)
                guard !uids.isEmpty else { continue }
                let found = try await session.connection.fetchSummaries(uids: uids)
                await ICloudCache.shared.keep(found, uidValidity: selected.uidValidity, account: account)
                if let summary = found.first { return ThreadID(account: account, providerID: Self.conversation(for: summary)) }
            }
            return nil
        }
    }

    // MARK: Sending

    /// Sends through iCloud's SMTP (STARTTLS on 587), then files a copy in
    /// Sent, which iCloud's SMTP doesn't do itself. Bcc is read from the
    /// message and removed before it goes out.
    @discardableResult
    func send(raw: String, threadId: String?, account: String) async throws -> String {
        guard let password = ICloudCredentials.password(for: account) else { throw ClientError.notSignedIn }
        let message = Self.mime(fromRaw: raw)
        let (recipients, outgoing) = Self.envelope(of: message)
        guard !recipients.isEmpty else { throw ClientError.refused(statusCode: 0, reason: nil, message: "This email has no recipients.") }
        let smtp = SMTPClient(host: Self.smtpHost, port: 587, security: .startTLS)
        do {
            try await smtp.send(Data(outgoing.utf8), from: account, to: recipients, username: account, password: password)
        } catch SMTPClient.SMTPError.authenticationFailed {
            throw ClientError.notSignedIn
        } catch SMTPClient.SMTPError.recipientRejected(let address, let why) {
            throw ClientError.refused(statusCode: 550, reason: "recipientRejected", message: "\(address): \(why)")
        } catch SMTPClient.SMTPError.rejected(let code, let why) {
            throw ClientError.refused(statusCode: code, reason: nil, message: why)
        }
        // Sent now; what follows is filing, and must never turn a delivered
        // email into a "Couldn't send".
        do {
            try await ICloudSessions.shared.with(account) { session in
                guard let sent = try await session.folders().sent else { return }
                _ = try await session.connection.append(Data(outgoing.utf8), to: sent, flags: ["\\Seen"])
            }
        } catch {
            ICloudSessions.log.error("Sent, but not filed in Sent: \(String(describing: error), privacy: .public)")
        }
        // The conversation it belongs to, the same id sync gives it.
        return threadId ?? Self.conversation(ofMessage: outgoing) ?? ""
    }

    /// A raw message's conversation, by the rule `conversation(for:)` uses
    /// on synced mail: the first References id, else In-Reply-To, else its
    /// own Message-ID.
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
        return try await ICloudSessions.shared.with(account) { session in
            guard let drafts = session.cachedFolders.drafts else { throw ClientError.refused(statusCode: 0, reason: nil, message: "No Drafts folder.") }
            if let existingID, let old = Self.parse(existingID) {
                try await session.connection.select(old.path)
                try await session.connection.setFlags(["\\Deleted"], uids: [old.uid], add: true)
                try await session.connection.expungeIfPossible(uids: [old.uid])
            }
            let uid = try await session.connection.append(message, to: drafts, flags: ["\\Draft", "\\Seen"])
            let selected = try await session.connection.select(drafts)
            return uid.map { "\(selected.uidValidity):\($0):\(drafts)" } ?? ""
        }
    }

    func deleteDraft(id: String, account: String) async throws {
        guard let key = Self.parse(id) else { return }
        try await ICloudSessions.shared.with(account) { session in
            try await session.connection.select(key.path)
            try await session.connection.setFlags(["\\Deleted"], uids: [key.uid], add: true)
            try await session.connection.expungeIfPossible(uids: [key.uid])
        }
    }

    // MARK: Changes

    /// Read, flagged, archive, spam and back to Inbox, on every message of
    /// the conversation Corres has seen.
    func modifyThread(threadId: String, addLabelIds: [String], removeLabelIds: [String], account: String) async throws {
        let keys = try await Self.messageKeys(inConversation: threadId, account: account)
        guard !keys.isEmpty else { return }
        try await ICloudSessions.shared.with(account) { session in
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
                if addLabelIds.contains("SPAM") { destination = folders.junk }
                else if removeLabelIds.contains("INBOX"), path == folders.inbox { destination = folders.archive }
                else if let folder = addLabelIds.first(where: { $0.hasPrefix("folder:") }) { destination = String(folder.dropFirst(7)) }
                if let destination, destination != path {
                    try await session.connection.move(uids: uids, to: destination)
                    await ICloudCache.shared.forget(group.map(\.raw), account: account)
                }
            }
            if addLabelIds.contains("INBOX") {
                try await Self.bringBack(conversation: threadId, from: [folders.archive, folders.trash, folders.junk].compactMap { $0 },
                                         to: folders.inbox, session: session, account: account)
            }
        }
    }

    func trashThread(threadId: String, account: String) async throws {
        let keys = try await Self.messageKeys(inConversation: threadId, account: account)
        try await ICloudSessions.shared.with(account) { session in
            guard let trash = session.cachedFolders.trash else { return }
            for (path, group) in Dictionary(grouping: keys, by: \.path) where path != trash {
                let selected = try await session.connection.select(path)
                let uids = group.filter { $0.uidValidity == selected.uidValidity }.map(\.uid)
                if !uids.isEmpty { try await session.connection.move(uids: uids, to: trash) }
                await ICloudCache.shared.forget(group.map(\.raw), account: account)
            }
        }
    }

    func untrashThread(threadId: String, account: String) async throws {
        try await ICloudSessions.shared.with(account) { session in
            let folders = session.cachedFolders
            try await Self.bringBack(conversation: threadId, from: [folders.trash].compactMap { $0 }, to: folders.inbox,
                                     session: session, account: account)
        }
    }

    /// A conversation's messages: from what's been fetched this session, or,
    /// after Corres restarts and that's gone, from iCloud itself, by the
    /// Message-ID the conversation started with.
    static func messageKeys(inConversation conversation: String, account: String) async throws -> [Key] {
        let known = await ICloudCache.shared.keys(inConversation: conversation, account: account).compactMap(parse)
        if !known.isEmpty { return known }
        return try await ICloudSessions.shared.with(account) { session in
            let folders = try await session.folders()
            var found: [Key] = []
            for path in [folders.inbox, folders.sent, folders.archive, folders.junk].compactMap({ $0 }) {
                let selected = try await session.connection.select(path)
                let uids = try await session.connection.search(conversation: conversation)
                guard !uids.isEmpty else { continue }
                let summaries = try await session.connection.fetchSummaries(uids: uids)
                await ICloudCache.shared.keep(summaries, uidValidity: selected.uidValidity, account: account)
                found += summaries.compactMap { parse(key($0, uidValidity: selected.uidValidity)) }
            }
            return found
        }
    }

    /// Finds a conversation's messages in other folders by Message-ID (their
    /// UIDs changed when they moved) and moves them to the Inbox.
    private static func bringBack(conversation: String, from sources: [String], to inbox: String?,
                                  session: ICloudSessions.Session, account: String) async throws {
        guard let inbox else { return }
        let messageIDs = await ICloudCache.shared.messageIDs(inConversation: conversation, account: account)
        for source in sources where source != inbox {
            try await session.connection.select(source)
            var uids: [UInt32] = []
            for id in messageIDs { uids += try await session.connection.search(messageID: id) }
            guard !uids.isEmpty else { continue }
            // Out of Junk: tell iCloud's filter it was wrong, as Apple Mail does.
            if source == session.cachedFolders.junk { try? await session.connection.setFlags(["$NotJunk"], uids: uids, add: true) }
            try await session.connection.move(uids: uids, to: inbox)
        }
    }

    // MARK: Settings and folders

    /// The account's addresses: the main one, plus every alias and custom-
    /// domain address it has sent from. iCloud gives apps no list of
    /// aliases, but Sent Messages shows each one in use, with its name.
    func sendAs(account: String) async throws -> [GmailAPIClient.SendAs] {
        let fromSent: [Address] = try await ICloudSessions.shared.with(account) { session in
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
        let page: (keys: [String], next: String?) = try await ICloudSessions.shared.with(account) { session in
            let folders = session.cachedFolders
            let path: String? = switch labelId {
            case nil, "INBOX": folders.inbox
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
            await ICloudCache.shared.keep(messages, uidValidity: selected.uidValidity, account: account)
            let keys = messages.sorted { $0.uid > $1.uid }.map { Self.key($0, uidValidity: selected.uidValidity) }
            let nextEnd = end - pageSize
            return (keys, nextEnd >= 1 ? String(nextEnd) : nil)
        }
        return (try await fetchMetadata(ids: page.keys, account: account).items, page.next)
    }

    func listDrafts(account: String, pageToken: String?, pageSize: Int) async throws -> (items: [(draftID: String, message: Correspondence)], nextPageToken: String?) {
        let page = try await listMailbox(labelId: "DRAFT", account: account, pageToken: pageToken, pageSize: pageSize)
        return (page.items.map { ($0.latestMessageID ?? "", $0) }, page.nextPageToken)
    }

    func watch(topicName: String, account: String) async throws -> String? { nil }
    func stopWatching(account: String) async throws {}

    /// The person's own folders, for Mailboxes and "Move to".
    func fetchUserLabels(account: String) async throws -> [GmailUserLabel] {
        try await ICloudSessions.shared.with(account) { session in
            try await session.refreshFolders()
            return session.allFolders
                // "Notes" is where iCloud kept notes before the Notes app
                // moved them; Apple Mail hides it too.
                .filter { $0.role == nil && $0.isSelectable && $0.path != "Notes" }
                .map { GmailUserLabel(id: "folder:\($0.path)", name: $0.path.replacingOccurrences(of: String($0.delimiter ?? "/"), with: " / ")) }
        }
    }

    func fetchAttachmentData(messageId: String, attachmentId: String, account: String) async throws -> Data {
        if let parsed = await ICloudCache.shared.body(for: messageId, account: account),
           let index = Int(attachmentId), parsed.attachments.indices.contains(index) {
            return parsed.attachments[index].data
        }
        _ = try await fetchMessages(ids: [messageId], account: account)
        guard let parsed = await ICloudCache.shared.body(for: messageId, account: account),
              let index = Int(attachmentId), parsed.attachments.indices.contains(index) else { throw ClientError.decodingFailed }
        return parsed.attachments[index].data
    }

    // MARK: Mapping

    private func map(_ m: MessageSummary, key: String, account: String, folders: ICloudSessions.FolderPaths, body: ParsedMessage?) -> Correspondence {
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
            subject: m.subject.isEmpty ? "(no subject)" : m.subject, excerpt: excerpt,
            body: plain, htmlBody: html, messageIdHeader: m.messageID,
            receivedAt: m.date ?? .now, isUnread: !m.isSeen,
            labelIds: Self.labels(flags: m.flags, folder: m.folder, folders: folders, hasUnsubscribe: mailto != nil || url != nil),
            attachments: attachments,
            toRecipients: m.to.map(Self.formatted), ccRecipients: m.cc.map(Self.formatted), replyTo: m.replyTo.map(Self.formatted),
            listUnsubscribeMailto: mailto, listUnsubscribeURL: url,
            listUnsubscribeOneClick: url != nil && (m.listUnsubscribePost?.lowercased().contains("one-click") ?? false),
            bodyLoaded: body != nil)
    }

    static func labels(flags: Set<String>, folder: String, folders: ICloudSessions.FolderPaths, hasUnsubscribe: Bool = false) -> [String] {
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
        return Dictionary(uniqueKeysWithValues: newest.map { ($0, all[$0]!) })
    }

    static func formatted(_ a: Address) -> String {
        guard let name = a.name, !name.isEmpty else { return a.email }
        return "\(name) <\(a.email)>"
    }

    static func encode(_ cursor: Cursor) throws -> String? {
        String(data: try JSONEncoder().encode(cursor), encoding: .utf8)
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
        var lines: [String] = []
        for line in headerText.components(separatedBy: "\n") {
            if let first = line.first, first == " " || first == "\t", !lines.isEmpty { lines[lines.count - 1] += " " + line.trimmingCharacters(in: .whitespaces) }
            else { lines.append(line) }
        }
        var recipients: [String] = []
        var kept: [String] = []
        for line in lines {
            let lower = line.lowercased()
            if lower.hasPrefix("to:") || lower.hasPrefix("cc:") || lower.hasPrefix("bcc:") {
                let value = line[line.index(after: line.firstIndex(of: ":")!)...]
                let pattern = #"[A-Za-z0-9._%+'-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#
                recipients += value.matches(of: try! Regex(pattern)).map { String(value[$0.range]).lowercased() }
            }
            if !lower.hasPrefix("bcc:") { kept.append(line) }
        }
        var seen = Set<String>()
        let unique = recipients.filter { seen.insert($0).inserted }
        let body = String(normalized[split.upperBound...])
        let message = (kept.joined(separator: "\n") + "\n\n" + body).replacingOccurrences(of: "\n", with: "\r\n")
        return (unique, message)
    }
}
