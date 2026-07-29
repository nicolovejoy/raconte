import Foundation

/// Inputs to the capture state machine (design §2). Pure value type; the
/// imperative host translates hardware/session/worker signals into these.
enum Event: Sendable, Equatable {
    /// User taps Record. Carries the ULID minted by the host (design §6: ID injected).
    case record(captureID: String)
    /// Engine finished configuring / restarting OK (rows 2, 9).
    case engineReady
    /// Permission denied or session/engine configuration failed (row 3).
    case prepareFailed(CaptureError)
    /// Segment rotation checkpoint reached (row 4).
    case rotationTick
    /// AVAudioSession interruption began — call/Siri/etc. (row 5).
    case interruptionBegan
    /// Route change: the recording device became unavailable (row 6).
    case routeLost
    /// Media services were reset; all AVAudio objects are invalid (row 7).
    case mediaServicesReset
    /// Interruption ended with `.shouldResume`, or the user tapped Resume (row 8).
    case resume
    /// Reacquiring the session/engine failed (rows 10/11 — budget decides).
    case reacquireFailed
    /// User tapped Done (rows 12, 14).
    case done
    /// The flush-window tail has drained; the final segment can close (row 13).
    case tailDrained
    /// The finalization worker picked up a captured recording (row 15).
    case finalizerPickup
    /// Encode + verify succeeded (row 16).
    case finalizeSucceeded
    /// Encode or verify failed (rows 17/18 — budget decides).
    case finalizeFailed
    /// A write hit a disk-full error (row 19).
    case diskFull
    /// App is terminating; last-gasp best-effort flush (row 20).
    case appTerminating
}
