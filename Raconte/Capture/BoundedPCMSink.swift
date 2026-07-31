import Foundation

/// A `PCMChunk` labelled with its position on the capture-frame axis — the same
/// axis as `SegmentSidecar.startFrameOffset`, so a stamped chunk maps directly to
/// a position in the finalized `recording.m4a`.
struct StampedChunk: Sendable, Equatable {
    let chunk: PCMChunk
    let startFrame: Int64
}

/// A bounded second branch off `TeeSink` for a derived consumer (M2: the live
/// transcriber). Transcription may fall behind or fail at any moment, so this
/// sink drops rather than growing without bound — and records exactly which
/// frames it dropped.
///
/// Drops are the *branch's* job, not the tee's: `PCMChunk` carries no frame
/// offset, so a counter in the tee couldn't label drops it didn't cause, and tee
/// state would cost a lock on the real-time thread. Because the tee delivers
/// every chunk to every branch unconditionally, advancing the cursor **on entry**
/// — including for chunks then dropped — gives this sink the true capture-frame
/// axis, which is what makes a gap expressible instead of silently compressed.
final class BoundedPCMSink: PCMSink, @unchecked Sendable {
    let stream: AsyncStream<StampedChunk>

    private let continuation: AsyncStream<StampedChunk>.Continuation
    private let lock = NSLock()
    private var cursor: Int64 = 0
    private var droppedRanges: [FrameRange] = []
    private var droppedChunkCount = 0

    /// `.bufferingOldest`: on overflow `yield` returns `.dropped(the element just
    /// yielded)`, so the recorded range is the current chunk's — no eviction
    /// bookkeeping. `.bufferingNewest` would evict the *oldest* buffered chunk,
    /// punching a hole mid-stream and forcing two converter restarts per burst.
    init(capacity: Int) {
        (stream, continuation) = AsyncStream<StampedChunk>.makeStream(
            bufferingPolicy: .bufferingOldest(max(1, capacity)))
    }

    /// Total frames handed to this sink, dropped or not.
    var ingestedFrames: Int64 {
        lock.lock(); defer { lock.unlock() }
        return cursor
    }

    /// Frame ranges this sink never delivered, coalesced where contiguous.
    var dropped: [FrameRange] {
        lock.lock(); defer { lock.unlock() }
        return droppedRanges
    }

    /// Number of individual chunks dropped (a coalesced range may cover many).
    var dropCount: Int {
        lock.lock(); defer { lock.unlock() }
        return droppedChunkCount
    }

    nonisolated func receive(_ chunk: PCMChunk) {
        let frames = Int64(chunk.frameCount)
        // Lock held for a few instructions only — never across the yield's
        // consumer-side work, and never across an `await` on the drain side.
        lock.lock()
        let start = cursor
        cursor += frames
        lock.unlock()

        switch continuation.yield(StampedChunk(chunk: chunk, startFrame: start)) {
        case .enqueued:
            break
        case .dropped, .terminated:
            recordDrop(FrameRange(start: start, end: start + frames))
        @unknown default:
            recordDrop(FrameRange(start: start, end: start + frames))
        }
    }

    /// End the stream. The consumer's `for await` finishes after the buffer drains.
    func finish() { continuation.finish() }

    private func recordDrop(_ range: FrameRange) {
        lock.lock()
        droppedChunkCount += 1
        if let last = droppedRanges.last, last.isContiguous(with: range) {
            droppedRanges[droppedRanges.count - 1].end = range.end
        } else {
            droppedRanges.append(range)
        }
        lock.unlock()
    }
}
