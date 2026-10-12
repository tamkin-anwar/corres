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
    }

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
                    if let data = await loadData(provider, type: movie) {
                        let ext = movie.preferredFilenameExtension ?? "mov"
                        content.files.append(File(filename: name(provider, fallback: "Video \(videos)", ext: ext),
                                                  mimeType: movie.preferredMIMEType ?? "video/quicktime", data: data, isImage: false))
                    }
                } else if types.contains(where: { $0 == .url }), !types.contains(where: { $0 == .fileURL }),
                          let url = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL, !url.isFileURL {
                    if content.link == nil {
                        content.link = Link(url: url, title: title?.isEmpty == false && title != url.absoluteString ? title : nil)
                    } else {
                        content.text += (content.text.isEmpty ? "" : "\n") + url.absoluteString
                    }
                } else if let file = types.first(where: { $0.conforms(to: .data) && !$0.conforms(to: .plainText) && $0 != .url && $0 != .fileURL })
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
        return await withCheckedContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, _ in
                guard let url, let data = try? Data(contentsOf: url) else {
                    continuation.resume(returning: nil)
                    return
                }
                let actual = UTType(filenameExtension: url.pathExtension) ?? type
                let filename = suggested.map { name in
                    (name as NSString).pathExtension.isEmpty && !url.pathExtension.isEmpty ? "\(name).\(url.pathExtension)" : name
                } ?? url.lastPathComponent
                continuation.resume(returning: File(filename: filename, mimeType: actual.preferredMIMEType ?? "application/octet-stream",
                                                    data: data, isImage: false))
            }
        }
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
        case .small: "Small"
        case .medium: "Medium"
        case .large: "Large"
        case .actual: "Actual Size"
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
    func resized(_ data: Data) -> Data {
        guard let maxPixels, let image = UIImage(data: data) else { return data }
        let longest = max(image.size.width * image.scale, image.size.height * image.scale)
        guard longest > maxPixels else { return data }
        let scale = maxPixels / longest
        let size = CGSize(width: (image.size.width * image.scale * scale).rounded(), height: (image.size.height * image.scale * scale).rounded())
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        guard let jpeg = resized.jpegData(compressionQuality: 0.8), jpeg.count < data.count else { return data }
        return jpeg
    }
}
