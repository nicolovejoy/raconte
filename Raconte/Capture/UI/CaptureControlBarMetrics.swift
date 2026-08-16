import Foundation

/// The capture control bar's geometry, as points, in one pure place.
///
/// This exists because of a requirement no earlier test encoded. Issue #53 pinned that the
/// controls never MOVE; the owner's next complaint (smoke, 2026-08-15) was that they were
/// too BIG — "the bottom half stays put but it's so big I can't even see the full backdate
/// interface let alone Two voices and Recents". The ruling that came out of it: **the
/// record section takes at most a third of the screen**, and the important controls stay
/// visible up top.
///
/// "At most a third" is a property of the sum of these constants, so the constants live
/// here rather than being scattered through `CaptureView.body` where the only way to check
/// the total is to build the app and hold it. `CaptureControlBarMetricsTests` does the
/// arithmetic; `CaptureControlsUITests` measures the rendered result, because a nominal
/// height agreeing with itself proves nothing about what SwiftUI actually draws.
enum CaptureControlBarMetrics {

    // MARK: - The ceiling

    /// The owner's ruling, as a number: the bar may occupy at most this fraction of the
    /// screen's height.
    static let maximumHeightFraction: Double = 1.0 / 3.0

    /// The screen the ruling was measured against — iPhone 17 Pro, the owner's device, in
    /// points. The shipped bar was 331 pt here, which is 38%.
    static let ownerScreenHeight: Double = 874

    /// The shortest screen worth holding this to: iPhone SE (3rd gen). A fraction rule is
    /// only as good as the smallest screen it is checked on, and a bar sized to look
    /// modest on a 17 Pro can still swallow an SE.
    static let compactScreenHeight: Double = 667

    // MARK: - Option B (owner-approved mockup, 2026-08-15)

    /// Space above the status row.
    static let topPadding: Double = 12

    /// Between the three rows (status, meter, controls). The shipped bar used 28 pt gaps
    /// throughout, which alone accounted for more height than the record button.
    static let rowSpacing: Double = 10

    /// The top row: elapsed timer, live dot, status text, and Done — all on one line.
    ///
    /// FIXED, not sized to content, and that is load-bearing rather than tidy. The status
    /// string varies ("Recording" against "Interrupted — reconnecting…"), the bar is
    /// anchored to the bottom edge, and anything of variable height inside it grows the
    /// bar upward and shoves the record button under the owner's thumb — measured at
    /// 151 pt during the #53 build. A fixed row plus `lineLimit(1)` makes a long status
    /// message shrink rather than reflow.
    static let statusRowHeight: Double = 36

    /// The elapsed-time readout.
    ///
    /// This is the single change that bought the most height. It was 44 pt — taller than
    /// the record button beneath it, and the largest item in a bar the owner rejected for
    /// being too large. The approved mockup drew it at roughly 27 pt while its own summary
    /// table said 19 pt; 24 pt splits them and is subject to the owner's smoke ruling.
    /// Whatever it settles at, it no longer governs the row: Done is the taller element.
    static let clockPointSize: Double = 24

    /// Height of the mic meter (`MicMeter` owns the same number for its own frame).
    static let meterHeight: Double = 8

    /// The record button's diameter, down from 132.
    ///
    /// It stops being the sole occupant of its row: the voice switch and the paragraph
    /// button now flank it, so the row costs what the button costs and the two rows they
    /// used to need are gone.
    static let recordDiameter: Double = 76

    /// The record glyph, kept in the same proportion to the button as before (46/132).
    static let recordGlyphPointSize: Double = 28

    /// Space below the control row, before the safe area.
    static let bottomPadding: Double = 20

    // MARK: - Horizontal

    /// Standard inset for the status row, matching the setup band above it.
    static let horizontalPadding: Double = 24

    /// Inset for the control row specifically — deliberately tighter than the status row.
    ///
    /// The owner's refinement on the mockup, verbatim: *"just make sure we separate the
    /// clickable buttons as much as we can within that paradigm… BN and paragraph marker
    /// could move towards the side just a bit"*. Pushing the marker buttons out to the
    /// edges is what keeps the widest possible dead zone around Stop, so a marker tap
    /// during a reading cannot land on it.
    static let controlRowHorizontalPadding: Double = 8

    /// Both marker buttons render at this exact width, whatever their label.
    ///
    /// Equal fixed widths, not intrinsic ones. The two buttons flank the record button
    /// with equal spacers, so unequal side widths would push the record button off centre
    /// — and the voice button's label CHANGES mid-recording ("BN" → "LN", or a journal's
    /// own labels, which can be any length). Intrinsic sizing would therefore move the
    /// Stop button horizontally on every voice mark, which is #53 again in the other axis.
    static let markerButtonWidth: Double = 76

    /// Height of each marker button, matching `.controlSize(.large)`.
    static let markerButtonHeight: Double = 44

    // MARK: - Derived

    /// What the bar adds up to, top padding to bottom padding.
    static var nominalHeight: Double {
        topPadding
            + statusRowHeight
            + rowSpacing
            + meterHeight
            + rowSpacing
            + recordDiameter
            + bottomPadding
    }

    /// The bar's share of a screen of the given height.
    static func heightFraction(onScreenOfHeight screenHeight: Double) -> Double {
        nominalHeight / screenHeight
    }
}
