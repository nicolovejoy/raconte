import XCTest
@testable import Raconte

/// The capture screen paints a fixed near-black background in every appearance, so it can
/// never delegate legibility to the system's light/dark handling — a label that is too dim
/// or too small there is too dim or too small for every user, forever, and no amount of
/// appearance-switching reveals it.
///
/// Owner smoke, 2026-08-15 (macOS): "font too small, text color too dark (similar to black
/// background)". The labels in question were `.caption` at `Color(white: 0.55)`, which
/// measures 5.81:1 — a PASSING WCAG AA score. That is precisely why nothing caught it, and
/// why the floor below is AAA rather than AA: AA was tried against this exact surface and
/// found insufficient in the field.
final class CaptureLabelTests: XCTestCase {

    // MARK: - The contrast math itself
    //
    // Pinned against published WCAG reference values FIRST. Without this, every assertion
    // below would only be proving that two of my own constants agree with each other.

    func testContrastRatioMatchesPublishedWCAGReferenceValues() {
        // Black on white is the definitional maximum, 21:1.
        XCTAssertEqual(CaptureSurface.contrastRatio(white: 1.0, against: 0.0), 21.0, accuracy: 0.01)
        // Any colour against itself is 1:1.
        XCTAssertEqual(CaptureSurface.contrastRatio(white: 0.5, against: 0.5), 1.0, accuracy: 0.0001)
        // Mid-grey (#808080, sRGB 0.5019) on black is a published 5.32:1.
        XCTAssertEqual(CaptureSurface.contrastRatio(white: 0.5019, against: 0.0), 5.32, accuracy: 0.01)
    }

    func testContrastRatioIsSymmetric() {
        XCTAssertEqual(CaptureSurface.contrastRatio(white: 0.8, against: 0.05),
                       CaptureSurface.contrastRatio(white: 0.05, against: 0.8),
                       accuracy: 0.0001)
    }

    /// The low end of the sRGB curve is linear, not a power function — a detail that is easy
    /// to drop and that would quietly inflate every ratio measured against this near-black
    /// background specifically.
    func testRelativeLuminanceUsesTheLinearSegmentBelowTheCurveThreshold() {
        XCTAssertEqual(CaptureSurface.relativeLuminance(white: 0.04), 0.04 / 12.92, accuracy: 1e-9)
        XCTAssertEqual(CaptureSurface.relativeLuminance(white: 0.0), 0.0, accuracy: 1e-9)
        XCTAssertEqual(CaptureSurface.relativeLuminance(white: 1.0), 1.0, accuracy: 1e-9)
    }

    // MARK: - The rules the owner's smoke feedback bought

    func testEveryControlLabelClearsTheContrastFloor() {
        for label in CaptureLabel.allCases {
            let ratio = CaptureSurface.contrastOnSurface(white: label.whiteLevel)
            XCTAssertGreaterThanOrEqual(
                ratio, CaptureSurface.minimumControlContrast,
                "\(label.rawValue): \(String(format: "%.2f", ratio)):1 against the capture "
                + "background — below the \(CaptureSurface.minimumControlContrast):1 floor")
        }
    }

    func testEveryControlLabelClearsTheSizeFloor() {
        for label in CaptureLabel.allCases {
            XCTAssertGreaterThanOrEqual(
                label.size, CaptureSurface.minimumControlSize,
                "\(label.rawValue): \(label.size) is below the \(CaptureSurface.minimumControlSize) floor")
        }
    }

    /// The floor has to be a real increase on BOTH platforms. macOS renders `.caption` and
    /// `.footnote` at the same 10 pt, so a floor set at `.footnote` would leave the reported
    /// bug fully intact on the exact platform it was reported from.
    func testSizeFloorIsAboveTheSizesThatMacOSRendersIdentically() {
        XCTAssertGreaterThan(CaptureSurface.minimumControlSize, .footnote,
                             "a .caption/.footnote floor is a no-op on macOS, where both are 10 pt")
    }

    /// Guards the one assumption every ratio above rests on: that this really is the colour
    /// `CaptureView` paints. If the background is lightened, these tests must be re-derived,
    /// not silently kept passing.
    func testBackgroundMatchesTheRenderedCaptureBackground() throws {
        XCTAssertTrue(
            try captureViewSource().contains("Color(white: \(CaptureSurface.backgroundWhite))"),
            "CaptureView no longer paints Color(white: \(CaptureSurface.backgroundWhite)) — "
            + "every contrast figure in this file is derived from that background")
    }

    /// Without this, every assertion above is decorative: `CaptureLabel` could satisfy all of
    /// them while `CaptureView` went on drawing its own hardcoded greys, and the screen the
    /// owner actually looks at would be unchanged. SwiftUI bodies cannot be introspected, so
    /// the honest available pin is that the dim literals this model replaced are GONE from
    /// the file — reintroducing one fails here rather than in a smoke test six weeks later.
    func testCaptureViewDoesNotReintroduceTheDimGreyLiteralsThisModelReplaced() throws {
        let source = try captureViewSource()
        for grey in ["Color(white: 0.55)", "Color(white: 0.6)", "Color(white: 0.7)"] {
            XCTAssertFalse(
                source.contains(grey),
                "CaptureView still hardcodes \(grey) — capture-screen labels must route "
                + "through CaptureLabel so their contrast is checkable")
        }
    }

    private func captureViewSource() throws -> String {
        try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()      // RaconteTests
                .deletingLastPathComponent()      // repo root
                .appendingPathComponent("Raconte/Capture/UI/CaptureView.swift"),
            encoding: .utf8)
    }
}
