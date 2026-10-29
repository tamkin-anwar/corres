import Foundation

/// What kind of file an attachment is, at a glance: a PDF, a Word file, a
/// spreadsheet, a photo, a video. Gmail and Outlook mark each type with
/// its own color and name; a paperclip on every one tells you nothing
/// (tester feedback).
public enum AttachmentKind: String, Sendable, CaseIterable {
    case pdf, word, excel, powerpoint, pages, numbers, keynote, image, video, audio, archive, calendar, contact, text, other

    public init(filename: String, mimeType: String) {
        let ext = (filename as NSString).pathExtension.lowercased()
        let mime = mimeType.lowercased()
        switch true {
        case ext == "pdf" || mime == "application/pdf": self = .pdf
        case ["doc", "docx", "docm", "dot", "dotx", "odt", "rtf"].contains(ext) || mime.contains("wordprocessingml") || mime == "application/msword": self = .word
        case ["xls", "xlsx", "xlsm", "csv", "ods", "tsv"].contains(ext) || mime.contains("spreadsheetml") || mime == "application/vnd.ms-excel" || mime == "text/csv": self = .excel
        case ["ppt", "pptx", "pps", "ppsx", "odp"].contains(ext) || mime.contains("presentationml") || mime == "application/vnd.ms-powerpoint": self = .powerpoint
        case ext == "pages": self = .pages
        case ext == "numbers": self = .numbers
        case ext == "key": self = .keynote
        case mime.hasPrefix("image/") || ["jpg", "jpeg", "png", "gif", "heic", "heif", "webp", "tif", "tiff", "bmp"].contains(ext): self = .image
        case mime.hasPrefix("video/") || ["mov", "mp4", "m4v", "avi", "mkv", "webm"].contains(ext): self = .video
        case mime.hasPrefix("audio/") || ["mp3", "m4a", "wav", "aac", "aiff", "caf", "ogg", "flac"].contains(ext): self = .audio
        case ["zip", "rar", "7z", "gz", "tar", "tgz"].contains(ext) || mime.contains("zip") || mime.contains("compressed"): self = .archive
        case ext == "ics" || mime.hasPrefix("text/calendar"): self = .calendar
        case ["vcf", "vcard"].contains(ext) || mime.contains("vcard"): self = .contact
        case mime.hasPrefix("text/") || ["txt", "md", "log", "json", "xml", "html", "htm"].contains(ext): self = .text
        default: self = .other
        }
    }

    /// "PDF", "Word", "Excel": said before the size ("PDF · 168 KB").
    public func label(filename: String) -> String {
        switch self {
        case .pdf: "PDF"
        case .word: "Word"
        case .excel: (filename as NSString).pathExtension.lowercased() == "csv" ? "CSV" : "Excel"
        case .powerpoint: "PowerPoint"
        case .pages: "Pages"
        case .numbers: "Numbers"
        case .keynote: "Keynote"
        case .image: "Image"
        case .video: "Video"
        case .audio: "Audio"
        case .archive: "ZIP"
        case .calendar: "Invitation"
        case .contact: "Contact"
        case .text: "Text"
        case .other:
            (filename as NSString).pathExtension.isEmpty ? "File" : (filename as NSString).pathExtension.uppercased()
        }
    }

    /// Worth showing a real preview of (its first page, the photo itself).
    public var hasPreview: Bool { [.pdf, .image, .word, .excel, .powerpoint, .pages, .numbers, .keynote, .video].contains(self) }
}

/// Images an HTML body carries with it, as MIME parts it refers to by
/// "cid:" (RFC 2392) rather than by a web address. A web view can't load
/// "cid:" at all, so each is swapped for its bytes as a data: URI, the way
/// Gmail and Mail show them. Senders write the reference loosely, so it's
/// matched the way those apps match it: any case, "%40" for "@", with or
/// without the angle brackets, and in `src`, `background` and CSS `url()`.
public enum InlineImages {
    public struct Image: Sendable {
        public let contentID: String?
        public let filename: String?
        public let dataURI: String

        public init(contentID: String?, filename: String?, dataURI: String) {
            self.contentID = contentID
            self.filename = filename
            self.dataURI = dataURI
        }
    }

    /// A reference ends at a quote, a bracket, a space or an entity
    /// (`url(&quot;cid:…&quot;)` in a style attribute).
    static let referencePattern = #"\bcid:([^\s"'()<>\\&;]+)"#

