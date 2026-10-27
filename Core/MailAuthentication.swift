import Foundation

/// Whether the mail service that received a message says it passed DMARC
/// for the domain in its From address, read from that service's own
/// `Authentication-Results` header (RFC 8601).
///
/// A company logo (BIMI) is only shown on mail that passes DMARC: the BIMI
/// draft says that without a DMARC pass "BIMI processing MUST NOT be
/// performed for this message" (draft-brand-indicators-for-message-
/// identification, section 7.1), and Gmail shows logos only on mail that
/// passes. Without this, a forged email "from" a bank would carry the
/// bank's verified logo.
///
/// Anyone can write an `Authentication-Results` header into the email they
/// send, so only the receiving service's own counts. Each service adds its
/// header above every header already in the message (RFC 8601 section 5
/// and RFC 5322's trace order), so the service's result is the first one,
/// and it's recognised by its authserv-id:
/// - Gmail: the first header, from `mx.google.com`.
/// - Outlook (Exchange Online Protection): the first header, which Microsoft
///   writes with no authserv-id at all ("spf=pass (sender IP is ...)
///   ...; dmarc=pass action=none header.from=..."), or one naming a
///   Microsoft host.
/// - iCloud: the run of headers at the top whose authserv-id is an
///   `icloud.com` host (`dmarc.icloud.com`, `dkim-verifier.icloud.com`...);
///   the first DMARC result among them.
/// - Any other mail service: no way to tell its header from the sender's,
///   so nothing counts (no logo without proof).
public enum MailAuthentication {
    public enum Receiver: Sendable {
        case google, microsoft, icloud, unknown
    }

    /// One parsed header: who wrote it (nil when Microsoft left it out),
    /// and each result in it.
    public struct Header: Equatable, Sendable {
        public var authservID: String?
        public var results: [Result]
    }

    public struct Result: Equatable, Sendable {
        /// "dmarc", "dkim", "spf", "bimi"...
        public var method: String
        /// "pass", "fail", "none", "bestguesspass"...
        public var value: String
        /// "header.from" → "example.com", lowercased keys.
        public var properties: [String: String]
    }

    /// `headers` are the message's `Authentication-Results` values in the
    /// order they appear in the message (topmost first). `fromAddress` is
    /// the From address or just its domain.
    public static func dmarcPasses(headers: [String], receiver: Receiver, fromAddress: String) -> Bool {
        guard let fromDomain = domain(of: fromAddress), let result = dmarcResult(headers: headers, receiver: receiver) else {
            return false
        }
        guard result.value == "pass", let headerFrom = result.properties["header.from"].flatMap(domain(of:)) else {
            return false
        }
        return headerFrom == fromDomain
    }

    /// The receiving service's DMARC result, or nil when it gave none (or
    /// the first header isn't the service's own).
    public static func dmarcResult(headers: [String], receiver: Receiver) -> Result? {
        let parsed = headers.map(parse)
        switch receiver {
        case .google:
            guard let first = parsed.first, first.authservID == "mx.google.com" else { return nil }
            return first.results.first { $0.method == "dmarc" }
        case .microsoft:
            guard let first = parsed.first else { return nil }
            if let id = first.authservID, !isMicrosoftHost(id) { return nil }
            return first.results.first { $0.method == "dmarc" }
        case .icloud:
            for header in parsed {
                guard let id = header.authservID, id == "icloud.com" || id.hasSuffix(".icloud.com") else { return nil }
                if let dmarc = header.results.first(where: { $0.method == "dmarc" }) { return dmarc }
            }
            return nil
        case .unknown:
            return nil
        }
    }

    private static func isMicrosoftHost(_ id: String) -> Bool {
        ["microsoft.com", "outlook.com", "office365.com"].contains { id == $0 || id.hasSuffix("." + $0) }
    }

    /// "Jane <jane@Example.COM>", "jane@example.com" or "example.com." →
    /// "example.com".
    static func domain(of value: String) -> String? {
        var text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if let at = text.lastIndex(of: "@") { text = String(text[text.index(after: at)...]) }
        text = text.trimmingCharacters(in: CharacterSet(charactersIn: "<>\"' ").union(.whitespacesAndNewlines))
        while text.hasSuffix(".") { text.removeLast() }
        let lowered = text.lowercased()
        return lowered.contains(".") ? lowered : nil
    }

