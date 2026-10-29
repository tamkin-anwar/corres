import Foundation

/// A whole message (RFC 5322 + MIME) taken apart into what Corres shows:
/// the plain and HTML bodies, and the attachments. Gmail and Graph do this
/// on their side; IMAP hands over the raw message.
public struct ParsedMessage: Sendable, Equatable {
    public var plainText: String?
    public var html: String?
    public var attachments: [Attachment] = []
    /// Top-level headers, in order, values decoded.
    public var headers: [(String, String)] = []

    public func header(_ name: String) -> String? {
        headers.first { $0.0.caseInsensitiveCompare(name) == .orderedSame }?.1
    }

    public static func == (a: ParsedMessage, b: ParsedMessage) -> Bool {
        a.plainText == b.plainText && a.html == b.html && a.attachments == b.attachments
    }
}

public struct Attachment: Sendable, Equatable {
    public let filename: String
    public let mimeType: String
    public let data: Data
    /// For inline images an HTML body refers to as "cid:…".
    public let contentID: String?
    public let isInline: Bool
    public var size: Int { data.count }
}

public enum MIMEParser {
    public static func parse(_ raw: Data) -> ParsedMessage {
        var result = ParsedMessage()
        let part = Part(raw)
        result.headers = part.headers.map { ($0.0, MIMEWords.decode($0.1)) }
        let root = Node(part, depth: 0)
        var shown = root.shown()
        // Nothing shown by those rules (a forwarded message on its own, a
        // body labelled as a file): the first text anywhere, as before.
        if shown.isEmpty, let first = root.first(where: { $0.type == "text/html" }) ?? root.first(where: { $0.type == "text/plain" }) {
            shown = [first]
        }
        let texts = shown.map { (isHTML: $0.type == "text/html", text: $0.part.text) }
        if texts.contains(where: \.isHTML) {
            result.html = joinedHTML(texts)
            // The plain alternative, for search and summaries.
            result.plainText = root.first { $0.type == "text/plain" && !$0.isAttachment }?.part.text
        } else if !texts.isEmpty {
            result.plainText = texts.map(\.text).joined(separator: "\n\n")
        }
        let shownIDs = Set(shown.map { ObjectIdentifier($0) })
        root.forEachLeaf { node in
            guard !shownIDs.contains(ObjectIdentifier(node)) else { return }
            let type = node.type
            // An alternative not shown (the plain text beside the HTML).
            if (type == "text/plain" || type == "text/html"), !node.isAttachment { return }
            let part = node.part
            let disposition = part.header("Content-Disposition")?.lowercased() ?? ""
            let cid = part.header("Content-ID").map(cleanMessageID)
            // An invitation's own calendar part is unnamed, and usually
            // beside a named invite.ics: listed only when it's the only one.
            if part.filename == nil, type == "text/calendar", hasNamedCalendar(root) { return }
            let name = part.filename ?? (type == "message/rfc822" ? "Message.eml" : type == "text/calendar" ? "invite.ics" : "Attachment")
            result.attachments.append(Attachment(filename: name, mimeType: type.isEmpty ? "application/octet-stream" : type,
                                                 data: part.decodedBody, contentID: cid,
                                                 isInline: disposition.hasPrefix("inline") || (cid != nil && !disposition.hasPrefix("attachment"))))
        }
        return result
    }

    private static func hasNamedCalendar(_ root: Node) -> Bool {
        var found = false
        root.forEachLeaf { node in
            if let name = node.part.filename,
               node.type == "text/calendar" || node.type == "application/ics" || name.lowercased().hasSuffix(".ics") { found = true }
        }
        return found
    }

    /// The text parts in order as one HTML body: plain text between HTML
    /// parts is set as text, and each part after the first goes inside the
    /// first one's body, as Mail shows an email written around a file.
    static func joinedHTML(_ texts: [(isHTML: Bool, text: String)]) -> String {
        var result = ""
        for piece in texts {
            let html = piece.isHTML ? piece.text
                : #"<div style="white-space: pre-wrap">"# + piece.text.replacingOccurrences(of: "&", with: "&amp;")
                    .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;") + "</div>"
            if result.isEmpty {
                result = html
            } else if let close = result.range(of: "</body>", options: [.caseInsensitive, .backwards]) {
                result.insert(contentsOf: html, at: close.lowerBound)
            } else {
                result += html
            }
        }
        return result
    }

    /// A part and the parts inside it, read once.
    final class Node {
        let part: Part
        let type: String
        let children: [Node]

        init(_ part: Part, depth: Int) {
            self.part = part
            // No Content-Type means plain text (RFC 2045 §5.2).
            type = part.contentType.isEmpty ? "text/plain" : part.contentType
            if depth < 20, type.hasPrefix("multipart/"), let boundary = part.parameter("boundary", of: "Content-Type") {
                children = part.children(boundary: boundary).map { Node($0, depth: depth + 1) }
            } else {
                children = []
            }
        }

