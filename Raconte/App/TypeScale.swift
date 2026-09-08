import SwiftUI

/// #162: the app's type-size decisions, in points, per platform (owner ruling 2026-09-08).
///
/// Two levers. On macOS a single Dynamic Type bump at the scene root scales every semantic
/// text style ~30% (the same style names are smaller in points on macOS than iOS —
/// `.callout` is 16 pt on iOS and 12 pt on macOS — so "too small on the laptop" was mostly
/// platform drift). `.font(.system(size:))` literals do NOT move with Dynamic Type, so the
/// Home shelf's three literal sizes are stated here explicitly, graded on iOS: the
/// smallest text up the most, the largest not at all.
enum TypeScale {
    /// One step above the +24% `.xxLarge`: body 23 pt against the default 17 pt.
    static let macDynamicTypeSize: DynamicTypeSize = .xxxLarge

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
