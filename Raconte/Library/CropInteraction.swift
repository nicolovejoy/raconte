import Foundation
import CoreGraphics

/// #203: decides which gesture's transform applies to the crop rectangle, and from which
/// starting rectangle. `ImageFramingView` runs a one-finger drag and a two-finger pinch
/// side by side; each reports a CUMULATIVE value (translation, magnification) measured from
/// its own start, so each must be applied to the rectangle it started from, and only one may
/// apply at a time or the rectangle jumps. Pure; the view holds one in `@State`.
struct CropInteraction: Equatable, Sendable {
    /// The drag being applied: its `startLocation` (constant for one drag, so it identifies
    /// it) and the rectangle it began from.
    private var dragLocation: CGPoint?
    private var dragStart: CGRect?
    /// The drag whose updates are dropped: a pinch took the rectangle from it, or it began
    /// while a pinch was running. Held until that drag ends or a different drag arrives.
    private var ignoredDrag: CGPoint?
    /// The rectangle the running pinch began from.
    private var pinchStart: CGRect?

    init() {}

    /// A drag update. `startLocation` is `DragGesture.Value.startLocation`, which is constant
    /// for one drag and so identifies it. Returns the rectangle the drag's cumulative
    /// translation applies to, or nil when this update must be ignored.
    mutating func dragChanged(from startLocation: CGPoint, current: CGRect) -> CGRect? {
        if ignoredDrag == startLocation { return nil }
        // A different drag from the one being ignored: it is over, forget it.
        ignoredDrag = nil
        if pinchStart != nil {
            forgetDrag()
            ignoredDrag = startLocation
            return nil
        }
        if dragLocation == startLocation, let dragStart { return dragStart }
        dragLocation = startLocation
        dragStart = current
        return current
    }

    mutating func dragEnded() {
        forgetDrag()
        ignoredDrag = nil
    }

    /// A pinch update. Returns the rectangle the pinch's cumulative magnification applies to.
    /// A pinch that begins mid-drag starts from the drag's own start, and that drag is
    /// ignored from then on: its translation predates the pinch, so applying it after the
    /// pinch ends would make the rectangle jump.
    mutating func pinchChanged(current: CGRect) -> CGRect {
        if let pinchStart { return pinchStart }
        let start = dragStart ?? current
        if let dragLocation { ignoredDrag = dragLocation }
        forgetDrag()
        pinchStart = start
        return start
    }

    mutating func pinchEnded() {
        pinchStart = nil
    }

    private mutating func forgetDrag() {
        dragLocation = nil
        dragStart = nil
    }
}
