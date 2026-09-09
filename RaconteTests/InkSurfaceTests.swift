import XCTest
@testable import Raconte

/// The ink & paper token layer's checkable guarantees — same shape as CaptureLabelTests:
/// the palette is constant, so its contrast is a build-time fact, not a squint test.
final class InkSurfaceTests: XCTestCase {

    /// Reading text on paper: WCAG AA for normal text, both text tones.
    func testInkTonesClearAAOnPaper() {
        XCTAssertGreaterThanOrEqual(InkSurface.contrastOnPaper(InkTone.ink.lightColor), 4.5)
        XCTAssertGreaterThanOrEqual(InkSurface.contrastOnPaper(InkTone.inkSecondary.lightColor), 4.5,
            "inkSecondary is READ text (row second lines, dates) — spec batch 2 puts it at the "
            + "4.5 normal-text floor, not the 3.0 large-text floor it had")
    }

    /// The accent is used for tappable text — it must clear AA for normal text on paper.
    func testAccentClearsAAOnPaper() {
        XCTAssertGreaterThanOrEqual(InkSurface.contrastOnPaper(InkTone.accent.lightColor), 4.5)
    }

    /// The studio tone IS the capture background — one near-black, never two.
    func testStudioMatchesCaptureSurface() {
        let studio = InkTone.studio.lightColor
        XCTAssertEqual(studio.red, CaptureSurface.backgroundWhite)
        XCTAssertEqual(studio.green, CaptureSurface.backgroundWhite)
        XCTAssertEqual(studio.blue, CaptureSurface.backgroundWhite)
    }

    /// Hairline vs paper must differ (a divider that vanishes is drift), but hairlines
    /// are decoration, not text — no WCAG floor, just "not identical".
    func testHairlineIsDistinctFromPaper() {
        XCTAssertNotEqual(InkTone.hairline.lightColor, InkTone.paper.lightColor)
    }

    /// Record red on paper (the library's floating button draws white-on-record):
    /// white on record must clear 3.0 (large text / graphical object floor).
    func testWhiteOnRecordClearsGraphicalFloor() {
        let record = InkTone.record.lightColor
        let luminanceRecord = CaptureSurface.relativeLuminance(record)
        let luminanceWhite = CaptureSurface.relativeLuminance(white: 1.0)
        let contrast = (max(luminanceRecord, luminanceWhite) + 0.05) / (min(luminanceRecord, luminanceWhite) + 0.05)
        XCTAssertGreaterThanOrEqual(contrast, 3.0)
    }

    // MARK: #118 §8 — the capture screen's own tones

    /// Text on studio clears the same 7.0:1 floor `CaptureLabel` enforces; the dim tone
    /// is the live transcript's provisional text (#118 §5) and must still be readable,
    /// just visibly weaker than full ink.
    func testStudioTextTonesClearTheCaptureFloor() {
        XCTAssertGreaterThanOrEqual(
            CaptureSurface.contrastOnSurface(InkTone.studioInk.lightColor),
            CaptureSurface.minimumControlContrast)
        XCTAssertGreaterThanOrEqual(
            CaptureSurface.contrastOnSurface(InkTone.studioInkDim.lightColor),
            CaptureSurface.minimumControlContrast)
        XCTAssertLessThan(
            CaptureSurface.relativeLuminance(InkTone.studioInkDim.lightColor),
            CaptureSurface.relativeLuminance(InkTone.studioInk.lightColor) * 0.5,
            "dim must be unmistakably dimmer than ink, not a near-white")
    }

    /// The card and its border are decoration: no WCAG floor, but each must differ from
    /// the studio ground and from each other, or the card disappears.
    func testStudioCardTonesAreDistinct() {
        XCTAssertNotEqual(InkTone.studioCard.lightColor, InkTone.studio.lightColor)
        XCTAssertNotEqual(InkTone.studioHairline.lightColor, InkTone.studio.lightColor)
        XCTAssertNotEqual(InkTone.studioHairline.lightColor, InkTone.studioCard.lightColor)
        XCTAssertNotEqual(InkTone.studioSaved.lightColor, InkTone.studio.lightColor)
    }

