import XCTest
import AVFoundation
@testable import Raconte

/// M2 T1: the bounded second branch and its drop ledger. The point of these
/// tests is that a gap is *expressed* (later chunks keep their true frame
/// offsets) rather than silently compressed.
final class BoundedPCMSinkTests: XCTestCase {

    private static let frames: AVAudioFrameCount = 100

    private func chunk(_ byte: UInt8 = 0) -> PCMChunk {
        PCMChunk(data: Data(repeating: byte, count: Int(Self.frames) * 4),
                 frameCount: Self.frames, sampleRate: 48000)
    }

    func testStartFramesAdvanceByFrameCount() async {
        let sink = BoundedPCMSink(capacity: 8)
        for i in 0..<4 { sink.receive(chunk(UInt8(i))) }
        sink.finish()

        var starts: [Int64] = []
        for await stamped in sink.stream { starts.append(stamped.startFrame) }
        XCTAssertEqual(starts, [0, 100, 200, 300])
        XCTAssertEqual(sink.ingestedFrames, 400)
        XCTAssertTrue(sink.dropped.isEmpty)
        XCTAssertEqual(sink.dropCount, 0)
    }

    func testOverflowDropsAreCountedAndCoalesced() {
        let capacity = 4, extra = 3
        let sink = BoundedPCMSink(capacity: capacity)
        for i in 0..<(capacity + extra) { sink.receive(chunk(UInt8(i))) }

        XCTAssertEqual(sink.dropCount, extra)
        XCTAssertEqual(sink.dropped, [FrameRange(start: Int64(capacity) * 100,
                                                 end: Int64(capacity + extra) * 100)],
                       "contiguous drops must coalesce into one range")
        // The cursor counts every chunk handed in, dropped or not.
        XCTAssertEqual(sink.ingestedFrames, Int64(capacity + extra) * 100)
    }

    /// The gap is expressed, not compressed: after draining, the next chunk's
    /// `startFrame` reflects the frames that were dropped in between.
    func testGapIsExpressedInLaterStartFrames() async {
        let capacity = 2
        let sink = BoundedPCMSink(capacity: capacity)
        for i in 0..<5 { sink.receive(chunk(UInt8(i))) }   // 2 buffered, 3 dropped

        var iterator = sink.stream.makeAsyncIterator()
        let first = await iterator.next()
        let second = await iterator.next()
        XCTAssertEqual(first?.startFrame, 0)
        XCTAssertEqual(second?.startFrame, 100)

        sink.receive(chunk(9))                            // room again
        let third = await iterator.next()
        XCTAssertEqual(third?.startFrame, 500,
                       "the post-gap chunk must keep its true capture-frame offset")
        XCTAssertEqual(sink.dropped, [FrameRange(start: 200, end: 500)])
    }

    func testTwoSeparatedBurstsProduceTwoRanges() async {
        let sink = BoundedPCMSink(capacity: 1)
        sink.receive(chunk(0))                            // buffered, frames 0..100
        sink.receive(chunk(1))                            // dropped,  100..200

        var iterator = sink.stream.makeAsyncIterator()
        _ = await iterator.next()                         // drain the buffered one

        sink.receive(chunk(2))                            // buffered, 200..300
        sink.receive(chunk(3))                            // dropped,  300..400
        _ = await iterator.next()
        sink.receive(chunk(4))                            // buffered, 400..500
        sink.receive(chunk(5))                            // dropped,  500..600

        XCTAssertEqual(sink.dropped, [FrameRange(start: 100, end: 200),
                                      FrameRange(start: 300, end: 400),
                                      FrameRange(start: 500, end: 600)],
                       "non-contiguous drops must stay separate ranges")
        XCTAssertEqual(sink.dropCount, 3)
    }

    func testChunkPayloadSurvivesTheStamp() async {
        let sink = BoundedPCMSink(capacity: 4)
        let original = chunk(0x5A)
        sink.receive(original)
        sink.finish()
        var iterator = sink.stream.makeAsyncIterator()
        let stamped = await iterator.next()
        XCTAssertEqual(stamped?.chunk, original)
        XCTAssertEqual(stamped?.startFrame, 0)
    }

    func testReceiveAfterFinishIsRecordedAsADrop() {
        let sink = BoundedPCMSink(capacity: 4)
        sink.finish()
        sink.receive(chunk(0))
        XCTAssertEqual(sink.dropCount, 1)
        XCTAssertEqual(sink.dropped, [FrameRange(start: 0, end: 100)])
        XCTAssertEqual(sink.ingestedFrames, 100)
    }

    func testCapacityIsAtLeastOne() {
        let sink = BoundedPCMSink(capacity: 0)
        sink.receive(chunk(0))
        XCTAssertEqual(sink.dropCount, 0, "capacity clamps to 1, so the first chunk fits")
    }

    // MARK: FrameRange

    func testFrameRangeMath() {
        XCTAssertEqual(FrameRange(start: 10, end: 40).frameCount, 30)
        XCTAssertEqual(FrameRange(start: 40, end: 10).frameCount, 0)
        XCTAssertTrue(FrameRange(start: 0, end: 100).isContiguous(with: FrameRange(start: 100, end: 200)))
        XCTAssertFalse(FrameRange(start: 0, end: 100).isContiguous(with: FrameRange(start: 101, end: 200)))
    }

    func testFrameRangeRoundTripsThroughJSON() throws {
        let range = FrameRange(start: 48_000, end: 96_000)
        let data = try JSONEncoder().encode(range)
        XCTAssertEqual(try JSONDecoder().decode(FrameRange.self, from: data), range)
    }
}
