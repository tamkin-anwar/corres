// Renders the App Store icon (1024x1024) and launch marks from the same
// vector view the app draws, so the icon is never an upscaled bitmap.
// Usage: swiftc -parse-as-library DesignSystem/CorrespondenceMark.swift Scripts/RenderIcon.swift -o /tmp/render-icon && /tmp/render-icon App/Assets.xcassets
import AppKit
import SwiftUI

@main
struct RenderIcon {
    @MainActor static func main() throws {
        let assets = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        // The obsidian icon in Light and Dark alike: it is Corres's
        // identity, the way Wallet and Stocks keep their dark tiles. Tinted:
        // iOS tints a grayscale mark.
        try writeIcon(CorresIconArtwork().frame(width: 1024, height: 1024),
                      to: assets.appendingPathComponent("AppIcon.appiconset/icon-1024.png"))
        try writeIcon(CorresIconArtwork().frame(width: 1024, height: 1024),
                      to: assets.appendingPathComponent("AppIcon.appiconset/icon-1024-dark.png"))
        try writeIcon(CorrespondenceMark(glow: false, field: .dark).frame(width: 1110, height: 1110).offset(x: 24)
                        .frame(width: 1024, height: 1024).clipped().grayscale(1).brightness(0.15)
                        .background(Color.black), grain: false,
                      to: assets.appendingPathComponent("AppIcon.appiconset/icon-1024-tinted.png"))
        // Brand exports for the README and the studio site.
        let brand = assets.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Docs/Brand")
        try write(CorresIconArtwork().frame(width: 1024, height: 1024)
                    .clipShape(RoundedRectangle(cornerRadius: 230, style: .continuous))
                    .padding(8), scale: 1, opaque: false,
                  to: brand.appendingPathComponent("corres-icon.png"))
        try write(CorresHeroArtwork().frame(width: 1200, height: 1200), scale: 2, opaque: true,
                  to: brand.appendingPathComponent("corres-hero.png"))
        // The launch screen is ivory in Light and obsidian in Dark; each
        // gets the mark drawn for its field.
        for scale in 1...3 {
            let suffix = scale == 1 ? "@1x" : "@\(scale)x"
            try write(CorrespondenceMark(field: .light).frame(width: 96, height: 96), scale: CGFloat(scale), opaque: false,
                      to: assets.appendingPathComponent("LaunchMark.imageset/launch-mark\(suffix).png"))
            try write(CorrespondenceMark(field: .dark).frame(width: 96, height: 96), scale: CGFloat(scale), opaque: false,
                      to: assets.appendingPathComponent("LaunchMark.imageset/launch-mark-dark\(suffix).png"))
        }
    }

    @MainActor static func write(_ view: some View, scale: CGFloat, opaque: Bool, to url: URL) throws {
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        renderer.isOpaque = opaque
        guard let image = renderer.cgImage else { throw CocoaError(.fileWriteUnknown) }
        try writePNG(image, to: url)
    }

    /// App icons: drawn at 4x (4096px), then reduced to 1024 with
    /// high-quality filtering, so every curve and highlight is supersampled
    /// rather than edge-aliased; a fine, invisible grain (±1 level) breaks
    /// up banding in the dark gradients. 1024 is the largest icon iOS
    /// accepts; it scales this one file down for every Home Screen size.
    @MainActor static func writeIcon(_ view: some View, side: Int = 1024, grain: Bool = true, to url: URL) throws {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 4
        renderer.isOpaque = true
        guard let big = renderer.cgImage,
              let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw CocoaError(.fileWriteUnknown) }
        context.interpolationQuality = .high
        context.draw(big, in: CGRect(x: 0, y: 0, width: side, height: side))
        if grain, let pixels = context.data?.assumingMemoryBound(to: UInt8.self) {
            var seed: UInt64 = 0x9E3779B97F4A7C15
            for i in 0..<(side * side) {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                let offset = Int((seed >> 33) % 3) - 1
                for c in 0..<3 {
                    let index = i * 4 + c
                    pixels[index] = UInt8(clamping: Int(pixels[index]) + offset)
                }
            }
        }
        guard let image = context.makeImage() else { throw CocoaError(.fileWriteUnknown) }
        try writePNG(image, to: url)
    }

    static func writePNG(_ image: CGImage, to url: URL) throws {
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: url)
    }
}
