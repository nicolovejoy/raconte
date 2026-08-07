import XCTest
@testable import Raconte

/// The dash-dot marker-confirmation pattern (`MarkerHaptic`) is a pure value — no
/// CoreHaptics import, testable on macOS. `MarkerHapticsPlayer` (Capture/Platform), the
/// CoreHaptics renderer, is intentionally untested here (device-only hardware behavior).
final class MarkerHapticTests: XCTestCase {

    func testPatternIsNonEmpty() {
        XCTAssertFalse(MarkerHaptic.pattern.isEmpty)
    }

    func testPatternIsStrictlyOrderedByRelativeTime() {
        let times = MarkerHaptic.pattern.map(\.relativeTime)
        XCTAssertEqual(times, times.sorted())
        XCTAssertEqual(Set(times).count, times.count, "no two events should land at the same instant")
    }

    func testDashIsFirstAndHasRealDuration() {
        let dash = MarkerHaptic.pattern[0]
        XCTAssertEqual(dash.relativeTime, 0)
        XCTAssertGreaterThan(dash.duration, 0, "the dash must be continuous, not a transient")
    }

    func testDotFollowsTheDashAndIsTransient() {
        let dash = MarkerHaptic.pattern[0]
        let dot = MarkerHaptic.pattern[1]
        XCTAssertEqual(dot.duration, 0, "the dot is an instantaneous tap")
        XCTAssertGreaterThanOrEqual(dot.relativeTime, dash.relativeTime + dash.duration,
                                    "the dot must start no earlier than the dash ends")
    }

    func testDashOutlastsTheDotsImpliedInstant() {
        // The dot has no duration of its own (transient), so "dash longer than dot" is
        // simply that the dash has any positive duration at all.
        XCTAssertGreaterThan(MarkerHaptic.dashDuration, 0)
    }

    func testTotalPatternSpanStaysUnderQuarterSecond() {
        let end = MarkerHaptic.pattern.map { $0.relativeTime + $0.duration }.max() ?? 0
        XCTAssertLessThanOrEqual(end, 0.25)
    }

    func testIntensitiesAreInValidRange() {
        for event in MarkerHaptic.pattern {
            XCTAssertGreaterThan(event.intensity, 0)
            XCTAssertLessThanOrEqual(event.intensity, 1)
        }
    }

    func testSharpnessesAreInValidRange() {
        for event in MarkerHaptic.pattern {
            XCTAssertGreaterThan(event.sharpness, 0)
            XCTAssertLessThanOrEqual(event.sharpness, 1)
        }
    }
}
