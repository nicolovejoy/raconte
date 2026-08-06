import XCTest
import AVFoundation
@testable import Raconte

/// The capture-frame clock (T6 §14 step 1, design §3): one addition per chunk on the
/// audio tap thread, readable from any thread.
final class FrameClockSinkTests: XCTestCase {

    private func chunk(frames: Int) -> PCMChunk {
        PCMChunk(data: Data(repeating: 0, count: frames * 4),
                 frameCount: AVAudioFrameCount(frames), sampleRate: 48000)
    }

    func testStartsAtZero() {
        XCTAssertEqual(FrameClockSink().currentFrame, 0)
    }

    func testAccumulatesFrameCountsAcrossChunks() {
        let clock = FrameClockSink()
        clock.receive(chunk(frames: 4_800))
        clock.receive(chunk(frames: 250))
        clock.receive(chunk(frames: 1))
        XCTAssertEqual(clock.currentFrame, 5_051,
                       "the clock must accumulate, not latch the last chunk")
    }

    func testConcurrentReceivesLoseNothing() {
        let clock = FrameClockSink()
        let one = chunk(frames: 100)
        DispatchQueue.concurrentPerform(iterations: 200) { _ in
            clock.receive(one)
        }
        XCTAssertEqual(clock.currentFrame, 20_000,
                       "concurrent receives lost or double-counted frames")
    }
}
