// Native SwiftUI component renders, not iOS Simulator screenshots.
//
// CAUTION: CorresPalette's colors now live in App/Assets.xcassets Color Sets
// (moved off UIColor trait closures to fix a real dark-mode redraw bug; see
// Tokens.swift). If this script is ever run as a bare executable outside an
// app bundle with that catalog compiled in, Color("name") lookups will not
// resolve and previews will render with fallback/incorrect colors. Run it
// through a target that has Assets.xcassets in its bundle, or update it to
// load the compiled .car explicitly, before trusting its output again.
import AppKit
import SwiftUI

@main
struct RenderDesign {
    @MainActor static func main() async throws {
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let store = MailStore(repository: SampleMailRepository())
        await store.load()
        for scheme in [ColorScheme.light, .dark] {
            let name = scheme == .light ? "light" : "dark"
            NSApplication.shared.appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)
            try render(BriefView(scrolls: false, store: store, selection: .constant(.brief), showingScreener: .constant(false)),
                       scheme: scheme, width: 393, height: 1550,
                       to: output.appendingPathComponent("brief-\(name).png"))
            try render(WelcomeView(scrolls: false, onExplore: {}), scheme: scheme, width: 393, height: 1100,
                       to: output.appendingPathComponent("welcome-\(name).png"))
        }
        try render(CorrespondenceList(scrolls: false, store: store, destination: .waiting),
                   scheme: .light, width: 393, height: 1000,
                   to: output.appendingPathComponent("waiting-light.png"))
        try render(CorrespondenceList(scrolls: false, store: store, destination: .needsYou),
                   scheme: .light, width: 393, height: 1200,
                   to: output.appendingPathComponent("needs-you-light.png"))
        try render(CorrespondenceSculpture(exportQuality: true).padding(180).background(InkMaterial(radius: 0)),
                   scheme: .dark, width: 1280, height: 1280,
                   to: output.appendingPathComponent("sculpture-4k.png"))
        try render(BriefView(scrolls: false, store: store, selection: .constant(.brief), showingScreener: .constant(false))
            .environment(\.dynamicTypeSize, .accessibility3), scheme: .light,
                   width: 320, height: 1900, to: output.appendingPathComponent("brief-large-text.png"))
        print("Rendered eight SwiftUI component previews at 3x. These exclude iOS system chrome.")
    }

    @MainActor static func render<V: View>(_ view: V, scheme: ColorScheme,
                                          width: CGFloat, height: CGFloat, to url: URL) throws {
        let content = view
            .frame(width: width, height: height, alignment: .top)
            .foregroundStyle(CorresPalette.ink)
            .background(CorresPalette.canvas)
            .environment(\.colorScheme, scheme)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 3
        guard let image = renderer.cgImage else { throw RenderError.noImage }
        let bitmap = NSBitmapImageRep(cgImage: image)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { throw RenderError.noImage }
        try data.write(to: url)
    }

    enum RenderError: Error { case noImage }
}
