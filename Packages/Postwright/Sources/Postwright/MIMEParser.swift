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
        walk(part, into: &result, depth: 0)
        return result
    }

    private static func walk(_ part: Part, into result: inout ParsedMessage, depth: Int) {
        guard depth < 20 else { return }
        // No Content-Type means plain text (RFC 2045 §5.2).
        let type = part.contentType.isEmpty ? "text/plain" : part.contentType
        if type.hasPrefix("multipart/"), let boundary = part.parameter("boundary", of: "Content-Type") {
            for child in part.children(boundary: boundary) { walk(child, into: &result, depth: depth + 1) }
            return
        }
        let disposition = part.header("Content-Disposition")?.lowercased() ?? ""
        let filename = part.filename
        let isAttachment = disposition.hasPrefix("attachment") || (filename != nil && !type.hasPrefix("text/"))
            || (!type.hasPrefix("text/") && !type.hasPrefix("multipart/"))
        if !isAttachment, type == "text/plain" || type.isEmpty, result.plainText == nil {
            result.plainText = part.text
        } else if !isAttachment, type == "text/html", result.html == nil {
            result.html = part.text
        } else if isAttachment || filename != nil {
            let cid = part.header("Content-ID").map(cleanMessageID)
            let name = filename ?? (type == "message/rfc822" ? "Message.eml" : "Attachment")
            result.attachments.append(Attachment(filename: name, mimeType: type.isEmpty ? "application/octet-stream" : type,
                                                 data: part.decodedBody, contentID: cid,
                                                 isInline: disposition.hasPrefix("inline") || (cid != nil && !disposition.hasPrefix("attachment"))))
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

        var text: String {
            let data = decodedBody
            let charset = parameter("charset", of: "Content-Type") ?? "utf-8"
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
                    if i + 1 < bytes.count, bytes[i + 1] == 10 { i += 2; continue }            // soft break LF
                    if i + 2 < bytes.count, bytes[i + 1] == 13, bytes[i + 2] == 10 { i += 3; continue } // soft break CRLF
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
