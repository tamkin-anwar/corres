import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Two open, opposing arcs: an exchange with space left for the other person.
/// Native paths remain sharp at every display scale; no raster upscaling.
struct CorrespondenceMark: View {
    var sculpted = false

    var body: some View {
        if sculpted {
            CorrespondenceSculpture()
        } else {
            flatMark
        }
    }

    private var flatMark: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            ZStack {
                if sculpted {
                    Circle()
                        .fill(RadialGradient(colors: [.white.opacity(0.10), .clear],
                                             center: .center, startRadius: 0, endRadius: side / 2))
                }
                arc(side: side, rotation: -32)
                arc(side: side * 0.61, rotation: 148)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .accessibilityHidden(true)
    }

    private func arc(side: CGFloat, rotation: Double) -> some View {
        Circle().trim(from: 0.12, to: 0.88)
            .stroke(
                LinearGradient(colors: sculpted
                    ? [Color.white, CorresPalette.champagne, Color(hex: 0x798E9B), .white]
                    : [CorresPalette.accent, CorresPalette.accent],
                    startPoint: .topLeading, endPoint: .bottomTrailing),
                style: StrokeStyle(lineWidth: side * 0.105, lineCap: .round)
            )
            .frame(width: side * 0.76, height: side * 0.76)
            .rotationEffect(.degrees(rotation))
            .shadow(color: .black.opacity(sculpted ? 0.35 : 0), radius: side * 0.025, x: 0, y: side * 0.045)
    }
}

enum CorresGlyph: String {
    case brief, needsYou, waiting, mail
}

struct CorresIcon: View {
    let glyph: CorresGlyph
    var body: some View {
        Canvas { context, size in
            let scale = min(size.width, size.height) / 24
            let path = Self.path(for: glyph)
            context.scaleBy(x: scale, y: scale)
            context.stroke(path, with: .foreground, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }
        .frame(width: 24, height: 24)
        .accessibilityHidden(true)
    }

    static func path(for glyph: CorresGlyph) -> Path {
        var path = Path()
        switch glyph {
        case .brief:
            path.addRoundedRect(in: CGRect(x: 4, y: 3, width: 16, height: 18), cornerSize: CGSize(width: 3, height: 3))
            for y in [8.0, 12.0, 16.0] {
                path.move(to: CGPoint(x: 8, y: y)); path.addLine(to: CGPoint(x: y == 16 ? 13 : 16, y: y))
            }
        case .needsYou:
            path.addEllipse(in: CGRect(x: 3, y: 3, width: 18, height: 18))
            path.move(to: CGPoint(x: 12, y: 7)); path.addLine(to: CGPoint(x: 12, y: 13))
            path.addEllipse(in: CGRect(x: 11.6, y: 16, width: 0.8, height: 0.8))
        case .waiting:
            path.addArc(center: CGPoint(x: 12, y: 12), radius: 9, startAngle: .degrees(-70), endAngle: .degrees(250), clockwise: false)
            path.move(to: CGPoint(x: 12, y: 6)); path.addLine(to: CGPoint(x: 12, y: 12)); path.addLine(to: CGPoint(x: 16, y: 14))
        case .mail:
            path.addRoundedRect(in: CGRect(x: 3, y: 5, width: 18, height: 14), cornerSize: CGSize(width: 3, height: 3))
            path.move(to: CGPoint(x: 4, y: 7)); path.addLine(to: CGPoint(x: 12, y: 13)); path.addLine(to: CGPoint(x: 20, y: 7))
        }
        return path
    }

    #if canImport(UIKit)
    /// TabView requires an Image; a Canvas inside tabItem can be dropped by UIKit.
    @MainActor static func tabImage(_ glyph: CorresGlyph) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 24, height: 24))
        return renderer.image { context in
            context.cgContext.addPath(path(for: glyph).cgPath)
            context.cgContext.setStrokeColor(UIColor.black.cgColor)
            context.cgContext.setLineWidth(1.5)
            context.cgContext.setLineCap(.round)
            context.cgContext.setLineJoin(.round)
            context.cgContext.strokePath()
        }.withRenderingMode(.alwaysTemplate)
    }
    #endif

}