    /// Capture tones do not follow the system appearance — the screen is pinned dark.
    func testStudioTonesAreAppearanceInvariant() {
        for tone in [InkTone.studioInk, .studioInkDim, .studioCard, .studioHairline, .studioSaved] {
            XCTAssertEqual(tone.darkColor, tone.lightColor, "\(tone)")
        }
    }

    /// #161: the warning tone marks a row (the out-of-span glyph) — a graphical object, so
    /// 3.0 is its floor on paper, and it must not collapse into the accent or record tones.
    func testWarningClearsTheGraphicalFloorAndIsItsOwnColour() {
        XCTAssertGreaterThanOrEqual(InkSurface.contrastOnPaper(InkTone.warning.lightColor), 3.0)
        XCTAssertNotEqual(InkTone.warning.lightColor, InkTone.accent.lightColor)
        XCTAssertNotEqual(InkTone.warning.lightColor, InkTone.record.lightColor)
        XCTAssertNotEqual(InkTone.warning.darkColor, InkTone.warning.lightColor,
                          "warning lightens on dark paper, like accent")
    }

    // MARK: #149 batch 2 — text roles on every reading surface, both appearances

    /// The spec's floor table as one loop, not one function per pair. `paper` and `paperInset`
    /// are the two grounds paper text sits on; both appearances, because dark paper is a
    /// different pair of colours, not an inversion. The numbers are re-derived from the channel
    /// values here — this test does not trust the table in the plan.
    func testTextRolesClearTheirFloorsOnEverySurfaceAndAppearance() {
        for (tone, floor) in InkSurface.textFloors {
            for surface in [InkTone.paper, .paperInset] {
                for appearance in InkAppearance.allCases {
                    let ratio = InkSurface.contrast(tone, on: surface, appearance: appearance)
                    XCTAssertGreaterThanOrEqual(
                        ratio, floor,
                        "\(tone) on \(surface) (\(appearance)) is \(ratio) — floor \(floor)")
                }
            }
        }
    }

    /// Disabled must read as disabled: visibly weaker than secondary, on the same ground, in
    /// both appearances. Without this a `inkDisabled` equal to `inkSecondary` passes the floor
    /// loop above and the role is a synonym.
    func testDisabledIsVisiblyWeakerThanSecondary() {
        for appearance in InkAppearance.allCases {
            let secondary = CaptureSurface.relativeLuminance(InkTone.inkSecondary.channels(for: appearance))
            let disabled = CaptureSurface.relativeLuminance(InkTone.inkDisabled.channels(for: appearance))
            let separation = (max(secondary, disabled) + 0.05) / (min(secondary, disabled) + 0.05)
            XCTAssertGreaterThanOrEqual(separation, 1.3,
                "\(appearance): disabled vs secondary is only \(separation):1")
            // Weaker means CLOSER to the paper it sits on, in luminance terms.
            let paper = CaptureSurface.relativeLuminance(InkTone.paper.channels(for: appearance))
            XCTAssertLessThan(abs(disabled - paper), abs(secondary - paper),
                "\(appearance): disabled must sit closer to paper than secondary does")
        }
    }

    /// The general contrast function and the old paper-only one agree — the old one is now a
    /// wrapper, and this pins that the wrapper picks light paper.
    func testContrastOnPaperIsTheLightPaperCaseOfTheGeneralFunction() {
        for tone in [InkTone.ink, .inkSecondary, .inkDisabled, .accent, .warning] {
            XCTAssertEqual(InkSurface.contrastOnPaper(tone.lightColor),
                           InkSurface.contrast(tone, on: .paper, appearance: .light),
                           accuracy: 1e-9, "\(tone)")
        }
    }
}
