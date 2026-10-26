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
        let enc = Charset.encoding(named: charset) ?? .utf8
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

/// The text encoding a MIME charset name means, as mail apps read it.
/// Senders label mail with the older, smaller standard while writing the
/// characters of its larger successor, so each is read as the superset:
/// GB2312 and GBK as GB18030, EUC-KR as Windows code page 949 (Outlook's
/// ks_c_5601-1987), Shift_JIS as code page 932, Big5 as Big5-HKSCS, and
/// ISO-8859-1 as Windows-1252 (curly quotes, the euro sign), US-ASCII as
/// UTF-8.
/// Strictly decoding as the labelled charset failed on those characters
/// and dropped the whole part to garbled UTF-8.
enum Charset {
    static func encoding(named name: String) -> String.Encoding? {
        let label = name.trimmingCharacters(in: CharacterSet(charactersIn: "\"' \t")).lowercased()
        let cf: CFStringEncoding
        switch label {
        case "gb2312", "gb_2312-80", "gbk", "x-gbk", "cp936", "ms936", "windows-936", "euc-cn", "csgb2312", "chinese", "gb18030":
            cf = CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        case "ks_c_5601-1987", "ks_c_5601-1989", "ks_c_5601", "ksc5601", "ksc_5601", "euc-kr", "cseuckr", "korean", "cp949", "ms949",
             "windows-949", "uhc":
            cf = CFStringEncoding(CFStringEncodings.dosKorean.rawValue)
        case "shift_jis", "shift-jis", "sjis", "x-sjis", "ms_kanji", "csshiftjis", "windows-31j", "cp932", "ms932", "x-ms-cp932":
            cf = CFStringEncoding(CFStringEncodings.dosJapanese.rawValue)
        case "big5", "csbig5", "x-x-big5", "cn-big5", "big5-hkscs":
            cf = CFStringEncoding(CFStringEncodings.big5_HKSCS_1999.rawValue)
        case "iso-8859-1", "iso8859-1", "iso_8859-1", "latin1", "l1", "cp819":
            cf = CFStringEncoding(CFStringBuiltInEncodings.windowsLatin1.rawValue)
        case "us-ascii", "ascii", "us", "ansi_x3.4-1968":
            // UTF-8 reads ASCII the same, and also the UTF-8 that mail
            // labelled ASCII often carries.
            return .utf8
        case "tis-620", "iso-8859-11", "windows-874", "cp874":
            cf = CFStringEncoding(CFStringEncodings.dosThai.rawValue)
        default:
            cf = CFStringConvertIANACharSetNameToEncoding(label as CFString)
        }
        guard cf != kCFStringEncodingInvalidId else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
    }
}
