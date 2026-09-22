import SwiftUI

/// Light is concentrated at the edge; text remains on a quiet, opaque surface.
struct InkMaterial: View {
    var radius: CGFloat = 30
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(LinearGradient(colors: [Color(hex: 0x254A5C), Color(hex: 0x122C3C), Color(hex: 0x0C1E2B)],
                                 startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay {
                if !reduceTransparency {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(RadialGradient(colors: [Color(hex: 0xA6C1CB).opacity(0.14), .clear],
                                             center: .topTrailing, startRadius: 0, endRadius: 270))
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [.white.opacity(0.5), .white.opacity(0.06), .white.opacity(0.2)],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing),
                                  lineWidth: contrast == .increased ? 1.5 : 0.75)
            }
    }
}

struct SculptedBadge: View {
    let glyph: CorresGlyph
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(LinearGradient(colors: [Color(hex: 0x496D7C), Color(hex: 0x183847)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing)
                    .shadow(.inner(color: .white.opacity(0.2), radius: 1, y: 1)))
                .overlay(RoundedRectangle(cornerRadius: 15).strokeBorder(.white.opacity(0.24), lineWidth: 0.5))
            CorresIcon(glyph: glyph)
                .foregroundStyle(LinearGradient(colors: [.white, CorresPalette.champagne], startPoint: .top, endPoint: .bottom))
                .shadow(color: .black.opacity(0.3), radius: 1, y: 2)
        }
        .frame(width: 46, height: 46)
        .compositingGroup()
        .shadow(color: CorresPalette.midnight.opacity(0.16), radius: 5, y: 4)
        // Static, non-animated per Design.md; rasterize once instead of
        // recomputing three layered shadows/gradients on every scroll frame.
        .drawingGroup()
        .accessibilityHidden(true)
    }
}

struct CorrespondentAvatar: View {
    let initials: String
    /// Drives the view's own internal frame and corner radius; a caller
    /// wanting a smaller avatar must pass a smaller `size`, not wrap the
    /// default-sized view in an external `.frame()`. SwiftUI's `.frame()`
    /// only changes the layout box a view is given, it never rescales a
    /// view's own already-fixed internal content to fit a smaller one, so
    /// an external override on the default 44x48 size would just overflow
    /// and clip against the smaller declared box instead of shrinking.
    var size = CGSize(width: 44, height: 48)

    var body: some View {
        Text(initials)
            .font(.system(.subheadline, design: .serif).weight(.medium))
            .foregroundStyle(CorresPalette.accent)
            .frame(width: size.width, height: size.height)
            .background {
                RoundedRectangle(cornerRadius: size.width * 0.36, style: .continuous)
                    .fill(CorresPalette.surface.gradient
                        .shadow(.inner(color: CorresPalette.accent.opacity(0.1), radius: 4, y: -3)))
                    .overlay(RoundedRectangle(cornerRadius: size.width * 0.36).strokeBorder(CorresPalette.line, lineWidth: 0.75))
            }
            // Rendered once per visible list row; rasterize the inner-shadow
            // fill so scrolling doesn't recompute it per frame.
            .drawingGroup()
            .accessibilityHidden(true)
    }
}
