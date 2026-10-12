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
