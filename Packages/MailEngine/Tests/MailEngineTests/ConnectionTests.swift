import Foundation
import NIOCore
import NIOPosix
import Testing
@testable import MailEngine

/// A tiny scripted IMAP server on 127.0.0.1: it answers each command with
/// lines recorded from real servers, so the whole client path (connect,
/// encode, parse, collect) runs without a real account.
final class FakeIMAPServer: @unchecked Sendable {
    /// Command name ("LOGIN", "UID FETCH") → reply lines; "{TAG}" is
    /// replaced with the command's tag.
    let script: [String: [String]]
    let greeting: String
    private(set) var received: [String] = []
    private let lock = NSLock()
    private var channel: Channel?
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)

    init(greeting: String, script: [String: [String]]) {
        self.greeting = greeting
        self.script = script
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

    func commands() -> [String] { lock.lock(); defer { lock.unlock() }; return received }

    func reply(to line: String) -> [String] {
        let parts = line.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count >= 2 else { return [] }
        let tag = parts[0]
        var name = parts[1].uppercased()
        if name == "UID", parts.count > 2 { name += " " + (parts[2].split(separator: " ").first.map(String.init)?.uppercased() ?? "") }
        lock.lock(); received.append(name); lock.unlock()
        let lines = script[name] ?? ["{TAG} BAD Unknown command"]
        return lines.map { $0.replacingOccurrences(of: "{TAG}", with: tag) }
    }

    final class Handler: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = ByteBuffer
        typealias OutboundOut = ByteBuffer
        let server: FakeIMAPServer
        var pending = ""
        init(server: FakeIMAPServer) { self.server = server }

        func channelActive(context: ChannelHandlerContext) {
            send(server.greeting + "\r\n", context)
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            pending += String(buffer: unwrapInboundIn(data))
            while let end = pending.range(of: "\r\n") {
                let line = String(pending[..<end.lowerBound])
                pending.removeSubrange(..<end.upperBound)
                let reply = server.reply(to: line)
                send(reply.map { $0 + "\r\n" }.joined(), context)
                if line.uppercased().hasSuffix("LOGOUT") { context.close(promise: nil) }
            }
        }

        func send(_ text: String, _ context: ChannelHandlerContext) {
            context.writeAndFlush(wrapOutboundOut(ByteBuffer(string: text)), promise: nil)
        }
    }
}

struct ConnectionTests {
    /// iCloud's real greeting, then replies shaped like iCloud's.
    func iCloudLikeServer(loginOK: Bool = true) -> FakeIMAPServer {
        FakeIMAPServer(
            greeting: "* OK [CAPABILITY XAPPLEPUSHSERVICE IMAP4 IMAP4rev1 SASL-IR AUTH=ATOKEN AUTH=PLAIN AUTH=XOAUTH2] ready",
            script: [
                "LOGIN": loginOK ? ["{TAG} OK user tamkin authenticated"]
                                 : ["{TAG} NO [AUTHENTICATIONFAILED] Authentication failed."],
                "CAPABILITY": ["* CAPABILITY IMAP4rev1 IDLE UIDPLUS ENABLE CONDSTORE QRESYNC", "{TAG} OK Completed"],
                "LIST": [
                    #"* LIST (\HasNoChildren) "/" "INBOX""#,
                    #"* LIST (\HasNoChildren) "/" "Sent Messages""#,
                    #"* LIST (\HasNoChildren) "/" "Deleted Messages""#,
                    "{TAG} OK LIST completed",
                ],
                "SELECT": [
                    "* 2 EXISTS",
                    "* OK [UIDVALIDITY 42] UIDs valid",
                    "* OK [UIDNEXT 12] next",
                    "* OK [HIGHESTMODSEQ 99] modseq",
                    "{TAG} OK [READ-WRITE] SELECT completed",
                ],
                "UID FETCH": [
                    #"* 1 FETCH (UID 10 FLAGS (\Seen) RFC822.SIZE 100 ENVELOPE ("Fri, 16 Oct 2026 09:07:48 -0400" "Hi" (("Ann" NIL "ann" "x.example")) NIL NIL ((NIL NIL "me" "icloud.com")) NIL NIL NIL "<m1@x.example>") BODY[HEADER.FIELDS (REFERENCES)] {2}"#,
                    "",
                    ")",
                    #"* 2 FETCH (UID 11 FLAGS () RFC822.SIZE 120 ENVELOPE ("Fri, 16 Oct 2026 10:07:48 -0400" "Re: Hi" (("Me" NIL "me" "icloud.com")) NIL NIL (("Ann" NIL "ann" "x.example")) NIL NIL "<m1@x.example>" "<m2@icloud.com>") BODY[HEADER.FIELDS (REFERENCES)] {30}"#,
                    "References: <m1@x.example>",
                    "",
                    ")",
                    "{TAG} OK FETCH completed",
                ],
                "LOGOUT": ["* BYE logging out", "{TAG} OK LOGOUT completed"],
            ])
    }

