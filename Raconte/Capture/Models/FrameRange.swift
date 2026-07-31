import Foundation

/// A half-open span of capture frames, `[start, end)`, on the same axis as
/// `SegmentSidecar.startFrameOffset` — so a range is directly a position in the
/// finalized `recording.m4a`.
///
/// Used for gaps a derived consumer couldn't keep up with (`BoundedPCMSink`
/// drops) and, in M2 T3, for `TranscriptRef.skippedRanges`.
struct FrameRange: Codable, Sendable, Equatable {
    var start: Int64
    var end: Int64

    init(start: Int64, end: Int64) {
        self.start = start
        self.end = end
    }

    var frameCount: Int64 { max(0, end - start) }

    /// True when `other` begins exactly where this one ends — the coalescing test.
    func isContiguous(with other: FrameRange) -> Bool { end == other.start }
}
