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

    // MARK: - MarkerFlash (#63): the same dash-dot as light

    /// The property the visual pattern exists for: it is the haptic's rhythm, seen. Every
    /// haptic beat starts a lit interval at the same instant — the two senses never say
    /// different things about when a marker landed.
    func testFlashStartsALitIntervalAtEveryHapticBeat() {
        XCTAssertEqual(MarkerFlash.steps.map(\.relativeTime),
                       MarkerHaptic.pattern.map(\.relativeTime),
                       "the flash must follow the haptic's own beat times")
    }

    /// Unlike the haptic's transient dot, a zero-duration LIGHT is invisible — every
    /// visual step needs real screen time.
    func testEveryFlashStepHasVisibleDuration() {
        XCTAssertFalse(MarkerFlash.steps.isEmpty)
        for step in MarkerFlash.steps {
            XCTAssertGreaterThan(step.duration, 0, "an instantaneous flash cannot be seen")
        }
    }

    /// The gap is what makes dash-dot read as two beats — lit intervals must not bleed
    /// into each other.
    func testFlashStepsDoNotOverlap() {
        let steps = MarkerFlash.steps
        for (a, b) in zip(steps, steps.dropFirst()) {
            XCTAssertLessThanOrEqual(a.relativeTime + a.duration, b.relativeTime,
                                     "lit intervals overlap — the pattern blurs into one blink")
        }
    }

    /// Same ≤ 0.25 s budget as the haptic: one quick confirmation, not a light show.
    func testFlashEndsInsideTheHapticsQuarterSecondBudget() {
        XCTAssertLessThanOrEqual(MarkerFlash.totalDuration, 0.25)
    }

    /// "Nothing too bold, but easy to detect" (owner, 2026-08-16): overlay opacities stay
    /// in a subtle band — bright enough to catch peripheral vision on the near-black
    /// surface, never a full-surface strobe. Dash outshines dot, mirroring the intensity
    /// hierarchy the haptic already has.
    func testFlashBrightnessesAreSubtleAndDashLed() {
        for step in MarkerFlash.steps {
            XCTAssertGreaterThanOrEqual(step.brightness, 0.1, "too dim to detect at a glance")
            XCTAssertLessThanOrEqual(step.brightness, 0.5, "too bold for a confirmation")
        }
        let dash = MarkerFlash.steps[0]
        let dot = MarkerFlash.steps[1]
        XCTAssertGreaterThan(dash.brightness, dot.brightness,
                             "the pair must read dash-then-dot, not two equal beats")
    }
}
