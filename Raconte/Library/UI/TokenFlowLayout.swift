import SwiftUI

/// A leading-aligned wrapping layout for `VoiceMarkingView`'s per-paragraph token
/// strips — SwiftUI has no built-in wrap layout. Deliberately dumb: no unit test (it's
/// exercised by the UI test), all the gesture math it exists to support lives in
/// `TokenSelection` below, which IS unit-tested.
struct TokenFlowLayout: Layout {
    var horizontalSpacing: CGFloat = 4
    var verticalSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var origin = CGPoint.zero
        var rowHeight: CGFloat = 0
        var width: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if origin.x > 0, origin.x + size.width > maxWidth {
                origin.x = 0
                origin.y += rowHeight + verticalSpacing
                rowHeight = 0
            }
            origin.x += size.width + horizontalSpacing
            rowHeight = max(rowHeight, size.height)
            width = max(width, origin.x - horizontalSpacing)
        }
        let height = origin.y + rowHeight
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxWidth = bounds.width
        var origin = CGPoint(x: bounds.minX, y: bounds.minY)
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if origin.x > bounds.minX, origin.x + size.width > bounds.minX + maxWidth {
                origin.x = bounds.minX
                origin.y += rowHeight + verticalSpacing
                rowHeight = 0
            }
            subview.place(at: origin, proposal: ProposedViewSize(size))
            origin.x += size.width + horizontalSpacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

/// The drag gesture's pure math (T7 Mark Voices, issue #56, Task 6) — fully
/// unit-tested (`TokenSelectionTests`) so `VoiceMarkingView` itself never needs to be.
enum TokenSelection {
    /// The token whose rect (expanded 3pt vertically, to tolerate a drag wandering
    /// slightly onto the neighbouring wrapped line) contains `point`. When more than
    /// one rect contains it — rects should not normally overlap, but nothing enforces
    /// that upstream — the SMALLEST id wins, deterministically.
    static func tokenIndex(at point: CGPoint, frames: [(id: Int, rect: CGRect)]) -> Int? {
        frames
            .filter { $0.rect.insetBy(dx: 0, dy: -3).contains(point) }
            .map(\.id)
            .min()
    }

    /// `anchor`/`current` ordered into `min...max`, then both endpoints clamped INWARD
    /// to the nearest placeable id that lies inside that range (never widened past a
    /// non-placeable endpoint) — a drag that starts or ends on a word with no timed
    /// frames must not pull that word into the mark. `nil` when no placeable id exists
    /// anywhere inside the ordered range.
    static func selectedRange(anchor: Int, current: Int, placeable: Set<Int>) -> ClosedRange<Int>? {
        let lower = min(anchor, current)
        let upper = max(anchor, current)
        guard let clampedLower = (lower...upper).first(where: { placeable.contains($0) }),
              let clampedUpper = (lower...upper).reversed().first(where: { placeable.contains($0) })
        else { return nil }
        guard clampedLower <= clampedUpper else { return nil }
        return clampedLower...clampedUpper
    }
}
