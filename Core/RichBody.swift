import Foundation

/// A formatted email body, as runs of text with their styles, turned into
/// the HTML part of the email (the plain-text part is the same words).
/// Lists are written as lines starting "• " or "1. " in the editor, so the
/// words read the same in plain text, and become real lists in HTML; a
/// quoted reply ("> ") becomes a quote.
public struct RichRun: Equatable, Sendable {
    public var text: String
    public var bold = false
    public var italic = false
    public var underline = false
    public var strikethrough = false
    public var link: URL?

    public init(_ text: String, bold: Bool = false, italic: Bool = false, underline: Bool = false,
                strikethrough: Bool = false, link: URL? = nil) {
        self.text = text; self.bold = bold; self.italic = italic
        self.underline = underline; self.strikethrough = strikethrough; self.link = link
    }

    var isStyled: Bool { bold || italic || underline || strikethrough || link != nil }
}

public enum RichBody {
    /// HTML for these runs, or nil when nothing in them is formatted (the
    /// email then goes as plain text alone, exactly as before).
    public static func html(_ runs: [RichRun]) -> String? {
        let plain = runs.map(\.text).joined()
        let hasList = plain.split(separator: "\n", omittingEmptySubsequences: false).contains { listItem(in: String($0)) != nil }
        guard runs.contains(where: \.isStyled) || hasList else { return nil }

        // Split the runs into lines, keeping each piece's style.
        var lines: [[RichRun]] = [[]]
        for run in runs {
            let pieces = run.text.split(separator: "\n", omittingEmptySubsequences: false)
            for (index, piece) in pieces.enumerated() {
                if index > 0 { lines.append([]) }
                if !piece.isEmpty {
                    var part = run
                    part.text = String(piece)
                    lines[lines.count - 1].append(part)
                }
            }
        }

        var html = ""
        var openList: String?
        var inQuote = false
        func closeList() { if let tag = openList { html += "</\(tag)>"; openList = nil } }
        for line in lines {
            let text = line.map(\.text).joined()
            let quoted = text.hasPrefix(">")
            if quoted != inQuote {
                closeList()
                html += quoted ? "<blockquote style=\"margin:0 0 0 .8ex;border-left:1px solid #ccc;padding-left:1ex\">" : "</blockquote>"
                inQuote = quoted
            }
            if quoted {
                html += escape(String(text.dropFirst(text.hasPrefix("> ") ? 2 : 1))) + "<br>"
                continue
            }
            if let item = listItem(in: text) {
                if openList != item.tag { closeList(); html += "<\(item.tag)>"; openList = item.tag }
                html += "<li>" + inline(dropping: item.prefixLength, from: line) + "</li>"
                continue
            }
            closeList()
            html += inline(dropping: 0, from: line) + "<br>"
        }
        closeList()
        if inQuote { html += "</blockquote>" }
        return "<div dir=\"auto\" style=\"font-family:-apple-system,Helvetica,Arial,sans-serif\">\(html)</div>"
    }

    /// "• Milk": a bulleted item; "1. Milk": a numbered one.
    static func listItem(in line: String) -> (tag: String, prefixLength: Int)? {
        if line.hasPrefix("• ") { return ("ul", 2) }
        if let match = line.patternRange(#"^\d{1,3}\. "#) {
            return ("ol", line.distance(from: line.startIndex, to: match.upperBound))
        }
        return nil
    }

    private static func inline(dropping count: Int, from line: [RichRun]) -> String {
        var remaining = count
        var out = ""
        for var run in line {
            if remaining > 0 {
                let drop = min(remaining, run.text.count)
                run.text = String(run.text.dropFirst(drop))
                remaining -= drop
                if run.text.isEmpty { continue }
            }
            var piece = escape(run.text)
            if run.bold { piece = "<b>\(piece)</b>" }
            if run.italic { piece = "<i>\(piece)</i>" }
            if run.underline { piece = "<u>\(piece)</u>" }
            if run.strikethrough { piece = "<s>\(piece)</s>" }
            // Web and mail links only: nothing that runs in the reader's app.
            if let link = run.link, ["http", "https", "mailto"].contains(link.scheme?.lowercased() ?? "") { piece = "<a href=\"\(escape(link.absoluteString))\">\(piece)</a>" }
            out += piece
        }
        return out
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    // MARK: Reopening

    /// `plain`, with the bold, italic, underline, strikethrough and links
    /// that `html` (as `html(_:)` wrote it) gives its words: for an email
    /// opened again to change (Undo Send, Send Later, a saved draft), which
    /// lost its formatting when only its plain text went back in. The runs
    /// always join to exactly `plain`; words the HTML doesn't have (a
    /// signature added since) stay unformatted.
    public static func runs(plain: String, html: String) -> [RichRun] {
        // The HTML's text, piece by piece, each with its style.
        var pieces: [RichRun] = []
        var bold = 0, italic = 0, underline = 0, strike = 0
        var links: [URL?] = []
        var index = html.startIndex
        while index < html.endIndex {
            if html[index] == "<", let close = html[index...].firstIndex(of: ">") {
                let tag = html[html.index(after: index)..<close].lowercased()
                let isEnd = tag.hasPrefix("/")
                let name = tag.drop { $0 == "/" }.prefix { $0.isLetter }
                let step = isEnd ? -1 : 1
                switch name {
                case "b", "strong": bold = max(0, bold + step)
                case "i", "em": italic = max(0, italic + step)
                case "u": underline = max(0, underline + step)
                case "s", "strike", "del": strike = max(0, strike + step)
                case "a":
                    if isEnd { _ = links.popLast() } else {
                        let source = String(html[index...close])
                        let href = source.patternRange(#"(?i)href\s*=\s*"[^"]*""#).map { range -> String in
                            let attribute = source[range]
                            let start = attribute.index(after: attribute.firstIndex(of: "\"")!)
                            return unescape(String(attribute[start..<attribute.index(before: attribute.endIndex)]))
                        }
                        links.append(href.flatMap(URL.init(string:)))
                    }
                default: break
                }
                index = html.index(after: close)
                continue
            }
            let end = html[index...].firstIndex(of: "<") ?? html.endIndex
            let text = unescape(String(html[index..<end]))
            if !text.isEmpty {
                pieces.append(RichRun(text, bold: bold > 0, italic: italic > 0, underline: underline > 0,
                                      strikethrough: strike > 0, link: links.last ?? nil))
            }
            // A "<" with no ">" after it is text.
            index = end == index ? html.index(after: index) : end
        }
        // Each piece found in `plain` in order, from where the last one
        // ended: list bullets and quote marks are in the plain text only.
        var styled: [(range: Range<String.Index>, run: RichRun)] = []
        var cursor = plain.startIndex
        for piece in pieces {
            guard let found = plain.range(of: piece.text, range: cursor..<plain.endIndex) else { continue }
            if piece.isStyled { styled.append((found, piece)) }
            cursor = found.upperBound
        }
        var runs: [RichRun] = []
        var position = plain.startIndex
        for (range, piece) in styled {
            if position < range.lowerBound { runs.append(RichRun(String(plain[position..<range.lowerBound]))) }
            var run = piece
            run.text = String(plain[range])
            runs.append(run)
            position = range.upperBound
        }
        if position < plain.endIndex || runs.isEmpty { runs.append(RichRun(String(plain[position...]))) }
        return runs
    }

    private static func unescape(_ text: String) -> String {
        text.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&nbsp;", with: "\u{00A0}").replacingOccurrences(of: "&amp;", with: "&")
    }
}
