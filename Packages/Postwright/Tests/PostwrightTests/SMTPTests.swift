import Foundation
import NIOCore
import NIOPosix
import Testing
@testable import Postwright

/// A scripted SMTP server on 127.0.0.1 that records what it was sent.
final class FakeSMTPServer: @unchecked Sendable {
    let offersStartTLS: Bool
    let acceptPassword: String
    let rejectRecipient: String?
    /// What happens after the end of the message: nil answers 250, "drop"
    /// closes the connection without an answer, anything else is sent.
    let afterData: String?
    private let lock = NSLock()
    private var commandLog: [String] = []
    private var bodies: [String] = []
    private var channel: Channel?
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)

    init(offersStartTLS: Bool = false, acceptPassword: String = "app-pass", rejectRecipient: String? = nil, afterData: String? = nil) {
        self.offersStartTLS = offersStartTLS
        self.acceptPassword = acceptPassword
        self.rejectRecipient = rejectRecipient
        self.afterData = afterData
    }

    func start() async throws -> Int {
        let server = self
        channel = try await ServerBootstrap(group: group)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture { try channel.pipeline.syncOperations.addHandler(Handler(server: server)) }
            }
            .bind(host: "127.0.0.1", port: 0).get()
        return channel!.localAddress!.port!
    }

    func stop() async { try? await channel?.close(); try? await group.shutdownGracefully() }
    func log() -> [String] { lock.lock(); defer { lock.unlock() }; return commandLog }
    func received() -> [String] { lock.lock(); defer { lock.unlock() }; return bodies }
    func record(_ line: String) { lock.lock(); commandLog.append(line); lock.unlock() }
    func store(_ body: String) { lock.lock(); bodies.append(body); lock.unlock() }

    final class Handler: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = ByteBuffer
        typealias OutboundOut = ByteBuffer
        let server: FakeSMTPServer
        var pending = ""
        var inData = false
        var data = ""
        init(server: FakeSMTPServer) { self.server = server }

        func channelActive(context: ChannelHandlerContext) { send("220 fake.test ESMTP", context) }

        func channelRead(context: ChannelHandlerContext, data incoming: NIOAny) {
            pending += String(buffer: unwrapInboundIn(incoming))
            while let end = pending.range(of: "\r\n") {
                let line = String(pending[..<end.lowerBound])
                pending.removeSubrange(..<end.upperBound)
                if inData {
                    if line == "." {
                        inData = false; server.store(data); data = ""
                        switch server.afterData {
                        case nil: send("250 2.0.0 queued", context)
                        case "drop": context.close(promise: nil); return
                        case let reply?: send(reply, context)
                        }
                    }
                    else { data += line + "\r\n" }
                    continue
                }
                let upper = line.uppercased()
                server.record(upper.hasPrefix("AUTH PLAIN") ? "AUTH PLAIN" : line)
                if upper.hasPrefix("EHLO") {
                    send("250-fake.test\r\n" + (server.offersStartTLS ? "250-STARTTLS\r\n" : "") + "250-AUTH PLAIN LOGIN\r\n250 SMTPUTF8", context)
                } else if upper.hasPrefix("AUTH PLAIN ") {
                    let encoded = String(line.dropFirst("AUTH PLAIN ".count))
                    let decoded = Data(base64Encoded: encoded).map { String(decoding: $0, as: UTF8.self) } ?? ""
                    send(decoded.hasSuffix("\0" + server.acceptPassword) ? "235 2.7.0 ok" : "535 5.7.8 Authentication credentials invalid", context)
                } else if upper.hasPrefix("MAIL FROM") {
                    send("250 2.1.0 ok", context)
                } else if upper.hasPrefix("RCPT TO") {
                    if let bad = server.rejectRecipient, line.contains(bad) { send("550 5.1.1 No such user", context) }
                    else { send("250 2.1.5 ok", context) }
                } else if upper == "DATA" {
                    inData = true; send("354 go ahead", context)
                } else if upper == "QUIT" {
                    send("221 bye", context); context.close(promise: nil)
                } else {
                    send("502 not implemented", context)
                }
            }
        }

        func send(_ text: String, _ context: ChannelHandlerContext) {
            context.writeAndFlush(wrapOutboundOut(ByteBuffer(string: text + "\r\n")), promise: nil)
        }
    }
}

struct SMTPTests {
    let message = "From: Me <me@icloud.com>\r\nTo: ann@x.example\r\nSubject: Hi\r\n\r\nHello\r\n.leading dot\r\n"

