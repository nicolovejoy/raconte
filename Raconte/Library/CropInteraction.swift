import Foundation
import CoreGraphics

/// #203: decides which gesture's transform applies to the crop rectangle, and from which
/// starting rectangle. `ImageFramingView` runs one-finger drags and a two-finger pinch side
/// by side; each reports a CUMULATIVE value (translation, magnification) measured from its
/// own start. The one invariant: that value is only ever applied to the rectangle the gesture
/// started from. A drag whose start rectangle is no longer the truth (a pinch or a newer drag
/// took the rectangle since) is ignored for the rest of its life, never re-based. Pure; the
/// view holds one in `@State`.
///
/// The type cannot see a cancelled pinch: the caller must call `pinchEnded()` on end AND on
/// cancel.
struct CropInteraction: Equatable, Sendable {
    /// The drag being applied: its `startLocation` and the rectangle it began from.
    private var dragLocation: CGPoint?
    private var dragStart: CGRect?
    /// Drags whose updates are dropped, by `startLocation`. Several at once: two fingers on
    /// two handles are two drags. Each stays until `dragEnded(from:)` names it.
    private var ignoredDrags: Set<CGPoint> = []
    /// The rectangle the running pinch began from.
    private var pinchStart: CGRect?

    init() {}

    /// A drag update. `startLocation` is `DragGesture.Value.startLocation`, which is constant
    /// for one drag and so identifies it. Returns the rectangle the drag's cumulative
    /// translation applies to, or nil when this update must be ignored.
    mutating func dragChanged(from startLocation: CGPoint, current: CGRect) -> CGRect? {
        // Exact CGPoint equality is intended: `startLocation` is constant for one drag.
        if ignoredDrags.contains(startLocation) { return nil }
        if pinchStart != nil {
            ignoredDrags.insert(startLocation)
            return nil
        }
        // Exact CGPoint equality is intended, as above.
        if dragLocation == startLocation, let dragStart { return dragStart }
        // A different drag takes over; the one it displaced is never re-based.
        silenceOwner()
        dragLocation = startLocation
        dragStart = current
        return current
    }

    /// The drag identified by `startLocation` ended. Forgets it, whether it was the owner
    /// or an ignored one.
    mutating func dragEnded(from startLocation: CGPoint) {
        ignoredDrags.remove(startLocation)
        // Exact CGPoint equality is intended, as above.
        if dragLocation == startLocation { forgetOwner() }
    }

    /// A pinch update. Returns the rectangle the pinch's cumulative magnification applies to.
    mutating func pinchChanged(current: CGRect) -> CGRect {
        if let pinchStart { return pinchStart }
        silenceOwner()
        pinchStart = current
        return current
    }

    mutating func pinchEnded() {
        pinchStart = nil
    }

    /// The owning drag, if any, loses the rectangle: ignored from now on.
    private mutating func silenceOwner() {
        if let dragLocation { ignoredDrags.insert(dragLocation) }
        forgetOwner()
    }

    private mutating func forgetOwner() {
        dragLocation = nil
        dragStart = nil
    }
}
