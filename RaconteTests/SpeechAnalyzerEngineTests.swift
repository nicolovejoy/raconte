import XCTest
import CoreMedia
import Speech
@testable import Raconte

/// M2 T4. Only the pure mapping is reachable on CI — `SpeechTranscriber.Result` has no
/// public initializer, and CI runners have no model assets, so
/// `bestAvailableAudioFormat` returns `nil` there. Everything else about this engine is
/// device smoke, and the design says so rather than implying coverage.
final class SpeechAnalyzerEngineTests: XCTestCase {

    // MARK: Time → capture frames

    func testAnalyzerTimeConvertsToCaptureFrames() {
        // 1 s on a 16 kHz analyzer axis is frame 48000 of a 48 kHz capture.
        let t = CMTime(value: 16_000, timescale: 16_000)
        XCTAssertEqual(SpeechAnalyzerEngine.frame(t, inputRate: 48_000), 48_000)
    }

    func testConversionIsSampleAccurateNotSecondsBased() {
        // A value that a Double round-trip through seconds would not land exactly.
        let t = CMTime(value: 1, timescale: 3)
        XCTAssertEqual(SpeechAnalyzerEngine.frame(t, inputRate: 48_000), 16_000)
    }

    /// A garbage timestamp is a derived-path fault and must not trap.
    func testInvalidTimeIsZeroNotACrash() {
        XCTAssertEqual(SpeechAnalyzerEngine.frame(.invalid, inputRate: 48_000), 0)
        XCTAssertEqual(SpeechAnalyzerEngine.frame(.indefinite, inputRate: 48_000), 0)
        XCTAssertEqual(SpeechAnalyzerEngine.frame(.negativeInfinity, inputRate: 48_000), 0)
    }

    // MARK: Run flattening

    private func timed(_ text: String, start: Int64, end: Int64) -> AttributedString {
        var s = AttributedString(text)
        s[AttributeScopes.SpeechAttributes.TimeRangeAttribute.self] = CMTimeRange(
            start: CMTime(value: start, timescale: 16_000),
            end: CMTime(value: end, timescale: 16_000))
        return s
    }

    func testTimedRunMapsOntoTheCaptureFrameAxis() {
        let runs = SpeechAnalyzerEngine.runs(of: timed("hello", start: 16_000, end: 32_000),
                                             inputRate: 48_000)
        XCTAssertEqual(runs.map(\.text), ["hello"])
        XCTAssertEqual(runs.first?.captureFrameStart, 48_000)
        XCTAssertEqual(runs.first?.captureFrameEnd, 96_000)
    }

    /// The SDK documents runs with no time-range attribute at all. The schema has to
    /// carry them, not drop them or invent a zero.
    func testUntimedRunKeepsItsTextAndReportsNoBounds() {
        let runs = SpeechAnalyzerEngine.runs(of: AttributedString("untimed"), inputRate: 48_000)
        XCTAssertEqual(runs.map(\.text), ["untimed"])
        XCTAssertNil(runs.first?.captureFrameStart)
        XCTAssertNil(runs.first?.captureFrameEnd)
    }

    /// Timed runs are "not necessarily contiguous" — a gap between them is legal and must
    /// survive rather than being closed up.
    func testNonContiguousRunsKeepTheirGap() {
        var combined = timed("first", start: 0, end: 16_000)
        combined.append(AttributedString(" "))
        combined.append(timed("second", start: 32_000, end: 48_000))

        let runs = SpeechAnalyzerEngine.runs(of: combined, inputRate: 48_000)
        let timedRuns = runs.filter { $0.captureFrameStart != nil }
        XCTAssertEqual(timedRuns.count, 2)
        XCTAssertEqual(timedRuns[0].captureFrameEnd, 48_000)
        XCTAssertEqual(timedRuns[1].captureFrameStart, 96_000,
                       "the gap between runs is real and must not be closed")
    }

    func testConfidenceIsCarriedWhenPresentAndNilWhenNot() {
        var s = AttributedString("sure")
        s[AttributeScopes.SpeechAttributes.ConfidenceAttribute.self] = 0.93
        XCTAssertEqual(SpeechAnalyzerEngine.runs(of: s, inputRate: 48_000).first?.confidence, 0.93)
        XCTAssertNil(SpeechAnalyzerEngine.runs(of: AttributedString("dunno"),
                                               inputRate: 48_000).first?.confidence)
    }
}
