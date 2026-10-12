import SwiftUI
import UIKit

/// Where each visible row is on screen, kept outside SwiftUI state so
/// scrolling doesn't redraw the list on every frame.
final class RowFrames {
    var frames: [ThreadID: CGRect] = [:]

    func id(at point: CGPoint, in order: [ThreadID]) -> ThreadID? {
        order.first { frames[$0]?.contains(point) == true }
    }
}

/// Mail's two-finger drag down a list to select a run of conversations,
/// built as its own recognizer rather than the system List selection, which
/// would replace Corres's swipes. It can't collide with them: swipes take
/// exactly one finger, this takes exactly two. While it's selecting, the
/// list doesn't scroll under the fingers, and it scrolls on its own near the
/// top and bottom edges, the way Mail does.
///
/// With `fingers: 1` and a `leadingZone`, it's Mail's other selection
/// drag: in Select, one finger down the column of circles. It only begins
/// on the circles, so a drag anywhere else still scrolls.
@available(iOS 18.0, *)
struct TwoFingerSelectGesture: UIGestureRecognizerRepresentable {
    var fingers = 2
    /// One finger: how far from the list's leading edge a drag may start
    /// (the circles' column), in points.
    var leadingZone: CGFloat? = nil
    var isEnabled = true
    /// Location in screen coordinates; `.began` / `.changed` / `.ended`.
    let onChange: (UIGestureRecognizer.State, CGPoint) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let recognizer = UIPanGestureRecognizer()
        recognizer.minimumNumberOfTouches = fingers
        recognizer.maximumNumberOfTouches = fingers
        recognizer.delegate = context.coordinator
        return recognizer
    }

    func updateUIGestureRecognizer(_ recognizer: UIPanGestureRecognizer, context: Context) {
        context.coordinator.onChange = onChange
        context.coordinator.leadingZone = leadingZone
        recognizer.isEnabled = isEnabled
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        let coordinator = context.coordinator
        let point = recognizer.location(in: nil)
        coordinator.lastPoint = point
        switch recognizer.state {
        case .began:
            // Two fingers belong to selection for this drag; one finger
            // scrolls as usual the moment they lift.
            // Cancel any scroll the fingers started, then hold the list still.
            coordinator.scrollView?.panGestureRecognizer.isEnabled = false
            coordinator.scrollView?.panGestureRecognizer.isEnabled = true
            coordinator.scrollView?.isScrollEnabled = false
            coordinator.startAutoScroll()
            onChange(.began, point)
        case .changed:
            onChange(.changed, point)
        default:
            coordinator.stopAutoScroll()
            coordinator.scrollView?.isScrollEnabled = true
            onChange(.ended, point)
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onChange: ((UIGestureRecognizer.State, CGPoint) -> Void)?
        var leadingZone: CGFloat?
        private var touchStart: CGPoint?
        weak var scrollView: UIScrollView?
        var lastPoint: CGPoint = .zero
        private var displayLink: CADisplayLink?

        /// Finds the list's own scroll view from the first touch.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            if scrollView == nil {
                var view = touch.view
                while let current = view, !(current is UIScrollView) { view = current.superview }
                scrollView = view as? UIScrollView
            }
            touchStart = touch.location(in: scrollView)
            return true
        }

        /// Mostly-vertical drags only, so a two-finger sideways gesture
        /// (Back, for one) isn't taken.
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
            let velocity = pan.velocity(in: pan.view)
            if let leadingZone {
                // On the circles, and clearly up or down: a sideways start
                // is left alone.
                guard let start = touchStart, start.x <= leadingZone else { return false }
                return abs(velocity.y) > abs(velocity.x) * 1.2
            }
            return abs(velocity.y) >= abs(velocity.x)
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            other === scrollView?.panGestureRecognizer
        }

        func startAutoScroll() {
            stopAutoScroll()
            let link = CADisplayLink(target: self, selector: #selector(tick))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }

        func stopAutoScroll() {
            displayLink?.invalidate()
            displayLink = nil
        }

        /// Near the top or bottom edge the list scrolls on its own, faster
        /// the closer the fingers are, and the selection follows.
        @objc private func tick() {
            guard let scrollView, let window = scrollView.window else { return }
            let frame = scrollView.convert(scrollView.bounds, to: window)
            let edge: CGFloat = 80
            let top = frame.minY + scrollView.adjustedContentInset.top
            let bottom = frame.maxY - scrollView.adjustedContentInset.bottom
            var delta: CGFloat = 0
            if lastPoint.y < top + edge { delta = -((top + edge - lastPoint.y) / edge) * 14 }
            if lastPoint.y > bottom - edge { delta = ((lastPoint.y - (bottom - edge)) / edge) * 14 }
            guard delta != 0 else { return }
            let minY = -scrollView.adjustedContentInset.top
            let maxY = max(minY, scrollView.contentSize.height - scrollView.bounds.height + scrollView.adjustedContentInset.bottom)
            let newY = min(max(scrollView.contentOffset.y + delta, minY), maxY)
            guard newY != scrollView.contentOffset.y else { return }
            scrollView.contentOffset.y = newY
            onChange?(.changed, lastPoint)
        }
    }
}
