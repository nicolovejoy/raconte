import XCTest
@testable import Raconte

final class PlaybackSeekTests: XCTestCase {

    private let counts = [100, 200, 300]   // total 600

    // MARK: plan

    func testFrameZeroIsFirstSegment() {
        XCTAssertEqual(PlaybackSeek.plan(frameCounts: counts, globalFrame: 0),
                       SegmentSeekPlan(position: 0, frameOffsetInSegment: 0))
    }

    func testMidSegment() {
        XCTAssertEqual(PlaybackSeek.plan(frameCounts: counts, globalFrame: 150),
                       SegmentSeekPlan(position: 1, frameOffsetInSegment: 50))
        XCTAssertEqual(PlaybackSeek.plan(frameCounts: counts, globalFrame: 99),
                       SegmentSeekPlan(position: 0, frameOffsetInSegment: 99))
    }

    func testExactBoundaryStartsNextSegmentAtZero() {
        XCTAssertEqual(PlaybackSeek.plan(frameCounts: counts, globalFrame: 100),
                       SegmentSeekPlan(position: 1, frameOffsetInSegment: 0))
        XCTAssertEqual(PlaybackSeek.plan(frameCounts: counts, globalFrame: 300),
                       SegmentSeekPlan(position: 2, frameOffsetInSegment: 0))
    }

    func testLastFrame() {
        XCTAssertEqual(PlaybackSeek.plan(frameCounts: counts, globalFrame: 599),
                       SegmentSeekPlan(position: 2, frameOffsetInSegment: 299))
    }

    func testAtOrPastTotalIsNil() {
        XCTAssertNil(PlaybackSeek.plan(frameCounts: counts, globalFrame: 600))
        XCTAssertNil(PlaybackSeek.plan(frameCounts: counts, globalFrame: 10_000))
    }

    func testNegativeIsNil() {
        XCTAssertNil(PlaybackSeek.plan(frameCounts: counts, globalFrame: -1))
    }

    func testEmptyIsNil() {
        XCTAssertNil(PlaybackSeek.plan(frameCounts: [], globalFrame: 0))
        XCTAssertNil(PlaybackSeek.plan(frameCounts: [0, 0], globalFrame: 0))
    }

    /// Zero-frame segments own no frame, so boundaries must not drift onto them.
    func testZeroFrameSegmentsSkipped() {
        let withHoles = [0, 100, 0, 0, 200, 0]
        XCTAssertEqual(PlaybackSeek.plan(frameCounts: withHoles, globalFrame: 0),
                       SegmentSeekPlan(position: 1, frameOffsetInSegment: 0))
        XCTAssertEqual(PlaybackSeek.plan(frameCounts: withHoles, globalFrame: 99),
                       SegmentSeekPlan(position: 1, frameOffsetInSegment: 99))
        XCTAssertEqual(PlaybackSeek.plan(frameCounts: withHoles, globalFrame: 100),
                       SegmentSeekPlan(position: 4, frameOffsetInSegment: 0))
        XCTAssertEqual(PlaybackSeek.plan(frameCounts: withHoles, globalFrame: 299),
                       SegmentSeekPlan(position: 4, frameOffsetInSegment: 199))
        XCTAssertNil(PlaybackSeek.plan(frameCounts: withHoles, globalFrame: 300))
    }

    /// Negative counts are treated as zero rather than rewinding the running sum.
    func testNegativeCountsTreatedAsZero() {
        XCTAssertEqual(PlaybackSeek.plan(frameCounts: [-5, 100], globalFrame: 0),
                       SegmentSeekPlan(position: 1, frameOffsetInSegment: 0))
    }

    // MARK: clamp

    func testClamp() {
        XCTAssertEqual(PlaybackSeek.clampFrame(-5, totalFrames: 600), 0)
        XCTAssertEqual(PlaybackSeek.clampFrame(0, totalFrames: 600), 0)
        XCTAssertEqual(PlaybackSeek.clampFrame(300, totalFrames: 600), 300)
        XCTAssertEqual(PlaybackSeek.clampFrame(600, totalFrames: 600), 600)
        XCTAssertEqual(PlaybackSeek.clampFrame(9_999, totalFrames: 600), 600)
        XCTAssertEqual(PlaybackSeek.clampFrame(5, totalFrames: 0), 0)
        XCTAssertEqual(PlaybackSeek.clampFrame(5, totalFrames: -3), 0)
    }

    // MARK: seconds <-> frames

    func testSecondsToFramesRounds() {
        XCTAssertEqual(PlaybackSeek.frame(forSeconds: 0, sampleRate: 48000), 0)
        XCTAssertEqual(PlaybackSeek.frame(forSeconds: -1, sampleRate: 48000), 0)
        XCTAssertEqual(PlaybackSeek.frame(forSeconds: 1, sampleRate: 48000), 48000)
        XCTAssertEqual(PlaybackSeek.frame(forSeconds: 0.5, sampleRate: 48000), 24000)
        // .rounded() not truncation: 1/48000 * 1.5 rounds up to 2 frames.
        XCTAssertEqual(PlaybackSeek.frame(forSeconds: 1.5 / 48000, sampleRate: 48000), 2)
        XCTAssertEqual(PlaybackSeek.frame(forSeconds: 1, sampleRate: 0), 0)
        XCTAssertEqual(PlaybackSeek.frame(forSeconds: .nan, sampleRate: 48000), 0)
        XCTAssertEqual(PlaybackSeek.frame(forSeconds: .infinity, sampleRate: 48000), Int.max)
    }

    func testFramesToSeconds() {
        XCTAssertEqual(PlaybackSeek.seconds(forFrame: 24000, sampleRate: 48000), 0.5, accuracy: 1e-9)
        XCTAssertEqual(PlaybackSeek.seconds(forFrame: 100, sampleRate: 0), 0)
    }

    func testRoundTrip() {
        for seconds in [0.0, 0.25, 1.0, 12.75, 3600.0] {
            let frame = PlaybackSeek.frame(forSeconds: seconds, sampleRate: 44100)
            XCTAssertEqual(PlaybackSeek.seconds(forFrame: frame, sampleRate: 44100),
                           seconds, accuracy: 1.0 / 44100)
        }
    }
}
