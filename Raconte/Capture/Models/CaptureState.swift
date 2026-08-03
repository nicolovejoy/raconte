import Foundation

/// The capture state machine's value type (design §2). Pure; no I/O.
/// Raw values are the on-disk manifest `state` strings.
enum CaptureState: String, Codable, Sendable, CaseIterable {
    case idle
    case preparing
    case recording
    case interrupted
    case resuming
    case stopping
    /// Durability commit point: raw audio is complete on disk regardless of finalization.
    case captured
    case finalizing
    /// Cleanup milestone: AAC verified, raw segments deleted.
    case complete
}

extension CaptureState {
    /// Issue #12: the display should stay awake exactly while frames are being captured
    /// live — `.recording` and `.resuming` (the brief reconnect after an interruption).
    /// `.interrupted` is deliberately excluded: the owner may be mid-phone-call and wants
    /// normal lock behavior. Every other phase (including `.idle`, which a freshly spawned
    /// coordinator starts in) is false, so a fresh per-capture coordinator can't leak the
    /// hold from the one it replaced. `CaseIterable` lets the test enumerate every case —
    /// a new phase fails the test until classified here.
    var keepsDisplayAwake: Bool {
        switch self {
        case .recording, .resuming: true
        case .idle, .preparing, .interrupted, .stopping, .captured, .finalizing, .complete: false
        }
    }
}

/// Why a segment stopped receiving frames (sidecar `closedReason`).
enum SegmentClosedReason: String, Codable, Sendable {
    case rotation
    case stop
    case interruption
    case appTermination
}

/// PCM sample encoding, mirroring `AVAudioCommonFormat` names without importing AVFoundation.
enum PCMCommonFormat: String, Codable, Sendable {
    case otherFormat
    case pcmFormatFloat32
    case pcmFormatFloat64
    case pcmFormatInt16
    case pcmFormatInt32
}
