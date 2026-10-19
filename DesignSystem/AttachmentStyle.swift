import SwiftUI

/// How each kind of attachment is marked, by colour and short tag, on
/// every device.
extension AttachmentKind {
    var color: Color {
        switch self {
        case .pdf: Color(hex: 0xD93025)
        case .word, .pages: Color(hex: 0x2B579A)
        case .excel, .numbers: Color(hex: 0x217346)
        case .powerpoint, .keynote: Color(hex: 0xC43E1C)
        case .image: Color(hex: 0x7A4FD0)
        case .video: Color(hex: 0xC2185B)
        case .audio: Color(hex: 0xD9730D)
        case .calendar: CorresPalette.accent
        case .archive, .contact, .text, .other: Color(hex: 0x6B7280)
        }
    }

    /// On a document's preview: "PDF", "DOC", "XLS", "PPT".
    var tag: String? {
        switch self {
        case .pdf: "PDF"
        case .word: "DOC"
        case .excel: "XLS"
        case .powerpoint: "PPT"
        case .pages: "PAGES"
        case .numbers: "NUM"
        case .keynote: "KEY"
        default: nil
        }
    }

    var symbol: String {
        switch self {
        case .pdf: "doc.richtext.fill"
        case .word, .pages: "doc.text.fill"
        case .excel, .numbers: "tablecells.fill"
        case .powerpoint, .keynote: "rectangle.on.rectangle.angled.fill"
        case .image: "photo.fill"
        case .video: "play.rectangle.fill"
        case .audio: "waveform"
        case .archive: "doc.zipper"
        case .calendar: "calendar"
        case .contact: "person.crop.square.fill"
        case .text: "doc.plaintext.fill"
        case .other: "doc.fill"
        }
    }
}
