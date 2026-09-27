// Renders the App Store icon (1024x1024) and launch marks from the same
// vector view the app draws, so the icon is never an upscaled bitmap.
// Usage: swiftc -parse-as-library DesignSystem/CorrespondenceMark.swift Scripts/RenderIcon.swift -o /tmp/render-icon && /tmp/render-icon App/Assets.xcassets
import AppKit
import SwiftUI

@main
struct RenderIcon {
    @MainActor static func main() throws {
        let assets = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try write(CorresIconArtwork().frame(width: 1024, height: 1024), scale: 1, opaque: true,
                  to: assets.appendingPathComponent("AppIcon.appiconset/icon-1024.png"))
        // Home Screen dark mode draws its own dark field behind a
        // transparent icon; tinted mode tints a grayscale one.
        try write(CorrespondenceMark(glow: false).frame(width: 1110, height: 1110).offset(x: 24)
                    .frame(width: 1024, height: 1024).clipped(), scale: 1, opaque: false,
                  to: assets.appendingPathComponent("AppIcon.appiconset/icon-1024-dark.png"))
        try write(CorrespondenceMark(glow: false).frame(width: 1110, height: 1110).offset(x: 24)
                    .frame(width: 1024, height: 1024).clipped().grayscale(1).brightness(0.15)
                    .background(Color.black), scale: 1, opaque: true,
                  to: assets.appendingPathComponent("AppIcon.appiconset/icon-1024-tinted.png"))
        for scale in 1...3 {
            let suffix = scale == 1 ? "@1x" : "@\(scale)x"
            try write(CorrespondenceMark().frame(width: 96, height: 96), scale: CGFloat(scale), opaque: false,
                      to: assets.appendingPathComponent("LaunchMark.imageset/launch-mark\(suffix).png"))
        }
    }

    @MainActor static func write(_ view: some View, scale: CGFloat, opaque: Bool, to url: URL) throws {
        let renderer = ImageRenderer(content: view)
        renderer.scale = scale
        renderer.isOpaque = opaque
        guard let image = renderer.cgImage else { throw CocoaError(.fileWriteUnknown) }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        try data.write(to: url)
    }
}
