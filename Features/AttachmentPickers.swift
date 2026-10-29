import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import VisionKit

/// The camera, for Compose → Attach → Take Photo. Hidden where there's no
/// camera (the Simulator, some iPads).
struct CameraPicker: UIViewControllerRepresentable {
    let onPhoto: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    static var isAvailable: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor
    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { parent.onPhoto(image) }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}

/// Compose → Attach → Scan Document: Apple's scanner, saved as one PDF.
struct DocumentScanner: UIViewControllerRepresentable {
    let onScan: (Data) -> Void
    @Environment(\.dismiss) private var dismiss

    static var isAvailable: Bool { VNDocumentCameraViewController.isSupported }

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let scanner = VNDocumentCameraViewController()
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ controller: VNDocumentCameraViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor
    final class Coordinator: NSObject, @preconcurrency VNDocumentCameraViewControllerDelegate {
        let parent: DocumentScanner
        init(_ parent: DocumentScanner) { self.parent = parent }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            let pages = (0..<scan.pageCount).map { scan.imageOfPage(at: $0) }
            if let pdf = Self.pdf(from: pages) { parent.onScan(pdf) }
            parent.dismiss()
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) { parent.dismiss() }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) {
            parent.dismiss()
        }

        /// Each page at its own shape, no bigger than the paper used where
        /// you are: US Letter in the US, A4 everywhere else.
        nonisolated static func pdf(from pages: [UIImage]) -> Data? {
            guard !pages.isEmpty else { return nil }
            let paper = Locale.current.measurementSystem == .us ? CGSize(width: 612, height: 792) : CGSize(width: 595, height: 842)
            let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: paper))
            return renderer.pdfData { context in
                for page in pages {
                    let scale = min(paper.width / page.size.width, paper.height / page.size.height)
                    let size = CGSize(width: page.size.width * scale, height: page.size.height * scale)
                    context.beginPage(withBounds: CGRect(origin: .zero, size: size), pageInfo: [:])
                    page.draw(in: CGRect(origin: .zero, size: size))
                }
            }
        }
    }
}

/// Turning picked media into attachments people can open anywhere.
enum AttachmentFiles {
    /// iPhone photos are HEIC, which plenty of mail apps and Windows can't
    /// open; Mail sends them as JPEG, and so does Corres. Other images and
    /// videos go as they are.
    static func fromPhotosItem(_ item: PhotosPickerItem, number: Int) async -> (filename: String, mimeType: String, data: Data)? {
        guard let data = try? await item.loadTransferable(type: Data.self) else { return nil }
        let type = item.supportedContentTypes.first
        if let type, type.conforms(to: .image) {
            if type.conforms(to: .heic) || type.conforms(to: .heif) || type == UTType("public.heic"),
               let jpeg = UIImage(data: data)?.jpegData(compressionQuality: 0.85) {
                return (name(.photo, number, "jpg"), "image/jpeg", jpeg)
            }
            let ext = type.preferredFilenameExtension ?? "jpg"
            return (name(.photo, number, ext), type.preferredMIMEType ?? "image/jpeg", data)
        }
        let ext = type?.preferredFilenameExtension ?? "mov"
        return (name(.video, number, ext), type?.preferredMIMEType ?? "video/quicktime", data)
    }

    /// A photo made smaller to fit under Gmail's 25 MB limit, the way Mail
    /// offers "Large" (longest side 2,048 pixels, still sharp on any
    /// screen). Nil if it isn't a picture.
    static func shrunk(_ data: Data, maxPixels: CGFloat = 2048) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let longest = max(image.size.width * image.scale, image.size.height * image.scale)
        let scale = min(1, maxPixels / longest)
        let size = CGSize(width: image.size.width * image.scale * scale, height: image.size.height * image.scale * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
        return resized.jpegData(compressionQuality: 0.8)
    }

    enum Kind { case photo, video, scan }

    /// "Photo 3.jpg", in the person's language ("写真 3.jpg").
    static func name(_ kind: Kind, _ number: Int, _ ext: String) -> String {
        let base = switch kind {
        case .photo: String(localized: "Photo \(number)")
        case .video: String(localized: "Video \(number)")
        case .scan: String(localized: "Scan \(number)")
        }
        return "\(base).\(ext)"
    }

    static func fromCamera(_ image: UIImage, number: Int) -> (filename: String, mimeType: String, data: Data)? {
        guard let jpeg = image.jpegData(compressionQuality: 0.85) else { return nil }
        return (name(.photo, number, "jpg"), "image/jpeg", jpeg)
    }

    /// A file from Files, downloaded first if it's in iCloud Drive but not
    /// on this iPhone yet (a plain read fails on those).
    static func read(_ url: URL) -> Data? {
        guard url.startAccessingSecurityScopedResource() else { return nil }
        defer { url.stopAccessingSecurityScopedResource() }
        var data: Data?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [.withoutChanges], error: &coordinationError) { readable in
            data = try? Data(contentsOf: readable)
        }
        return data
    }
}
