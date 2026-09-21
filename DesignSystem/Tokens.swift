import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

enum CorresPalette {
    static let canvas = adaptive(light: 0xF4F2ED, dark: 0x10171C)
    static let surface = adaptive(light: 0xFFFEFA, dark: 0x1A252D)
    static let ink = adaptive(light: 0x192D39, dark: 0xF3F0E8)
    static let secondary = adaptive(light: 0x5B6870, dark: 0xB6C1C7)
    static let accent = adaptive(light: 0x274D61, dark: 0xB4D1DF)
    static let line = adaptive(light: 0xDADDD9, dark: 0x394750)
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

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        #if canImport(UIKit)
        Color(uiColor: UIColor { traits in
            UIColor(rgb: traits.userInterfaceStyle == .dark ? dark : light)
        })
        #else
        Color(nsColor: NSColor(name: nil) { appearance in
            let rgb = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255,
                           green: CGFloat((rgb >> 8) & 255) / 255,
                           blue: CGFloat(rgb & 255) / 255, alpha: 1)
        })
        #endif
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 255) / 255,
                  green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255)
    }
}

#if canImport(UIKit)
private extension UIColor {
    convenience init(rgb: UInt32) {
        self.init(red: CGFloat((rgb >> 16) & 255) / 255,
                  green: CGFloat((rgb >> 8) & 255) / 255,
                  blue: CGFloat(rgb & 255) / 255, alpha: 1)
    }
}

#endif

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
