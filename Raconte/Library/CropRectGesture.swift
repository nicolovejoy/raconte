import Foundation
import CoreGraphics

/// Which part of the crop rectangle a drag grabbed.
enum CropHandle: CaseIterable, Sendable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

    var movesLeft: Bool { self == .topLeft || self == .left || self == .bottomLeft }
    var movesRight: Bool { self == .topRight || self == .right || self == .bottomRight }
    var movesTop: Bool { self == .topLeft || self == .top || self == .topRight }
    var movesBottom: Bool { self == .bottomLeft || self == .bottom || self == .bottomRight }
}

/// #121: `ImageFramingView`'s drag math, in unit space (0…1, y down). Pure so the clamping
/// rules — stay inside the image, never thinner than `ImageFraming.minimumSide`, never
/// inverted — are pinned by `CropRectGestureTests` rather than eyeballed.
enum CropRectGesture {
    /// Slide `rect` by `delta`, size unchanged, stopping at the unit square.
    static func moved(_ rect: CGRect, by delta: CGSize) -> CGRect {
        var r = rect
        r.origin.x = min(max(rect.minX + delta.width, 0), 1 - rect.width)
        r.origin.y = min(max(rect.minY + delta.height, 0), 1 - rect.height)
        return r
    }

    /// Move the edge(s) `handle` owns by `delta`; the opposite edge(s) stay put. An edge that
    /// would cross its opposite stops at `minimumSide` from it; everything is clamped to the
    /// unit square.
    static func resized(_ rect: CGRect, handle: CropHandle, by delta: CGSize) -> CGRect {
        let minSide = ImageFraming.minimumSide
        var minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY
        if handle.movesLeft { minX = min(max(rect.minX + delta.width, 0), maxX - minSide) }
        if handle.movesRight { maxX = max(min(rect.maxX + delta.width, 1), minX + minSide) }
        if handle.movesTop { minY = min(max(rect.minY + delta.height, 0), maxY - minSide) }
        if handle.movesBottom { maxY = max(min(rect.maxY + delta.height, 1), minY + minSide) }
        return ImageFraming.clamped(CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY))
    }
}
