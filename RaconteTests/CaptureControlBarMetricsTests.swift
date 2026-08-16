import XCTest
@testable import Raconte

/// The requirement that shipped without a test, and so shipped wrong.
///
/// Issue #53's fix pinned that the capture controls never move, and every one of its tests
/// passed on a bar that measured 331 pt — 38% of the owner's screen. He rejected it on
/// sight: "the bottom half stays put but it's so big I can't even see the full backdate
/// interface let alone Two voices and Recents." The ruling is a proportion — *at most a
/// third of the screen* — and a proportion is exactly the kind of thing that decays one
/// well-meaning `spacing: 28` at a time unless something checks the total.
///
/// This file checks the total. `CaptureControlsUITests` separately measures what SwiftUI
/// actually renders, because these constants agreeing with each other says nothing about
/// the drawn result.
final class CaptureControlBarMetricsTests: XCTestCase {

    private typealias Bar = CaptureControlBarMetrics

    /// The owner's ruling, on the screen it was made about.
    func testBarFitsWithinAThirdOfTheOwnersScreen() {
        let fraction = Bar.heightFraction(onScreenOfHeight: Bar.ownerScreenHeight)
        XCTAssertLessThanOrEqual(
            fraction, Bar.maximumHeightFraction,
            "the control bar is \(Bar.nominalHeight) pt = "
            + "\(Int((fraction * 100).rounded()))% of an iPhone 17 Pro screen; the ruling "
            + "is a third at most. The shipped version this replaces was 331 pt / 38%.")
    }

    /// A fraction rule checked only on the largest phone is not a fraction rule. The bar is
    /// a fixed number of points, so the smallest screen is where it bites hardest.
    func testBarFitsWithinAThirdOfTheSmallestSupportedScreen() {
        let fraction = Bar.heightFraction(onScreenOfHeight: Bar.compactScreenHeight)
        XCTAssertLessThanOrEqual(
            fraction, Bar.maximumHeightFraction,
            "the control bar is \(Bar.nominalHeight) pt = "
            + "\(Int((fraction * 100).rounded()))% of an iPhone SE screen")
    }

    /// The approved mockup's own figure. Not a restatement of the sum — an independent
    /// number from the design, which the parts have to land near or the build has drifted
    /// from the picture the owner said yes to.
    func testBarLandsNearTheApprovedMockupHeight() {
        XCTAssertEqual(Bar.nominalHeight, 172, accuracy: 20,
                       "Option B was drawn at ≈164 pt; this build is \(Bar.nominalHeight)")
    }

    /// The timer was the costliest single element in the rejected bar: 44 pt for a
    /// readout, in a bar the owner said was too tall. A readout is not a control, and it
    /// should not out-size the things you actually touch.
    ///
    /// Stated against the marker button rather than the record button on purpose. An
    /// earlier version of this test compared it to `recordDiameter` and was VACUOUS: the
    /// rejected geometry was a 44 pt clock against a 132 pt button, so it passed on the
    /// very configuration it was written to reject. Verified by mutation — restoring the
    /// shipped constants must fail this.
    func testTimerDoesNotOutsizeTheControlsItSitsAbove() {
        XCTAssertLessThan(Bar.clockPointSize, Bar.markerButtonHeight,
                          "the elapsed timer (\(Bar.clockPointSize) pt) is as tall as a "
                          + "tappable control again; it was 44 pt in the bar the owner "
                          + "rejected")
    }

    /// The whole point of Option B is that the timer stopped needing a row of its own: it
    /// shares one line with the status text and Done. If the row ever grows past the
    /// record button it has gone back to being a stack.
    func testStatusRowIsShorterThanTheControlRow() {
        XCTAssertLessThan(Bar.statusRowHeight, Bar.recordDiameter,
                          "the status row is taller than the row of controls beneath it")
    }

    /// The marker buttons flank the record button with equal spacers, so equal widths are
    /// what keeps the record button centred. The voice button's label changes mid-capture
    /// ("BN" → "LN", or a journal's own labels), so intrinsic widths would slide the Stop
    /// button sideways on every voice mark — #53 in the horizontal axis.
    func testMarkerButtonsAreFixedAndEqualWidth() {
        XCTAssertGreaterThan(Bar.markerButtonWidth, 0,
                             "marker buttons must have a fixed width, not an intrinsic one")
        XCTAssertGreaterThanOrEqual(Bar.markerButtonWidth, 44,
                                    "below the 44 pt minimum tap target")
        XCTAssertGreaterThanOrEqual(Bar.markerButtonHeight, 44,
                                    "below the 44 pt minimum tap target")
    }

    /// The owner's refinement: the marker buttons move toward the screen edges so Stop
    /// keeps the widest possible exclusion zone around it.
    func testControlRowIsInsetLessThanTheStatusRow() {
        XCTAssertLessThan(Bar.controlRowHorizontalPadding, Bar.horizontalPadding,
                          "the marker buttons are no longer pushed toward the edges")
    }

    /// The record button must still be a comfortable target after shrinking — the ruling
    /// was about the bar's share of the screen, not about making Stop hard to hit while
    /// reading aloud from a page.
    func testRecordButtonRemainsAComfortableTarget() {
        XCTAssertGreaterThanOrEqual(Bar.recordDiameter, 60,
                                    "record button shrank below a comfortable thumb target")
    }
}
