import Foundation

/// Where a global playback frame lands inside an ordered segment set.
/// `position` is the index *into the ordered array*, not `EncodableSegment.index`.
struct SegmentSeekPlan: Equatable, Sendable {
    var position: Int
    var frameOffsetInSegment: Int
}

/// Pure seek math for raw-segment playback (issue #6). No filesystem, no audio.
///
/// Walks cumulative `frameCount`, never `startFrameOffset`: `rawSegments` takes
/// `startFrameOffset` from the sidecar and tolerates gaps in that chain, but what
/// `SegmentPlayer` actually renders is the concatenation of the `frameCount`s.
/// Seeking off `startFrameOffset` would desync the playhead wherever a gap exists.
enum PlaybackSeek {
    /// The segment holding `globalFrame` and the offset within it, or nil when the
    /// frame is out of range (negative, at/past the total, or no frames at all).
    static func plan(frameCounts: [Int], globalFrame: Int) -> SegmentSeekPlan? {
        guard globalFrame >= 0 else { return nil }
        var running = 0
        for (position, rawCount) in frameCounts.enumerated() {
            let count = max(0, rawCount)
            guard count > 0 else { continue }   // zero-frame segments never own a frame
            if globalFrame < running + count {
                return SegmentSeekPlan(position: position,
                                       frameOffsetInSegment: globalFrame - running)
            }
            running += count
        }
        return nil
    }

    /// Clamp into `[0, totalFrames]` — the end is addressable (a seek to the end
    /// is "finished"), even though `plan` returns nil there.
    static func clampFrame(_ frame: Int, totalFrames: Int) -> Int {
        let total = max(0, totalFrames)
        return min(max(0, frame), total)
    }

    static func frame(forSeconds seconds: Double, sampleRate: Double) -> Int {
        guard sampleRate > 0, !seconds.isNaN, seconds > 0 else { return 0 }
        let frames = (seconds * sampleRate).rounded()
        guard frames.isFinite, frames < Double(Int.max) else { return Int.max }
        return Int(frames)
    }

    static func seconds(forFrame frame: Int, sampleRate: Double) -> TimeInterval {
        guard sampleRate > 0 else { return 0 }
        return Double(frame) / sampleRate
    }
}
