import SwiftUI
import UIKit

/// Transparent touch layer over the location map. UIKit recognizers rather
/// than SwiftUI gestures because the map needs one-finger drag, pinch and
/// two-finger pan *at once*, with the one-finger drag called off the moment a
/// second finger lands — SwiftUI on iOS 17 can't express that (a
/// `MagnifyGesture` reports no centroid movement, and a `DragGesture` next to
/// a `ScrollView` either blocks it or never fires). The map itself stays a
/// SwiftUI `Canvas`; this view only reports touches, in its own coordinate
/// space, which is the canvas's.
struct MapGestureView: UIViewRepresentable {
    var onTap: (CGPoint) -> Void
    /// A one-finger drag passed the movement threshold. `start` is where the
    /// finger first went down, not where the threshold was crossed.
    var onDragBegan: (_ start: CGPoint) -> Void
    var onDragChanged: (_ location: CGPoint, _ translation: CGSize) -> Void
    var onDragEnded: (_ velocity: CGSize) -> Void
    /// A second finger turned the drag into a pinch: undo whatever it did.
    var onDragCancelled: () -> Void
    /// The finger rested for half a second. Its further movement, release or
    /// cancellation arrive through the drag callbacks, as for a drag.
    var onLongPressBegan: (_ location: CGPoint) -> Void
    /// Incremental: multiply zoom by `scale` around `centroid`, then pan by
    /// `translation`.
    var onPinch: (_ scale: CGFloat, _ translation: CGSize, _ centroid: CGPoint) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.accessibilityIdentifier = "locationMap"
        let coordinator = context.coordinator

        let tap = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.handleTap(_:)))
        let drag = UIPanGestureRecognizer(target: coordinator, action: #selector(Coordinator.handleDrag(_:)))
        drag.maximumNumberOfTouches = 1
        let pinch = UIPinchGestureRecognizer(target: coordinator, action: #selector(Coordinator.handlePinch(_:)))
        let twoFingerPan = UIPanGestureRecognizer(target: coordinator, action: #selector(Coordinator.handleTwoFingerPan(_:)))
        twoFingerPan.minimumNumberOfTouches = 2
        let longPress = UILongPressGestureRecognizer(target: coordinator, action: #selector(Coordinator.handleLongPress(_:)))
        longPress.minimumPressDuration = 0.5
        // A held finger is not a tap. A finger lifted early fails the long
        // press at once, so ordinary taps aren't delayed.
        tap.require(toFail: longPress)

        for recognizer in [drag, pinch, twoFingerPan, longPress] as [UIGestureRecognizer] {
            recognizer.delegate = coordinator
        }
        for recognizer in [tap, drag, pinch, twoFingerPan, longPress] as [UIGestureRecognizer] {
            view.addGestureRecognizer(recognizer)
        }
        coordinator.drag = drag
        coordinator.longPress = longPress
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.parent = self
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: MapGestureView
        weak var drag: UIPanGestureRecognizer?
        weak var longPress: UILongPressGestureRecognizer?
        private var dragActive = false
        private var longPressActive = false
        private var longPressStart: CGPoint = .zero

        init(parent: MapGestureView) { self.parent = parent }

        @objc func handleTap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended else { return }
            parent.onTap(recognizer.location(in: recognizer.view))
        }

        @objc func handleDrag(_ recognizer: UIPanGestureRecognizer) {
            let view = recognizer.view
            let translation = recognizer.translation(in: view)
            let location = recognizer.location(in: view)
            switch recognizer.state {
            case .began:
                dragActive = true
                parent.onDragBegan(CGPoint(x: location.x - translation.x, y: location.y - translation.y))
                parent.onDragChanged(location, CGSize(width: translation.x, height: translation.y))
            case .changed:
                guard dragActive else { return }
                parent.onDragChanged(location, CGSize(width: translation.x, height: translation.y))
            case .ended:
                guard dragActive else { return }
                dragActive = false
                let velocity = recognizer.velocity(in: view)
                parent.onDragEnded(CGSize(width: velocity.x, height: velocity.y))
            case .cancelled, .failed:
                guard dragActive else { return }
                dragActive = false
                parent.onDragCancelled()
            default:
                break
            }
        }

        @objc func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
            let location = recognizer.location(in: recognizer.view)
            switch recognizer.state {
            case .began:
                longPressActive = true
                longPressStart = location
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                parent.onLongPressBegan(location)
            case .changed:
                guard longPressActive else { return }
                parent.onDragChanged(location, CGSize(width: location.x - longPressStart.x, height: location.y - longPressStart.y))
            case .ended:
                guard longPressActive else { return }
                longPressActive = false
                parent.onDragChanged(location, CGSize(width: location.x - longPressStart.x, height: location.y - longPressStart.y))
                parent.onDragEnded(.zero)
            case .cancelled, .failed:
                guard longPressActive else { return }
                longPressActive = false
                parent.onDragCancelled()
            default:
                break
            }
        }

        @objc func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
            if recognizer.state == .began { cancelDrag() }
            guard recognizer.state == .began || recognizer.state == .changed else { return }
            parent.onPinch(recognizer.scale, .zero, recognizer.location(in: recognizer.view))
            recognizer.scale = 1
        }

        @objc func handleTwoFingerPan(_ recognizer: UIPanGestureRecognizer) {
            if recognizer.state == .began { cancelDrag() }
            guard recognizer.state == .began || recognizer.state == .changed else { return }
            let translation = recognizer.translation(in: recognizer.view)
            parent.onPinch(1, CGSize(width: translation.x, height: translation.y), recognizer.location(in: recognizer.view))
            recognizer.setTranslation(.zero, in: recognizer.view)
        }

        /// Fingers rarely land together, so a pinch usually starts as a
        /// one-finger drag that already moved an object or began a shape.
        /// Toggling `isEnabled` is UIKit's way to cancel a live recognizer.
        private func cancelDrag() {
            if dragActive, let drag {
                drag.isEnabled = false
                drag.isEnabled = true
            }
            if longPressActive, let longPress {
                longPress.isEnabled = false
                longPress.isEnabled = true
            }
        }

        /// One finger does one thing: once the long press holds, moving the
        /// finger draws its rectangle instead of also panning, and a drag
        /// already under way doesn't turn into a long press.
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            if gestureRecognizer === drag { return !longPressActive }
            if gestureRecognizer === longPress { return !dragActive }
            return true
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            // Pinch and two-finger pan run together; the one-finger drag is
            // allowed alongside only so a pinch can start while it is live,
            // at which point `cancelDrag` ends it.
            // Only among the map's own recognizers.
            other.view === gestureRecognizer.view
                && !(gestureRecognizer is UITapGestureRecognizer || other is UITapGestureRecognizer)
        }

        /// iOS 26's swipe-back works from anywhere in the content, so a drag
        /// to the right on the map would leave the screen. Outside recognizers
        /// wait for the map's own to fail; the screen-edge swipe still works.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer) -> Bool {
            other.view !== gestureRecognizer.view && !(other is UIScreenEdgePanGestureRecognizer)
                && (gestureRecognizer === drag || gestureRecognizer === longPress)
        }
    }
}
