import XCTest
import AVFoundation
@testable import Raconte

/// Seek support for the raw-segment path (issue #6). No audible-output
/// assertions: a headless runner may have no route, so everything asserted here
/// holds with the engine stopped.
@MainActor
final class SegmentPlayerTests: XCTestCase {
    private var root: URL!
    private static let sampleRate = 48000

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SegmentPlayer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func format() -> AudioFormatDescriptor {
        AudioFormatDescriptor(sampleRate: Self.sampleRate, channels: 1,
                              commonFormat: .pcmFormatFloat32, interleaved: false, bytesPerFrame: 4)
    }

    private func renderFormat() -> AVAudioFormat {
        AVAudioFormat(standardFormatWithSampleRate: Double(Self.sampleRate), channels: 1)!
    }

    /// A ramp segment: sample i == Float(startFrame + i), so any sample identifies
    /// its own global frame — an off-by-one in the range loader is visible.
    @discardableResult
    private func makeRamp(index: Int, frames: Int, startFrame: Int) -> EncodableSegment {
        var samples = [Float](repeating: 0, count: frames)
        for i in 0..<frames { samples[i] = Float(startFrame + i) }
        let data = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        let url = root.appendingPathComponent("ramp-\(index).pcm")
        try? data.write(to: url)
        return EncodableSegment(index: index, startFrameOffset: startFrame,
                                frameCount: frames, pcmURL: url)
    }

    // MARK: - range-limited loader

    func testLoadWholeFile() throws {
        let seg = makeRamp(index: 0, frames: 100, startFrame: 0)
        let buffer = try XCTUnwrap(SegmentPlayer.loadBuffer(
            url: seg.pcmURL, format: renderFormat(), bytesPerFrame: 4))
        XCTAssertEqual(buffer.frameLength, 100)
        XCTAssertEqual(buffer.floatChannelData![0][0], 0)
        XCTAssertEqual(buffer.floatChannelData![0][99], 99)
    }

    func testLoadFromOffset() throws {
        let seg = makeRamp(index: 0, frames: 100, startFrame: 0)
        let buffer = try XCTUnwrap(SegmentPlayer.loadBuffer(
            url: seg.pcmURL, format: renderFormat(), bytesPerFrame: 4, frameOffset: 40))
        XCTAssertEqual(buffer.frameLength, 60)
        XCTAssertEqual(buffer.floatChannelData![0][0], 40)
        XCTAssertEqual(buffer.floatChannelData![0][59], 99)
    }

    func testLoadBoundedFrameCount() throws {
        let seg = makeRamp(index: 0, frames: 100, startFrame: 0)
        let buffer = try XCTUnwrap(SegmentPlayer.loadBuffer(
            url: seg.pcmURL, format: renderFormat(), bytesPerFrame: 4,
            frameOffset: 10, frameCount: 5))
        XCTAssertEqual(buffer.frameLength, 5)
        XCTAssertEqual(buffer.floatChannelData![0][0], 10)
        XCTAssertEqual(buffer.floatChannelData![0][4], 14)
    }

    func testLoadRejectsOffsetPastEnd() {
        let seg = makeRamp(index: 0, frames: 100, startFrame: 0)
        XCTAssertNil(SegmentPlayer.loadBuffer(url: seg.pcmURL, format: renderFormat(),
                                              bytesPerFrame: 4, frameOffset: 100))
        XCTAssertNil(SegmentPlayer.loadBuffer(url: seg.pcmURL, format: renderFormat(),
                                              bytesPerFrame: 4, frameOffset: -1))
        XCTAssertNil(SegmentPlayer.loadBuffer(url: seg.pcmURL, format: renderFormat(),
                                              bytesPerFrame: 0))
    }

    func testLoadMissingFile() {
        XCTAssertNil(SegmentPlayer.loadBuffer(url: root.appendingPathComponent("nope.pcm"),
                                              format: renderFormat(), bytesPerFrame: 4))
    }

    // MARK: - seek

    private func player() -> SegmentPlayer {
        let segs = (0..<3).map { makeRamp(index: $0, frames: 24000, startFrame: $0 * 24000) }
        return SegmentPlayer(segments: segs, format: format())
    }

    func testSeekWhileStoppedReadsBackTarget() {
        let p = player()
        XCTAssertEqual(p.totalFrames, 72000)
        p.seek(toFrame: 36000)
        XCTAssertEqual(p.currentFrame, 36000)
        XCTAssertEqual(p.currentTime, 0.75, accuracy: 1e-9)
        // The generation guard must keep a discarded completion callback from
        // marking the capture finished.
        XCTAssertFalse(p.didFinish)
    }

    func testSeekClamps() {
        let p = player()
        p.seek(toFrame: -100)
        XCTAssertEqual(p.currentFrame, 0)
        p.seek(toFrame: 999_999)
        XCTAssertEqual(p.currentFrame, 72000)
        XCTAssertEqual(p.currentTime, p.totalDuration, accuracy: 1e-9)
    }

    /// The real generation-guard test: `node.stop()` fires the `.dataPlayedBack`
    /// handlers of the buffers it discards, and those hop to the main actor, so
    /// the test has to let them run before asserting.
    func testRepeatedSeeksDoNotFinish() async throws {
        let p = player()
        for frame in [10_000, 50_000, 1_000, 71_999, 24_000] {
            p.seek(toFrame: frame)
            XCTAssertEqual(p.currentFrame, frame)
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(p.didFinish, "a superseded completion callback marked the capture finished")
        XCTAssertEqual(p.currentFrame, 24_000)
    }

    func testStopResetsSeekBase() {
        let p = player()
        p.seek(toFrame: 36000)
        p.stop()
        XCTAssertEqual(p.currentFrame, 0)
        XCTAssertFalse(p.didFinish)
    }

    func testSeekOnEmptySetIsHarmless() {
        let p = SegmentPlayer(segments: [], format: format())
        p.seek(toFrame: 100)
        XCTAssertEqual(p.currentFrame, 0)
        XCTAssertEqual(p.totalFrames, 0)
    }
}
