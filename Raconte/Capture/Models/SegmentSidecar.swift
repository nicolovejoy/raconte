import Foundation

/// Audio format record embedded in sidecars and the manifest (design §1).
/// `bytesPerFrame` is present in segment sidecars and omitted in the manifest's
/// format block (nil → key absent under synthesized Codable).
struct AudioFormatDescriptor: Codable, Sendable, Equatable {
    var sampleRate: Int
    var channels: Int
    var commonFormat: PCMCommonFormat
    var interleaved: Bool
    var bytesPerFrame: Int?

    init(sampleRate: Int, channels: Int, commonFormat: PCMCommonFormat,
         interleaved: Bool, bytesPerFrame: Int? = nil) {
        self.sampleRate = sampleRate
        self.channels = channels
        self.commonFormat = commonFormat
        self.interleaved = interleaved
        self.bytesPerFrame = bytesPerFrame
    }
}

/// Per-finalized-segment checkpoint (`NNNNNN.json`), written after the `.pcm`
/// is fsync'd and renamed (design §1). `startFrameOffset + frameCount` yields
/// exact cumulative duration without decoding any PCM.
struct SegmentSidecar: Codable, Sendable, Equatable {
    var captureID: String
    var index: Int
    var format: AudioFormatDescriptor
    var frameCount: Int
    /// Cumulative frames before this segment (sum of all prior segments' frameCount).
    var startFrameOffset: Int
    /// Engine time of the first frame, seconds (monotonic host clock).
    var startHostTime: Double
    var wallClockStart: Date
    /// First 8 hex chars of sha256(pcm bytes) — integrity, not security.
    var sha256Prefix: String
    var closedReason: SegmentClosedReason
    var byteCount: Int
}
