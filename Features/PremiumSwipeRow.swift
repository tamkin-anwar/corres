import SwiftUI
import UIKit

/// Icon/label/tint for whichever action is armed at a given point in the
/// gesture. `removesRow` (Archive, Trash) makes the row slide fully off
/// screen on commit instead of springing back, the way Mail does.
struct SwipeVisual {
    let title: String
    let systemImage: String
    let tint: Color
    var removesRow = false
}

/// A Mail row with four independent swipe slots: a short and a long swipe
/// in each direction (Spark's model), where releasing fires the action
/// directly with no reveal-then-tap step.
///
/// Why this is built on a UIKit pan recognizer (iOS 18+) and not SwiftUI's
/// `DragGesture`: inside a scrolling `List`, a `DragGesture` competes with
/// the list's own pan for the same touches, which is what made the old
/// version stutter, hitch scrolling and misfire on diagonal drags. A
/// `UIPanGestureRecognizer` whose delegate only lets it begin when the
/// finger is clearly moving sideways hands every vertical movement to the
/// scroll view untouched, the same arbitration Mail's rows get from UIKit.
///
/// Feel, matched to Mail and Spark:
/// - distances scale with the row's width (short at about a fifth, long
///   past half), not fixed points;
/// - a quick flick counts, judged from the finger's speed, not only its
///   distance;
/// - the action colour fills from the edge, its icon grows as it arms,
///   and a haptic tick marks each threshold, in both directions;
/// - past the long threshold the row stretches with resistance instead of
///   stopping dead;
/// - Archive and Trash carry the row off screen before it's removed;
///   everything else springs back into place.
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

    // A custom gesture doesn't automatically respect `.disabled()` the way a
    // real Button does; read it so a row mid-action can't fire twice.
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var offset: CGFloat = 0
    @State private var rowWidth: CGFloat = 390
    @State private var zone: Zone = .none
    @State private var isCommitting = false

    /// Quarter swipes: the short action arms at about 15% of the row (a
    /// quick thumb movement), the long one at about 42%, far enough apart
    /// that one never slips into the other.
    private var shortThreshold: CGFloat { max(52, rowWidth * 0.15) }
    private var longThreshold: CGFloat { max(shortThreshold + 72, rowWidth * 0.42) }
    private var allowsPositive: Bool { leadingShort != nil || leadingLong != nil }
    private var allowsNegative: Bool { trailingShort != nil || trailingLong != nil }

    var body: some View {
        ZStack {
            // Decorative: the same actions are exposed to VoiceOver as named
            // accessibility actions by the list.
            background.accessibilityHidden(true)
            content
                .offset(x: offset)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { rowWidth = max($0, 1) }
        .modifier(SwipeGesture(isEnabled: isEnabled && !isCommitting,
                               allowsPositive: allowsPositive, allowsNegative: allowsNegative,
                               changed: dragChanged, ended: dragEnded))
        .sensoryFeedback(trigger: zone) { old, new in
            new.rawValue > old.rawValue ? .impact(weight: new == .long ? .medium : .light, intensity: 0.9)
                                        : .impact(weight: .light, intensity: 0.5)
        }
    }

    // MARK: - Gesture handling

    private func dragChanged(_ translation: CGFloat) {
        var next = translation
        if next > 0 && !allowsPositive { next = 0 }
        if next < 0 && !allowsNegative { next = 0 }
        offset = resisted(next)
        let newZone = zone(for: offset)
        if newZone != zone {
            withAnimation(reduceMotion ? nil : .snappy(duration: 0.18)) { zone = newZone }
        }
    }

    private func dragEnded(_ translation: CGFloat, _ velocity: CGFloat) {
        var committed = zone(for: offset)
        // A decisive flick arms the short action even before its distance.
        let flicked = abs(velocity) > 450 && abs(offset) > 16 && (velocity > 0) == (offset > 0)
        if committed == .none && flicked { committed = .short }
        guard isEnabled, committed != .none, let visual = visual(for: committed, positive: offset > 0) else {
            settle()
            return
        }
        let positive = offset > 0
        let action = self.action(for: committed, positive: positive)
        if visual.removesRow {
            isCommitting = true
            let target = (positive ? 1 : -1) * (rowWidth + 40)
            // Leaves at the finger's own speed (never slower than a brisk
            // throw) and eases out, so the row keeps moving the instant it's
            // let go; an ease-in started it from rest, which read as a hitch.
            let remaining = abs(target - offset)
            let speed = max(abs(velocity), 1600)
            let duration = min(0.22, max(0.1, Double(remaining / speed)))
            let finish = {
                action()
                // If the row stays (Undo, or Gmail refused), bring it back.
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(600))
                    isCommitting = false
                    settle()
                }
            }
            if reduceMotion {
                offset = target
                finish()
            } else {
                withAnimation(.easeOut(duration: duration)) { offset = target } completion: { finish() }
            }
        } else {
            action()
            settle()
        }
    }

    private func settle() {
        withAnimation(reduceMotion ? nil : .spring(response: 0.36, dampingFraction: 0.78)) {
            offset = 0
            zone = .none
        }
    }

    /// 1:1 with the finger up to the long threshold, then progressively
    /// harder to pull, capped short of the row's own width.
    private func resisted(_ translation: CGFloat) -> CGFloat {
        let magnitude = abs(translation)
        guard magnitude > longThreshold else { return translation }
        let extra = magnitude - longThreshold
        let limit = rowWidth * 0.85 - longThreshold
        let damped = longThreshold + limit * (1 - exp(-extra / max(limit, 1)))
        return translation < 0 ? -damped : damped
    }

    private func zone(for offset: CGFloat) -> Zone {
        let magnitude = abs(offset)
        if magnitude >= longThreshold, visual(for: .long, positive: offset > 0) != nil { return .long }
        if magnitude >= shortThreshold { return .short }
        return .none
    }

    private func visual(for zone: Zone, positive: Bool) -> SwipeVisual? {
        switch (zone, positive) {
        case (.long, true): leadingLong ?? leadingShort
        case (.long, false): trailingLong ?? trailingShort
        case (.short, true): leadingShort ?? leadingLong
        case (.short, false): trailingShort ?? trailingLong
        case (.none, _): nil
        }
    }

    private func action(for zone: Zone, positive: Bool) -> () -> Void {
        switch (zone, positive) {
        case (.long, true): leadingLong != nil ? onLeadingLong : onLeadingShort
        case (.long, false): trailingLong != nil ? onTrailingLong : onTrailingShort
        case (_, true): leadingShort != nil ? onLeadingShort : onLeadingLong
        case (_, false): trailingShort != nil ? onTrailingShort : onTrailingLong
        }
    }

    // MARK: - Background

    @ViewBuilder
    private var background: some View {
        if offset != 0 {
            let positive = offset > 0
            let shown = visual(for: zone == .none ? .short : zone, positive: positive)
            let revealed = min(abs(offset), rowWidth)
            let progress = min(1, abs(offset) / shortThreshold)
            ZStack(alignment: positive ? .leading : .trailing) {
                Rectangle()
                    .fill((shown?.tint ?? .gray).opacity(zone == .none ? 0.55 + 0.45 * progress : 1))
                if let shown {
                    Image(systemName: shown.systemImage)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white)
                        .scaleEffect(zone == .none ? 0.7 + 0.3 * progress : (zone == .long ? 1.15 : 1))
                        .opacity(progress)
                        // Pinned to the edge while arming, then carried
                        // along with the row once it's committed to long,
                        // the way Mail signals "let go now".
                        .padding(positive ? .leading : .trailing, zone == .long ? max(22, revealed - 56) : 22)
                        .accessibilityLabel(shown.title)
                }
            }
            .frame(width: revealed)
            .frame(maxWidth: .infinity, alignment: positive ? .leading : .trailing)
        }
    }
}