    @Test func fullSessionAgainstAniCloudShapedServer() async throws {
        let server = iCloudLikeServer()
        let port = try await server.start()
        defer { Task { await server.stop() } }

        let connection = IMAPConnection(host: "127.0.0.1", port: port, useTLS: false, timeout: .seconds(5))
        let greeting = try await connection.connect()
        #expect(!greeting.idle, "iCloud lists almost nothing before login")
        try await connection.login(username: "me@icloud.com", password: "abcd-efgh-ijkl-mnop")
        let caps = await connection.capabilities
        #expect(caps.idle && caps.condstore && caps.qresync)

        let folders = try await connection.listFolders()
        #expect(folders.folder(for: .sent)?.path == "Sent Messages")

        let selected = try await connection.select("INBOX")
        #expect(selected == SelectedFolder(uidValidity: 42, uidNext: 12, exists: 2, highestModSeq: 99))

        let plan = SyncPlanner.plan(stored: nil, selected: selected, capabilities: caps)
        #expect(plan == .full(newest: SyncPlanner.firstSyncLimit))

        let messages = try await connection.fetchSummaries(uids: 1...11)
        #expect(messages.map(\.uid) == [10, 11])
        #expect(messages[1].references == ["m1@x.example"])
        #expect(Threader.threads(messages).count == 1)

        await connection.logout()
        #expect(server.commands() == ["LOGIN", "CAPABILITY", "LIST", "SELECT", "UID FETCH", "LOGOUT"])
    }

    @Test func wrongPasswordIsReportedAsSuch() async throws {
        let server = iCloudLikeServer(loginOK: false)
        let port = try await server.start()
        defer { Task { await server.stop() } }
        let connection = IMAPConnection(host: "127.0.0.1", port: port, useTLS: false, timeout: .seconds(5))
        try await connection.connect()
        await #expect(throws: IMAPConnection.ConnectionError.authenticationFailed("Authentication failed.")) {
            try await connection.login(username: "me@icloud.com", password: "wrong")
        }
    }

    @Test func aSilentServerTimesOut() async throws {
        let server = FakeIMAPServer(greeting: "* OK ready", script: ["NOOP": []])
        let port = try await server.start()
        defer { Task { await server.stop() } }
        let connection = IMAPConnection(host: "127.0.0.1", port: port, useTLS: false, timeout: .milliseconds(300))
        try await connection.connect()
        await #expect(throws: IMAPConnection.ConnectionError.timedOut) {
            try await connection.run(.noop)
        }
    }
}

/// Real servers, greeting only (no login). Opt in: CORRES_LIVE=1 swift test
struct LiveServerTests {
    static let enabled = ProcessInfo.processInfo.environment["CORRES_LIVE"] == "1"

    @Test(.enabled(if: LiveServerTests.enabled), arguments: ["imap.mail.me.com", "imap.fastmail.com", "imap.mail.yahoo.com"])
    func tlsGreeting(host: String) async throws {
        let connection = IMAPConnection(host: host, timeout: .seconds(10))
        let caps = try await connection.connect()
        #expect(caps.authPlain || caps.xoauth2)
        await connection.logout()
    }
}
