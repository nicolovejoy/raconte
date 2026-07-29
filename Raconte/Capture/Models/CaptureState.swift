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