    @Test func sendsAMessage() async throws {
        let server = FakeSMTPServer()
        let port = try await server.start()
        defer { Task { await server.stop() } }
        let client = SMTPClient(host: "127.0.0.1", port: port, security: .none, timeout: .seconds(5))
        try await client.send(Data(message.utf8), from: "me@icloud.com", to: ["ann@x.example", "bo@y.example"],
                              username: "me@icloud.com", password: "app-pass")
        #expect(server.log() == ["EHLO corres.app", "AUTH PLAIN", "MAIL FROM:<me@icloud.com>",
                                 "RCPT TO:<ann@x.example>", "RCPT TO:<bo@y.example>", "DATA", "QUIT"])
        // The server undoes dot-stuffing; the body arrives as written.
        #expect(server.received().first?.contains("\r\n..leading dot\r\n") == true)
    }

    @Test func verifySignsInWithoutSending() async throws {
        let server = FakeSMTPServer()
        let port = try await server.start()
        defer { Task { await server.stop() } }
        try await SMTPClient(host: "127.0.0.1", port: port, security: .none, timeout: .seconds(5))
            .verify(username: "me@icloud.com", password: "app-pass")
        #expect(!server.log().contains { $0.hasPrefix("MAIL FROM") })
        await #expect(throws: SMTPClient.SMTPError.authenticationFailed("Authentication credentials invalid")) {
            try await SMTPClient(host: "127.0.0.1", port: port, security: .none, timeout: .seconds(5))
                .verify(username: "me@icloud.com", password: "nope")
        }
    }

    @Test func wrongPassword() async throws {
        let server = FakeSMTPServer()
        let port = try await server.start()
        defer { Task { await server.stop() } }
        let client = SMTPClient(host: "127.0.0.1", port: port, security: .none, timeout: .seconds(5))
        await #expect(throws: SMTPClient.SMTPError.authenticationFailed("Authentication credentials invalid")) {
            try await client.send(Data(self.message.utf8), from: "me@icloud.com", to: ["ann@x.example"],
                                  username: "me@icloud.com", password: "nope")
        }
    }

    @Test func aRejectedRecipientIsNamed() async throws {
        let server = FakeSMTPServer(rejectRecipient: "ghost@x.example")
        let port = try await server.start()
        defer { Task { await server.stop() } }
        let client = SMTPClient(host: "127.0.0.1", port: port, security: .none, timeout: .seconds(5))
        await #expect(throws: SMTPClient.SMTPError.recipientRejected("ghost@x.example", "No such user")) {
            try await client.send(Data(self.message.utf8), from: "me@icloud.com", to: ["ghost@x.example"],
                                  username: "me@icloud.com", password: "app-pass")
        }
    }

    @Test func refusesToSendInTheClearWhenTheServerCannotUpgrade() async throws {
        let server = FakeSMTPServer(offersStartTLS: false)
        let port = try await server.start()
        defer { Task { await server.stop() } }
        let client = SMTPClient(host: "127.0.0.1", port: port, security: .startTLS, timeout: .seconds(5))
        await #expect(throws: SMTPClient.SMTPError.noSecureConnection) { try await client.open() }
        #expect(!server.log().contains("AUTH PLAIN"))
    }

    /// The whole message went and the connection dropped before the
    /// answer: it may have been taken, which isn't "not sent".
    @Test func aLostAnswerAfterTheMessageIsUnconfirmed() async throws {
        let server = FakeSMTPServer(afterData: "drop")
        let port = try await server.start()
        defer { Task { await server.stop() } }
        let client = SMTPClient(host: "127.0.0.1", port: port, security: .none, timeout: .seconds(5))
        await #expect(throws: SMTPClient.SMTPError.unconfirmed) {
            try await client.send(Data(self.message.utf8), from: "me@icloud.com", to: ["ann@x.example"],
                                  username: "me@icloud.com", password: "app-pass")
        }
        #expect(server.received().count == 1)
    }

    /// A refusal after the message is a real answer: not sent, safe to
    /// try again.
    @Test func aRefusalAfterTheMessageIsNotUnconfirmed() async throws {
        let server = FakeSMTPServer(afterData: "451 4.3.0 Try again later")
        let port = try await server.start()
        defer { Task { await server.stop() } }
        let client = SMTPClient(host: "127.0.0.1", port: port, security: .none, timeout: .seconds(5))
        await #expect(throws: SMTPClient.SMTPError.rejected(451, "Try again later")) {
            try await client.send(Data(self.message.utf8), from: "me@icloud.com", to: ["ann@x.example"],
                                  username: "me@icloud.com", password: "app-pass")
        }
    }

    @Test func dotStuffing() {
        let out = String(decoding: SMTPClient.dotStuffed(Data("a\n.b\r\n..c".utf8)), as: UTF8.self)
        #expect(out == "a\r\n..b\r\n...c\r\n.\r\n")
    }

    /// iCloud upgrades to TLS and then offers password login. No login is
    /// attempted. Opt in: CORRES_LIVE=1
    @Test(.enabled(if: LiveServerTests.enabled)) func iCloudStartTLS() async throws {
        let client = SMTPClient(host: "smtp.mail.me.com", port: 587, security: .startTLS, timeout: .seconds(15))
        try await client.open()
        #expect(await client.extensions.contains("AUTH=PLAIN"))
        await client.close()
    }
}
