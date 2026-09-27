import SwiftUI

/// Adaptive colors live in Assets.xcassets (light/dark Color Sets), not as
/// programmatic UIColor(traits:) closures. SwiftUI resolves asset-catalog
/// colors directly against its own `\.colorScheme` environment, so they
/// update immediately with .preferredColorScheme(); a UIColor trait-closure
/// resolves against UIKit's trait collection instead, which lags a full
/// layout pass behind, the cause of a real bug where switching Appearance
/// in Preferences updated the sheet's background instantly but left card
/// backgrounds on the old color until the view was left and revisited.
///
/// Two themes, one system: Obsidian (dark, #0A0A0C) and Ivory (light,
/// #F6F3EC), with a single sapphire accent. Restraint is the point: one
/// accent, serif display type, SF for everything functional, hairlines
/// instead of heavy borders. Every value is vector or a color, never a
/// bitmap, so it renders at the display's native scale.
enum CorresPalette {
    static let canvas = Color("canvas")
    static let surface = Color("surface")
    static let surfaceRaised = Color("surfaceRaised")
    static let ink = Color("ink")
    static let secondary = Color("secondary")
    static let tertiary = Color("tertiary")
    // Named "corresAccent," not "accent": SwiftUI already generates a
    // symbol for the built-in Color.accent/accentColor, and reusing that
    // name collided with it.
    static let accent = Color("corresAccent")
    /// Text and icons placed on a solid accent fill.
    static let accentInk = Color("accentInk")
    static let line = Color("line")
    static let avatarFill = Color("avatarFill")

    // Swipe-action tints: swipe buttons render a fixed white icon/label
    // regardless of appearance, so these must NOT be the adaptive text colors
    // above (accent/secondary flip to light tones in dark mode and would put
    // white-on-white). Each is >=4.5:1 against white; see the WCAG audit in
    // Docs/Verification.md.
    static let swipeHandled = Color(hex: 0x2F5D9E) // sapphire, 6.4:1
    static let swipeSnooze = Color(hex: 0x4A5560)
    static let swipePin = Color(hex: 0x5B4B8A)
    static let swipeArchive = Color(hex: 0x3D5A4C)
    static let swipeTrash = Color(hex: 0xA33B2E) // 6.51:1
    /// iOS Mail's own flag orange (#FF9500) is only 2.2:1 against white, too
    /// faint for a white swipe icon or a row indicator on the light canvas.
    /// 5.18:1 against white, 3.76:1 against the dark canvas (icons need 3:1).
    static let flag = Color(hex: 0xC2410C)
    static let swipeFlag = flag
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
    static let page: CGFloat = 20
    static let section: CGFloat = 28
    static let radius: CGFloat = 22
    static let readableWidth: CGFloat = 680
}

/// New York for display, SF Pro for everything you act on. All sizes are
/// Dynamic Type text styles, so they scale with the person's setting.
enum CorresType {
    static let display = Font.system(.largeTitle, design: .serif, weight: .regular)
    static let title = Font.system(.title, design: .serif, weight: .regular)
    static let heading = Font.system(.title2, design: .serif, weight: .regular)
    static let brief = Font.system(.title3, design: .serif, weight: .regular)
    /// Small tracked uppercase section label ("NEEDS YOU", "IN SHORT").
    static let eyebrow = Font.system(.caption, design: .default, weight: .semibold)
    static let label = eyebrow
}

extension View {
    /// Tracked uppercase label style used for section eyebrows.
    func eyebrow(_ color: Color = CorresPalette.tertiary) -> some View {
        self.font(CorresType.eyebrow).tracking(1.6).textCase(.uppercase).foregroundStyle(color)
    }

    /// Caps content at a comfortable reading width on iPad and landscape
    /// while staying leading-aligned. Order matters: expand first, then cap.
    func readableWidth() -> some View {
        self.frame(maxWidth: .infinity, alignment: .leading).frame(maxWidth: CorresSpace.readableWidth)
    }
}

/// A quiet card: an opaque surface, a hairline edge, a soft long shadow in
/// dark mode where the canvas needs separation. No inner glows or bevels.
struct CorresSurface: ViewModifier {
    var radius: CGFloat = CorresSpace.radius
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.colorScheme) private var scheme
    @Environment(\.displayScale) private var displayScale

    func body(content: Content) -> some View {
        content
            .background(CorresPalette.surface, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(CorresPalette.line, lineWidth: contrast == .increased ? 1.5 : 1 / displayScale)
            }
            .shadow(color: .black.opacity(scheme == .dark ? 0.35 : 0.05), radius: scheme == .dark ? 20 : 14, y: 10)
    }
}

extension View {
    /// `rasterize` is accepted for source compatibility and ignored: the
    /// new surface is a flat fill and hairline, cheap enough to draw live,
    /// and skipping `.drawingGroup()` keeps text at the display's native
    /// resolution and lets WKWebView content render inside it.
    func corresSurface(rasterize: Bool = true, radius: CGFloat = CorresSpace.radius) -> some View {
        modifier(CorresSurface(radius: radius))
    }
}

/// The signature primary button: brushed titanium on Obsidian, polished
/// ink on Ivory. Used once per screen at most.
struct CorresMetalBackground: View {
    var shape: AnyShape = AnyShape(Capsule())
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        shape
            .fill(scheme == .dark
                  ? LinearGradient(stops: [.init(color: Color(hex: 0xF7F8FA), location: 0),
                                           .init(color: Color(hex: 0xCBD0D6), location: 0.42),
                                           .init(color: Color(hex: 0xA3A8B0), location: 0.64),
                                           .init(color: Color(hex: 0xE6E9ED), location: 1)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                  : LinearGradient(colors: [Color(hex: 0x2A2824), Color(hex: 0x141312)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing))
            .overlay(shape.stroke(.white.opacity(scheme == .dark ? 0.55 : 0.12), lineWidth: 0.5))
            .shadow(color: .black.opacity(scheme == .dark ? 0.45 : 0.18), radius: 12, y: 6)
    }

    static func ink(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? Color(hex: 0x111214) : Color(hex: 0xF6F3EC)
    }
}

struct CorresButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: 54)
            .foregroundStyle(CorresMetalBackground.ink(scheme))
            .background(CorresMetalBackground())
            .opacity(configuration.isPressed ? 0.85 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: configuration.isPressed)
    }
}

/// A compact titanium capsule (Send, Reply, Allow).
struct CorresMetalCapsuleStyle: ButtonStyle {
    var minHeight: CGFloat = 40
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 18)
            .frame(minHeight: minHeight)
            .foregroundStyle(CorresMetalBackground.ink(scheme))
            .background(CorresMetalBackground())
            .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.4)
    }
}

/// A quiet secondary capsule on the raised surface.
struct CorresPillStyle: ButtonStyle {
    var minHeight: CGFloat = 36
    @Environment(\.displayScale) private var displayScale
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 15)
            .frame(minHeight: minHeight)
            .foregroundStyle(CorresPalette.ink)
            .background(CorresPalette.surfaceRaised, in: Capsule())
            .overlay(Capsule().strokeBorder(CorresPalette.line, lineWidth: 1 / displayScale))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

struct CorresRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// A hairline that is exactly one physical pixel on every display.
struct Hairline: View {
    var leading: CGFloat = 0
    @Environment(\.displayScale) private var displayScale
    var body: some View {
        Rectangle().fill(CorresPalette.line).frame(height: 1 / displayScale).padding(.leading, leading)
    }
}
