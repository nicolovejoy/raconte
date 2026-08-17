import Foundation

/// The capture screen's text sizes as a pure, ordered value — smallest to largest — so
/// "is this label below the legibility floor" is a question the tests can ask without
/// importing SwiftUI. The raw values are ordering only; the SwiftUI `Font` mapping lives
/// in `CaptureSurface+SwiftUI.swift`.
///
/// The ordering is for reasoning about the scale; it is NOT what the legibility floor is
/// expressed in. macOS renders `.caption`, `.footnote` and `.caption2` at the same 10 pt
/// and runs a smaller scale throughout, so "at least style X" does not mean the same size
/// on both platforms — `pointSize(on:)` is the comparable quantity, and
/// `CaptureSurface.minimumControlPointSize` is stated in points for that reason.
enum CaptureTextSize: Int, CaseIterable, Sendable, Comparable {
    case caption2 = 0
    case caption = 1
    case footnote = 2
    case subheadline = 3
    case callout = 4
    case body = 5
    case headline = 6
    case title3 = 7
    case title2 = 8
    case title = 9

    static func < (lhs: CaptureTextSize, rhs: CaptureTextSize) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Apple's rendered point size for each text style, per platform (HIG typography
    /// tables, default Dynamic Type size).
    ///
    /// This table is the whole reason the model exists in this shape. A semantic style
    /// does NOT mean the same size on both platforms — macOS runs a systematically
    /// smaller scale, and `.callout` is 16 pt on iPhone against 12 pt on Mac. Expressing
    /// the floor as "at least `.callout`" therefore bought roughly nothing on the very
    /// platform the complaint came from (owner smoke, 2026-08-15, twice).
    func pointSize(on platform: CapturePlatform) -> Double {
        switch platform {
        case .iOS:
            switch self {
            case .caption2: 11
            case .caption: 12
            case .footnote: 13
            case .subheadline: 15
            case .callout: 16
            case .body: 17
            case .headline: 17
            case .title3: 20
            case .title2: 22
            case .title: 28
            }
        case .macOS:
            switch self {
            case .caption2: 10
            case .caption: 10
            case .footnote: 10
            case .subheadline: 11
            case .callout: 12
            case .body: 13
            case .headline: 13
            case .title3: 15
            case .title2: 17
            case .title: 22
            }
        }
    }
}

/// The two platforms this app ships on, as a pure value so the typography rules can be
/// checked for BOTH from a single test run on either one.
enum CapturePlatform: String, CaseIterable, Sendable {
    case iOS
    case macOS
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

    /// Smallest RENDERED SIZE, in points, permitted for a label the owner must read to
    /// operate the screen — expressed in points rather than as a semantic style because a
    /// style-based floor is not comparable across platforms (see `pointSize(on:)`).
    ///
    /// 16 pt is the iPhone `.callout` size. This screen is read at arm's length while the
    /// owner reads aloud from a paper journal, not scanned up close like a document, so
    /// macOS is held to the same rendered size as iOS instead of to the smaller Mac scale.
    static let minimumControlPointSize: Double = 16

    /// WCAG 2.1 relative luminance of an sRGB grey (r = g = b = `white`).
    static func relativeLuminance(white: Double) -> Double {
        white <= 0.04045 ? white / 12.92 : pow((white + 0.055) / 1.055, 2.4)
    }

    /// WCAG 2.1 relative luminance of a full sRGB colour. The grey overload above is this
    /// with all three channels equal — `relativeLuminance(white:)` doubles as the
    /// per-channel linearization, which is the same formula.
    static func relativeLuminance(_ color: CaptureLabelColor) -> Double {
        0.2126 * relativeLuminance(white: color.red)
            + 0.7152 * relativeLuminance(white: color.green)
            + 0.0722 * relativeLuminance(white: color.blue)
    }

