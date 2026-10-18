import Foundation
import NIOCore
import NIOIMAP

/// Gathers the server's replies to one command into Corres's models: the
/// untagged lines a command produces (folders, message data, mailbox
/// status), until its tagged OK, NO or BAD. One collector per command;
/// `IMAPConnection` feeds it, and tests feed it recorded transcripts.
public struct ResponseCollector: Sendable {
    public enum Outcome: Sendable, Equatable {
        case ok
        case no(String)
        case bad(String)
    }

    public private(set) var outcome: Outcome?
    public private(set) var capabilities: [String] = []
    public private(set) var folders: [Folder] = []
    public private(set) var messages: [MessageSummary] = []
    /// UIDs a QRESYNC server says were deleted (VANISHED).
    public private(set) var vanished: [UInt32] = []
    /// From SELECT.
    public private(set) var uidValidity: UInt32?
    public private(set) var uidNext: UInt32?
    public private(set) var exists: Int?
    public private(set) var highestModSeq: UInt64?
    /// A message body or header fetched with BODY.PEEK[...], by UID.
    public private(set) var bodies: [UInt32: Data] = [:]
    /// The server said BYE: the connection is going away.
    public private(set) var sawBye = false

    let tag: String?
    let folder: String

    public init(tag: String?, folder: String = "") {
        self.tag = tag
        self.folder = folder
    }

    public var isComplete: Bool { outcome != nil }

    public var selected: SelectedFolder? {
        guard let uidValidity, let uidNext else { return nil }
        return SelectedFolder(uidValidity: uidValidity, uidNext: uidNext, exists: exists ?? 0, highestModSeq: highestModSeq)
    }

    // The message being assembled from a streamed FETCH.
    private var fetch = PartialFetch()

    private struct PartialFetch: Sendable {
        var uid: UInt32?
        var flags: Set<String> = []
        var envelope: Envelope?
        var size: Int?
        var streamed = Data()
        var headerFields: Data?
        var isHeaderStream = false
    }

    public mutating func receive(_ response: Response) {
        switch response {
        case .untagged(let payload):
            receive(payload)
        case .fetch(let part):
            receive(part)
        case .tagged(let tagged):
            guard tag == nil || tagged.tag == tag else { return }
            switch tagged.state {
            case .ok(let text): note(text.code); outcome = .ok
            case .no(let text): outcome = .no(text.text)
            case .bad(let text): outcome = .bad(text.text)
            }
        case .fatal(let text):
            sawBye = true
            outcome = .no(text.text)
        case .authenticationChallenge, .idleStarted:
            break
        }
    }

    private mutating func receive(_ payload: ResponsePayload) {
        switch payload {
        case .capabilityData(let caps):
            capabilities = caps.map { String($0) }
        case .conditionalState(let status):
            switch status {
            case .ok(let text), .no(let text), .bad(let text), .preauth(let text): note(text.code)
            case .bye: sawBye = true
            }
        case .mailboxData(let data):
            switch data {
            case .list(let info):
                let path = String(decoding: info.path.name.bytes, as: UTF8.self)
                let attrs = Set(info.attributes.map { String($0) })
                folders.append(Folder(path: path, delimiter: info.path.pathSeparator, attributes: attrs))
            case .exists(let n):
                exists = n
            default:
                break
            }
        case .messageData(let data):
            if case .vanished(let set) = data {
                vanished += set.map { UInt32($0.rawValue) }
            } else if case .vanishedEarlier(let set) = data {
                vanished += set.map { UInt32($0.rawValue) }
            }
        default:
            break
        }
    }

    private mutating func note(_ code: ResponseTextCode?) {
        switch code {
        case .capability(let caps): capabilities = caps.map { String($0) }
        case .uidValidity(let v): uidValidity = UInt32(v)
        case .uidNext(let n): uidNext = n.rawValue
        case .highestModificationSequence(let m): highestModSeq = UInt64(m)
        default: break
        }
    }

