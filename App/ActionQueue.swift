import Foundation
import Network
import os

/// Changes waiting for the server: an archive, a delete, a read or a flag
/// made with no connection (or while the server was busy) is kept here, on
/// this iPhone, and sent once it can be. What you did stays done on screen
/// meanwhile, as in Superhuman, Gmail and Outlook; an archive used to fail
/// and bring the row back.
///
/// In order, oldest first, so two changes to one conversation (read, then
/// unread) reach the server the way you made them. Saved to a file, so a
/// change survives Corres being closed before the connection returns.
@MainActor
final class ActionQueue {
    static let shared = ActionQueue()

    struct Action: Codable, Identifiable {
        enum Kind: Codable, Equatable {
            case modify(add: [String], remove: [String])
            case trash

            /// Takes mail out of the Inbox or marks it read: what a reply
            /// that came after it shouldn't have done to it too.
            var leavesNewMail: Bool {
                switch self {
                case .trash: true
                case .modify(let add, let remove): remove.contains("INBOX") || remove.contains("UNREAD") || add.contains("SPAM")
                }
            }
        }
        var id = UUID()
        let account: String
        let threadID: String
        let kind: Kind
        /// The conversation as it was, for a removal: put back if the
        /// server refuses for good.
        var snapshot: Correspondence?
        /// Its latest message when the change was made, and when that came:
        /// a change that waits doesn't reach mail that arrived after it.
        /// Optional so saved changes decode.
        var knownMessageID: String?
        var knownAt: Date?
        var createdAt = Date.now
        var attempts = 0
    }

    private(set) var actions: [Action] = []
    /// Told when the server refused a change for good (not a lost
    /// connection): put the conversation back, say why.
    var onRefused: ((Action, Error) async -> Void)?

    private let client = MailClient()
    private var draining = false
    private var retry: Task<Void, Never>?
    private let monitor = NWPathMonitor()
    private static let log = Logger(subsystem: "studio.anwarcreative.corres", category: "actions")