    /// A Content-ID header value or a cid: reference, in the one form both
    /// are compared in.
    public static func normalized(_ contentID: String) -> String {
        let trimmed = contentID.trimmingCharacters(in: .whitespacesAndNewlines)
        let decoded = trimmed.removingPercentEncoding ?? trimmed
        return decoded.trimmingCharacters(in: CharacterSet(charactersIn: "<> \t\r\n")).lowercased()
    }

    /// Every image the HTML refers to by cid:, normalized, in order.
    public static func references(in html: String) -> [String] {
        guard html.range(of: "cid:", options: .caseInsensitive) != nil,
              let regex = PatternCache.shared.regex(referencePattern, caseInsensitive: true) else { return [] }
        var seen = Set<String>()
        return regex.matches(in: html, range: NSRange(html.startIndex..., in: html)).compactMap { match in
            guard let range = Range(match.range(at: 1), in: html) else { return nil }
            let reference = normalized(String(html[range]))
            return seen.insert(reference).inserted ? reference : nil
        }
    }

    /// Whether a part with this Content-ID (or, without one, this file
    /// name) is the one a reference means. Outlook names its pictures
    /// "image001.png@01DD…", so a part that lost its Content-ID is still
    /// found by its file name.
    public static func matches(_ reference: String, contentID: String?, filename: String?) -> Bool {
        if let contentID, !normalized(contentID).isEmpty { return normalized(contentID) == reference }
        guard let filename, !filename.isEmpty else { return false }
        let name = filename.lowercased()
        return reference == name || reference.split(separator: "@").first.map(String.init) == name
    }

    /// Whether a part is one the HTML shows in place, so it isn't also
    /// listed as an attachment.
    public static func isReferenced(contentID: String?, filename: String?, in references: [String]) -> Bool {
        references.contains { matches($0, contentID: contentID, filename: filename) }
    }

    /// The HTML with each reference it has an image for replaced by that
    /// image. One without (not downloaded, or not in the email at all) is
    /// left as "cid:…", which the reading view can't load and treats as a
    /// missing picture.
    public static func resolving(_ html: String, with images: [Image]) -> String {
        guard !images.isEmpty, html.range(of: "cid:", options: .caseInsensitive) != nil,
              let regex = PatternCache.shared.regex(referencePattern, caseInsensitive: true) else { return html }
        let found = regex.matches(in: html, range: NSRange(html.startIndex..., in: html))
        guard !found.isEmpty else { return html }
        var result = html
        // From the end, so the ranges before it stay where they were.
        for match in found.reversed() {
            guard let whole = Range(match.range, in: result), let idRange = Range(match.range(at: 1), in: result) else { continue }
            let reference = normalized(String(result[idRange]))
            // An exact Content-ID first, then a file name.
            guard let image = images.first(where: { $0.contentID.map(normalized) == reference })
                    ?? images.first(where: { matches(reference, contentID: nil, filename: $0.filename) }) else { continue }
            result.replaceSubrange(whole, with: image.dataURI)
        }
        return result
    }

    /// A data: URI for an image part. A part labelled only
    /// "application/octet-stream" is named by its file extension, or
    /// WebKit may not draw it.
    public static func dataURI(base64: String, mimeType: String?, filename: String?) -> String {
        "data:\(imageType(mimeType: mimeType, filename: filename));base64,\(base64)"
    }

    static func imageType(mimeType: String?, filename: String?) -> String {
        let type = (mimeType ?? "").split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        if type.hasPrefix("image/") { return type }
        let types = ["png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif", "webp": "image/webp",
                     "bmp": "image/bmp", "svg": "image/svg+xml", "heic": "image/heic", "tif": "image/tiff", "tiff": "image/tiff"]
        let ext = ((filename ?? "") as NSString).pathExtension.lowercased()
        return types[ext] ?? (type.isEmpty ? "application/octet-stream" : type)
    }
}

/// A message's MIME structure, only as far as choosing what to show needs
/// it: Gmail's API hands it over as a tree of parts.
public struct MIMEOutline: Sendable {
    public var mimeType: String
    public var disposition: String?
    public var filename: String?
    public var children: [MIMEOutline]

    public init(mimeType: String, disposition: String? = nil, filename: String? = nil, children: [MIMEOutline] = []) {
        self.mimeType = mimeType.lowercased()
        self.disposition = disposition?.trimmingCharacters(in: .whitespaces).lowercased()
        self.filename = filename
        self.children = children
    }

