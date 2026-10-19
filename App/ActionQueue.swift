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
        }
        var id = UUID()
        let account: String
        let threadID: String
        let kind: Kind
        /// The conversation as it was, for a removal: put back if the
        /// server refuses for good.
        var snapshot: Correspondence?
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
        while let action = actions.first {
            do {
                try await Self.run(action, client: client)
                actions.removeFirst()
                save()
            } catch where Self.isTransient(error) {
                actions[0].attempts += 1
                save()
                scheduleRetry(after: actions[0].attempts)
                return
            } catch {
                Self.log.error("A waiting change was refused: \(String(describing: error), privacy: .public)")
                actions.removeFirst()
                save()
                await onRefused?(action, error)
            }
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

    /// No connection, a dropped one, the server busy or briefly failing,
    /// or a sign-in that needs renewing: worth waiting for, not a refusal.
    static func isTransient(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            return [.notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotConnectToHost, .cannotFindHost,
                    .dnsLookupFailed, .internationalRoamingOff, .dataNotAllowed, .secureConnectionFailed].contains(urlError.code)
        }
        switch error {
        case GmailAPIClient.ClientError.badResponse(let status):
            return status == 0 || status == 429 || status >= 500 || status == -1
        case GmailAPIClient.ClientError.refused(let status, let reason, _):
            return status == 429 || status >= 500 || reason.map(GmailAPIClient.rateLimitReasons.contains) == true
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
