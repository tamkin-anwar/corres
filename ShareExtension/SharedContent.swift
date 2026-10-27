import ImageIO
import LinkPresentation
import UIKit
import UniformTypeIdentifiers

/// What was shared, read from the share sheet's items: photos and videos,
/// files, a web page, or text. Photos keep their original until you pick
/// a size, the way Mail offers Small / Medium / Large / Actual Size.
struct SharedContent {
    struct File: Identifiable {
        let id = UUID()
        var filename: String
        var mimeType: String
        var data: Data
        var isImage: Bool
        var thumbnail: UIImage?
        /// A file too big for any service to carry is left unread (`data`
        /// stays empty), only its size kept so the sheet can say so: a long
        /// video read whole used up the little memory a Share sheet gets,
        /// and it closed.
        var unreadSize: Int?
        var size: Int { unreadSize ?? data.count }
    }

    /// The most any service takes in one email (`MailProvider.attachmentLimit`).
    static let largestSendable = [MailProvider.google, .microsoft, .icloud, .imap].map(\.attachmentLimit).max() ?? 25_000_000

    struct Link {
        let url: URL
        var title: String?
        var metadata: LPLinkMetadata?
    }

    var files: [File] = []
    var link: Link?
    var text = ""

    /// A page's title, or a single document's name: what Mail puts in the
    /// subject. Photos are left for you to name.
    var suggestedSubject: String {
        if let title = link?.title, !title.isEmpty { return title }
        if files.count == 1, let file = files.first, !file.isImage, !file.mimeType.hasPrefix("video/") {
            return (file.filename as NSString).deletingPathExtension
        }
        return ""
    }

    @MainActor
    static func load(from items: [NSExtensionItem]) async -> SharedContent {
        var content = SharedContent()
        var photos = 0, videos = 0
        for item in items {
            // Safari passes the page's title here.
            let title = item.attributedContentText?.string.trimmingCharacters(in: .whitespacesAndNewlines)
            for provider in item.attachments ?? [] {
                let types = provider.registeredTypeIdentifiers.compactMap(UTType.init)
                if let image = types.first(where: { $0.conforms(to: .image) }) {
                    photos += 1
                    if let file = await loadImage(provider, type: image, number: photos) { content.files.append(file) }
                } else if let movie = types.first(where: { $0.conforms(to: .movie) || $0.conforms(to: .audiovisualContent) }) {
                    videos += 1
                    if let read = await loadFileData(provider, type: movie) {
                        let ext = movie.preferredFilenameExtension ?? "mov"
                        content.files.append(File(filename: name(provider, fallback: "Video \(videos)", ext: ext),
                                                  mimeType: movie.preferredMIMEType ?? "video/quicktime", data: read.data, isImage: false,
                                                  unreadSize: read.unreadSize))
                    }
                } else if types.contains(where: { $0 == .url }), !types.contains(where: { $0 == .fileURL }),
                          let url = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL, !url.isFileURL {
                    if content.link == nil {
                        content.link = Link(url: url, title: title?.isEmpty == false && title != url.absoluteString ? title : nil)
                    } else {
                        content.text += (content.text.isEmpty ? "" : "\n") + url.absoluteString
                    }
                } else if !isDocument(provider, types: types), !types.contains(where: { $0.conforms(to: .vCard) }),
                          types.contains(where: { $0.conforms(to: .text) }) {
                    // Words (a note, a selection, rich text): into the message,
                    // never attached as an .rtf. A text file (a .txt from
                    // Files) is attached, as Mail does.
                    if let text = await loadText(provider, types: types), !text.isEmpty {
                        content.text += (content.text.isEmpty ? "" : "\n\n") + text
                    }
                } else if let file = types.first(where: { $0.conforms(to: .data) && $0 != .url && $0 != .fileURL })
                            ?? types.first(where: { $0 == .fileURL }) {
                    if let loaded = await loadFile(provider, type: file) { content.files.append(loaded) }
                } else if types.contains(where: { $0.conforms(to: .text) }),
                          let text = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String {
                    content.text += (content.text.isEmpty ? "" : "\n\n") + text
                }
            }
            // Text shared on its own (a note, a selection) comes as the item's text.
            if content.files.isEmpty, content.link == nil, content.text.isEmpty, let title, !title.isEmpty {
                content.text = title
            }
        }
        return content
    }

    /// The page's title and image, for the preview card.
    static func fetchMetadata(for url: URL) async -> LPLinkMetadata? {
        let provider = LPMetadataProvider()
        provider.timeout = 6
        return try? await provider.startFetchingMetadata(for: url)
    }

    // MARK: Loading

    /// A file rather than words: Files hands over a .txt as plain text with
    /// no file URL, so its name ("notes.txt") or an open-in-place copy is
    /// what says it's a document. A selection or a note has neither.
    @MainActor
    private static func isDocument(_ provider: NSItemProvider, types: [UTType]) -> Bool {
        if types.contains(.fileURL) || !provider.registeredContentTypesForOpenInPlace.isEmpty { return true }
        guard let name = provider.suggestedName, !(name as NSString).pathExtension.isEmpty else { return false }
        return UTType(filenameExtension: (name as NSString).pathExtension)?.conforms(to: .text) == true
    }