    /// Sent as a file to save, not as part of the text.
    var isAttachment: Bool {
        (disposition ?? "").hasPrefix("attachment") || !(filename ?? "").isEmpty
    }
}

/// Which parts of a message are its text, read the way Mail and
/// Thunderbird read it (RFC 2046): of alternatives, the last one that can
/// be shown, HTML before plain text; of a multipart/related, its first
/// part; of a multipart/mixed, every part in turn. An email from Apple's
/// Mail with a file in the middle is HTML, the file, then more HTML, and a
/// mailing list adds its footer as a part of its own; taking only the
/// first text part left the rest of those emails out.
public enum MessageLayout {
    public enum Kind: Sendable { case html, plain }

    public struct Piece: Sendable, Equatable {
        public let path: [Int]
        public let kind: Kind
    }

    public static func pieces(of root: MIMEOutline) -> [Piece] {
        let found = displayed(root, path: [], depth: 0)
        guard found.isEmpty else { return found }
        // Nothing shown by those rules (a forwarded message on its own, or a
        // body labelled as a file): the first text anywhere, as before.
        return firstLeaf(root, type: "text/html", path: []).map { [Piece(path: $0, kind: .html)] }
            ?? firstLeaf(root, type: "text/plain", path: []).map { [Piece(path: $0, kind: .plain)] } ?? []
    }

    private static func displayed(_ part: MIMEOutline, path: [Int], depth: Int) -> [Piece] {
        guard depth < 30 else { return [] }
        if part.mimeType.hasPrefix("multipart/") {
            let children = part.children.enumerated().map { displayed($1, path: path + [$0], depth: depth + 1) }
            switch part.mimeType {
            case "multipart/alternative":
                let options = children.filter { !$0.isEmpty }
                return options.last { $0.contains { $0.kind == .html } } ?? options.last ?? []
            case "multipart/related":
                // The root is the first part (RFC 2387); the rest are what it
                // refers to.
                return children.first { !$0.isEmpty } ?? []
            default:
                return children.flatMap { $0 }
            }
        }
        guard !part.isAttachment else { return [] }
        switch part.mimeType {
        case "text/html": return [Piece(path: path, kind: .html)]
        case "text/plain", "": return [Piece(path: path, kind: .plain)]
        default: return []
        }
    }

    private static func firstLeaf(_ part: MIMEOutline, type: String, path: [Int]) -> [Int]? {
        if part.mimeType == type, !(part.disposition ?? "").hasPrefix("attachment") { return path }
        for (index, child) in part.children.enumerated() {
            if let found = firstLeaf(child, type: type, path: path + [index]) { return found }
        }
        return nil
    }

    /// The pieces' text as one HTML body, in order: a plain-text piece
    /// between HTML ones is set as text, and each piece after the first
    /// goes inside the first one's body. Nil when there's no HTML at all,
    /// so plain-text mail stays plain text.
    public static func html(joining pieces: [(kind: Kind, text: String)]) -> String? {
        guard pieces.contains(where: { $0.kind == .html }) else { return nil }
        var result = ""
        for piece in pieces {
            let html = piece.kind == .html ? piece.text : PlainTextEmail.html(from: piece.text)
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

    /// The charset an HTML part names in its own `<meta>` tag, for one
    /// whose header doesn't: `<meta charset="shift_jis">` or the older
    /// `<meta http-equiv="Content-Type" content="text/html; charset=…">`.
    /// Only the start is read, as a browser does.
    public static func metaCharset(in data: Data) -> String? {
        let head = String(decoding: data.prefix(4096), as: UTF8.self)
        guard let regex = PatternCache.shared.regex(#"<meta[^>]{0,200}?charset\s*=\s*["']?\s*([A-Za-z0-9_\-:.]+)"#, caseInsensitive: true),
              let match = regex.firstMatch(in: head, range: NSRange(head.startIndex..., in: head)),
              let range = Range(match.range(at: 1), in: head) else { return nil }
        return String(head[range])
    }

    /// The plain-text pieces as one text.
    public static func plain(joining pieces: [(kind: Kind, text: String)]) -> String? {
        let texts = pieces.filter { $0.kind == .plain }.map(\.text)
        return texts.isEmpty ? nil : texts.joined(separator: "\n\n")
    }
}
