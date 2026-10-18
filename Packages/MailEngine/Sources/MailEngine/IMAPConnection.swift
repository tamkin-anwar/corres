import Foundation
import NIOCore
import NIOIMAP
import NIOTransportServices

/// One connection to an IMAP server, one command at a time. Network.framework
/// underneath (NIOTransportServices), so TLS, Wi-Fi to cellular handover and
/// Low Data Mode behave like the rest of iOS.
public actor IMAPConnection {
    public enum ConnectionError: Error, Equatable, Sendable {
        /// Wrong email or app-specific password, or the password was revoked.
        case authenticationFailed(String)
        /// The server rejected the command (NO) or didn't understand it (BAD).
        case commandFailed(String)
        /// The connection closed or the server said BYE.
        case disconnected
        /// No reply in time.
        case timedOut
        case notConnected
    }

    public let host: String
    public let port: Int
    let useTLS: Bool
    let timeout: Duration

    private var channel: Channel?
    private var responses: ResponseQueue?
    private var tagCounter = 0
    public private(set) var capabilities = Capabilities([])
    public private(set) var selectedFolder: String?

    /// `useTLS: false` is only for the tests' local fake server.
    public init(host: String, port: Int = 993, useTLS: Bool = true, timeout: Duration = .seconds(30)) {
        self.host = host
        self.port = port
        self.useTLS = useTLS
        self.timeout = timeout
    }

    // MARK: Session

    /// Connects and reads the greeting. Returns what the server advertises
    /// before login (often very little; see `login`).
    @discardableResult
    public func connect() async throws -> Capabilities {
        let queue = ResponseQueue()
        let group = NIOTSEventLoopGroup.singleton
        var bootstrap = NIOTSConnectionBootstrap(group: group)
            .connectTimeout(.seconds(15))
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandlers([
                        IMAPClientHandler(),
                        ResponseForwarder(queue: queue),
                    ])
                }
            }
        if useTLS { bootstrap = bootstrap.tlsOptions(.init()) }
        channel = try await bootstrap.connect(host: host, port: port).get()
        responses = queue

        var greeting = ResponseCollector(tag: nil)
        guard let first = try await nextResponse() else { throw ConnectionError.disconnected }
        greeting.receive(first)
        if greeting.sawBye { throw ConnectionError.disconnected }
        capabilities = Capabilities(greeting.capabilities)
        return capabilities
    }

    /// Plain login over TLS with the account's email and (for iCloud) an
    /// app-specific password. Asks for capabilities again afterwards, since
    /// servers like iCloud only list their features once you're in.
    public func login(username: String, password: String) async throws {
        do {
            let result = try await run(.login(username: username, password: password))
            if !result.capabilities.isEmpty { capabilities = Capabilities(result.capabilities) }
        } catch ConnectionError.commandFailed(let message) {
            throw ConnectionError.authenticationFailed(message)
        }
        let caps = try await run(.capability)
        capabilities = Capabilities(caps.capabilities)
    }

    public func logout() async {
        _ = try? await run(.logout)
        try? await channel?.close()
        channel = nil
        responses = nil
        selectedFolder = nil
    }

    // MARK: Folders and messages

    public func listFolders() async throws -> [Folder] {
        try await run(.list(nil, reference: MailboxName(ByteBuffer(string: "")), .pattern([ByteBuffer(string: "*")]))).folders
    }

    /// Opens a folder for reading and writing. With CONDSTORE it also asks
    /// for the folder's change counter.
    @discardableResult
    public func select(_ path: String) async throws -> SelectedFolder {
        let parameters: [SelectParameter] = capabilities.condstore ? [.condStore] : []
        let result = try await run(.select(MailboxName(ByteBuffer(string: path)), parameters), folder: path)
        guard let selected = result.selected else { throw ConnectionError.commandFailed("SELECT gave no UIDVALIDITY") }
        selectedFolder = path
        return selected
    }

    /// Headers for list rows and threading, for the UIDs in `range` of the
    /// selected folder. Bodies are fetched separately, on open.
    public func fetchSummaries(uids range: ClosedRange<UInt32>) async throws -> [MessageSummary] {
        guard let folder = selectedFolder else { throw ConnectionError.notConnected }
        let attributes: [FetchAttribute] = [
            .uid, .flags, .rfc822Size, .envelope,
            .bodySection(peek: true, SectionSpecifier(kind: .headerFields(["REFERENCES"])), nil),
        ]
        return try await run(.uidFetch(Self.uidSet(range), attributes, []), folder: folder).messages
    }

    /// Only flags, to notice mail read, flagged or deleted elsewhere on
    /// servers without CONDSTORE.
    public func fetchFlags(uids range: ClosedRange<UInt32>) async throws -> [UInt32: Set<String>] {
        guard let folder = selectedFolder else { throw ConnectionError.notConnected }
        let messages = try await run(.uidFetch(Self.uidSet(range), [.uid, .flags], []), folder: folder).messages
        return Dictionary(messages.map { ($0.uid, $0.flags) }, uniquingKeysWith: { a, _ in a })
    }

    /// The whole raw message (RFC 822), without marking it read.
    public func fetchMessage(uid: UInt32) async throws -> Data? {
        guard let folder = selectedFolder else { throw ConnectionError.notConnected }
        let result = try await run(.uidFetch(Self.uidSet(uid...uid), [.uid, .bodySection(peek: true, SectionSpecifier(), nil)], []), folder: folder)
        return result.bodies[uid]
    }

    // MARK: Running commands

    /// Sends one command and gathers every reply until its tagged result.
    @discardableResult
    func run(_ command: Command, folder: String = "") async throws -> ResponseCollector {
        guard let channel else { throw ConnectionError.notConnected }
        tagCounter += 1
        let tag = "C\(tagCounter)"
        var collector = ResponseCollector(tag: tag, folder: folder)
        try await channel.writeAndFlush(IMAPClientHandler.Message.part(.tagged(TaggedCommand(tag: tag, command: command))))
        while !collector.isComplete {
            guard let response = try await nextResponse() else { throw ConnectionError.disconnected }
            collector.receive(response)
        }
        switch collector.outcome {
        case .no(let text), .bad(let text):
            if collector.sawBye { throw ConnectionError.disconnected }
            throw ConnectionError.commandFailed(text)
        default:
            return collector
        }
    }

    private func nextResponse() async throws -> Response? {
        guard let responses else { throw ConnectionError.notConnected }
        return try await responses.next(timeout: timeout)
    }

    static func uidSet(_ range: ClosedRange<UInt32>) -> LastCommandSet<UID> {
        let ids = MessageIdentifierRange<UID>(UID(rawValue: range.lowerBound)...UID(rawValue: range.upperBound))
        return .set(MessageIdentifierSetNonEmpty(range: ids))
    }
}