    private mutating func receive(_ part: FetchResponse) {
        switch part {
        case .start, .startUID:
            fetch = PartialFetch()
            if case .startUID(let uid) = part { fetch.uid = uid.rawValue }
        case .simpleAttribute(let attribute):
            switch attribute {
            case .uid(let uid): fetch.uid = uid.rawValue
            case .flags(let flags): fetch.flags = Set(flags.map { String($0).lowercased() })
            case .envelope(let envelope): fetch.envelope = envelope
            case .rfc822Size(let size): fetch.size = size
            default: break
            }
        case .streamingBegin(let kind, _):
            fetch.streamed = Data()
            // BODY.PEEK[HEADER.FIELDS (REFERENCES)] for threading.
            if case .body(let section, _) = kind, section.kind != .complete, section.kind != .text {
                fetch.isHeaderStream = true
            } else if case .rfc822Header = kind {
                fetch.isHeaderStream = true
            } else {
                fetch.isHeaderStream = false
            }
        case .streamingBytes(let bytes):
            fetch.streamed.append(contentsOf: bytes.readableBytesView)
        case .streamingEnd:
            if fetch.isHeaderStream { fetch.headerFields = fetch.streamed } else if let uid = fetch.uid {
                bodies[uid] = fetch.streamed
            }
        case .finish:
            if let uid = fetch.uid, let summary = makeSummary(uid: uid) { messages.append(summary) }
            if let uid = fetch.uid, fetch.envelope == nil, !fetch.streamed.isEmpty, !fetch.isHeaderStream {
                bodies[uid] = fetch.streamed
            }
        }
    }

    private func makeSummary(uid: UInt32) -> MessageSummary? {
        guard let envelope = fetch.envelope else {
            // A flags-only fetch (checking read state of stored mail).
            return MessageSummary(uid: uid, folder: folder, flags: fetch.flags, subject: "", from: nil, to: [],
                                  date: nil, messageID: nil, inReplyTo: nil, size: fetch.size)
        }
        let headers = fetch.headerFields.map { HeaderFields(data: $0) }
        return MessageSummary(
            uid: uid,
            folder: folder,
            flags: fetch.flags,
            subject: envelope.subject.map { MIMEWords.decode(String(buffer: $0)) } ?? "",
            from: Self.addresses(envelope.from).first,
            to: Self.addresses(envelope.to),
            cc: Self.addresses(envelope.cc),
            date: envelope.date.flatMap { RFC2822Date.parse(String($0)) },
            messageID: envelope.messageID.map { cleanMessageID(String($0)) },
            inReplyTo: envelope.inReplyTo.flatMap { messageIDs(in: String($0)).first ?? cleanMessageID(String($0)) },
            references: headers?.value("References").map(messageIDs(in:)) ?? [],
            size: fetch.size)
    }

    static func addresses(_ list: [EmailAddressListElement]) -> [Address] {
        list.flatMap { element -> [Address] in
            switch element {
            case .singleAddress(let a):
                guard let mailbox = a.mailbox, let host = a.host else { return [] }
                let name = a.personName.map { MIMEWords.decode(String(buffer: $0)) }
                return [Address(name: name?.isEmpty == true ? nil : name,
                                email: "\(String(buffer: mailbox))@\(String(buffer: host))".lowercased())]
            case .group(let group):
                return addresses(group.children)
            }
        }
    }
}

/// Raw header lines ("References: <a@b>\r\n <c@d>") with folding undone.
struct HeaderFields {
    let fields: [(String, String)]
    init(data: Data) {
        let text = String(decoding: data, as: UTF8.self)
        var out: [(String, String)] = []
        for line in text.components(separatedBy: "\r\n").flatMap({ $0.components(separatedBy: "\n") }) {
            if let first = line.first, first == " " || first == "\t", !out.isEmpty {
                out[out.count - 1].1 += " " + line.trimmingCharacters(in: .whitespaces)
            } else if let colon = line.firstIndex(of: ":") {
                out.append((String(line[..<colon]), String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)))
            }
        }
        fields = out
    }
    func value(_ name: String) -> String? { fields.first { $0.0.caseInsensitiveCompare(name) == .orderedSame }?.1 }
}
