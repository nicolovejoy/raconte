import Foundation

/// Pure phase+toggle → marker-control state (T6 §14 step 5), mirroring
/// `RecordControlModel.make(phase:canResume:)`: the testable core of the capture
/// screen's structure-marker controls, with no SwiftUI and no I/O.
///
/// The `switch` is exhaustive with no `default` on purpose — a new `CaptureState`
/// must break the build here rather than silently hiding the controls in a phase
/// nobody thought about.
struct MarkerControlsModel: Equatable, Sendable {
    /// The BN/LN voice switch. Present in every recording (#118 §4) — there is no
    /// pre-record toggle left to gate it.
    var showsVoiceControl: Bool
    /// The paragraph button. Independent of the voice switch (owner decision 7)
    /// — paragraphs are structure in a single-voice reading too.
    var showsParagraphControl: Bool
    /// Taps land only in `.recording` (design §5). The controls are shown in every phase —
    /// greyed everywhere else — so the layout never jumps.
    var isEnabled: Bool

    // There was a `reservedForLayout` constant here, and an `isVisible` flag, from the
    // #53 build: the marks had a ROW of their own inside a bottom-anchored bar, so the
    // row's height had to be reserved in phases where it drew nothing or the record button
    // moved 151 pt between idle and recording. Both are gone with the Option B rebuild
    // (2026-08-15) — the marks now flank the record button in fixed-size slots that hold
    // their space individually, so no phase-dependent substitute model is needed to keep
    // the geometry constant. See `RecordControlsRow.markerButton`.

    /// Owner ruling, 2026-08-16 smoke: "when I select Two voices, show the switcher button
    /// right away, don't wait for me to hit record. Just greyed out. Same with paragraph
    /// button, leave it up, but grey, when not recording."
    ///
    /// The controls used to appear only from `.recording`, which made the Two-voices toggle
    /// look inert: you turn on the thing whose whole purpose is the voice switch, and nothing
    /// appears. They are the answer to "can this reading be marked at all", and that is asked
    /// BEFORE the record button is pressed. So visibility is phase-independent — voice and
    /// paragraph both shown in every phase (owner decision 7) — and only `isEnabled` tracks
    /// the phase.
    ///
    /// The cases stay listed individually rather than collapsing to `default`: a new
    /// `CaptureState` must still break the build here and be considered, which is the
    /// property this type was written for.
    static func make(phase: CaptureState) -> MarkerControlsModel {
        switch phase {
        case .idle, .preparing, .recording, .interrupted, .resuming,
             .stopping, .captured, .finalizing, .complete:
            // #118 §4: the voice switch is present in every recording. The Two-voices
            // toggle that used to gate it is gone; `VoiceMarkingPlan.openerIfNeeded`
            // makes a single-voice recording convertible after the fact, so nothing the
            // gate protected is lost.
            return .init(showsVoiceControl: true,
                         showsParagraphControl: true,
                         // Only `.recording` has a frame to anchor a marker to; a tap in any
                         // other phase would have nowhere to land.
                         isEnabled: phase == .recording)
        }
    }
}
