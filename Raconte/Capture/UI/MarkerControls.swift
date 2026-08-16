import Foundation

/// Pure phase+toggle → marker-control state (T6 §14 step 5), mirroring
/// `RecordControlModel.make(phase:canResume:)`: the testable core of the capture
/// screen's structure-marker controls, with no SwiftUI and no I/O.
///
/// The `switch` is exhaustive with no `default` on purpose — a new `CaptureState`
/// must break the build here rather than silently hiding the controls in a phase
/// nobody thought about.
struct MarkerControlsModel: Equatable, Sendable {
    /// The BN/LN voice switch. Gated on the multi-voice toggle (design §5).
    var showsVoiceControl: Bool
    /// The paragraph button. Independent of the multi-voice toggle (owner decision 7)
    /// — paragraphs are structure in a single-voice reading too.
    var showsParagraphControl: Bool
    /// Taps land only in `.recording` (design §5); the controls stay *shown* through
    /// `.interrupted`/`.resuming` so the layout doesn't jump across an interruption
    /// (plan §0.3.9).
    var isEnabled: Bool

    // There was a `reservedForLayout` constant here, and an `isVisible` flag, from the
    // #53 build: the marks had a ROW of their own inside a bottom-anchored bar, so the
    // row's height had to be reserved in phases where it drew nothing or the record button
    // moved 151 pt between idle and recording. Both are gone with the Option B rebuild
    // (2026-08-15) — the marks now flank the record button in fixed-size slots that hold
    // their space individually, so no phase-dependent substitute model is needed to keep
    // the geometry constant. See `RecordControlsRow.markerButton`.

    static func make(phase: CaptureState, multiVoice: Bool) -> MarkerControlsModel {
        switch phase {
        case .recording, .interrupted, .resuming:
            return .init(showsVoiceControl: multiVoice,
                         showsParagraphControl: true,
                         isEnabled: phase == .recording)
        case .idle, .preparing, .stopping, .captured, .finalizing, .complete:
            return .init(showsVoiceControl: false,
                         showsParagraphControl: false,
                         isEnabled: false)
        }
    }
}
