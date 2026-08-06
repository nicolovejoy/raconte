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
