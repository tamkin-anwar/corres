import Foundation
import NIOCore
import NIOPosix
import NIOSSL

/// Sends one message over SMTP. iCloud accepts mail only on port 587 with
/// STARTTLS (checked 2026-10-17: 465 is closed), so the connection starts
/// plain and is upgraded before anything private is sent; port 465 servers
/// get TLS from the first byte. Login is AUTH PLAIN with the same
/// app-specific password IMAP uses.
public actor SMTPClient {
    public enum Security: Sendable {
        /// Plain connection upgraded with STARTTLS (port 587). Refuses to
        /// continue if the server won't upgrade.
        case startTLS
        /// TLS from the start (port 465).
        case tls
        /// Tests only.
        case none
    }

    public enum SMTPError: Error, Equatable, Sendable {
        case authenticationFailed(String)
        /// The server turned down a recipient (bad address, mailbox full).
        case recipientRejected(String, String)
        /// Any other refusal, with the server's code and words.
        case rejected(Int, String)
        case noSecureConnection
        case disconnected
        case timedOut
    }

    public struct Reply: Sendable, Equatable {
        public let code: Int
        public let lines: [String]
        /// The server's words, without enhanced status codes ("5.7.8").
        public var text: String {
            lines.map { $0.replacingOccurrences(of: #"^\d\.\d{1,3}\.\d{1,3}\s+"#, with: "", options: .regularExpression) }
                .joined(separator: " ")
        }
    }

    public let host: String
    public let port: Int
    let security: Security
    let timeout: Duration
    private var channel: Channel?
    private let lines = LineQueue()
    public private(set) var extensions: Set<String> = []

    public init(host: String, port: Int = 587, security: Security = .startTLS, timeout: Duration = .seconds(30)) {
        self.host = host
        self.port = port
        self.security = security
        self.timeout = timeout
    }

    /// Connects, secures the connection and introduces itself. After this
    /// `extensions` holds what the server offers (AUTH PLAIN, SMTPUTF8…).
    public func open() async throws {
        let queue = lines
        let host = self.host
        let tlsFromStart = security == .tls
        channel = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .connectTimeout(.seconds(15))
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    if tlsFromStart {
                        let context = try NIOSSLContext(configuration: .makeClientConfiguration())
                        try channel.pipeline.syncOperations.addHandler(NIOSSLClientHandler(context: context, serverHostname: host))
                    }
                    try channel.pipeline.syncOperations.addHandler(LineHandler(queue: queue))
                }
            }
            .connect(host: host, port: port).get()

        try await expect(220, try await readReply())
        try await hello()
        if security == .startTLS {
            guard extensions.contains("STARTTLS") else { throw SMTPError.noSecureConnection }
            try await expect(220, try await command("STARTTLS"))
            // Made on the connection's own thread: the handler isn't Sendable.
            guard let channel else { throw SMTPError.disconnected }
            let host = self.host
            try await channel.eventLoop.submit {
                let context = try NIOSSLContext(configuration: .makeClientConfiguration())
                let handler = try NIOSSLClientHandler(context: context, serverHostname: host)
                try channel.pipeline.syncOperations.addHandler(handler, position: .first)
            }.get()
            // Anything learned before encryption is discarded (RFC 3207).
            try await hello()
        }
    }

    /// Logs in and sends `message` (a complete RFC 5322 message) to every
    /// recipient. One connection per message keeps failures independent.
    public func send(_ message: Data, from sender: String, to recipients: [String],
                     username: String, password: String) async throws {
        if channel == nil { try await open() }
        let credentials = Data("\0\(username)\0\(password)".utf8).base64EncodedString()
        let auth = try await command("AUTH PLAIN \(credentials)")
        guard auth.code == 235 else { throw SMTPError.authenticationFailed(auth.text) }

        let utf8 = !(sender + recipients.joined()).allSatisfy(\.isASCII) && extensions.contains("SMTPUTF8")
        try await expect(250, try await command("MAIL FROM:<\(sender)>" + (utf8 ? " SMTPUTF8" : "")))
        for recipient in recipients {
            let reply = try await command("RCPT TO:<\(recipient)>")
            guard reply.code == 250 || reply.code == 251 else { throw SMTPError.recipientRejected(recipient, reply.text) }
        }
        try await expect(354, try await command("DATA"))
        try await write(Self.dotStuffed(message))
        try await expect(250, try await readReply())
        _ = try? await command("QUIT")
        await close()
    }

    /// Connects, secures and signs in, then leaves: proves an outgoing
    /// server and password without sending anything.
    public func verify(username: String, password: String) async throws {
        if channel == nil { try await open() }
        let credentials = Data("\0\(username)\0\(password)".utf8).base64EncodedString()
        let auth = try await command("AUTH PLAIN \(credentials)")
        _ = try? await command("QUIT")
        await close()
        guard auth.code == 235 else { throw SMTPError.authenticationFailed(auth.text) }
    }

    public func close() async {
        try? await channel?.close()
        channel = nil
    }

    // MARK: Protocol

    private func hello() async throws {
        var reply = try await command("EHLO corres.app")
        if reply.code != 250 { reply = try await command("HELO corres.app") }
        try await expect(250, reply)
        extensions = Set(reply.lines.dropFirst().map { $0.split(separator: " ").first.map { String($0).uppercased() } ?? "" })
        if reply.lines.dropFirst().contains(where: { $0.uppercased().hasPrefix("AUTH") && $0.uppercased().contains("PLAIN") }) {
            extensions.insert("AUTH=PLAIN")
        }
    }

    private func command(_ line: String) async throws -> Reply {
        try await write(Data((line + "\r\n").utf8))
        return try await readReply()
    }

    private func write(_ data: Data) async throws {
        guard let channel else { throw SMTPError.disconnected }
        try await channel.writeAndFlush(ByteBuffer(bytes: data))
    }

    /// One reply: "250-first", "250-more", "250 last".
    private func readReply() async throws -> Reply {
        var collected: [String] = []
        while true {
            guard let line = try await lines.next(timeout: timeout) else { throw SMTPError.disconnected }
            guard line.count >= 3, let code = Int(line.prefix(3)) else { continue }
            let rest = line.dropFirst(4)
            collected.append(String(rest))
            if line.count == 3 || line[line.index(line.startIndex, offsetBy: 3)] == " " {
                return Reply(code: code, lines: collected)
            }
        }
    }

    private func expect(_ code: Int, _ reply: Reply) async throws {
        guard reply.code == code else { throw SMTPError.rejected(reply.code, reply.text) }
    }

    /// Lines starting with "." get another (RFC 5321 §4.5.2), line ends are
    /// CRLF, and the message ends with a lone ".".
    static func dotStuffed(_ message: Data) -> Data {
        let text = String(decoding: message, as: UTF8.self)
            .replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n")
        var out = text.components(separatedBy: "\r\n").map { $0.hasPrefix(".") ? "." + $0 : $0 }.joined(separator: "\r\n")
        if !out.hasSuffix("\r\n") { out += "\r\n" }
        return Data((out + ".\r\n").utf8)
    }
}

