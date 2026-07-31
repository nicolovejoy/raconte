import XCTest
import AVFoundation
import CoreMedia
@testable import Raconte

/// The analyzer rejects overlapping input with `SFSpeechError.audioDisordered`, and that
/// error arrives on the *results* stream — so it kills the session and every later chunk
/// is silently ignored. This suite pins the invariant that prevents it.
final class AnalyzerInputOrderingTests: XCTestCase {

    private let captureFormat = AudioFormatDescriptor(
        sampleRate: 48_000, channels: 1, commonFormat: .pcmFormatFloat32, interleaved: false)

    private func stamped(at frame: Int64, frames: AVAudioFrameCount = 4_800) -> StampedChunk {
        StampedChunk(chunk: PCMChunk(data: Data(count: Int(frames) * MemoryLayout<Float>.size),
                                     frameCount: frames,
                                     sampleRate: 48_000),
                     startFrame: frame)
    }

    /// Every buffer handed to the analyzer must begin at or after the end of the one
    /// before it. The SDK: "The audio buffer must not overlap or precede other audio
    /// input, as determined by the `bufferStartTime` value."
    func testConsecutiveInputsNeverOverlap() async {
        let engine = ScriptedTranscriptionEngine()
        let session = TranscriptionSession(engine: engine, inputFormat: captureFormat)
        await session.start()

        for i in 0..<40 {
            await session.ingest(stamped(at: Int64(i) * 4_800))
        }

        var cursor = CMTime.zero
        var violations: [String] = []
        for (i, input) in engine.inputs.enumerated() {
            let frames = Double(input.buffer.frameLength)
            let duration = CMTime(seconds: frames / input.buffer.format.sampleRate,
                                  preferredTimescale: 48_000)
            guard let start = input.bufferStartTime else {
                // nil means "immediately after the previous buffer" — contiguous by
                // definition, so it cannot overlap.
                cursor = cursor + duration
                continue
            }
            if start < cursor {
                violations.append("input \(i): starts \(start.seconds)s, "
                                  + "previous audio runs to \(cursor.seconds)s")
            }
            cursor = start + duration
        }
        XCTAssertEqual(violations, [], "overlapping input → audioDisordered → dead session")
    }
}
