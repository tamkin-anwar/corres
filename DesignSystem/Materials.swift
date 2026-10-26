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
        if #available(iOS 26.0, macOS 26.0, *), !reduceTransparency {
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

/// Glass controls that sit together (the reading bar and Reply, the reply
/// suggestions above them) drawn as one group, as Apple recommends: they
/// blend where they meet and morph as they come and go, and the system
/// renders the group in one pass instead of each piece on its own.
struct CorresGlassGroup<Content: View>: View {
    var spacing: CGFloat = 12
    @ViewBuilder var content: Content

    var body: some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

/// A round monogram, the person's photo from your Contacts once you've
/// allowed them (read on this iPhone), or a company's own verified logo,
/// fetched privately through Corres's relay (BrandLogos), never from the
/// sender directly. Initials are set in SF at a
/// fixed ratio of the circle so they stay optically centered at any size.
struct CorrespondentAvatar: View {
    let initials: String
    /// Whose photo to show, when Contacts has one.
    var email: String? = nil
    /// Drives the view's own frame; pass a smaller size rather than
    /// wrapping the default in an external `.frame()`, which never
    /// rescales the fixed internal content.
    var size = CGSize(width: 42, height: 42)
    var highlighted = false
    @Environment(\.displayScale) private var displayScale
    @Environment(PeopleDirectory.self) private var people: PeopleDirectory?

    var body: some View {
        let side = min(size.width, size.height)
        Text(initials.isEmpty ? "·" : initials.uppercased())
            .font(.system(size: side * 0.34, weight: .semibold))
            .foregroundStyle(CorresPalette.ink)
            .frame(width: side, height: side)
            .background(CorresPalette.avatarFill, in: Circle())
            .overlay {
                if let email, let photo = people?.photo(for: email) {
                    Image(platformImage: photo).resizable().scaledToFill()
                        .frame(width: side, height: side).clipShape(Circle())
                } else if let email, let logo = BrandLogos.shared.logo(for: email) {
                    // The company's own verified mark (BrandLogos).
                    Image(platformImage: logo).resizable().interpolation(.high).scaledToFill()
                        .frame(width: side, height: side).clipShape(Circle())
                        .transition(.opacity)
                }
            }
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
    @Environment(\.dynamicTypeSize) private var typeSize
    let text: String
    let isIntelligence: Bool

    var body: some View {
        Label {
            Text(text).lineLimit(typeSize.isAccessibilitySize ? 3 : 1)
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

/// A small outlined day marker ("Fri") for something due. Once the day
/// has passed, an appointment or event reads "Was Sep 28" (it's over,
/// nothing to do), and only a real deadline reads "Overdue", in red.
struct DueChip: View {
    let date: Date
    var isEvent = false
    @Environment(\.displayScale) private var displayScale

    private var isPast: Bool { date < Calendar.current.startOfDay(for: .now) }
    private var tint: Color { isPast ? (isEvent ? CorresPalette.tertiary : CorresPalette.alert) : CorresPalette.accent }

    var body: some View {
        Text(label)
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 8).padding(.vertical, 2)
            .overlay(Capsule().strokeBorder(isPast && isEvent ? CorresPalette.line : tint.opacity(0.5), lineWidth: 1))
            // Whole sentences: the English pieces joined together were
            // read out in English in every language.
            .accessibilityLabel(spokenLabel)
    }

    private var spokenLabel: String {
        let day = date.formatted(.dateTime.weekday(.wide).month().day())
        if !isPast { return String(localized: "Due \(day)") }
        return isEvent ? String(localized: "Was on \(day)") : String(localized: "Overdue, was due \(day)")
    }

    private var label: String {
        let calendar = Calendar.current
        if isPast { return isEvent ? String(localized: "Was \(date.formatted(.dateTime.month(.abbreviated).day()))") : String(localized: "Overdue") }
        if calendar.isDateInToday(date) { return String(localized: "Today") }
        if calendar.isDateInTomorrow(date) { return String(localized: "Tomorrow") }
        if let days = calendar.dateComponents([.day], from: .now, to: date).day, days < 6, days >= 0 {
            return date.formatted(.dateTime.weekday(.abbreviated))
        }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }
}

/// How long a Waiting conversation has gone without a reply. After three
/// days it turns into a nudge, the way Gmail's "Sent 3 days ago. Follow
/// up?" and Superhuman's "if no reply" reminders resurface a thread.
struct WaitChip: View {
    let since: Date
    /// Settings → Sorting → Follow up after.
    static var followUpAfterDays: Int { CorresSettings.followUpDays }

    private var days: Int { max(0, Calendar.current.dateComponents([.day], from: since, to: .now).day ?? 0) }
    private var isNudge: Bool { days >= Self.followUpAfterDays }

    var body: some View {
        Text(isNudge ? "Follow up" : days == 0 ? "Today" : "\(days)d")
            .font(.caption.weight(.semibold))
            .foregroundStyle(isNudge ? CorresPalette.accent : CorresPalette.tertiary)
            .padding(.horizontal, 8).padding(.vertical, 2)
            .overlay(Capsule().strokeBorder(isNudge ? CorresPalette.accent.opacity(0.5) : CorresPalette.line, lineWidth: 1))
            .accessibilityLabel(days == 0 ? "Sent today" : days == 1 ? "No reply in 1 day" : "No reply in \(days) days")
    }
}

extension View {
    /// The one emphasized action in a toolbar (Send). Toolbars size their
    /// items themselves, so this uses the system's prominent style (glass
    /// on iOS 26) tinted with the accent, rather than a custom capsule the
    /// toolbar would clip.
    @ViewBuilder
    func prominentToolbarButton() -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
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

/// An empty screen's headline, whole on as many lines as it needs.
/// ContentUnavailableView keeps its title to one line, which cut
/// "Nichts Ungelesenes in Braucht dich" short in German.
struct EmptyTitle: View {
    private let title: Text
    private let systemImage: String

    init(_ key: LocalizedStringKey, systemImage: String) {
        title = Text(key)
        self.systemImage = systemImage
    }

    /// For text already worked out. Disfavored, as Text's own is: without
    /// it a plain "One moment" took this one and was never translated.
    @_disfavoredOverload
    init<S: StringProtocol>(_ string: S, systemImage: String) {
        title = Text(string)
        self.systemImage = systemImage
    }

    var body: some View {
        Label {
            title.lineLimit(4).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: systemImage)
        }
    }
}
