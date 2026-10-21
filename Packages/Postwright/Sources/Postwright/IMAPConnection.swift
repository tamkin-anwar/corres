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
    /// Between IDLE and its tagged end. Only DONE may be sent meanwhile.
    private var inIdle = false
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
                    if ProcessInfo.processInfo.environment["CORRES_IMAP_TRACE"] != nil {
                        try channel.pipeline.syncOperations.addHandler(TraceHandler())
                    }
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
        // Mid-IDLE (a wait cut off before it ended), the only thing the
        // server and swift-nio-imap accept is DONE; a LOGOUT then stopped
        // the app. Just close.
        if !inIdle { _ = try? await run(.logout) }
        inIdle = false
        try? await channel?.close()
        channel = nil
        responses = nil
        selectedFolder = nil
    }

    // MARK: Folders and messages

    public func listFolders() async throws -> [Folder] {
        try await run(.list(nil, reference: MailboxName(ByteBuffer(string: "")), .mailbox(ByteBuffer(string: "*")))).folders
    }

    /// Makes a folder. A folder that already exists isn't an error.
    public func createFolder(_ path: String) async throws {
        do {
            try await run(.create(MailboxName(ByteBuffer(string: path)), []))
        } catch ConnectionError.commandFailed(let text) where text.uppercased().contains("EXIST") {
            return
        }
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
    public func fetchSummaries(uids: [UInt32]) async throws -> [MessageSummary] {
        guard !uids.isEmpty else { return [] }
        guard let folder = selectedFolder else { throw ConnectionError.notConnected }
        return try await run(.uidFetch(Self.uidSet(uids), Self.summaryAttributes, []), folder: folder).messages
    }

    public func fetchSummaries(uids range: ClosedRange<UInt32>) async throws -> [MessageSummary] {
        guard let folder = selectedFolder else { throw ConnectionError.notConnected }
        return try await run(.uidFetch(Self.uidSet(range), Self.summaryAttributes, []), folder: folder).messages
    }

    static let summaryAttributes: [FetchAttribute] = [
        .uid, .flags, .rfc822Size, .envelope,
        .bodySection(peek: true, SectionSpecifier(kind: .headerFields(["REFERENCES", "LIST-UNSUBSCRIBE", "LIST-UNSUBSCRIBE-POST"])), nil),
    ]

    /// The newest `count` messages of the selected folder (a first sync, or
    /// a mailbox page): by position, since UIDs can have gaps. `endingAt`
    /// is the newest position to include (defaults to the last).
    public func fetchNewestSummaries(count: Int, of exists: Int, endingAt end: Int? = nil) async throws -> [MessageSummary] {
        guard let folder = selectedFolder else { throw ConnectionError.notConnected }
        let last = min(end ?? exists, exists)
        guard last >= 1, count > 0 else { return [] }
        let first = max(1, last - count + 1)
        let range = MessageIdentifierRange<SequenceNumber>(SequenceNumber(rawValue: UInt32(first))...SequenceNumber(rawValue: UInt32(last)))
        let set: LastCommandSet<SequenceNumber> = .set(MessageIdentifierSetNonEmpty(range: range))
        return try await run(.fetch(set, Self.summaryAttributes, []), folder: folder).messages
    }

    /// UIDs in the selected folder matching words anywhere in the message.
    public func search(text: String) async throws -> [UInt32] {
        try await run(.uidSearch(key: .text(ByteBuffer(string: text))), folder: selectedFolder ?? "").searchResults
    }

    /// UIDs in the selected folder whose Message-ID is `messageID`: how a
    /// message is found again after it moved (UIDs are per folder).
    /// UIDs of the flagged messages in the selected folder.
    public func searchFlagged() async throws -> [UInt32] {
        try await run(.uidSearch(key: .flagged), folder: selectedFolder ?? "").searchResults
    }

    /// UIDs in the selected folder where `name` (or an address) appears in
    /// From, To or Cc.
    public func search(person name: String) async throws -> [UInt32] {
        let term = ByteBuffer(string: name)
        return try await run(.uidSearch(key: .or(.from(term), .or(.to(term), .cc(term)))), folder: selectedFolder ?? "").searchResults
    }

    /// UIDs in the selected folder that belong to the conversation started
    /// by `messageID`: the message itself, and any that answer it or name
    /// it in References.
    public func search(conversation messageID: String) async throws -> [UInt32] {
        let id = ByteBuffer(string: "<\(messageID)>")
        let key: SearchKey = .or(.header("Message-ID", id), .or(.header("References", id), .header("In-Reply-To", id)))
        return try await run(.uidSearch(key: key), folder: selectedFolder ?? "").searchResults
    }

    public func search(messageID: String) async throws -> [UInt32] {
        try await run(.uidSearch(key: .header("Message-ID", ByteBuffer(string: "<\(messageID)>"))), folder: selectedFolder ?? "").searchResults
    }

    /// Only flags, to notice mail read, flagged or deleted elsewhere on
    /// servers without CONDSTORE.
    public func fetchFlags(uids range: ClosedRange<UInt32>) async throws -> [UInt32: Set<String>] {
        guard let folder = selectedFolder else { throw ConnectionError.notConnected }
        let messages = try await run(.uidFetch(Self.uidSet(range), [.uid, .flags], []), folder: folder).messages
        return Dictionary(messages.map { ($0.uid, $0.flags) }, uniquingKeysWith: { a, _ in a })
    }

    /// The whole raw message (RFC 822), without marking it read.
    /// Several whole messages in one command, by UID: one round trip for
    /// a batch instead of one each.
    public func fetchMessages(uids: [UInt32]) async throws -> [UInt32: Data] {
        guard !uids.isEmpty else { return [:] }
        guard let folder = selectedFolder else { throw ConnectionError.notConnected }
        return try await run(.uidFetch(Self.uidSet(uids), [.uid, .bodySection(peek: true, SectionSpecifier(), nil)], []), folder: folder).bodies
    }

    public func fetchMessage(uid: UInt32) async throws -> Data? {
        guard let folder = selectedFolder else { throw ConnectionError.notConnected }
        let result = try await run(.uidFetch(Self.uidSet(uid...uid), [.uid, .bodySection(peek: true, SectionSpecifier(), nil)], []), folder: folder)
        return result.bodies[uid]
    }

    // MARK: Changing mail

    /// Adds or removes flags ("\\Seen", "\\Flagged") on messages in the
    /// selected folder, without the server echoing every change back.
    public func setFlags(_ flags: [String], uids: [UInt32], add: Bool) async throws {
        guard !uids.isEmpty, !flags.isEmpty else { return }
        let list = flags.map { Flag($0) }
        let store: StoreFlags = add ? .add(silent: true, list: list) : .remove(silent: true, list: list)
        try await run(.uidStore(Self.uidSet(uids), [], .flags(store)), folder: selectedFolder ?? "")
    }

    /// Moves messages from the selected folder. Servers without MOVE
    /// (iCloud reportedly) get the classic copy, mark deleted, expunge;
    /// with UIDPLUS only these messages are expunged, never others someone
    /// marked deleted elsewhere.
    public func move(uids: [UInt32], to destination: String) async throws {
        guard !uids.isEmpty else { return }
        let target = MailboxName(ByteBuffer(string: destination))
        let set = Self.uidSet(uids)
        if capabilities.move {
            try await run(.uidMove(set, target), folder: selectedFolder ?? "")
            return
        }
        try await run(.uidCopy(set, target), folder: selectedFolder ?? "")
        try await setFlags(["\\Deleted"], uids: uids, add: true)
        if capabilities.uidplus {
            try await run(.uidExpunge(set), folder: selectedFolder ?? "")
        } else {
            try await run(.expunge, folder: selectedFolder ?? "")
        }
    }

    /// Saves a message into a folder (a sent copy into Sent, a draft into
    /// Drafts). Returns its new UID when the server says (UIDPLUS).
    @discardableResult
    public func append(_ message: Data, to folder: String, flags: [String] = ["\\Seen"]) async throws -> UInt32? {
        guard let channel else { throw ConnectionError.notConnected }
        tagCounter += 1
        let tag = "C\(tagCounter)"
        var collector = ResponseCollector(tag: tag, folder: folder)
        let options = AppendOptions(flagList: flags.map { Flag($0) })
        let parts: [AppendCommand] = [
            .start(tag: tag, appendingTo: MailboxName(ByteBuffer(string: folder))),
            .beginMessage(message: AppendMessage(options: options, data: AppendData(byteCount: message.count))),
            .messageBytes(ByteBuffer(bytes: message)),
            .endMessage,
            .finish,
        ]
        for part in parts {
            try await channel.writeAndFlush(IMAPClientHandler.Message.part(.append(part)))
        }
        while !collector.isComplete {
            guard let response = try await nextResponse() else { throw ConnectionError.disconnected }
            collector.receive(response)
        }
        if case .no(let text) = collector.outcome { throw ConnectionError.commandFailed(text) }
        if case .bad(let text) = collector.outcome { throw ConnectionError.commandFailed(text) }
        return collector.appendedUID
    }

    /// Removes messages marked deleted: only these with UIDPLUS, otherwise
    /// every one marked in the folder.
    public func expungeIfPossible(uids: [UInt32]) async throws {
        guard !uids.isEmpty else { return }
        if capabilities.uidplus {
            try await run(.uidExpunge(Self.uidSet(uids)), folder: selectedFolder ?? "")
        } else {
            try await run(.expunge, folder: selectedFolder ?? "")
        }
    }

    // MARK: Waiting for new mail

    public enum Change: Sendable, Equatable {
        /// The folder now holds this many messages (new mail arrived).
        case exists(Int)
        /// A message was removed elsewhere.
        case expunged
        /// Flags changed elsewhere (read on another device).
        case flagsChanged(uid: UInt32?)
    }

    /// Holds IDLE on the selected folder until something changes or `wait`
    /// passes, then ends it and reports what changed (empty: nothing). Call
    /// it in a loop while the app is open; servers drop IDLE after about 29
    /// minutes, so keep `wait` well under that.
    public func waitForChanges(wait: Duration = .seconds(25 * 60)) async throws -> [Change] {
        guard capabilities.idle else { throw ConnectionError.commandFailed("Server has no IDLE") }
        guard let channel, let responses else { throw ConnectionError.notConnected }
        tagCounter += 1
        let tag = "C\(tagCounter)"
        try await channel.writeAndFlush(IMAPClientHandler.Message.part(.tagged(TaggedCommand(tag: tag, command: .idleStart))))
        inIdle = true
        var changes: [Change] = []
        var idling = false
        var done = false
        let started = ContinuousClock.now
        func record(_ response: Response) {
            switch response {
            case .idleStarted: idling = true
            case .untagged(.mailboxData(.exists(let n))): changes.append(.exists(n))
            case .untagged(.messageData(.expunge)), .untagged(.messageData(.vanished)): changes.append(.expunged)
            case .fetch(.startUID(let uid)): changes.append(.flagsChanged(uid: uid.rawValue))
            case .fetch(.start): changes.append(.flagsChanged(uid: nil))
            case .tagged(let t) where t.tag == tag: done = true
            default: break
            }
        }
        // Wait for the first change (or time), without treating quiet as an error.
        while changes.isEmpty && !done {
            let remaining = wait - (ContinuousClock.now - started)
            guard remaining > .zero else { break }
            switch try await responses.poll(wait: remaining) {
            case .response(let r): record(r)
            case .closed: throw ConnectionError.disconnected
            case .quiet: break
            }
            if ContinuousClock.now - started >= wait { break }
        }
        _ = idling
        if !done {
            try await channel.writeAndFlush(IMAPClientHandler.Message.part(.idleDone))
            while !done {
                guard let r = try await nextResponse() else { throw ConnectionError.disconnected }
                record(r)
            }
        }
        inIdle = false
        // Several EXISTS in a row: only the latest count matters.
        if let lastExists = changes.last(where: { if case .exists = $0 { true } else { false } }) {
            changes.removeAll { if case .exists = $0 { true } else { false } }
            changes.insert(lastExists, at: 0)
        }
        return changes
    }

    // MARK: Running commands

    /// Sends one command and gathers every reply until its tagged result.
    @discardableResult
    func run(_ command: Command, folder: String = "") async throws -> ResponseCollector {
        guard let channel else { throw ConnectionError.notConnected }
        // Left in IDLE by a wait that was cut off: nothing but DONE can be
        // sent (swift-nio-imap stops the process otherwise). This
        // connection is spent; the caller opens a fresh one.
        guard !inIdle else {
            try? await channel.close()
            self.channel = nil
            responses = nil
            throw ConnectionError.disconnected
        }
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

    static func uidSet(_ uids: [UInt32]) -> LastCommandSet<UID> {
        let ranges = uids.sorted().reduce(into: [ClosedRange<UInt32>]()) { ranges, uid in
            if let last = ranges.last, last.upperBound + 1 == uid { ranges[ranges.count - 1] = last.lowerBound...uid }
            else if ranges.last?.contains(uid) != true { ranges.append(uid...uid) }
        }
        let set = MessageIdentifierSet<UID>(ranges.map { MessageIdentifierRange<UID>(UID(rawValue: $0.lowerBound)...UID(rawValue: $0.upperBound)) })
        return .set(MessageIdentifierSetNonEmpty(set: set)!)
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
    struct QuietSignal: Error {}
    private let lock = NSLock()
    private var buffered: [Response] = []
    private var finished: Error?? = nil
    private var waiter: CheckedContinuation<Response?, Error>?
    /// Which `take` the waiter belongs to, so a late cancellation of one
    /// never ends another's wait.
    private var waiterID = 0
    private var nextWaiterID = 0

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

    enum Polled: Sendable { case response(Response), closed, quiet }

    /// Waits up to `wait` for a reply; unlike `next`, running out of time
    /// is normal here (IDLE with no new mail) and leaves the queue usable.
    func poll(wait: Duration) async throws -> Polled {
        try await withThrowingTaskGroup(of: Polled.self) { group in
            group.addTask {
                do { return (try await self.take()).map(Polled.response) ?? .closed } catch is QuietSignal { return .quiet }
            }
            group.addTask {
                try await Task.sleep(for: wait)
                self.cancelWaiter()
                return .quiet
            }
            defer { group.cancelAll() }
            return try await group.next() ?? .quiet
        }
    }

    /// Ends a pending `take` with "nothing yet", without closing the queue.
    private func cancelWaiter() {
        lock.lock()
        let waiter = self.waiter; self.waiter = nil
        lock.unlock()
        waiter?.resume(throwing: QuietSignal())
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

    /// Cancellable: a stopped task used to stay suspended here for good
    /// (the IDLE watch, each time Corres left the screen), and a second
    /// `take` replaced the first one's waiter without ever waking it.
    private func take() async throws -> Response? {
        let id = lock.withLock { nextWaiterID += 1; return nextWaiterID }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if !buffered.isEmpty { let r = buffered.removeFirst(); lock.unlock(); continuation.resume(returning: r); return }
                if let done = finished {
                    lock.unlock()
                    if let error = done { continuation.resume(throwing: error) } else { continuation.resume(returning: nil) }
                    return
                }
                if Task.isCancelled { lock.unlock(); continuation.resume(throwing: CancellationError()); return }
                let replaced = waiter
                waiter = continuation
                waiterID = id
                lock.unlock()
                replaced?.resume(throwing: QuietSignal())
            }
        } onCancel: {
            lock.lock()
            guard waiterID == id, let waiter else { lock.unlock(); return }
            self.waiter = nil
            lock.unlock()
            waiter.resume(throwing: CancellationError())
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

/// Raw traffic to stderr when CORRES_IMAP_TRACE is set, for debugging a
/// server. LOGIN lines are hidden so the password never appears.
final class TraceHandler: ChannelDuplexHandler, Sendable {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        Self.print("S:", unwrapInboundIn(data))
        context.fireChannelRead(data)
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        Self.print("C:", unwrapOutboundIn(data))
        context.write(data, promise: promise)
    }

    private static func print(_ side: String, _ buffer: ByteBuffer) {
        let text = String(decoding: buffer.readableBytesView, as: UTF8.self)
        for line in text.split(separator: "\r\n", omittingEmptySubsequences: true) {
            let shown = line.uppercased().contains(" LOGIN ") ? "[login hidden]" : String(line.prefix(300))
            FileHandle.standardError.write(Data("IMAP \(side) \(shown)\n".utf8))
        }
    }
}
