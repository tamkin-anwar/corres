import CryptoKit
import SwiftUI

/// The account button's face: the person's own Google profile photo in a
/// circle, the convention in Gmail and in Apple's own apps (App Store,
/// Music, Photos). Before a photo is available, or if the account has
/// none, a two-letter monogram on a filled circle, never a bare letter.
struct AccountAvatar: View {
    let email: String?
    let name: String?
    let photoURL: URL?
    var size: CGFloat = 32
    @State private var image: UIImage?
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
            } else {
                Circle().fill(LinearGradient(colors: [CorresPalette.accent.opacity(0.9), CorresPalette.accent.opacity(0.55)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                if email == nil && (name ?? "").isEmpty {
                    Image(systemName: "person.fill")
                        .font(.system(size: size * 0.46, weight: .medium))
                        .foregroundStyle(CorresPalette.accentInk)
                } else {
                    Text(initials)
                        .font(.system(size: size * 0.38, weight: .semibold))
                        .foregroundStyle(CorresPalette.accentInk)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(CorresPalette.line, lineWidth: 1 / displayScale))
        .task(id: photoURL) { image = await ProfilePhotoCache.shared.image(for: photoURL) }
        .accessibilityHidden(true)
    }

    private var initials: String {
        if let name, !name.isEmpty {
            let parts = name.split(separator: " ").prefix(2).compactMap(\.first)
            if !parts.isEmpty { return String(parts).uppercased() }
        }
        return email?.first.map { String($0).uppercased() } ?? "·"
    }
}

/// Profile photos cached on disk (Caches), so the avatar is there
/// instantly on every launch and offline, and only fetched once per URL.
actor ProfilePhotoCache {
    static let shared = ProfilePhotoCache()
    private var memory: [URL: UIImage] = [:]

    func image(for url: URL?) async -> UIImage? {
        guard let url else { return nil }
        if let cached = memory[url] { return cached }
        let file = Self.fileURL(for: url)
        if let data = try? Data(contentsOf: file), let image = UIImage(data: data) {
            memory[url] = image
            return image
        }
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let image = UIImage(data: data) else { return nil }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
        memory[url] = image
        return image
    }

    private static func fileURL(for url: URL) -> URL {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ProfilePhotos", isDirectory: true)
            .appendingPathComponent(digest + ".img")
    }
}
