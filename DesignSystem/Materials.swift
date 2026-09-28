import SwiftUI

/// Floating chrome (action bars, reply chips): Apple's Liquid Glass where
/// the system has it, a frosted material with a hairline edge before that.
/// Content itself always sits on opaque surfaces; glass is only for
/// controls that float above it, the way the system uses it.
struct CorresGlass<S: Shape>: ViewModifier {
    let shape: S
    var interactive = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.displayScale) private var displayScale

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *), !reduceTransparency {
            content.glassEffect(interactive ? .regular.interactive() : .regular, in: shape)
        } else {
            content
                .background(reduceTransparency ? AnyShapeStyle(CorresPalette.surfaceRaised) : AnyShapeStyle(.ultraThinMaterial), in: shape)
                .overlay(shape.stroke(CorresPalette.line, lineWidth: 1 / displayScale))
                .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
        }
    }
}

extension View {
    func corresGlass<S: Shape>(in shape: S, interactive: Bool = false) -> some View {
        modifier(CorresGlass(shape: shape, interactive: interactive))
    }
}

/// A round monogram. Initials are set in SF at a fixed ratio of the circle
/// so they stay optically centered at any size.
struct CorrespondentAvatar: View {
    let initials: String
    /// Drives the view's own frame; pass a smaller size rather than
    /// wrapping the default in an external `.frame()`, which never
    /// rescales the fixed internal content.
    var size = CGSize(width: 42, height: 42)
    var highlighted = false
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        let side = min(size.width, size.height)
        Text(initials.isEmpty ? "·" : initials)
            .font(.system(size: side * 0.34, weight: .semibold))
            .foregroundStyle(CorresPalette.ink)
            .frame(width: side, height: side)
            .background(CorresPalette.avatarFill, in: Circle())
            .overlay(Circle().strokeBorder(CorresPalette.line, lineWidth: 1 / displayScale))
            .overlay {
                if highlighted {
                    Circle().stroke(CorresPalette.accent, lineWidth: 1.5).padding(-3)
                }
            }
            .accessibilityHidden(true)
    }
}

/// The one-line "why this is here" evidence under a row or on a
/// conversation. A sparkle marks a judgment Apple Intelligence made on this
/// iPhone; an arrow marks a rule (a Gmail category, a person you write to).
struct ReasonLine: View {
    let text: String
    let isIntelligence: Bool

    var body: some View {
        Label {
            Text(text).lineLimit(1)
        } icon: {
            Image(systemName: isIntelligence ? "sparkle" : "arrow.turn.down.right")
                .font(.caption2.weight(.semibold))
        }
        .labelStyle(TightLabelStyle())
        .font(.footnote.weight(.medium))
        .foregroundStyle(CorresPalette.accent)
    }
}

struct TightLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) { configuration.icon; configuration.title }
    }
}

/// A small outlined day marker ("Fri") for something due.
struct DueChip: View {
    let date: Date
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        Text(label)
            .font(.caption.weight(.semibold))
            .foregroundStyle(CorresPalette.accent)
            .padding(.horizontal, 8).padding(.vertical, 2)
            .overlay(Capsule().strokeBorder(CorresPalette.accent.opacity(0.5), lineWidth: 1))
            .accessibilityLabel("Due \(date.formatted(.dateTime.weekday(.wide).month().day()))")
    }

    private var label: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInTomorrow(date) { return "Tomorrow" }
        if let days = calendar.dateComponents([.day], from: .now, to: date).day, days < 6, days >= 0 {
            return date.formatted(.dateTime.weekday(.abbreviated))
        }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }
}

extension View {
    /// The one emphasized action in a toolbar (Send). Toolbars size their
    /// items themselves, so this uses the system's prominent style (glass
    /// on iOS 26) tinted with the accent, rather than a custom capsule the
    /// toolbar would clip.
    @ViewBuilder
    func prominentToolbarButton() -> some View {
        if #available(iOS 26.0, *) {
            self.buttonStyle(.glassProminent).tint(CorresPalette.accent)
        } else {
            self.buttonStyle(.borderedProminent).tint(CorresPalette.accent)
        }
    }
}


extension View {
    /// Fades the trailing edge of a horizontal scroller, so a row that
    /// runs past the screen reads as "more this way" rather than cut off.
    func trailingFade(_ width: CGFloat = CorresSpace.page) -> some View {
        mask {
            HStack(spacing: 0) {
                Color.black
                LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                    .frame(width: width)
            }
        }
    }
}
