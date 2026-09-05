import XCTest
@testable import Raconte

/// The ink & paper token layer's checkable guarantees — same shape as CaptureLabelTests:
/// the palette is constant, so its contrast is a build-time fact, not a squint test.
final class InkSurfaceTests: XCTestCase {

    /// Reading text on paper: WCAG AA for normal text, both text tones.
    func testInkTonesClearAAOnPaper() {
        XCTAssertGreaterThanOrEqual(InkSurface.contrastOnPaper(InkTone.ink.lightColor), 4.5)
        XCTAssertGreaterThanOrEqual(InkSurface.contrastOnPaper(InkTone.inkSecondary.lightColor), 3.0,
            "inkSecondary is a secondary tone — 3.0 (large-text AA) is its floor")
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
}