/// Replies from the channel, waiting for the actor to take them. A plain
/// locked queue rather than an AsyncStream iterator, whose isolated `next`
/// needs iOS 18.
final class ResponseQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var buffered: [Response] = []
    private var finished: Error?? = nil
    private var waiter: CheckedContinuation<Response?, Error>?

    func push(_ response: Response) {
        lock.lock()
        if let waiter { self.waiter = nil; lock.unlock(); waiter.resume(returning: response); return }
        buffered.append(response)
        lock.unlock()
    }

    /// `error` nil: closed cleanly.
    func finish(_ error: Error?) {
        lock.lock()
        if finished == nil { finished = .some(error) }
        let waiter = self.waiter; self.waiter = nil
        lock.unlock()
        if let error { waiter?.resume(throwing: error) } else { waiter?.resume(returning: nil) }
    }

    func next(timeout: Duration) async throws -> Response? {
        try await withThrowingTaskGroup(of: Response?.self) { group in
            group.addTask { try await self.take() }
            group.addTask {
                try await Task.sleep(for: timeout)
                self.finish(IMAPConnection.ConnectionError.timedOut)
                throw IMAPConnection.ConnectionError.timedOut
            }
            defer { group.cancelAll() }
            return try await group.next() ?? nil
        }
    }

    private func take() async throws -> Response? {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if !buffered.isEmpty { let r = buffered.removeFirst(); lock.unlock(); continuation.resume(returning: r); return }
            if let done = finished {
                lock.unlock()
                if let error = done { continuation.resume(throwing: error) } else { continuation.resume(returning: nil) }
                return
            }
            waiter = continuation
            lock.unlock()
        }
    }
}

/// Hands parsed replies from the channel to the actor.
final class ResponseForwarder: ChannelInboundHandler, Sendable {
    typealias InboundIn = Response
    let queue: ResponseQueue

    init(queue: ResponseQueue) { self.queue = queue }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        queue.push(unwrapInboundIn(data))
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        queue.finish(error)
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        queue.finish(nil)
        context.fireChannelInactive()
    }
}
