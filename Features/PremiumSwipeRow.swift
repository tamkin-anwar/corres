import SwiftUI

/// Icon/label/tint for whichever action is armed at a given point in the
/// gesture — pure display data, independent of which underlying action type
/// (`PrimarySwipeAction`/`LeadingSwipeAction`, each with their own
/// state-dependent variants like Pin/Unpin) it came from.
struct SwipeVisual {
    let title: String
    let systemImage: String
    let tint: Color
}

/// Swift doesn't allow stored `static` properties on a generic type
/// (`PremiumSwipeRow<Content>` below), so these live in a plain, non-generic
/// namespace instead. Tuned by feel against Spark's own described
/// short/long distinction, not measured against the real app (no access to
/// it here): short is reachable with a casual swipe, long needs a
/// deliberate, further drag past it. `maxDrag` caps how far the row can
/// visually slide so a determined drag doesn't send it flying off
/// unbounded.
private enum SwipeMetrics {
    static let shortThreshold: CGFloat = 76
    static let longThreshold: CGFloat = 156
    static let maxDrag: CGFloat = 172
}

/// Corres's own hand-built replacement for Apple's `.swipeActions` on a
/// Mail row, built specifically to match Spark's own swipe model,
/// researched directly rather than guessed at: Spark assigns an
/// independent action to *four* slots — Left Short, Left Long, Right
/// Short, Right Long — where a short swipe fires one action directly on
/// release and a longer swipe fires a different one, no intermediate
/// "reveal a row of buttons and tap one" step at all. Apple's own
/// `.swipeActions` API has no equivalent of this: it only offers reveal-
/// then-tap plus a single auto-fire-on-full-swipe action, which is exactly
/// why this exists as a real custom gesture instead of another
/// `.swipeActions` configuration, the way the rest of this session's swipe
/// customization was.
///
/// Genuinely higher-risk than most of this app's other UI, and known to be
/// so before it ships: a hand-rolled horizontal drag gesture living inside
/// a vertically-scrolling `List` is exactly the class of thing that can
/// look correct in code and still misbehave on a real device (competing
/// with the List's own scroll recognizer, or with `NavigationLink`'s own
/// tap) in ways a build can't catch — the same lesson the `.swipeActions`/
/// `ForEach` bug just taught, applied here proactively rather than found
/// the same way again. `.simultaneousGesture` (not `.gesture`) is used
/// specifically so this never claims exclusive priority over the List's
/// own vertical pan recognizer; a `minimumDistance` on the `DragGesture`
/// plus checking which axis actually dominates on the very first reported
/// translation is what lets an ordinary vertical scroll pass through
/// untouched instead of being hijacked by a horizontal-swipe row.
struct PremiumSwipeRow<Content: View>: View {
    let leadingShort: SwipeVisual?
    let leadingLong: SwipeVisual?
    let trailingShort: SwipeVisual?
    let trailingLong: SwipeVisual?
    let onLeadingShort: () -> Void
    let onLeadingLong: () -> Void
    let onTrailingShort: () -> Void
    let onTrailingLong: () -> Void
    @ViewBuilder let content: Content

    private enum Zone: Int { case none = 0, short = 1, long = 2 }

    // A custom gesture doesn't automatically respect `.disabled()` the way
    // a real `Button` does; read it explicitly so callers can still disable
    // a row mid-action (`store.pending`, preventing a double-fire) exactly
    // like before.
    @Environment(\.isEnabled) private var isEnabled
    // Matches `CorresShell`'s own outbox banner and `DesignSystem/Tokens.swift`'s
    // row-press animation, the established convention throughout this app:
    // Reduce Motion drops the animated spring specifically (the large,
    // springy positional movement Reduce Motion's own guidance targets),
    // never the state change itself — the row still snaps back to flat
    // instantly, just without the bounce.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var offset: CGFloat = 0
    /// nil until the first meaningful movement of a given gesture, then
    /// fixed for its duration: whether *this* gesture turned out to be
    /// predominantly horizontal (a swipe this view should handle) or
    /// vertical (an ordinary scroll this view must get out of the way of).
    @State private var isHorizontalDrag: Bool?
    @State private var zone: Zone = .none

