import SwiftUI

/// The Corres monogram: a titanium outer C holding a sapphire inner C and a
/// single point, an exchange with room left for the other person. Pure
/// vector paths drawn at the display's native scale, so it is exactly as
/// sharp on a 1024pt App Store render as in a 28pt toolbar.
///
/// Self-contained on purpose (no asset-catalog colors): the app icon is
/// rendered from this same view by Scripts/RenderIcon.swift, outside the
/// app bundle.
struct CorrespondenceMark: View {
    /// A faint sapphire halo behind the mark, for hero placements only.
    var glow = false

    private static let titaniumAxis = (UnitPoint(x: 0.24, y: 0.2), UnitPoint(x: 0.76, y: 0.8))
    private static let sapphireAxis = (UnitPoint(x: 0.36, y: 0.36), UnitPoint(x: 0.62, y: 0.64))

    var body: some View {
        Canvas { context, size in
            let side = min(size.width, size.height)
            let unit = side / 240
            let origin = CGPoint(x: (size.width - side) / 2, y: (size.height - side) / 2)
            let center = CGPoint(x: origin.x + 120 * unit, y: origin.y + 120 * unit)
            let rect = CGRect(origin: origin, size: CGSize(width: side, height: side))

            if glow {
                context.fill(Path(ellipseIn: CGRect(x: center.x - 80 * unit, y: center.y - 80 * unit,
                                                    width: 160 * unit, height: 160 * unit)),
                             with: .radialGradient(Gradient(colors: [.init(markHex: 0x9FBEE8).opacity(0.22), .clear]),
                                                   center: center, startRadius: 0, endRadius: 80 * unit))
            }

            let outer = Self.arc(center: center, radius: 62 * unit, from: 40, to: 320)
            let inner = Self.arc(center: center, radius: 34 * unit, from: 60, to: 300)
            let outerStyle = StrokeStyle(lineWidth: 22 * unit, lineCap: .round)
            let innerStyle = StrokeStyle(lineWidth: 11 * unit, lineCap: .round)

            // Soft contact shadows give the metal depth without a bevel.
            var shadowed = context
            shadowed.addFilter(.blur(radius: 2.2 * unit))
            shadowed.opacity = 0.5
            shadowed.stroke(outer.offsetBy(dx: 0, dy: 3 * unit), with: .color(.black), style: outerStyle)
            shadowed.stroke(inner.offsetBy(dx: 0, dy: 2 * unit), with: .color(.black), style: innerStyle)

            context.stroke(outer, with: Self.shading(Self.titaniumStops, Self.titaniumAxis, rect), style: outerStyle)
            // A fine specular line along the upper edge of the outer ring.
            context.stroke(Self.arc(center: center, radius: 72 * unit, from: 150, to: 300),
                           with: .color(.white.opacity(0.35)), style: StrokeStyle(lineWidth: 1.2 * unit, lineCap: .round))
            context.stroke(inner, with: Self.shading(Self.sapphireStops, Self.sapphireAxis, rect), style: innerStyle)
            context.fill(Path(ellipseIn: CGRect(x: center.x + 32 * unit - 5.5 * unit, y: center.y - 5.5 * unit,
                                                width: 11 * unit, height: 11 * unit)),
                         with: Self.shading(Self.titaniumStops, Self.titaniumAxis, rect))
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }

    /// Angles in degrees, measured clockwise from 3 o'clock in screen space;
    /// sweeping 40→320 draws a C that opens to the right.
    private static func arc(center: CGPoint, radius: CGFloat, from: Double, to: Double) -> Path {
        var path = Path()
        path.addArc(center: center, radius: radius, startAngle: .degrees(from), endAngle: .degrees(to), clockwise: false)
        return path
    }

    private static func point(_ unit: UnitPoint, in rect: CGRect) -> CGPoint {
        CGPoint(x: rect.minX + unit.x * rect.width, y: rect.minY + unit.y * rect.height)
    }

    private static func shading(_ gradient: Gradient, _ axis: (UnitPoint, UnitPoint), _ rect: CGRect) -> GraphicsContext.Shading {
        .linearGradient(gradient, startPoint: point(axis.0, in: rect), endPoint: point(axis.1, in: rect))
    }
    private static let titaniumStops = Gradient(stops: [
        .init(color: .init(markHex: 0xFFFFFF), location: 0), .init(color: .init(markHex: 0xD5D9DF), location: 0.3),
        .init(color: .init(markHex: 0x9197A0), location: 0.55), .init(color: .init(markHex: 0xE7EAEE), location: 0.78),
        .init(color: .init(markHex: 0x848A93), location: 1)])
    private static let sapphireStops = Gradient(stops: [
        .init(color: .init(markHex: 0xE3EEFC), location: 0), .init(color: .init(markHex: 0x8FB4E8), location: 0.4),
        .init(color: .init(markHex: 0x4A6C9C), location: 0.7), .init(color: .init(markHex: 0xB9D1F2), location: 1)])
}

/// The app icon's composition: the mark on an obsidian field with a faint
/// cool light from above. Rendered to App/Assets.xcassets by
/// Scripts/RenderIcon.swift.
struct CorresIconArtwork: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(markHex: 0x1D2027), Color(markHex: 0x0C0D10), Color(markHex: 0x060607)],
                           startPoint: .top, endPoint: .bottom)
            // A cool light from above, and a faint sapphire bloom behind
            // the mark, so the field has depth rather than flat black.
            RadialGradient(colors: [Color(markHex: 0xC8D6EE).opacity(0.18), .clear],
                           center: UnitPoint(x: 0.5, y: -0.1), startRadius: 0, endRadius: 820)
            RadialGradient(colors: [Color(markHex: 0x5E86C4).opacity(0.22), .clear],
                           center: .center, startRadius: 0, endRadius: 420)
            // The mark fills about two thirds of the icon, like the other
            // studio apps; nudged right because an open C reads left-heavy.
            CorrespondenceMark(glow: true)
                .frame(width: 1110, height: 1110)
                .offset(x: 24)
        }
        .frame(width: 1024, height: 1024)
        .clipped()
    }
}

/// A square showcase of the mark for the studio site: the icon's field
/// with wider breathing room. The site sets the name and tagline itself.
struct CorresHeroArtwork: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(markHex: 0x1A1D24), Color(markHex: 0x0B0C0F), Color(markHex: 0x060607)],
                           startPoint: .top, endPoint: .bottom)
            RadialGradient(colors: [Color(markHex: 0xC8D6EE).opacity(0.14), .clear],
                           center: UnitPoint(x: 0.5, y: -0.1), startRadius: 0, endRadius: 900)
            RadialGradient(colors: [Color(markHex: 0x5E86C4).opacity(0.20), .clear],
                           center: .center, startRadius: 0, endRadius: 520)
            CorrespondenceMark(glow: true).frame(width: 780, height: 780).offset(x: 18)
        }
    }
}

extension Color {
    init(markHex hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 255) / 255,
                  green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255)
    }
}
