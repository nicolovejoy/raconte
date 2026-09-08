import SwiftUI

/// #162: the app's type-size decisions, in points, per platform (owner ruling 2026-09-08).
///
/// The plan assumed a root-level Dynamic Type bump would raise macOS text sizes; measured on
/// 2026-09-08 in a standalone harness, `.dynamicTypeSize` (and `@ScaledMetric`) is inert on
/// macOS 26 — `.font(.body)` does not change size at any setting. Dropped entirely. macOS sizes
/// below are therefore stated in points, ×1.3 over the old literals; the rest of the macOS type
/// (everything not on this shelf) still needs a token sweep later — #162 stays open for that.
/// `.font(.system(size:))` literals do NOT move with Dynamic Type, so the Home shelf's three
/// literal sizes are stated here explicitly, graded on iOS: the smallest text up the most, the
/// largest not at all.
enum TypeScale {
    #if os(macOS)
    /// Was 13 — ×1.3.
    static let homeFaceOutTitle: CGFloat = 17
    /// Was 17 — ×1.3.
    static let homeSpineTitle: CGFloat = 22
    /// Was 11 — ×1.3.
    static let homeRelativeTime: CGFloat = 14
    #else
    /// Was 13 — +20% (journal titles on rows WITH a cover).
    static let homeFaceOutTitle: CGFloat = 16
    /// Was 17 — +10% (journal titles on rows WITHOUT a cover).
    static let homeSpineTitle: CGFloat = 19
    /// Was 11 — +30% (the "18 hours ago" line, the smallest text on Home).
    static let homeRelativeTime: CGFloat = 14
    #endif
}
