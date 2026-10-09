import Foundation

/// A plain-text email, made into a page the reading view shows like any
/// other: the same typography, Dark mode, tappable links, addresses and
/// phone numbers, pinch to zoom, and the quoted history folded away.
/// Shown as bare text before, its links did nothing and every reply
/// repeated the whole conversation in `>` lines.
public enum PlainTextEmail {
    /// The class on the quoted history (attribution line and quote), which
    /// the reading view folds like a Gmail or Mail quote.
    public static let quoteClass = "corres-quote"

    public static func html(from text: String) -> String {
        let lines = unwrapped(text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init))
        let trimmed = Array(lines.drop { $0.trimmingCharacters(in: .whitespaces).isEmpty }
            .reversed().drop { $0.trimmingCharacters(in: .whitespaces).isEmpty }.reversed())
        return #"<div class="corres-plain-text" style="white-space: pre-wrap">"# + render(trimmed) + "</div>"
    }

    /// Lines as HTML, `>` quotes as nested `<blockquote type="cite">` (the
    /// form Mail itself sends), with the "On … wrote:" line that
    /// introduces a quote kept with it.
    static func render(_ lines: [String]) -> String {
        var output: [String] = []
        var index = 0
        while index < lines.count {
            guard isQuoted(lines[index]) else {
                // The attribution line(s) right before a quote go with it.
                if let span = attributionSpan(at: index, in: lines) {
                    let attribution = lines[index..<index + span].map(escape).joined(separator: "\n")
                    index += span
                    let quoted = takeQuote(from: &index, in: lines)
                    output.append(#"<div class="\#(quoteClass)">"# + attribution + "\n"
                                  + #"<blockquote type="cite">"# + render(quoted) + "</blockquote></div>")
                    continue
                }
                output.append(escape(lines[index]))
                index += 1
                continue
            }
            let quoted = takeQuote(from: &index, in: lines)
            output.append(#"<blockquote type="cite">"# + render(quoted) + "</blockquote>")
        }
        // Block elements end their own line.
        return output.joined(separator: "\n").replacingOccurrences(of: "</blockquote>\n", with: "</blockquote>")
            .replacingOccurrences(of: "</div>\n", with: "</div>")
    }

    private static func isQuoted(_ line: String) -> Bool { line.hasPrefix(">") }

    /// Consecutive quoted lines, one level of `>` removed. Blank lines
    /// between two quoted lines belong to the quote.
    private static func takeQuote(from index: inout Int, in lines: [String]) -> [String] {
        var quoted: [String] = []
        while index < lines.count {
            let line = lines[index]
            if isQuoted(line) {
                var rest = line.dropFirst()
                if rest.hasPrefix(" ") { rest = rest.dropFirst() }
                quoted.append(String(rest))
                index += 1
            } else if line.trimmingCharacters(in: .whitespaces).isEmpty,
                      index + 1 < lines.count, isQuoted(lines[index + 1]), !quoted.isEmpty {
                quoted.append("")
                index += 1
            } else {
                break
            }
        }
        return quoted
    }

    /// "On Tue, Oct 7, 2026 at 3:12 PM Maya <maya@example.com> wrote:",
    /// which Gmail often breaks over two lines, directly followed by `>`
    /// lines (blank lines between allowed).
    private static func attributionSpan(at index: Int, in lines: [String]) -> Int? {
        for span in 1...2 where index + span <= lines.count {
            let text = lines[index..<index + span].joined(separator: " ").trimmingCharacters(in: .whitespaces)
            guard text.range(of: #"^(On|Le|Am|El|Il|Op) .+(wrote|a écrit|schrieb|escribió|ha scritto|schreef)\s*:$"#,
                             options: .regularExpression) != nil else { continue }
            var next = index + span
            while next < lines.count, lines[next].trimmingCharacters(in: .whitespaces).isEmpty { next += 1 }
            return next < lines.count && isQuoted(lines[next]) ? next - index : nil
        }
        return nil
    }

    /// Text hard-wrapped at about 72 characters (most plain-text mail
    /// software, and format=flowed) read as ragged half-lines on a phone.
    /// Its paragraphs are joined back up; lists, quotes and short lines
    /// keep their breaks.
    static func unwrapped(_ lines: [String]) -> [String] {
        let body = lines.filter { !isQuoted($0) && $0.count > 40 }
        let nearWrap = body.filter { (60...80).contains($0.count) }
        let flowed = lines.contains { $0.hasSuffix(" ") && $0 != "-- " && !isQuoted($0) }
        let hardWrapped = body.count >= 3 && nearWrap.count * 2 >= body.count && body.allSatisfy { $0.count <= 80 }
        guard hardWrapped || flowed else { return lines }
        var result: [String] = []
        for line in lines {
            if let last = result.last, joins(last, line, flowedOnly: !hardWrapped) {
                let left = last.hasSuffix(" ") ? last : last + " "
                result[result.count - 1] = left + line
            } else {
                result.append(line)
            }
        }
        return result.map { $0 == "-- " ? $0 : $0.replacingOccurrences(of: #" +$"#, with: "", options: .regularExpression) }
    }

    private static func joins(_ previous: String, _ line: String, flowedOnly: Bool) -> Bool {
        guard !isQuoted(previous), !isQuoted(line), previous != "-- ",
              let first = line.first, !first.isWhitespace else { return false }
        if line.range(of: #"^([-*•+]\s|\d{1,2}[.)]\s|--\s?$)"#, options: .regularExpression) != nil { return false }
        if previous.hasSuffix(" ") { return true }
        return !flowedOnly && previous.count >= 50 && !previous.hasSuffix(":")
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
