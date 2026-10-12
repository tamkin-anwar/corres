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
        if let match = line.range(of: #"^\d{1,3}\. "#, options: .regularExpression) {
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
}
