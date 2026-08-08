import XCTest
@testable import Raconte

/// T6 §14 step 6: pure gap-snapping of raw marker frames (design §6, plan §0.3.7).
///
/// Every fixture is literal frame numbers on a 48 kHz axis with an explicit
/// 72 000-frame (±1.5 s) test window, so each expected value can be checked by hand.
/// The production constant is pinned separately in
/// `testWindowConstantConvertsToFrames`.
final class MarkerSnappingTests: XCTestCase {

    /// `MarkerSnapping.windowFrames(sampleRate: 48_000)`, written out so the fixtures
    /// below can be read without running the conversion in your head.
    private let w: Int64 = 72_000

    // MARK: - Fixtures

    private func iv(_ start: Int64, _ end: Int64) -> MarkerSnapping.SpokenInterval {
        MarkerSnapping.SpokenInterval(start: start, end: end)
    }

    /// A committed result over `range`. Each entry in `runs` is either a timed run's
    /// `(start, end)` or `nil` for a run the transcriber attributed no time range to —
    /// which the SDK explicitly permits (see `TranscriptRun`).
    private func result(_ range: (Int64, Int64),
                        runs: [(Int64, Int64)?] = []) -> TranscriptResult {
        TranscriptResult(
            text: "text",
            range: FrameRange(start: range.0, end: range.1),
            isVolatile: false,
            runs: runs.map { pair in
                guard let pair else { return TranscriptRun(text: "untimed") }
                return TranscriptRun(text: "word",
                                     captureFrameStart: pair.0,
                                     captureFrameEnd: pair.1)
            })
    }

    private func mark(_ frame: Int64,
                      seq: Int = 0,
                      kind: StructureMarker.Kind = .paragraph,
                      voice: String? = nil) -> StructureMarker {
        StructureMarker(seq: seq, frame: frame, kind: kind, voice: voice)
    }

    private func snapOne(_ frame: Int64,
                         _ intervals: [MarkerSnapping.SpokenInterval],
                         file: StaticString = #filePath,
                         line: UInt = #line) throws -> MarkerSnapping.SnappedMarker {
        let snapped = MarkerSnapping.snap(markers: [mark(frame)],
                                          intervals: intervals,
                                          windowFrames: w)
        XCTAssertEqual(snapped.count, 1, file: file, line: line)
        return try XCTUnwrap(snapped.first, file: file, line: line)
    }

    // MARK: - Design §8's named cases

    /// Two gaps sit inside the window. The larger one wins even though the smaller one
    /// is nearer the tap — which is also what separates this from "first gap found".
    func testMarkerInsideSpeechSnapsToTheLargestGapInWindow() throws {
        // window = [1_928_000, 2_072_000]
        // gap 1 = (1_985_000, 1_990_000)  len  5_000  mid 1_987_500
        // gap 2 = (2_005_000, 2_045_000)  len 40_000  mid 2_025_000
        let intervals = [iv(1_000_000, 1_985_000),
                         iv(1_990_000, 2_005_000),
                         iv(2_045_000, 3_000_000)]

        let snapped = try snapOne(2_000_000, intervals)

        XCTAssertEqual(snapped.snappedFrame, 2_025_000)
        XCTAssertFalse(snapped.approximate)
    }

    /// Equal intersection lengths: the tie breaks toward the tap, not toward whichever
    /// gap the scan happened to reach first.
    func testEqualGapsResolveToTheNearestOne() throws {
        // window = [1_928_000, 2_072_000]
        // gap 1 = (1_980_000, 1_990_000)  len 10_000  mid 1_985_000  dist 15_000
        // gap 2 = (2_005_000, 2_015_000)  len 10_000  mid 2_010_000  dist 10_000
        let intervals = [iv(1_900_000, 1_980_000),
                         iv(1_990_000, 2_005_000),
                         iv(2_015_000, 2_100_000)]

        let snapped = try snapOne(2_000_000, intervals)

        XCTAssertEqual(snapped.snappedFrame, 2_010_000)
        XCTAssertFalse(snapped.approximate)
    }

    /// Rule 3 is reachable exactly at the head of the first interval and the tail of the
    /// last: every interior boundary abuts a gap that would have intersected the window
    /// first. Both halves are checked.
    func testNoGapInWindowSnapsToNearestRunBoundary() throws {
        let intervals = [iv(500_000, 2_000_000), iv(2_500_000, 3_000_000)]

        // Inside the first interval, 40 000 frames past its start; the only interior gap
        // (2_000_000 → 2_500_000) is far outside the window.
        let head = try snapOne(540_000, intervals)
        XCTAssertEqual(head.snappedFrame, 500_000)
        XCTAssertFalse(head.approximate)

        // Inside the last interval, 10 000 frames short of its end.
        let tail = try snapOne(2_990_000, intervals)
        XCTAssertEqual(tail.snappedFrame, 3_000_000)
        XCTAssertFalse(tail.approximate)
    }

