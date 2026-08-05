import Foundation

/// Third tee branch (design §3): the capture-frame clock the marker entry points read
/// on the main actor. Accumulates on the audio tap thread — one lock, one addition,
/// nothing else. `currentFrame` is on the same axis as `StampedChunk.startFrame` and
/// `SegmentSidecar.startFrameOffset`: position in `final/recording.m4a`.
final class FrameClockSink: PCMSink, @unchecked Sendable {
    private let lock = NSLock()
    private var frames: Int64 = 0

    var currentFrame: Int64 { lock.withLock { frames } }

    nonisolated func receive(_ chunk: PCMChunk) {
        lock.lock()
        frames += Int64(chunk.frameCount)
        lock.unlock()
    }
}
