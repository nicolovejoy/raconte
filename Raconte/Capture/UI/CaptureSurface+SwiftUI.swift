import SwiftUI

/// The SwiftUI half of `CaptureSurface` — kept apart from the model so the model itself
/// stays pure Foundation and unit-testable, matching `MarkerControlsModel`'s split.
extension CaptureTextSize {
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
        }
    }
}

extension CaptureLabel {
    var color: Color { Color(white: whiteLevel) }
    var font: Font { size.font }
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
