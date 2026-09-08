import SwiftUI

/// #162: the app's type-size decisions, in points, per platform (owner rulings 2026-09-08,
/// spec docs/plans/2026-09-08-design-system-type-and-ink.md).
///
/// `.dynamicTypeSize` and `@ScaledMetric` are inert on macOS 26 (measured 2026-09-08 in a
/// standalone harness), so macOS sizes are stated in points. iOS keeps Apple's semantic styles so
/// Dynamic Type still scales them. The rule for the macOS numbers is the one `CaptureSurface`
/// already states for the capture screen: **macOS renders at the iOS size**. Apple's macOS
/// scale runs ~30% smaller (caption 10 vs 12, body 13 vs 17), which was the whole complaint.
///
/// The paper screens' text roles. Capture-screen text is NOT on this scale — it has its own
/// (`CaptureLabel`, a stricter 7:1 surface) and was ruled out of the sweep.
enum TypeRole: CaseIterable, Sendable {
    /// Counts, tiny status — caption2.
    case meta
    /// Row metadata, sidebar subtitles, dates — caption.
    case label
    /// Section footers and explanations — footnote.
    case footnote
    /// Row second lines, banners — subheadline.
    case secondary
    /// About rows, detail prose — body.
    case body
    /// Row titles, section titles — headline.
    case headline
    /// Transcript prose on paper — body, serif.
    case reading

    /// The Apple style this role wears on iOS (and whose iOS size macOS is held to).
    var iOSStyle: CaptureTextSize {
        switch self {
        case .meta: .caption2
        case .label: .caption
        case .footnote: .footnote
        case .secondary: .subheadline
        case .body, .reading: .body
        case .headline: .headline
        }
    }

    /// Stated literally — NOT computed from `CaptureTextSize` — so an edit to the capture
    /// table can never silently move the paper screens. `TypeScaleTests` pins the two equal.
    var macOSPointSize: Double {
        switch self {
        case .meta: 11
        case .label: 12
        case .footnote: 13
        case .secondary: 15
        case .body, .reading, .headline: 17
        }
    }

    var isSerif: Bool { self == .reading }

    var font: Font {
        #if os(macOS)
        .system(size: macOSPointSize, design: isSerif ? .serif : .default)
        #else
        switch self {
        case .meta: .caption2
        case .label: .caption
        case .footnote: .footnote
        case .secondary: .subheadline
        case .body: .body
        case .headline: .headline
        case .reading: .system(.body, design: .serif)
        }
        #endif
    }
}

/// Sizes no text style has: the former `.system(size:)` literals, named, per platform.
/// macOS values are the iOS value scaled toward the same ~1.3 ratio and rounded to whole points;
/// `detailPlayGlyph` is a glyph, not text, and does not move.
enum TypeScale {
    #if os(macOS)
    static let homeFaceOutTitle: CGFloat = 17
    static let homeSpineTitle: CGFloat = 22
    static let homeRelativeTime: CGFloat = 14
    static let homeChevron: CGFloat = 15
    static let homeNewEntryButton: CGFloat = 19
    static let homeEmptyTitle: CGFloat = 28
    static let homeEmptyBody: CGFloat = 17
    static let libraryRowMeta: CGFloat = 15
    static let libraryOutOfSpanGlyph: CGFloat = 16
    static let trashUnreadableTitle: CGFloat = 18
    static let libraryJournalTitle: CGFloat = 24
    static let libraryCoverTitle: CGFloat = 28
    #else
    static let homeFaceOutTitle: CGFloat = 16
    static let homeSpineTitle: CGFloat = 19
    static let homeRelativeTime: CGFloat = 14
    static let homeChevron: CGFloat = 13
    static let homeNewEntryButton: CGFloat = 17
    static let homeEmptyTitle: CGFloat = 24
    static let homeEmptyBody: CGFloat = 15
    static let libraryRowMeta: CGFloat = 13
    static let libraryOutOfSpanGlyph: CGFloat = 14
    static let trashUnreadableTitle: CGFloat = 16
    static let libraryJournalTitle: CGFloat = 22
    static let libraryCoverTitle: CGFloat = 26
    #endif
    static let detailPlayGlyph: CGFloat = 36

    /// Every named size with its iOS value, for the never-shrinks test. The iOS column is
    /// repeated here on purpose (a second, independent statement of the numbers).
    static let namedSizes: [(name: String, size: CGFloat, iOSSize: CGFloat)] = [
        ("homeFaceOutTitle", homeFaceOutTitle, 16),
        ("homeSpineTitle", homeSpineTitle, 19),
        ("homeRelativeTime", homeRelativeTime, 14),
        ("homeChevron", homeChevron, 13),
        ("homeNewEntryButton", homeNewEntryButton, 17),
        ("homeEmptyTitle", homeEmptyTitle, 24),
        ("homeEmptyBody", homeEmptyBody, 15),
        ("libraryRowMeta", libraryRowMeta, 13),
        ("libraryOutOfSpanGlyph", libraryOutOfSpanGlyph, 14),
        ("trashUnreadableTitle", trashUnreadableTitle, 16),
        ("libraryJournalTitle", libraryJournalTitle, 22),
        ("libraryCoverTitle", libraryCoverTitle, 26),
        ("detailPlayGlyph", detailPlayGlyph, 36),
    ]
}
