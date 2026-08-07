import Foundation

#if os(iOS)
import CoreHaptics

/// Renders `MarkerHaptic.pattern` (the pure dash-dot spec) as real `CHHapticEvent`s.
/// `.sensoryFeedback`/`UIImpactFeedbackGenerator` can only express instantaneous taps, so
/// the dash's real duration needs CoreHaptics directly (owner device feedback
/// 2026-08-07). Recording already opts in to haptics via
/// `IOSAudioSessionController.activate`'s `setAllowHapticsAndSystemSoundsDuringRecording`.
///
/// Every failure — no haptics hardware, engine creation, engine reset/stop, pattern/player
/// errors — degrades silently. Haptics are cosmetic confirmation; they must never affect
/// capture (design §5, same rule as the `sensoryFeedback` modifier this replaces).
@MainActor
final class MarkerHapticsPlayer {
    private var engine: CHHapticEngine?

    init() {}

    /// Plays the dash-dot confirmation. Safe to call from the main actor — engine
    /// creation/start is fast, and every failure path is a silent no-op.
    func play() {
        guard let engine = currentEngine() else { return }
        do {
            let pattern = try CHHapticPattern(events: MarkerHaptic.pattern.map(Self.makeEvent), parameters: [])
            let player = try engine.makePlayer(with: pattern)
            try player.start(atTime: CHHapticTimeImmediate)
        } catch {
            // Cosmetic only — never surface a haptics failure to the capture path.
        }
    }

    /// Lazily creates and starts the engine, and recreates it if a prior instance was
    /// reset or stopped out from under us (interruption, route change, background —
    /// CoreHaptics has its own suspension model independent of `AVAudioSession`).
    private func currentEngine() -> CHHapticEngine? {
        if let engine {
            return engine
        }
        guard CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return nil }
        do {
            let newEngine = try CHHapticEngine()
            // CoreHaptics calls these on its own queue; `engine` is main-actor state, so
            // hop rather than assign in place (the compiler can't see across the ObjC
            // boundary that these closures leave the main actor).
            newEngine.stoppedHandler = { [weak self] _ in
                Task { @MainActor in self?.engine = nil }
            }
            newEngine.resetHandler = { [weak self] in
                Task { @MainActor in self?.engine = nil }
            }
            try newEngine.start()
            engine = newEngine
            return newEngine
        } catch {
            return nil
        }
    }

    private static func makeEvent(_ event: MarkerHaptic.Event) -> CHHapticEvent {
        let parameters = [
            CHHapticEventParameter(parameterID: .hapticIntensity, value: Float(event.intensity)),
            CHHapticEventParameter(parameterID: .hapticSharpness, value: Float(event.sharpness))
        ]
        let type: CHHapticEvent.EventType = event.duration > 0 ? .hapticContinuous : .hapticTransient
        return CHHapticEvent(eventType: type,
                             parameters: parameters,
                             relativeTime: event.relativeTime,
                             duration: event.duration)
    }
}

#else

/// macOS has no Taptic-style haptic device for this use — CoreHaptics targets game
/// controllers here, not the machine itself. No-op so `MarkerControlsRow` needs no
/// platform `#if` of its own.
@MainActor
final class MarkerHapticsPlayer {
    init() {}
    func play() {}
}

#endif
