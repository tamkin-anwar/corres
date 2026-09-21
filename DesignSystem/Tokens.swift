import SwiftUI

/// Adaptive colors live in Assets.xcassets (light/dark Color Sets), not as
/// programmatic UIColor(traits:) closures. SwiftUI resolves asset-catalog
/// colors directly against its own `\.colorScheme` environment, so they
/// update immediately with .preferredColorScheme(); a UIColor trait-closure
/// resolves against UIKit's trait collection instead, which lags a full
/// layout pass behind — the cause of a real bug where switching Appearance
/// in Preferences updated the sheet's background instantly but left card
/// backgrounds on the old color until the view was left and revisited.
enum CorresPalette {
    static let canvas = Color("canvas")
    static let surface = Color("surface")
    static let ink = Color("ink")
    static let secondary = Color("secondary")
    static let accent = Color("accent")
    static let line = Color("line")
    static let champagne = Color(hex: 0xD7C4A0)
    static let midnight = Color(hex: 0x142D3D)

    // Swipe-action tints: system swipe buttons render a fixed white icon/label
    // regardless of appearance, so these must NOT be the adaptive text colors
    // above (accent/secondary flip to light tones in dark mode and would put
    // white-on-white). Chosen and verified for >=4.5:1 contrast against white
    // in both light and dark canvas — see the WCAG audit in Docs/Verification.md.
    static let swipeHandled = Color(hex: 0x2D5A70)
    static let swipeSnooze = Color(hex: 0x4A5560)
    static let swipePin = Color(hex: 0x8A6A3E)
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 255) / 255,
                  green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255)
    }
}

enum CorresSpace {
    static let small: CGFloat = 8
    static let medium: CGFloat = 16
    static let page: CGFloat = 24
    static let section: CGFloat = 32
    static let radius: CGFloat = 26
}

enum CorresType {
    static let display = Font.system(.largeTitle, design: .serif, weight: .regular)
    static let heading = Font.system(.title2, design: .serif, weight: .medium)
    static let label = Font.system(.caption, design: .monospaced, weight: .medium)
}

struct CorresSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: CorresSpace.radius, style: .continuous)
                    .fill(CorresPalette.surface.gradient
                        .shadow(.inner(color: CorresPalette.accent.opacity(0.035), radius: 5, y: -3)))
            }
            .overlay {
                RoundedRectangle(cornerRadius: CorresSpace.radius)
                    .strokeBorder(CorresPalette.line, lineWidth: contrast == .increased ? 1.5 : 0.5)
            }
            .compositingGroup()
            .shadow(color: .black.opacity(reduceTransparency ? 0 : 0.035), radius: 16, x: 0, y: 8)
            // This card shape is reused on every list row and repeats across a
            // scrolling List; rasterizing it once avoids recomputing the inner
            // fill shadow, stroke, and outer blur on every scroll frame.
            .drawingGroup()
    }
}

extension View {
    func corresSurface() -> some View { modifier(CorresSurface()) }
}

struct CorresButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: 52)
            .foregroundStyle(.white)
            .background(CorresPalette.midnight, in: RoundedRectangle(cornerRadius: 18))
            .opacity(configuration.isPressed ? 0.82 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: configuration.isPressed)
    }
}

struct CorresRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.7 : 1)
    }
}
