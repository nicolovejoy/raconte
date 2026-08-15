import Foundation

/// The capture screen's text sizes as a pure, ordered value — smallest to largest — so
/// "is this label below the legibility floor" is a question the tests can ask without
/// importing SwiftUI. The raw values are ordering only; the SwiftUI `Font` mapping lives
/// in `CaptureSurface+SwiftUI.swift`.
///
/// Ordering is the whole point: macOS renders `.caption` and `.footnote` at the SAME
/// 10 pt, so a floor expressed as "at least footnote" would be a no-op on the platform
/// where the complaint originated. Anything meant as a real size increase has to clear
/// `.subheadline`.
enum CaptureTextSize: Int, CaseIterable, Sendable, Comparable {
    case caption2 = 0
    case caption = 1
    case footnote = 2
    case subheadline = 3
    case callout = 4
    case body = 5
    case headline = 6
    case title3 = 7

    static func < (lhs: CaptureTextSize, rhs: CaptureTextSize) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// The fixed near-black field the capture screen paints in EVERY appearance (the project's
/// standing UI rule: this screen does not follow the system light/dark setting, so its
/// legibility can never be delegated to the system's own contrast handling).
///
/// Because the background is a constant, the contrast of every label on it is a constant
/// too — which means it is checkable at build time rather than discoverable by a human
/// squinting at a phone. `CaptureLabelTests` does exactly that.
enum CaptureSurface {
    /// Matches `Color(white:)` in `CaptureView.body`. Changing one without the other
    /// silently invalidates every contrast guarantee below, so they are pinned together
    /// by `testBackgroundMatchesTheRenderedCaptureBackground`.
    static let backgroundWhite: Double = 0.05

    /// WCAG 2.1 contrast floor for capture-screen control labels.
    ///
    /// Deliberately 7.0 (the AAA bar for normal text), not the more common 4.5 AA bar:
    /// the labels that prompted this were at 5.81:1 — passing AA — and were still
    /// reported unreadable in the field. AA was measured against this exact surface and
    /// found insufficient, so the floor is set where the evidence puts it.
    static let minimumControlContrast: Double = 7.0

    /// Smallest text size permitted for a label the owner must read to operate the
    /// screen. See `CaptureTextSize` on why this cannot be `.footnote`.
    static let minimumControlSize: CaptureTextSize = .callout

    /// WCAG 2.1 relative luminance of an sRGB grey (r = g = b = `white`).
    static func relativeLuminance(white: Double) -> Double {
        white <= 0.04045 ? white / 12.92 : pow((white + 0.055) / 1.055, 2.4)
    }

    /// WCAG 2.1 contrast ratio between two sRGB greys. Symmetric; always >= 1.
    static func contrastRatio(white: Double, against other: Double) -> Double {
        let a = relativeLuminance(white: white)
        let b = relativeLuminance(white: other)
        let lighter = max(a, b)
        let darker = min(a, b)
        return (lighter + 0.05) / (darker + 0.05)
    }

    /// Contrast of a label against this screen's own background.
    static func contrastOnSurface(white: Double) -> Double {
        contrastRatio(white: white, against: backgroundWhite)
    }
}

/// Every persistent text label drawn directly on the capture surface that the owner must
/// read in order to operate the screen.
///
/// Deliberately NOT included: the build stamp (a deliberate whisper, not an operating
/// label), transcript body text, and anything inside a sheet, popover, menu dropdown, or
/// alert — those render on their own system material, follow the ambient appearance, and
/// are out of scope by the same reasoning that scopes the screen's colour-scheme pins.
enum CaptureLabel: String, CaseIterable, Sendable {
    case journalHeaderCaption
    case journalName
    case journalPickerChevron
    case journalsUnreadable
    case backdateToggle
    case backdateFieldCaption
    case multiVoiceToggle
    case recentHeader
    case seeAllLink

    /// One secondary level (0.78 → 11.5:1) rather than the three near-identical greys this
    /// screen used to carry (0.55/0.6/0.7). Those greys were not expressing a hierarchy —
    /// they were drift — and the darkest of them was the reported bug.
    var whiteLevel: Double {
        switch self {
        case .journalName: 1.0
        case .journalHeaderCaption, .journalsUnreadable, .backdateToggle,
             .backdateFieldCaption, .multiVoiceToggle, .journalPickerChevron,
             .recentHeader, .seeAllLink: 0.78
        }
    }

    var size: CaptureTextSize {
        switch self {
        case .journalName: .title3
        case .recentHeader: .headline
        case .journalHeaderCaption, .journalsUnreadable, .backdateToggle,
             .backdateFieldCaption, .multiVoiceToggle, .journalPickerChevron,
             .seeAllLink: .callout
        }
    }
}