/// Text lines from the server, for the SMTP actor to take one at a time.
final class LineQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var buffered: [String] = []
    private var closed = false
    private var waiter: CheckedContinuation<String?, Error>?

    func push(_ line: String) {
        lock.lock()
        if let waiter { self.waiter = nil; lock.unlock(); waiter.resume(returning: line); return }
        buffered.append(line)
        lock.unlock()
    }

    private func failWaiter() {
        lock.lock()
        let waiter = self.waiter; self.waiter = nil
        lock.unlock()
        waiter?.resume(throwing: SMTPClient.SMTPError.timedOut)
    }

    func close() {
        lock.lock(); closed = true
        let waiter = self.waiter; self.waiter = nil
        lock.unlock()
        waiter?.resume(returning: nil)
    }

    func next(timeout: Duration) async throws -> String? {
        try await withThrowingTaskGroup(of: String?.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { continuation in
                    self.lock.lock()
                    if !self.buffered.isEmpty { let l = self.buffered.removeFirst(); self.lock.unlock(); continuation.resume(returning: l); return }
                    if self.closed { self.lock.unlock(); continuation.resume(returning: nil); return }
                    self.waiter = continuation
                    self.lock.unlock()
                }
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                self.failWaiter()
                throw SMTPClient.SMTPError.timedOut
            }
            defer { group.cancelAll() }
            return try await group.next() ?? nil
        }
    }
}

final class LineHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    let queue: LineQueue
    private var pending = ""
    init(queue: LineQueue) { self.queue = queue }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        pending += String(buffer: unwrapInboundIn(data))
        while let end = pending.range(of: "\r\n") {
            queue.push(String(pending[..<end.lowerBound]))
            pending.removeSubrange(..<end.upperBound)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        queue.close()
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        queue.close()
        context.close(promise: nil)
    }
}