// MARK: - Gesture plumbing

/// Picks the UIKit recognizer on iOS 18+, a tuned `DragGesture` before that.
private struct SwipeGesture: ViewModifier {
    let isEnabled: Bool
    let allowsPositive: Bool
    let allowsNegative: Bool
    let changed: (CGFloat) -> Void
    let ended: (CGFloat, CGFloat) -> Void

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.gesture(HorizontalPanGesture(isEnabled: isEnabled, allowsPositive: allowsPositive,
                                                 allowsNegative: allowsNegative, changed: changed, ended: ended))
        } else {
            content.simultaneousGesture(LegacyDrag(isEnabled: isEnabled, changed: changed, ended: ended).gesture)
        }
    }
}

@available(iOS 18.0, *)
private struct HorizontalPanGesture: UIGestureRecognizerRepresentable {
    let isEnabled: Bool
    let allowsPositive: Bool
    let allowsNegative: Bool
    let changed: (CGFloat) -> Void
    let ended: (CGFloat, CGFloat) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator(allowsPositive: allowsPositive, allowsNegative: allowsNegative) }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let recognizer = UIPanGestureRecognizer()
        recognizer.delegate = context.coordinator
        recognizer.maximumNumberOfTouches = 1
        return recognizer
    }

    func updateUIGestureRecognizer(_ recognizer: UIPanGestureRecognizer, context: Context) {
        recognizer.isEnabled = isEnabled
        context.coordinator.allowsPositive = allowsPositive
        context.coordinator.allowsNegative = allowsNegative
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        // Measured from where the finger first touched down, not from where
        // UIKit finished recognizing the pan: recognition lands a beat after
        // the finger starts moving, and `translation(in:)` would discard
        // that first stretch, so fast swipes lost most of their distance.
        let current = recognizer.location(in: recognizer.view).x
        let translation = current - (context.coordinator.touchDownX ?? current)
        switch recognizer.state {
        case .began, .changed:
            changed(translation)
        case .ended:
            ended(translation, recognizer.velocity(in: recognizer.view).x)
        case .cancelled, .failed:
            ended(0, 0)
        default:
            break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var allowsPositive: Bool
        var allowsNegative: Bool
        var touchDownX: CGFloat?

        init(allowsPositive: Bool, allowsNegative: Bool) {
            self.allowsPositive = allowsPositive
            self.allowsNegative = allowsNegative
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            touchDownX = touch.location(in: gestureRecognizer.view).x
            return true
        }

        /// Only a clearly sideways start becomes a swipe; anything else is
        /// left entirely to the scroll view.
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
            let velocity = pan.velocity(in: pan.view)
            guard abs(velocity.x) > abs(velocity.y) * 1.2 else { return false }
            return velocity.x > 0 ? allowsPositive : allowsNegative
        }

        /// Never alongside the list's scrolling: once a swipe owns the
        /// touch, the list holds still, and vice versa.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            false
        }
    }
}

/// iOS 17: SwiftUI's drag, locked to whichever axis dominates first.
@MainActor
private struct LegacyDrag {
    let isEnabled: Bool
    let changed: (CGFloat) -> Void
    let ended: (CGFloat, CGFloat) -> Void

    var gesture: some Gesture {
        DragGesture(minimumDistance: 14)
            .onChanged { value in
                guard isEnabled, abs(value.translation.width) > abs(value.translation.height) * 1.2 else { return }
                changed(value.translation.width)
            }
            .onEnded { value in
                let horizontal = abs(value.translation.width) > abs(value.translation.height) * 1.2
                let velocity = (value.predictedEndTranslation.width - value.translation.width) * 4
                ended(horizontal ? value.translation.width : 0, horizontal ? velocity : 0)
            }
    }
}
