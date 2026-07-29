import Foundation
import AVFoundation

/// A chunk of canonical capture PCM handed off by the tap thread.
///
/// `data` is a flat little-endian `Float32` stream: mono, non-interleaved, one channel,
/// at `sampleRate`. This matches the on-disk segment format (design §1) exactly, so a
/// sink can append the bytes verbatim.
struct PCMChunk: Sendable, Equatable {
    let data: Data
    let frameCount: AVAudioFrameCount
    let sampleRate: Double
}

/// Destination for canonical PCM produced during capture.
///
/// `receive(_:)` is called on the audio tap thread and MUST NOT block (no disk I/O, no
/// locks held across syscalls). The concrete sink (`SegmentStore`, T3) enqueues the bytes
/// onto its own serial writer. `Sendable` because the tap thread is a different execution
/// context than the caller that installed it.
protocol PCMSink: Sendable {
    func receive(_ chunk: PCMChunk)
}
