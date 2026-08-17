import SwiftUI

/// The SwiftUI half of `CaptureSurface` — kept apart from the model so the model itself
/// stays pure Foundation and unit-testable, matching `MarkerControlsModel`'s split.
extension CaptureTextSize {
    /// Semantic styles, not `.system(size:)`, so Dynamic Type still scales these.
    var font: Font {
        switch self {
        case .caption2: .caption2
        case .caption: .caption
        case .footnote: .footnote
        case .subheadline: .subheadline
        case .callout: .callout
        case .body: .body
        case .headline: .headline
        case .title3: .title3
        case .title2: .title2
        case .title: .title
        }
    }
}

extension CapturePlatform {
    /// The platform this binary is running on — the single place the compile-time
    /// condition lives, so `CaptureLabel`'s tables stay pure and testable for BOTH
    /// platforms from a test run on either one.
    static var current: CapturePlatform {
        #if os(macOS)
        .macOS
        #else
        .iOS
        #endif
    }
}

extension CaptureLabel {
    var color: Color {
        let c = labelColor
        return Color(red: c.red, green: c.green, blue: c.blue)
    }
    var font: Font { textSize(on: .current).font }
}

extension View {
    /// Applies a capture-screen label's checked font and colour together.
    ///
    /// Deliberately one modifier rather than two call sites: the contrast floor is a
    /// property of the *pair*, so letting a view take the colour without the size (or vice
    /// versa) would let half a guarantee through.
    func captureLabel(_ label: CaptureLabel) -> some View {
        font(label.font).foregroundStyle(label.color)
    }
}
