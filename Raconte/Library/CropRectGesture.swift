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

    /// #203: pinch. Both sides grow or shrink by `magnification` about the rectangle's centre,
    /// so its shape is kept. The factor is held to the range where the shorter side stays at
    /// `minimumSide` or more and the longer side stays inside the photo; the origin is then
    /// pulled back inside the unit square, so a rectangle against an edge slides to keep
    /// growing rather than stalling. A side that reaches a bound is set to exactly `1` or
    /// exactly `minimumSide`, not to the product, which rounds to just under or over it: a
    /// pinch fully out must give exactly the full photo, or `ImageFraming.isIdentity` is false
    /// and an untouched original is re-encoded. A magnification that is not finite, or is
    /// `<= 0`, changes nothing.
    static func scaled(_ rect: CGRect, by magnification: CGFloat) -> CGRect {
        let r = ImageFraming.clamped(rect)
        guard magnification.isFinite, magnification > 0 else { return r }
        let lower = max(ImageFraming.minimumSide / r.width, ImageFraming.minimumSide / r.height)
        let upper = min(1 / r.width, 1 / r.height)
        let factor = min(max(magnification, lower), upper)
        var width = r.width * factor, height = r.height * factor
        // `r.width * (1 / r.width)` is often 0.9999999999999999: state the bound side exactly.
        // With a side exactly 1, `1 - side` is exactly 0, so its origin below is exactly 0.
        if factor == upper {
            if r.width >= r.height { width = 1 }
            if r.height >= r.width { height = 1 }
        }
        if factor == lower {
            if r.width <= r.height { width = ImageFraming.minimumSide }
            if r.height <= r.width { height = ImageFraming.minimumSide }
        }
        return CGRect(x: min(max(r.midX - width / 2, 0), 1 - width),
                      y: min(max(r.midY - height / 2, 0), 1 - height),
                      width: width, height: height)
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
