import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers

/// A file dropped onto an email you're writing (iPad): from Files, Photos,
/// Safari or another window, copied in as an attachment.
struct DroppedFile: Transferable {
    let filename: String
    let mimeType: String
    let data: Data

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .item) { received in
            let url = received.file
            let type = UTType(filenameExtension: url.pathExtension)
            return DroppedFile(filename: url.lastPathComponent,
                               mimeType: type?.preferredMIMEType ?? "application/octet-stream",
                               data: try Data(contentsOf: url))
        }
    }
}

/// A conversation dragged out of the list into Notes, Reminders or a
/// message: who it's from, the subject, and a link that opens it in Corres.
struct ConversationDrag: Transferable {
    let sender: String
    let subject: String
    let link: URL

    static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation(exporting: \.link)
        ProxyRepresentation { (drag: ConversationDrag) in
            "\(drag.sender): \(drag.subject)\n\(drag.link.absoluteString)"
        }
    }
}