    private static var file: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("waiting-changes.json")
    }

    private init() {
        if let file = Self.file, let data = try? Data(contentsOf: file),
           let saved = try? JSONDecoder().decode([Action].self, from: data) {
            actions = saved
        }
        // Back online: send what waited.
        monitor.pathUpdateHandler = { path in
            guard path.status == .satisfied else { return }
            Task { @MainActor in await ActionQueue.shared.drain() }
        }
        monitor.start(queue: DispatchQueue(label: "studio.anwarcreative.corres.network"))
    }

    /// Whether this conversation has changes waiting: a newer change to it
    /// joins the queue too, so they arrive in order.
    func hasWaiting(account: String, threadID: String) -> Bool {
        actions.contains { $0.account == account && $0.threadID == threadID }
    }

    /// When each conversation was last changed here (read, flagged, moved).
    private var changedAt: [String: Date] = [:]
    private static let settling: TimeInterval = 120

    func noteChange(account: String, threadID: String) {
        let now = Date.now
        if changedAt.count > 500 { changedAt = changedAt.filter { now.timeIntervalSince($0.value) < Self.settling } }
        changedAt[account + "|" + threadID] = now
    }

    /// A change of yours is waiting, or was just made: what a sync read
    /// from the server about this conversation may be from before it, and
    /// would put the dot or the flag back for a moment.
    func isChanging(account: String, threadID: String) -> Bool {
        if let at = changedAt[account + "|" + threadID], Date.now.timeIntervalSince(at) < Self.settling { return true }
        return hasWaiting(account: account, threadID: threadID)
    }

    /// The account was removed: what waited for it is dropped, not sent
    /// later (if it's added back) or put back on screen.
    func forget(account: String) {
        let before = actions.count
        actions.removeAll { $0.account == account }
        if actions.count != before { save() }
    }

    func enqueue(_ action: Action) {
        actions.append(action)
        save()
        Self.log.info("Queued \(String(describing: action.kind), privacy: .public) until the server can take it")
        Task { await drain() }
    }

    /// Sends what's waiting, oldest first. Stops at the first change that
    /// can't go yet (still offline), and tries again later.
    func drain() async {
        guard !draining, !actions.isEmpty else { return }
        draining = true
        defer { draining = false }
        // An account that can't take changes yet (offline, or waiting to be
        // signed in again) holds only its own: other accounts' go through.
        var waitingAccounts = Set<String>()
        var index = 0
        var nextRetry: Int?
        while index < actions.count {
            let action = actions[index]
            guard !waitingAccounts.contains(action.account) else { index += 1; continue }
            // Found again by id after each wait: the list can change meanwhile
            // (an account removed drops its changes), and a stale index
            // would touch the wrong change or none.
            func position() -> Int? { actions.firstIndex { $0.id == action.id } }
            do {
                try await Self.runWaiting(action, client: client)
                if let at = position() { actions.remove(at: at); save() }
            } catch where Self.isGone(error) {
                // Already gone on the server (deleted elsewhere): what this
                // change wanted is true. Putting it back would undo that.
                if let at = position() { actions.remove(at: at); save() }
            } catch where Self.isTransient(error) && action.attempts < Self.maxAttempts {
                guard let at = position() else { continue }
                actions[at].attempts += 1
                save()
                waitingAccounts.insert(action.account)
                nextRetry = min(nextRetry ?? .max, actions[at].attempts)
                index = at + 1
            } catch {
                Self.log.error("A waiting change was refused: \(String(describing: error), privacy: .public)")
                if let at = position() { actions.remove(at: at); save() }
                await onRefused?(action, error)
            }
        }
        if let nextRetry { scheduleRetry(after: nextRetry) }
    }

    /// About a day of tries at the longest wait; a change still not taken
    /// then is treated as refused rather than kept forever.
    static let maxAttempts = 300

    /// The conversation no longer exists on the server.
    static func isGone(_ error: Error) -> Bool {
        switch error {
        case GmailAPIClient.ClientError.badResponse(let status): status == 404
        case GmailAPIClient.ClientError.refused(let status, _, _): status == 404
        default: false
        }
    }

    static func run(_ action: Action, client: MailClient) async throws {
        switch action.kind {
        case .modify(let add, let remove):
            try await client.modifyThread(threadId: action.threadID, addLabelIds: add, removeLabelIds: remove, account: action.account)
        case .trash:
            try await client.trashThread(threadId: action.threadID, account: action.account)
        }
    }

    /// A change that waited, sent as it was meant: to the mail there when
    /// you made it. A reply that came meanwhile stays in the Inbox, unread,
    /// rather than being archived, deleted or marked read with what you'd
    /// seen. Gmail takes the change on those messages alone; Outlook and
    /// IMAP accounts leave the conversation as it is, the reply with it.
    static func runWaiting(_ action: Action, client: MailClient) async throws {
        guard action.kind.leavesNewMail, let known = action.knownMessageID else { return try await run(action, client: client) }
        let messages = try await client.fetchThreadMessages(threadId: action.threadID, account: action.account)
        guard let earlier = WaitingChange.messagesKnown(atMessage: known, at: action.knownAt, in: messages) else {
            return try await run(action, client: client)
        }
        guard client.changesSingleMessages(account: action.account), !earlier.isEmpty else {
            log.info("A waiting change was left out: a reply came after it")
            return
        }
        switch action.kind {
        case .modify(let add, let remove):
            try await client.modifyMessages(ids: earlier, addLabelIds: add, removeLabelIds: remove, account: action.account)
        case .trash:
            try await client.trashMessages(ids: earlier, account: action.account)
        }
    }

    /// No connection, a dropped one, the server busy or briefly failing,
    /// or a sign-in that needs renewing: worth waiting for, not a refusal.
    static func isTransient(_ error: Error) -> Bool {
        // Cut off before an answer came back: whether it went through is
        // unknown, and sending it again does no harm.
        if error is CancellationError { return true }
        if let urlError = error as? URLError {
            return [.notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotConnectToHost, .cannotFindHost,
                    .dnsLookupFailed, .internationalRoamingOff, .dataNotAllowed, .secureConnectionFailed,
                    .cancelled].contains(urlError.code)
        }
        switch error {
        case GmailAPIClient.ClientError.badResponse(let status):
            return status == 0 || status == 429 || status >= 500 || status == -1
        case GmailAPIClient.ClientError.refused(let status, let reason, _):
            // Status 0 with no reason is an iCloud server answering NO to a
            // command, most often while it's busy.
            return status == 429 || status >= 500 || reason.map(GmailAPIClient.rateLimitReasons.contains) == true
                || (status == 0 && reason == nil)
        case GmailAPIClient.ClientError.notSignedIn:
            // Kept for after you sign in again; the app asks you to.
            return true
        default:
            return (error as NSError).domain == NSURLErrorDomain
        }
    }

    private func scheduleRetry(after attempts: Int) {
        retry?.cancel()
        let seconds = min(300.0, 5 * pow(2, Double(min(attempts, 6))))
        retry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            await self?.drain()
        }
    }

    private func save() {
        guard let file = Self.file else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder().encode(actions).write(to: file, options: .atomic)
    }
}
