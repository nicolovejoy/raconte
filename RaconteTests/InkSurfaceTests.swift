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
}