    @MainActor
    private static func name(_ provider: NSItemProvider, fallback: String, ext: String) -> String {
        guard let suggested = provider.suggestedName, !suggested.isEmpty else { return "\(fallback).\(ext)" }
        return (suggested as NSString).pathExtension.isEmpty ? "\(suggested).\(ext)" : suggested
    }

    /// iPhone photos are HEIC, which plenty of mail apps and Windows can't
    /// open; Mail sends them as JPEG, and so does Corres.
    @MainActor
    private static func loadImage(_ provider: NSItemProvider, type: UTType, number: Int) async -> File? {
        var data = await loadData(provider, type: type)
        if data == nil, let image = try? await provider.loadItem(forTypeIdentifier: type.identifier) as? UIImage {
            data = image.jpegData(compressionQuality: 0.85)
        }
        guard var data else { return nil }
        var ext = type.preferredFilenameExtension ?? "jpg"
        var mime = type.preferredMIMEType ?? "image/jpeg"
        let image = UIImage(data: data)
        if type.conforms(to: .heic) || type.conforms(to: .heif), let jpeg = image?.jpegData(compressionQuality: 0.85) {
            data = jpeg
            ext = "jpg"
            mime = "image/jpeg"
        }
        var filename = name(provider, fallback: "Photo \(number)", ext: ext)
        if ext == "jpg", !["jpg", "jpeg"].contains((filename as NSString).pathExtension.lowercased()) {
            filename = (filename as NSString).deletingPathExtension + ".jpg"
        }
        return File(filename: filename, mimeType: mime, data: data, isImage: true,
                    thumbnail: image?.preparingThumbnail(of: CGSize(width: 180, height: 180)))
    }

    @MainActor
    private static func loadFile(_ provider: NSItemProvider, type: UTType) async -> File? {
        let suggested = provider.suggestedName
        guard let read = await loadFileData(provider, type: type) else { return nil }
        let url = read.url
        let actual = UTType(filenameExtension: url.pathExtension) ?? type
        let filename = suggested.map { name in
            (name as NSString).pathExtension.isEmpty && !url.pathExtension.isEmpty ? "\(name).\(url.pathExtension)" : name
        } ?? url.lastPathComponent
        return File(filename: filename, mimeType: actual.preferredMIMEType ?? "application/octet-stream",
                    data: read.data, isImage: false, unreadSize: read.unreadSize)
    }

    /// A file's contents, from the copy the provider hands over. Too big to
    /// send anywhere: its size only (see `File.unreadSize`).
    @MainActor
    private static func loadFileData(_ provider: NSItemProvider, type: UTType) async -> (data: Data, unreadSize: Int?, url: URL)? {
        await withCheckedContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, _ in
                guard let url else {
                    continuation.resume(returning: nil)
                    return
                }
                if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > largestSendable {
                    continuation.resume(returning: (Data(), size, url))
                    return
                }
                guard let data = try? Data(contentsOf: url) else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: (data, nil, url))
            }
        }
    }

    @MainActor
    private static func loadText(_ provider: NSItemProvider, types: [UTType]) async -> String? {
        if types.contains(where: { $0.conforms(to: .plainText) }),
           let text = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        for (type, document) in [(UTType.rtf, NSAttributedString.DocumentType.rtf), (.html, .html)] where types.contains(where: { $0.conforms(to: type) }) {
            if let data = await loadData(provider, type: type),
               let string = try? NSAttributedString(data: data, options: [.documentType: document], documentAttributes: nil) {
                return string.string.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }

    @MainActor
    private static func loadData(_ provider: NSItemProvider, type: UTType) async -> Data? {
        await withCheckedContinuation { continuation in
            _ = provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, _ in
                continuation.resume(returning: data)
            }
        }
    }
}

/// Photo sizes, as Mail offers them. Longest side in pixels.
enum PhotoSize: String, CaseIterable, Identifiable {
    case small, medium, large, actual
    var id: Self { self }

    var title: String {
        switch self {
        case .small: String(localized: "Small")
        case .medium: String(localized: "Medium")
        case .large: String(localized: "Large")
        case .actual: String(localized: "Actual Size")
        }
    }

    var maxPixels: CGFloat? {
        switch self {
        case .small: 640
        case .medium: 1280
        case .large: 2048
        case .actual: nil
        }
    }

    /// The photo at this size, as JPEG (never larger than the original).
    /// Scaled as it's read, never drawn at full size first: each full
    /// 12- or 48-megapixel decode, three sizes for every photo, took more
    /// memory than the Share sheet is allowed.
    func resized(_ data: Data) -> Data {
        guard let maxPixels, let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              max(width, height) > maxPixels else { return data }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        let jpeg = autoreleasepool { () -> Data? in
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            return UIImage(cgImage: image).jpegData(compressionQuality: 0.8)
        }
        guard let jpeg, jpeg.count < data.count else { return data }
        return jpeg
    }
}