    /// Parses one `Authentication-Results` value (RFC 8601 section 2.2):
    /// `authserv-id [version] ; method=result [reason] ptype.property=value ...`,
    /// with comments in parentheses and quoted strings allowed anywhere.
    /// Lenient, as real headers are: Microsoft's has no authserv-id, and
    /// adds its own words ("action=none", "compauth=pass reason=100").
    public static func parse(_ raw: String) -> Header {
        let text = stripComments(raw.replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " "))
        var segments = splitOutsideQuotes(text, on: [";"]).map { $0.trimmingCharacters(in: .whitespaces) }
        var authservID: String?
        if let first = segments.first {
            let words = splitOutsideQuotes(first, on: [" ", "\t"]).filter { !$0.isEmpty }
            let firstToken = words.first ?? ""
            if firstToken.contains("=") {
                // No authserv-id (Microsoft): the first segment is a result.
            } else {
                authservID = firstToken.isEmpty ? nil : unquote(firstToken).lowercased()
                segments.removeFirst()
            }
        }
        var results: [Result] = []
        for segment in segments where !segment.isEmpty {
            let tokens = tokenize(segment)
            guard let head = tokens.first, let equals = head.firstIndex(of: "=") else { continue }
            let method = head[..<equals].split(separator: "/").first.map { String($0).lowercased() } ?? ""
            let value = unquote(String(head[head.index(after: equals)...])).lowercased()
            guard !method.isEmpty, !value.isEmpty else { continue }
            var properties: [String: String] = [:]
            for token in tokens.dropFirst() {
                guard let eq = token.firstIndex(of: "=") else { continue }
                let key = token[..<eq].lowercased()
                // "reason=..." and Microsoft's "action=none" are kept too;
                // only the first of a key counts.
                if properties[key] == nil { properties[key] = unquote(String(token[token.index(after: eq)...])) }
            }
            results.append(Result(method: method, value: value, properties: properties))
        }
        return Header(authservID: authservID, results: results)
    }

    /// Comments (nested parentheses, RFC 5322 CFWS) removed, quoted
    /// strings left whole.
    private static func stripComments(_ text: String) -> String {
        var out = ""
        var depth = 0
        var quoted = false
        var escaped = false
        for character in text {
            if escaped {
                if depth == 0 { out.append(character) }
                escaped = false
                continue
            }
            if character == "\\" {
                escaped = true
                if depth == 0 { out.append(character) }
                continue
            }
            if quoted {
                out.append(character)
                if character == "\"" { quoted = false }
                continue
            }
            switch character {
            case "\"" where depth == 0:
                quoted = true
                out.append(character)
            case "(":
                depth += 1
            case ")":
                if depth > 0 {
                    depth -= 1
                    if depth == 0 { out.append(" ") }
                }
            default:
                if depth == 0 { out.append(character) }
            }
        }
        return out
    }

    /// `text` cut at each `separator` that isn't inside a quoted string.
    private static func splitOutsideQuotes(_ text: String, on separators: Set<Character>) -> [String] {
        var parts: [String] = []
        var current = ""
        var quoted = false
        var escaped = false
        for character in text {
            if escaped {
                current.append(character)
                escaped = false
            } else if character == "\\", quoted {
                current.append(character)
                escaped = true
            } else if character == "\"" {
                quoted.toggle()
                current.append(character)
            } else if !quoted, separators.contains(character) {
                parts.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        parts.append(current)
        return parts
    }

    /// Words split on spaces (not inside quotes), with "a = b" joined back
    /// into "a=b".
    private static func tokenize(_ segment: String) -> [String] {
        let words = splitOutsideQuotes(segment, on: [" ", "\t"]).filter { !$0.isEmpty }
        var tokens: [String] = []
        var index = 0
        while index < words.count {
            var word = words[index]
            if word.hasSuffix("="), index + 1 < words.count {
                word += words[index + 1]
                index += 1
            } else if index + 1 < words.count, words[index + 1].hasPrefix("=") {
                word += words[index + 1]
                index += 1
                if word.hasSuffix("="), index + 1 < words.count {
                    word += words[index + 1]
                    index += 1
                }
            }
            tokens.append(word)
            index += 1
        }
        return tokens
    }

    private static func unquote(_ value: String) -> String {
        guard value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") else { return value }
        return String(value.dropFirst().dropLast())
    }
}