    /// Contrast of a full-colour label against this screen's own background.
    static func contrastOnSurface(_ color: CaptureLabelColor) -> Double {
        let a = relativeLuminance(color)
        let b = relativeLuminance(white: backgroundWhite)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
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

/// An sRGB colour as pure channel values, so a non-grey label's contrast stays checkable
/// without SwiftUI — same reasoning that keeps `CaptureTextSize` out of `Font`.
struct CaptureLabelColor: Sendable, Equatable {
    var red: Double
    var green: Double
    var blue: Double

    static func grey(_ white: Double) -> CaptureLabelColor {
        CaptureLabelColor(red: white, green: white, blue: white)
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
    /// The macOS backdate day button (2026-08-15) — the Mac draws its own date button and
    /// calendar sheet instead of a system date picker, so unlike the iOS `.compact` chip
    /// this text is ours to size and colour, and therefore ours to check.
    case backdateDateButton
    /// The one-line "Backdated to …" / "Not backdated" summary shown in place of the full
    /// `BackdateField` while capturing (approach 2, 2026-08-16 IA discussion) — the same
    /// role as `backdateDateButton`, just cross-platform and reachable during a recording
    /// rather than only inside macOS's own picker.
    case backdateSummary
    case multiVoiceToggle
    case recentHeader
    /// Post-stop receipt (2026-08-15).
    case receiptDate
    case receiptSummary
    case receiptSavedChip
    /// Capture errors above the control bar (owner ruling 2026-08-16). Previously raw
    /// `.footnote` + `.red` — 10 pt on the Mac, below the size floor, and dark-mode
    /// system red only manages ~5.7:1 on this surface, below the contrast floor too.
    /// An operating message ("the recorder died") is exactly what the floors exist for,
    /// so it joins the model — as the model's first non-grey.
    case errorBanner

    /// One secondary level (0.78 → 11.5:1) rather than the three near-identical greys this
    /// screen used to carry (0.55/0.6/0.7). Those greys were not expressing a hierarchy —
    /// they were drift — and the darkest of them was the reported bug.
    ///
    /// Almost everything here is a grey; the colour model exists in full-sRGB form for the
    /// one label that is not (owner ruling 2026-08-16: the error banner joins the model
    /// rather than living outside it at 10 pt).
    var labelColor: CaptureLabelColor {
        switch self {
        // The receipt's date is the answer to "what did I just record", so it carries the
        // same full-white weight the journal name does.
        // The backdated date is a value the owner has to read back and confirm, not a
        // caption naming a control — full white, like the journal name and the receipt date.
        case .journalName, .receiptDate, .receiptSavedChip,
             .backdateDateButton, .backdateSummary: .grey(1.0)
        case .journalHeaderCaption, .journalsUnreadable, .backdateToggle,
             .backdateFieldCaption, .multiVoiceToggle, .journalPickerChevron,
             .recentHeader, .receiptSummary: .grey(0.78)
        // Unmistakably red, lightened until it clears the same 7.0:1 floor as every grey
        // here (~8.8:1). Not the system red: dark-mode systemRed (1.0, 0.27, 0.23) is
        // ~5.7:1 on this surface — the same passes-somewhere-fails-here trap as the
        // original 0.55 grey.
        case .errorBanner: CaptureLabelColor(red: 1.0, green: 0.56, blue: 0.52)
        }
    }

    /// The style to draw this label in on a given platform.
    ///
    /// macOS deliberately picks a LARGER semantic style than iOS for the same role — that
    /// is not an inconsistency, it is what keeps the two platforms the same rendered size
    /// given macOS's smaller scale. Read the sizes, not the style names.
    func textSize(on platform: CapturePlatform) -> CaptureTextSize {
        switch platform {
        case .iOS:
            switch self {
            case .journalName, .receiptDate: .title3   // 20
            case .recentHeader: .headline // 17
            case .journalHeaderCaption, .journalsUnreadable, .backdateToggle,
                 .backdateFieldCaption, .multiVoiceToggle, .journalPickerChevron,
                 .receiptSummary,
                 .receiptSavedChip, .backdateDateButton, .backdateSummary,
                 .errorBanner: .callout    // 16
            }
        case .macOS:
            switch self {
            case .journalName, .receiptDate: .title    // 22
            case .recentHeader: .title2  // 17
            case .journalHeaderCaption, .journalsUnreadable, .backdateToggle,
                 .backdateFieldCaption, .multiVoiceToggle, .journalPickerChevron,
                 .receiptSummary,
                 .receiptSavedChip, .backdateDateButton, .backdateSummary,
                 .errorBanner: .title2     // 17
            }
        }
    }
}
