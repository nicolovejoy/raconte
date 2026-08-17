import Foundation

/// Pure description of the "dash-dot" haptic confirmation for a structure-marker tap
/// landing on disk (owner device feedback 2026-08-07: the single `.sensoryFeedback(.impact,
/// …)` in `MarkerControlsRow` reads as "a weak single dot"). Giving the dash a real
/// duration needs CoreHaptics — `.sensoryFeedback` and `UIImpactFeedbackGenerator` can only
/// express instantaneous taps, not a buzz that outlasts one. This file stays pure (no
/// CoreHaptics import, no platform `#if`) so it is testable on macOS too; `MarkerHapticsPlayer`
/// (Capture/Platform) is the thin renderer that turns it into real `CHHapticEvent`s on iOS.
enum MarkerHaptic {

    /// One event on the pattern's own relative-time axis, seconds from pattern start.
    /// `duration == 0` renders as a transient (an instant tap); `duration > 0` renders as
    /// continuous — the only way to give a beat a felt length. `intensity`/`sharpness` are
    /// CoreHaptics' own [0, 1] parameters, carried here unconverted so the platform layer
    /// does no tuning of its own.
    struct Event: Equatable, Sendable {
        var relativeTime: Double
        var duration: Double
        var intensity: Double
        var sharpness: Double
    }

    // Tune here, nowhere else — same convention as `MarkerSnapping.snapWindowSeconds`.
    /// The dash: a short continuous buzz at full intensity — the "longer" half of the pair.
    static let dashDuration: Double = 0.12
    /// Silence between dash and dot, long enough for the pair to read as two distinct
    /// beats rather than one blurred buzz.
    static let gapDuration: Double = 0.06
    static let dashIntensity: Double = 1.0
    /// Slightly below the dash's, so a dash-then-dot pair doesn't read as two equal beats.
    static let dotIntensity: Double = 0.7
    /// Shared by both events — one pattern, one felt texture.
    static let sharpness: Double = 0.5

    /// The dash-dot pattern: a `dashDuration` continuous buzz at full intensity, a
    /// `gapDuration` silence, then an instantaneous dot. Ends at `dashDuration +
    /// gapDuration` (0.18 s as tuned above) — comfortably inside the ≤ 0.25 s budget so the
    /// whole thing still reads as one quick confirmation, not a tap-and-wait.
    static let pattern: [Event] = [
        Event(relativeTime: 0,
             duration: dashDuration,
             intensity: dashIntensity,
             sharpness: sharpness),
        Event(relativeTime: dashDuration + gapDuration,
             duration: 0,
             intensity: dotIntensity,
             sharpness: sharpness)
    ]
}

/// The SAME dash-dot, as light instead of touch (#63, owner ruling 2026-08-16: "a little
/// visual signal that's subtle … i like that with the haptic too. nothing too bold, but
/// easy to detect"). Macs have no haptic engine the owner uses, so on macOS this is the
/// whole confirmation; on iOS it plays alongside the buzz — one rhythm, two senses.
///
/// Pure values like `MarkerHaptic` above, for the same reason: the pattern is testable
/// without SwiftUI, and the view layer does no tuning of its own.
enum MarkerFlash {

    /// One lit interval on the pattern's own relative-time axis: the tapped button's
    /// surface brightens by `brightness` (a white-overlay opacity) for `duration`.
    struct Step: Equatable, Sendable {
        var relativeTime: Double
        var duration: Double
        var brightness: Double
    }

    // Tune here, nowhere else — same convention as `MarkerHaptic`'s constants above.
    /// Both blinks are this long. Owner smoke 2026-08-16 on the first cut ("pass, a bit
    /// too flashy — just a single blink would be fine, or two very short ones"): the
    /// first blink used to hold the dash's full 0.12 s of light, which reads bolder to
    /// the eye than the same duration does to the thumb. Two very short winks keep the
    /// dash-dot identity with the haptic; only the lit time shrank.
    static let blinkDuration: Double = 0.05
    /// White-overlay opacities on the near-black capture surface: detectable in
    /// peripheral vision, deliberately nowhere near a strobe ("nothing too bold").
    /// Dropped from 0.4/0.25 in the same smoke round.
    static let dashBrightness: Double = 0.3
    static let dotBrightness: Double = 0.2

    /// The dash-dot, lit: the same BEAT TIMES as `MarkerHaptic.pattern` (pinned by test —
    /// the two senses never disagree about when a marker landed), with the dash's light
    /// slightly brighter than the dot's — the intensity hierarchy the thumb already
    /// knows, shown rather than held.
    static let steps: [Step] = [
        Step(relativeTime: 0,
             duration: blinkDuration,
             brightness: dashBrightness),
        Step(relativeTime: MarkerHaptic.dashDuration + MarkerHaptic.gapDuration,
             duration: blinkDuration,
             brightness: dotBrightness)
    ]

    /// When the last step's light goes out — the view's cue to tidy its overlay state.
    static var totalDuration: Double {
        steps.map { $0.relativeTime + $0.duration }.max() ?? 0
    }
}
