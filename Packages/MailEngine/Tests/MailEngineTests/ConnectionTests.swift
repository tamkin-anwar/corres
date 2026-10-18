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
    private var appendedMessages: [String] = []
    func appended(_ message: String) { lock.lock(); appendedMessages.append(message); lock.unlock() }
    func appendedSoFar() -> [String] { lock.lock(); defer { lock.unlock() }; return appendedMessages }
    /// Every full command line, for checking what was sent.
    private var lines: [String] = []
    func sentLines() -> [String] { lock.lock(); defer { lock.unlock() }; return lines }

    func reply(to line: String) -> [String] {
        let parts = line.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count >= 2 else { return [] }
        let tag = parts[0]
        lock.lock(); lines.append(line); lock.unlock()
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

        var literalLeft = 0
        var literalLine = ""
        var idleTag: String?

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            pending += String(buffer: unwrapInboundIn(data))
            while true {
                if literalLeft > 0 {
                    // APPEND's message bytes, then the line's end.
                    let utf8 = Array(pending.utf8)
                    guard utf8.count >= literalLeft + 2 else { return }
                    server.appended(String(decoding: utf8[..<literalLeft], as: UTF8.self))
                    pending = String(decoding: utf8[(literalLeft + 2)...], as: UTF8.self)
                    literalLeft = 0
                    send(server.reply(to: literalLine).map { $0 + "\r\n" }.joined(), context)
                    continue
                }
                guard let end = pending.range(of: "\r\n") else { return }
                let line = String(pending[..<end.lowerBound])
                pending.removeSubrange(..<end.upperBound)
                if line == "DONE", let tag = idleTag {
                    idleTag = nil
                    send("\(tag) OK IDLE terminated\r\n", context)
                    continue
                }
                if let open = line.lastIndex(of: "{"), line.hasSuffix("}"),
                   let n = Int(line[line.index(after: open)..<line.index(before: line.endIndex)].replacingOccurrences(of: "+", with: "")) {
                    literalLeft = n
                    literalLine = line
                    if !line.hasSuffix("+}") { send("+ Ready for literal data\r\n", context) }
                    continue
                }
                if line.uppercased().hasSuffix(" IDLE") {
                    idleTag = String(line.split(separator: " ")[0])
                    _ = server.reply(to: line)
                    send("+ idling\r\n", context)
                    if let event = server.script["IDLE-EVENT"] {
                        let loop = context.eventLoop
                        let ctx = NIOLoopBound(context, eventLoop: loop)
                        loop.scheduleTask(in: .milliseconds(100)) {
                            self.send(event.map { $0 + "\r\n" }.joined(), ctx.value)
                        }
                    }
                    continue
                }
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


struct ActionTests {
    func server(capabilities: String, extra: [String: [String]] = [:]) -> FakeIMAPServer {
        var script: [String: [String]] = [
            "LOGIN": ["{TAG} OK logged in"],
            "CAPABILITY": ["* CAPABILITY \(capabilities)", "{TAG} OK"],
            "SELECT": ["* 3 EXISTS", "* OK [UIDVALIDITY 1] v", "* OK [UIDNEXT 20] n", "{TAG} OK [READ-WRITE] done"],
            "UID STORE": ["{TAG} OK STORE done"],
            "UID MOVE": ["{TAG} OK MOVE done"],
            "UID COPY": ["{TAG} OK COPY done"],
            "UID EXPUNGE": ["{TAG} OK EXPUNGE done"],
            "EXPUNGE": ["{TAG} OK EXPUNGE done"],
            "APPEND": ["{TAG} OK [APPENDUID 1 57] APPEND done"],
            "LOGOUT": ["* BYE", "{TAG} OK"],
        ]
        script.merge(extra) { $1 }
        return FakeIMAPServer(greeting: "* OK ready", script: script)
    }

    func session(_ server: FakeIMAPServer) async throws -> IMAPConnection {
        let port = try await server.start()
        let connection = IMAPConnection(host: "127.0.0.1", port: port, useTLS: false, timeout: .seconds(5))
        try await connection.connect()
        try await connection.login(username: "me@icloud.com", password: "x")
        try await connection.select("INBOX")
        return connection
    }

    /// iCloud answers the LIST-EXTENDED form, LIST "" ("*"), with OK and no
    /// folders at all, so Sent, Trash and Junk went missing. The plain form
    /// is what every server takes.
    @Test func listUsesThePlainPatternEveryServerUnderstands() async throws {
        let s = server(capabilities: "IMAP4rev1", extra: [
            "LIST": [#"* LIST (\HasNoChildren) "/" "INBOX""#, #"* LIST (\HasNoChildren) "/" "Sent Messages""#, "{TAG} OK LIST done"],
        ])
        defer { Task { await s.stop() } }
        let c = try await session(s)
        let folders = try await c.listFolders()
        #expect(s.sentLines().last?.hasSuffix(#"LIST "" "*""#) == true)
        #expect(folders.folder(for: .sent)?.path == "Sent Messages")
    }

    @Test func markReadUsesSilentStoreOnARangeOfUIDs() async throws {
        let s = server(capabilities: "IMAP4rev1")
        defer { Task { await s.stop() } }
        let c = try await session(s)
        try await c.setFlags(["\\Seen"], uids: [5, 3, 4, 9], add: true)
        #expect(s.sentLines().last?.hasSuffix("UID STORE 3:5,9 +FLAGS.SILENT (\\Seen)") == true)
    }

    @Test func moveUsesMOVEWhenTheServerHasIt() async throws {
        let s = server(capabilities: "IMAP4rev1 MOVE UIDPLUS")
        defer { Task { await s.stop() } }
        let c = try await session(s)
        try await c.move(uids: [7], to: "Archive")
        #expect(Array(s.commands().suffix(1)) == ["UID MOVE"])
    }

    @Test func moveWithoutMOVECopiesDeletesAndExpungesOnlyThoseUIDs() async throws {
        let s = server(capabilities: "IMAP4rev1 UIDPLUS")
        defer { Task { await s.stop() } }
        let c = try await session(s)
        try await c.move(uids: [7, 8], to: "Deleted Messages")
        #expect(Array(s.commands().suffix(3)) == ["UID COPY", "UID STORE", "UID EXPUNGE"])
        #expect(s.sentLines().last?.hasSuffix("UID EXPUNGE 7:8") == true)
    }

    @Test func moveWithoutUIDPLUSFallsBackToExpunge() async throws {
        let s = server(capabilities: "IMAP4rev1")
        defer { Task { await s.stop() } }
        let c = try await session(s)
        try await c.move(uids: [7], to: "Archive")
        #expect(Array(s.commands().suffix(3)) == ["UID COPY", "UID STORE", "EXPUNGE"])
    }

    @Test func appendSavesTheMessageAndReturnsItsUID() async throws {
        let s = server(capabilities: "IMAP4rev1 UIDPLUS")
        defer { Task { await s.stop() } }
        let c = try await session(s)
        let message = "From: me@icloud.com\r\nSubject: Hi\r\n\r\nHello\r\n"
        let uid = try await c.append(Data(message.utf8), to: "Sent Messages")
        #expect(uid == 57)
        #expect(s.appendedSoFar() == [message])
    }

    @Test func idleReportsNewMail() async throws {
        let s = server(capabilities: "IMAP4rev1 IDLE", extra: ["IDLE-EVENT": ["* 4 EXISTS"]])
        defer { Task { await s.stop() } }
        let c = try await session(s)
        let changes = try await c.waitForChanges(wait: .seconds(3))
        #expect(changes == [.exists(4)])
        // The connection is still usable afterwards.
        try await c.setFlags(["\\Seen"], uids: [3], add: true)
    }

    @Test func idleWithNothingNewEndsQuietly() async throws {
        let s = server(capabilities: "IMAP4rev1 IDLE")
        defer { Task { await s.stop() } }
        let c = try await session(s)
        let changes = try await c.waitForChanges(wait: .milliseconds(300))
        #expect(changes.isEmpty)
        try await c.setFlags(["\\Seen"], uids: [3], add: true)
    }
}