    var body: some View {
        ZStack {
            // Purely decorative: the real actions it previews are exposed
            // to VoiceOver as proper named accessibility actions (see
            // `CorrespondenceList`'s use of this view), not by making
            // VoiceOver stumble onto this icon as its own, separate,
            // context-free element while navigating the row.
            background.accessibilityHidden(true)
            content
                .offset(x: offset)
        }
        .simultaneousGesture(dragGesture)
        // One haptic tick exactly when `zone` changes value, in either
        // direction (crossing a threshold forward while dragging further,
        // or crossing back while easing off) — SwiftUI fires this
        // automatically on any change to the trigger value, so the zone
        // state machine above is the only place that needs to get this
        // right.
        .sensoryFeedback(.impact(weight: .light), trigger: zone)
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 16)
            .onChanged { value in
                guard isEnabled else { return }
                if isHorizontalDrag == nil {
                    isHorizontalDrag = abs(value.translation.width) > abs(value.translation.height)
                }
                guard isHorizontalDrag == true else { return }
                // Only drag toward a side that actually has something
                // configured; dragging toward an empty side (e.g. no
                // leading actions at all) simply does nothing rather than
                // revealing a blank background.
                let allowsPositive = leadingShort != nil || leadingLong != nil
                let allowsNegative = trailingShort != nil || trailingLong != nil
                var next = value.translation.width
                if next > 0 && !allowsPositive { next = 0 }
                if next < 0 && !allowsNegative { next = 0 }
                offset = max(-SwipeMetrics.maxDrag, min(SwipeMetrics.maxDrag, next))
                zone = Self.zone(for: offset)
            }
            .onEnded { _ in
                defer {
                    isHorizontalDrag = nil
                    zone = .none
                }
                guard isHorizontalDrag == true else { return }
                commit(offset)
                withAnimation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.82)) {
                    offset = 0
                }
            }
    }

    private static func zone(for offset: CGFloat) -> Zone {
        let magnitude = abs(offset)
        if magnitude >= SwipeMetrics.longThreshold { return .long }
        if magnitude >= SwipeMetrics.shortThreshold { return .short }
        return .none
    }

    private func commit(_ offset: CGFloat) {
        switch Self.zone(for: offset) {
        case .none:
            return
        case .short:
            if offset > 0 { onLeadingShort() } else { onTrailingShort() }
        case .long:
            if offset > 0 { onLeadingLong() } else { onTrailingLong() }
        }
    }

    /// The colored panel revealed behind the row as it slides, showing
    /// whichever action is currently armed (switching from the short
    /// action's icon/tint to the long action's the moment the drag passes
    /// `longThreshold`, so the visible icon always matches what will
    /// actually fire if released right now).
    private var background: some View {
        HStack(spacing: 0) {
            if offset > 0 {
                armedVisual(short: leadingShort, long: leadingLong)
                    .frame(width: min(offset, SwipeMetrics.maxDrag), alignment: .leading)
                Spacer(minLength: 0)
            } else if offset < 0 {
                Spacer(minLength: 0)
                armedVisual(short: trailingShort, long: trailingLong)
                    .frame(width: min(-offset, SwipeMetrics.maxDrag), alignment: .trailing)
            }
        }
    }

    @ViewBuilder
    private func armedVisual(short: SwipeVisual?, long: SwipeVisual?) -> some View {
        let visual = zone == .long ? (long ?? short) : (short ?? long)
        if let visual {
            ZStack(alignment: offset > 0 ? .leading : .trailing) {
                Rectangle().fill(visual.tint)
                Label(visual.title, systemImage: visual.systemImage)
                    .labelStyle(.iconOnly)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    // Only worth showing once there's enough room for it to
                    // read as an icon rather than a sliver; fades and grows
                    // in with the drag instead of popping in abruptly at
                    // the threshold.
                    .opacity(min(1, Double(abs(offset)) / Double(SwipeMetrics.shortThreshold)))
                    .padding(.horizontal, 22)
            }
        }
    }
}
