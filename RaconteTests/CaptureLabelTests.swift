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
            let ratio = CaptureSurface.contrastOnSurface(label.labelColor)
            XCTAssertGreaterThanOrEqual(
                ratio, CaptureSurface.minimumControlContrast,
                "\(label.rawValue): \(String(format: "%.2f", ratio)):1 against the capture "
                + "background — below the \(CaptureSurface.minimumControlContrast):1 floor")
        }
    }

    func testEveryControlLabelClearsTheSizeFloorOnBothPlatforms() {
        for platform in CapturePlatform.allCases {
            for label in CaptureLabel.allCases {
                let points = label.textSize(on: platform).pointSize(on: platform)
                XCTAssertGreaterThanOrEqual(
                    points, CaptureSurface.minimumControlPointSize,
                    "\(label.rawValue) on \(platform.rawValue): renders at \(points) pt, "
                    + "below the \(CaptureSurface.minimumControlPointSize) pt floor")
            }
        }
    }

    /// The bug this round exists to fix. The first attempt raised every label to `.callout`,
    /// which is 16 pt on iPhone but only 12 pt on Mac — so the owner reported it still too
    /// small on exactly the platform he had reported it from. A style-name floor is not a
    /// size floor; only points compare across platforms.
    func testTheSameRoleIsNotRenderedSmallerOnMacOSThanOniOS() {
        for label in CaptureLabel.allCases {
            let mac = label.textSize(on: .macOS).pointSize(on: .macOS)
            let ios = label.textSize(on: .iOS).pointSize(on: .iOS)
            XCTAssertGreaterThanOrEqual(
                mac, ios - 1,
                "\(label.rawValue): \(mac) pt on macOS against \(ios) pt on iOS — the Mac "
                + "must not render this role meaningfully smaller")
        }
    }

    /// Pins the table the whole comparison rests on, at the two entries that caused the
    /// miss. If these drift to "whatever makes the floor pass", every assertion above stops
    /// meaning anything.
    func testPointSizeTableMatchesApplesPublishedTypographyAtTheStylesThatMisled() {
        XCTAssertEqual(CaptureTextSize.callout.pointSize(on: .iOS), 16)
        XCTAssertEqual(CaptureTextSize.callout.pointSize(on: .macOS), 12)
        // macOS collapses these three onto one size — the reason a style-based floor failed.
        XCTAssertEqual(CaptureTextSize.caption.pointSize(on: .macOS), 10)
        XCTAssertEqual(CaptureTextSize.footnote.pointSize(on: .macOS), 10)
        XCTAssertEqual(CaptureTextSize.caption2.pointSize(on: .macOS), 10)
    }

    /// The error banner is the model's one non-grey (owner ruling 2026-08-16), and this
    /// pins the "non-" half: the floor test above would happily accept a grey here, and a
    /// grey error banner stops reading as an error at all. Red must dominate.
    func testErrorBannerIsActuallyRedNotAGreyThatPassesTheFloor() {
        let c = CaptureLabel.errorBanner.labelColor
        XCTAssertGreaterThan(c.red, c.green + 0.2, "error banner has stopped being red")
        XCTAssertGreaterThan(c.red, c.blue + 0.2, "error banner has stopped being red")
    }

    /// Same shape as the dim-grey scan below, for the literal the errorBanner case
    /// replaced: a raw `.red` + `.footnote` banner in CaptureView would satisfy every
    /// model rule while drawing 10 pt at 5.7:1 on the Mac.
    func testCaptureViewDoesNotReintroduceTheRawRedErrorBanner() throws {
        let source = try captureViewSource()
        XCTAssertFalse(
            source.contains(".foregroundStyle(.red)"),
            "CaptureView draws a raw .red label — the error banner must route through "
            + "CaptureLabel.errorBanner so its size and contrast are checkable")
    }

    /// Guards the one assumption every ratio above rests on: that this really is the colour
    /// `CaptureView` paints. If the background is lightened, these tests must be re-derived,
    /// not silently kept passing. Since task 2, CaptureView paints via the `InkTone.studio`
    /// token rather than the raw literal — so the source scan checks for the token reference,
    /// and the pin to the actual channel value (`CaptureSurface.backgroundWhite`) is asserted
    /// directly here rather than by grepping a literal that no longer appears in the file.
    func testBackgroundMatchesTheRenderedCaptureBackground() throws {
        XCTAssertTrue(
            try captureViewSource().contains("InkTone.studio.color"),
            "CaptureView no longer paints InkTone.studio.color — "
            + "every contrast figure in this file is derived from that background")
        XCTAssertEqual(
            InkTone.studio.lightColor.red, CaptureSurface.backgroundWhite,
            "InkTone.studio has drifted from CaptureSurface.backgroundWhite — "
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

    /// #118 §8's regression pin: the colour literals `InkTone` absorbed out of `CaptureView`
    /// must not creep back in. Comment-stripped (via the shared `strippingComments` helper,
    /// same as `captureUISources()` above) so a literal merely *named* in a doc comment
    /// explaining this test cannot satisfy the check — a raw-source scan would be.
    func testCaptureViewDoesNotReintroduceTheColourLiteralsInkToneReplaced() throws {
        let source = strippingComments(try captureViewSource())
        for literal in [".foregroundStyle(.white)", "Color.white.opacity(", "Color.green",
                        ".tint(.white)", ".tint(.red)"] {
            XCTAssertFalse(
                source.contains(literal),
                "CaptureView still hardcodes \(literal) — capture-screen colour must route "
                + "through InkTone (#118 §8) so it stays pinned to the near-black studio "
                + "surface regardless of system appearance")
        }
    }

    /// The adversary the floor tests were missing.
    ///
    /// Every assertion above quantifies over `CaptureLabel.allCases` — so a case that no
    /// view ever applies is a guarantee about nothing, and worse, it reads in the suite as
    /// coverage. That is not hypothetical: `journalName` declared `.title` on macOS (22 pt)
    /// and passed every floor above, while `JournalHeaderView` drew the journal name with a
    /// raw `.font(.title3.weight(.semibold))` — 15 pt on the Mac, BELOW the 16 pt floor, on
    /// the exact platform the "font too small" report came from. The model said one thing
    /// and the screen did another, and nothing in the suite could tell.
    ///
    /// This is the same shape as `testCaptureViewDoesNotReintroduceTheDimGreyLiterals…`,
    /// pointed the other way: that one checks no label escapes the model downward, this one
    /// checks no case sits in the model unattached to a label at all.
    func testEveryLabelCaseIsActuallyAppliedToAView() throws {
        let sources = try captureUISources()
        for label in CaptureLabel.allCases {
            XCTAssertTrue(
                sources.contains(".captureLabel(.\(label.rawValue))"),
                "CaptureLabel.\(label.rawValue) is declared and checked by every floor in "
                + "this file, but no view applies it — so those checks prove nothing about "
                + "the screen. Either apply it, or delete the case")
        }
    }

    /// The hole the two scans above leave between them, found in the record-flow final
    /// review: a label CAN route through the model and still draw an unswept colour, by
    /// overriding it on the very next line. The discard notice did exactly that —
    /// `.captureLabel(.receiptSavedChip)` followed by `.foregroundStyle(.white.opacity(0.7))`
    /// — so every floor in this file measured `receiptSavedChip`'s full white while the
    /// screen painted something else. It cleared the floors anyway, which is the point:
    /// nothing here could have told us either way.
    ///
    /// A `.foregroundStyle` immediately after a `.captureLabel` is always this mistake. The
    /// fix is a case of its own (`discardNotice`), not an override. The build stamp's own
    /// `.white.opacity(0.35)` is untouched by this — it is deliberately outside the model
    /// (see `CaptureLabel`'s doc comment) and never carries a `.captureLabel`.
    func testNoLabelOverridesTheColourCaptureLabelJustGaveIt() throws {
        let lines = try captureUISources()
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        for (index, line) in lines.enumerated() where line.hasPrefix(".captureLabel(") {
            let next = index + 1 < lines.count ? lines[index + 1] : ""
            XCTAssertFalse(
                next.hasPrefix(".foregroundStyle("),
                "\(line) is followed by \(next) — a capture-screen label may not override the "
                + "colour CaptureLabel just gave it, or every floor in this file is measuring "
                + "a colour the screen does not paint. Add a CaptureLabel case instead")
        }
    }

    /// #118 final-review fix wave. `InkTone.studioInkDim` has exactly one call site
    /// (`LiveTranscriptText.swift:14`), and `LiveTranscriptTextTests` inject `.white`/
    /// `.gray` directly rather than the token — so `InkSurfaceTests.
    /// testStudioTextTonesClearTheCaptureFloor` can pass while measuring a colour nothing
    /// on screen paints. This source scan is the only pin that the view actually applies
    /// both studio tones, not just injectable stand-ins for them.
    func testTheLiveTranscriptActuallyAppliesTheStudioTones() throws {
        let sources = try captureUISources()   // comment-stripped, Raconte/Capture/UI
        XCTAssertTrue(sources.contains("InkTone.studioInk.color"))
        XCTAssertTrue(sources.contains("InkTone.studioInkDim.color"),
                      "studioInkDim's contrast floors are decorative unless a view applies it")
    }

    /// Concatenated source of every capture-screen view, comments stripped (via the
    /// shared `strippingComments` helper) so a case merely *named* in prose cannot
    /// satisfy the check above.
    private func captureUISources() throws -> String {
        let uiDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()          // RaconteTests
            .deletingLastPathComponent()          // repo root
            .appendingPathComponent("Raconte/Capture/UI")
        let files = try FileManager.default
            .contentsOfDirectory(at: uiDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty, "found no capture UI sources to scan")
        let joined = try files
            .map { try String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")
        return strippingComments(joined)
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