        /// Sent as a file to save, not as part of the text.
        var isAttachment: Bool {
            (part.header("Content-Disposition")?.lowercased() ?? "").hasPrefix("attachment") || part.filename != nil
        }

        /// The text parts shown, as Mail and Thunderbird choose them (RFC
        /// 2046): of alternatives, the last that can be shown, HTML before
        /// plain text; of a multipart/related, its first part; of a
        /// multipart/mixed, every part in turn. Only the first text part
        /// used to count, so the rest of an email written around a file,
        /// or a mailing list's footer, was left out.
        func shown() -> [Node] {
            if type.hasPrefix("multipart/") {
                let options = children.map { $0.shown() }
                switch type {
                case "multipart/alternative":
                    let usable = options.filter { !$0.isEmpty }
                    return usable.last { $0.contains { $0.type == "text/html" } } ?? usable.last ?? []
                case "multipart/related":
                    return options.first { !$0.isEmpty } ?? []
                default:
                    return options.flatMap { $0 }
                }
            }
            guard !isAttachment, type == "text/html" || type == "text/plain" else { return [] }
            return [self]
        }

        func first(where matches: (Node) -> Bool) -> Node? {
            if children.isEmpty { return matches(self) && !(part.header("Content-Disposition")?.lowercased() ?? "").hasPrefix("attachment") ? self : nil }
            for child in children {
                if let found = child.first(where: matches) { return found }
            }
            return nil
        }

        func forEachLeaf(_ body: (Node) -> Void) {
            if children.isEmpty && !type.hasPrefix("multipart/") { body(self); return }
            children.forEach { $0.forEachLeaf(body) }
        }
    }

    /// One MIME entity: its headers and its still-encoded body.
    struct Part {
        let headers: [(String, String)]
        let body: Data

        init(_ raw: Data) {
            let bytes = [UInt8](raw)
            // Headers end at the first empty line (CRLF CRLF, or LF LF).
            var split = bytes.count
            var bodyStart = bytes.count
            var i = 0
            while i < bytes.count {
                if bytes[i] == 10 {
                    if i + 1 < bytes.count, bytes[i + 1] == 10 { split = i; bodyStart = i + 2; break }
                    if i + 2 < bytes.count, bytes[i + 1] == 13, bytes[i + 2] == 10 { split = i; bodyStart = i + 3; break }
                }
                i += 1
            }
            if bytes.first == 13 || bytes.first == 10 { split = 0; bodyStart = bytes.first == 13 ? 2 : 1 }
            headers = HeaderFields(data: Data(bytes[0..<min(split, bytes.count)])).fields
            body = bodyStart < bytes.count ? Data(bytes[bodyStart...]) : Data()
        }

        func header(_ name: String) -> String? {
            headers.first { $0.0.caseInsensitiveCompare(name) == .orderedSame }?.1
        }

        var contentType: String {
            (header("Content-Type")?.split(separator: ";").first.map(String.init) ?? "")
                .trimmingCharacters(in: .whitespaces).lowercased()
        }

