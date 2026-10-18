import Foundation

/// RFC 2047 encoded words, used for any header that isn't plain ASCII:
/// "=?UTF-8?B?8J+TpiBZb3VyIG9yZGVy?=" is "📦 Your order". Gmail and Graph
/// decode these for Corres; IMAP hands them over raw.
enum MIMEWords {
    static func decode(_ text: String) -> String {
        guard text.contains("=?") else { return text }
        let pattern = #"=\?([^?]+)\?([BbQq])\?([^?]*)\?="#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        var result = ""
        var cursor = 0
        var lastWasEncoded = false
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let between = ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            // Whitespace between two encoded words is dropped (RFC 2047 §6.2).
            if !(lastWasEncoded && between.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                result += between
            }
            let charset = ns.substring(with: match.range(at: 1))
            let encoding = ns.substring(with: match.range(at: 2)).uppercased()
            let payload = ns.substring(with: match.range(at: 3))
            if let decoded = decodeWord(payload, encoding: encoding, charset: charset) {
                result += decoded
            } else {
                result += ns.substring(with: match.range)
            }
            cursor = match.range.location + match.range.length
            lastWasEncoded = true
        }
        result += ns.substring(from: cursor)
        return result
    }

    private static func decodeWord(_ payload: String, encoding: String, charset: String) -> String? {
        let data: Data?
        if encoding == "B" {
            var padded = payload
            while padded.count % 4 != 0 { padded += "=" }
            data = Data(base64Encoded: padded)
        } else {
            var bytes: [UInt8] = []
            var chars = Array(payload.utf8)[...]
            while let c = chars.popFirst() {
                if c == UInt8(ascii: "_") { bytes.append(0x20) } else if c == UInt8(ascii: "="), chars.count >= 2,
                    let byte = UInt8(String(decoding: chars.prefix(2), as: UTF8.self), radix: 16) {
                    bytes.append(byte); chars = chars.dropFirst(2)
                } else { bytes.append(c) }
            }
            data = Data(bytes)
        }
        guard let data else { return nil }
        let cf = CFStringConvertIANACharSetNameToEncoding(charset.lowercased() as CFString)
        let enc = cf == kCFStringEncodingInvalidId ? String.Encoding.utf8
            : String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
        return String(data: data, encoding: enc) ?? String(decoding: data, as: UTF8.self)
    }
}

/// The Date header in its many real-world shapes: "Fri, 16 Oct 2026
/// 09:07:48 -0400", without the weekday, with "(PDT)" after it, or with a
/// zone name instead of an offset.
enum RFC2822Date {
    private static let formats = [
        "EEE, d MMM yyyy HH:mm:ss Z", "d MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm Z",
        "EEE, d MMM yyyy HH:mm:ss zzz", "d MMM yyyy HH:mm:ss zzz", "EEE, d MMM yy HH:mm:ss Z",
    ]

    static func parse(_ raw: String) -> Date? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let paren = text.firstIndex(of: "(") { text = String(text[..<paren]).trimmingCharacters(in: .whitespaces) }
        text = text.replacingOccurrences(of: "  ", with: " ")
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        for format in formats {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }
}