    /// The tap landed in the middle of one long run: nothing to snap to, so the raw
    /// frame stands and the boundary is flagged for T7 to surface.
    func testNothingInWindowKeepsRawFrameAndFlagsApproximate() throws {
        let snapped = try snapOne(5_000_000, [iv(0, 10_000_000)])

        XCTAssertEqual(snapped.snappedFrame, 5_000_000)
        XCTAssertTrue(snapped.approximate)
    }

    /// A record containing any untimed run contributes its record-level range as one
    /// interval — no interior gaps invented from partial data, so the gap its timed
    /// sibling implies does not attract the snap.
    func testUntimedRunFallsBackToRecordLevelRange() throws {
        let committed = [result((1_000_000, 2_000_000),
                                runs: [(1_000_000, 1_400_000), nil])]

        let intervals = MarkerSnapping.intervals(fromCommitted: committed)
        XCTAssertEqual(intervals, [iv(1_000_000, 2_000_000)])

        // 1_390_000 sits just inside the timed sibling's end; had that run's boundary
        // survived, the snap would have moved. It must not.
        let snapped = try snapOne(1_390_000, intervals)
        XCTAssertEqual(snapped.snappedFrame, 1_390_000)
        XCTAssertTrue(snapped.approximate)
    }

    /// Rule 0, including the frame-0 multi-voice opener: a frame that lies outside every
    /// interval is already in silence and is kept exactly, never pulled toward speech.
    func testMarkerBeforeTheFirstRunKeepsRawFrame() {
        let intervals = [iv(480_000, 2_000_000)]

        let snapped = MarkerSnapping.snap(
            markers: [mark(0, seq: 0, kind: .voice, voice: StructureMarker.Voice.bigNico),
                      mark(100_000, seq: 1)],
            intervals: intervals,
            windowFrames: w)

        XCTAssertEqual(snapped.map(\.snappedFrame), [0, 100_000])
        XCTAssertEqual(snapped.map(\.approximate), [false, false])
    }

    /// Rule 0 at the other end.
    func testMarkerAfterTheLastRunKeepsRawFrame() throws {
        let snapped = try snapOne(5_000_000, [iv(480_000, 2_000_000)])

        XCTAssertEqual(snapped.snappedFrame, 5_000_000)
        XCTAssertFalse(snapped.approximate)
    }

    // MARK: - Plan additions

    /// Rule 0 pre-empts the largest-gap ranking: a tap that already landed in an interior
    /// gap is a correct boundary, and moving it to that gap's window-clipped midpoint
    /// (2_041_000 here) could only lose information.
    func testMarkerAlreadyInAnInterRunGapKeepsRawFrame() throws {
        let intervals = [iv(1_000_000, 2_000_000), iv(2_100_000, 3_000_000)]

        let snapped = try snapOne(2_010_000, intervals)

        XCTAssertEqual(snapped.snappedFrame, 2_010_000)
        XCTAssertFalse(snapped.approximate)
    }

    /// A fully-timed record contributes one interval per run, so intra-record gaps are
    /// snap candidates like any other.
    func testAllRunsTimedUsesPerRunGaps() throws {
        let committed = [result((1_000_000, 2_000_000),
                                runs: [(1_000_000, 1_400_000), (1_600_000, 2_000_000)])]

        let intervals = MarkerSnapping.intervals(fromCommitted: committed)
        XCTAssertEqual(intervals, [iv(1_000_000, 1_400_000), iv(1_600_000, 2_000_000)])

        // window = [1_318_000, 1_462_000]; the gap clips to [1_400_000, 1_462_000].
        let snapped = try snapOne(1_390_000, intervals)
        XCTAssertEqual(snapped.snappedFrame, 1_431_000)
        XCTAssertFalse(snapped.approximate)
    }