        /// A parameter of a header ("boundary", "charset", "filename"),
        /// including RFC 2231 forms: filename*=UTF-8''r%C3%A9sum%C3%A9.pdf
        /// and continuations filename*0*=…; filename*1*=….
        func parameter(_ name: String, of headerName: String) -> String? {
            guard let value = header(headerName) else { return nil }
            var params: [String: String] = [:]
            for piece in Self.splitParameters(value).dropFirst() {
                guard let eq = piece.firstIndex(of: "=") else { continue }
                let key = piece[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
                var val = piece[piece.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                if val.hasPrefix("\""), val.hasSuffix("\""), val.count >= 2 { val = String(val.dropFirst().dropLast()) }
                params[key] = val
            }
            let lower = name.lowercased()
            if let extended = params[lower + "*"] { return Self.decode2231(extended) }
            let continued = (0..<50).compactMap { n -> (String, Bool)? in
                if let v = params["\(lower)*\(n)*"] { return (v, true) }
                if let v = params["\(lower)*\(n)"] { return (v, false) }
                return nil
            }
            if !continued.isEmpty {
                let encoded = continued.first!.1
                let joined = continued.map(\.0).joined()
                return encoded ? Self.decode2231(joined) : joined
            }
            return params[lower].map(MIMEWords.decode)
        }

        var filename: String? {
            parameter("filename", of: "Content-Disposition") ?? parameter("name", of: "Content-Type")
        }

        var decodedBody: Data {
            switch header("Content-Transfer-Encoding")?.lowercased().trimmingCharacters(in: .whitespaces) {
            case "base64":
                let cleaned = String(decoding: body, as: UTF8.self).filter { !$0.isWhitespace }
                var padded = cleaned
                while padded.count % 4 != 0 { padded += "=" }
                return Data(base64Encoded: padded) ?? Data()
            case "quoted-printable":
                return Self.decodeQuotedPrintable(body)
            default:
                return body
            }
        }

        /// HTML that doesn't name its charset in its header names it in its
        /// own `<meta>` tag, read as a browser reads it.
        var text: String {
            let data = decodedBody
            let charset = parameter("charset", of: "Content-Type")
                ?? (contentType == "text/html" ? Self.metaCharset(in: data) : nil) ?? "utf-8"
            if let encoding = Charset.encoding(named: charset), let s = String(data: data, encoding: encoding) {
                return s
            }
            return String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        }

        func children(boundary: String) -> [Part] {
            let delimiter = Array(("--" + boundary).utf8)
            let bytes = [UInt8](body)
            var parts: [Part] = []
            var start: Int?
            var lineStart = 0
            var i = 0
            while i <= bytes.count {
                if i == bytes.count || bytes[i] == 10 {
                    var line = Array(bytes[lineStart..<i])
                    if line.last == 13 { line.removeLast() }
                    // The boundary, then only "--" (the last) or spaces
                    // (RFC 2046 5.1.1). A line that merely starts with it is
                    // content: "--b1" isn't the end of a part inside "--b".
                    let rest = line.count >= delimiter.count && Array(line.prefix(delimiter.count)) == delimiter
                        ? line.dropFirst(delimiter.count) : nil
                    let isDelimiter = rest.map { $0.starts(with: [45, 45]) || $0.allSatisfy { $0 == 32 || $0 == 9 } } ?? false
                    if isDelimiter, let rest {
                        if let s = start {
                            // The part ends before the CRLF preceding the delimiter.
                            var end = lineStart
                            if end > s, bytes[end - 1] == 10 { end -= 1 }
                            if end > s, bytes[end - 1] == 13 { end -= 1 }
                            parts.append(Part(Data(bytes[s..<max(s, end)])))
                        }
                        if rest.starts(with: [45, 45]) { break } // closing "--boundary--"
                        start = i + 1
                    }
                    lineStart = i + 1
                }
                i += 1
            }
            return parts
        }

        private static let metaCharsetPattern = try? NSRegularExpression(
            pattern: #"<meta[^>]{0,200}?charset\s*=\s*["']?\s*([A-Za-z0-9_\-:.]+)"#, options: .caseInsensitive)

        static func metaCharset(in data: Data) -> String? {
            let head = String(decoding: data.prefix(4096), as: UTF8.self)
            guard let regex = metaCharsetPattern,
                  let match = regex.firstMatch(in: head, range: NSRange(head.startIndex..., in: head)),
                  let range = Range(match.range(at: 1), in: head) else { return nil }
            return String(head[range])
        }

        static func splitParameters(_ value: String) -> [String] {
            var out: [String] = []
            var current = ""
            var quoted = false
            for ch in value {
                if ch == "\"" { quoted.toggle() }
                if ch == ";" && !quoted { out.append(current); current = "" } else { current.append(ch) }
            }
            out.append(current)
            return out
        }

        /// charset'language'percent-encoded
        static func decode2231(_ value: String) -> String {
            let pieces = value.split(separator: "'", maxSplits: 2, omittingEmptySubsequences: false)
            guard pieces.count == 3 else { return value.removingPercentEncoding ?? value }
            let encoded = String(pieces[2])
            var bytes: [UInt8] = []
            var chars = Array(encoded.utf8)[...]
            while let c = chars.popFirst() {
                if c == UInt8(ascii: "%"), chars.count >= 2,
                   let b = UInt8(String(decoding: chars.prefix(2), as: UTF8.self), radix: 16) {
                    bytes.append(b); chars = chars.dropFirst(2)
                } else { bytes.append(c) }
            }
            let enc = Charset.encoding(named: String(pieces[0])) ?? .utf8
            return String(data: Data(bytes), encoding: enc) ?? String(decoding: bytes, as: UTF8.self)
        }

        static func decodeQuotedPrintable(_ data: Data) -> Data {
            let bytes = [UInt8](data)
            var out: [UInt8] = []
            out.reserveCapacity(bytes.count)
            var i = 0
            func hex(_ b: UInt8) -> UInt8? {
                switch b {
                case 48...57: b - 48
                case 65...70: b - 55
                case 97...102: b - 87
                default: nil
                }
            }
            while i < bytes.count {
                let b = bytes[i]
                if b == UInt8(ascii: "=") {
                    // Spaces a server added after the "=" of a soft break
                    // don't stop it being one (RFC 2045 6.7).
                    var end = i + 1
                    while end < bytes.count, bytes[end] == 32 || bytes[end] == 9 { end += 1 }
                    if end < bytes.count, bytes[end] == 10 { i = end + 1; continue }            // soft break LF
                    if end + 1 < bytes.count, bytes[end] == 13, bytes[end + 1] == 10 { i = end + 2; continue } // soft break CRLF
                    if i + 2 < bytes.count, let h = hex(bytes[i + 1]), let l = hex(bytes[i + 2]) {
                        out.append(h << 4 | l); i += 3; continue
                    }
                }
                out.append(b); i += 1
            }
            return Data(out)
        }
    }
}