    /// Overlapping and exactly-touching records merge into one interval before any gap
    /// is computed — otherwise the overlap would manufacture a negative-length "gap".
    func testOverlappingIntervalsAreMergedBeforeGapsAreComputed() throws {
        let committed = [result((1_000_000, 2_000_000)),
                         result((1_800_000, 2_500_000)),
                         result((2_500_000, 2_800_000))]

        let intervals = MarkerSnapping.intervals(fromCommitted: committed)
        XCTAssertEqual(intervals, [iv(1_000_000, 2_800_000)])

        // Inside the overlap, far from either surviving boundary: nothing to snap to.
        let snapped = try snapOne(1_900_000, intervals)
        XCTAssertEqual(snapped.snappedFrame, 1_900_000)
        XCTAssertTrue(snapped.approximate)
    }

    /// The candidate is ranked and centred on its *intersection with the window*, so a
    /// four-million-frame gap cannot drag the marker past the window edge.
    func testSnapNeverLandsFurtherThanTheWindowFromTheRawFrame() throws {
        let intervals = [iv(0, 1_000_000), iv(5_000_000, 6_000_000)]
        let raw: Int64 = 999_990

        // window = [927_990, 1_071_990]; gap clips to [1_000_000, 1_071_990].
        // The whole gap's midpoint would be 3_000_000 — 2 million frames out.
        let snapped = try snapOne(raw, intervals)

        XCTAssertEqual(snapped.snappedFrame, 1_035_995)
        XCTAssertLessThanOrEqual(abs(snapped.snappedFrame - raw), w)
        XCTAssertFalse(snapped.approximate)
    }

    /// The governing rule of the whole feature: snapping is derived, the stored frame is
    /// ground truth and comes back byte-for-byte.
    func testRawFrameIsNeverMutated() {
        let markers = [mark(2_000_000, seq: 0, kind: .voice, voice: StructureMarker.Voice.littleNico),
                       mark(5_000_000, seq: 1, kind: .paragraph),
                       mark(0, seq: 2, kind: .unknown("chapter"))]
        let intervals = [iv(1_000_000, 1_985_000),
                         iv(1_990_000, 2_005_000),
                         iv(2_045_000, 3_000_000)]

        let snapped = MarkerSnapping.snap(markers: markers,
                                          intervals: intervals,
                                          windowFrames: w)

        XCTAssertEqual(snapped.map(\.marker), markers)
        // Not vacuous: the first marker really did move.
        XCTAssertEqual(snapped[0].snappedFrame, 2_025_000)
        XCTAssertNotEqual(snapped[0].snappedFrame, markers[0].frame)
    }

    func testWindowConstantConvertsToFrames() {
        XCTAssertEqual(MarkerSnapping.snapWindowSeconds, 0.75)
        XCTAssertEqual(MarkerSnapping.windowFrames(sampleRate: 48_000), 36_000)
        XCTAssertEqual(MarkerSnapping.windowFrames(sampleRate: 16_000), 12_000)
    }

    /// Snapping is kind-agnostic: a kind written by a newer build snaps exactly as a
    /// known one does.
    func testUnknownKindMarkersPassThroughSnapping() {
        let intervals = [iv(1_000_000, 1_985_000),
                         iv(1_990_000, 2_005_000),
                         iv(2_045_000, 3_000_000)]

        let snapped = MarkerSnapping.snap(
            markers: [mark(2_000_000, seq: 0, kind: .unknown("chapter")),
                      mark(2_000_000, seq: 1, kind: .paragraph)],
            intervals: intervals,
            windowFrames: w)

        XCTAssertEqual(snapped.map(\.snappedFrame), [2_025_000, 2_025_000])
        XCTAssertEqual(snapped.map(\.approximate), [false, false])
    }

    /// Markers outlive any given transcript. With no intervals every frame is outside
    /// them, so rule 0 keeps each one exactly — this function is total. (Design §7's
    /// "no transcript ⇒ assign nothing" is T7's read-layer behavior, not this rule.)
    func testEmptyTranscriptSnapsNothingButReturnsEveryMarker() {
        XCTAssertEqual(MarkerSnapping.intervals(fromCommitted: []), [])

        let markers = [mark(0, seq: 0, kind: .voice, voice: StructureMarker.Voice.bigNico),
                       mark(480_000, seq: 1),
                       mark(9_600_000, seq: 2, kind: .voice, voice: StructureMarker.Voice.littleNico)]

        let snapped = MarkerSnapping.snap(markers: markers, intervals: [], windowFrames: w)

        XCTAssertEqual(snapped.map(\.marker), markers)
        XCTAssertEqual(snapped.map(\.snappedFrame), [0, 480_000, 9_600_000])
        XCTAssertEqual(snapped.map(\.approximate), [false, false, false])
    }
}
