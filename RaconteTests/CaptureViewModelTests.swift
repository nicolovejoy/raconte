import XCTest
@testable import Raconte

/// Pure UI-logic tests for T10: the `CaptureState → RecordControlModel` mapping and the
/// elapsed-clock / status-text formatting. No XCUITest — only the testable functions the
/// SwiftUI views render from (design §6).
final class CaptureViewModelTests: XCTestCase {

    // MARK: RecordControlModel mapping

    func testIdleOffersRecord() {
        let m = RecordControlModel.make(phase: .idle, canResume: false)
        XCTAssertEqual(m.action, .record)
        XCTAssertEqual(m.tint, .idle)
        XCTAssertTrue(m.isEnabled)
        XCTAssertFalse(m.isBlinking)
        XCTAssertFalse(m.showsDoneButton)
    }

    func testRecordingOffersDoneAndIsRed() {
        let m = RecordControlModel.make(phase: .recording, canResume: false)
        XCTAssertEqual(m.action, .done)
        XCTAssertEqual(m.tint, .capturing)
        XCTAssertTrue(m.isEnabled)
        XCTAssertFalse(m.isBlinking)
        XCTAssertFalse(m.showsDoneButton)
    }

    func testPreparingIsNeutralAndDisabled() {
        let m = RecordControlModel.make(phase: .preparing, canResume: false)
        XCTAssertEqual(m.action, .none)
        XCTAssertEqual(m.tint, .neutral)
        XCTAssertFalse(m.isEnabled)
        XCTAssertFalse(m.isBlinking)
    }

    func testResumingIsNeutralAndDisabled() {
        let m = RecordControlModel.make(phase: .resuming, canResume: false)
        XCTAssertEqual(m.action, .none)
        XCTAssertEqual(m.tint, .neutral)
        XCTAssertFalse(m.isEnabled)
    }

    func testStoppingIsNeutralAndDisabled() {
        let m = RecordControlModel.make(phase: .stopping, canResume: false)
        XCTAssertEqual(m.action, .none)
        XCTAssertEqual(m.tint, .neutral)
        XCTAssertFalse(m.isEnabled)
    }

    func testInterruptedWithResumeOffersResumeBlinkingRed() {
        let m = RecordControlModel.make(phase: .interrupted, canResume: true)
        XCTAssertEqual(m.action, .resume)
        XCTAssertEqual(m.tint, .interrupted)
        XCTAssertTrue(m.isBlinking)
        XCTAssertTrue(m.isEnabled)
        XCTAssertTrue(m.showsDoneButton)
    }

    func testInterruptedWithoutResumeIsBlinkingDisabledButOffersDone() {
        let m = RecordControlModel.make(phase: .interrupted, canResume: false)
        XCTAssertEqual(m.action, .none)
        XCTAssertEqual(m.tint, .interrupted)
        XCTAssertTrue(m.isBlinking)
        XCTAssertFalse(m.isEnabled)
        XCTAssertTrue(m.showsDoneButton)
    }

    func testFinalizingIsNeutral() {
        let m = RecordControlModel.make(phase: .finalizing, canResume: false)
        XCTAssertEqual(m.action, .none)
        XCTAssertEqual(m.tint, .neutral)
        XCTAssertFalse(m.isEnabled)
    }

    func testCapturedAndCompleteAreDoneTintNotRed() {
        for phase in [CaptureState.captured, .complete] {
            let m = RecordControlModel.make(phase: phase, canResume: false)
            XCTAssertEqual(m.action, .none, "\(phase)")
            XCTAssertEqual(m.tint, .done, "\(phase)")
            XCTAssertFalse(m.isEnabled, "\(phase)")
        }
    }

    /// Affordance rule: red only while capturing or interrupted (paused) — never idle,
    /// preparing, resuming, stopping, finalizing, or a finished phase.
    func testRedTintOnlyForCapturingAndInterrupted() {
        let redPhases: Set<CaptureState> = [.recording, .interrupted]
        for phase in CaptureState.allCases {
            let tint = RecordControlModel.make(phase: phase, canResume: false).tint
            let isRed = tint == .capturing || tint == .interrupted
            XCTAssertEqual(isRed, redPhases.contains(phase),
                           "\(phase) red=\(isRed) expected=\(redPhases.contains(phase))")
        }
    }

    /// Every phase yields a valid model (exhaustive; guards against a missing case).
    func testEveryPhaseMaps() {
        for phase in CaptureState.allCases {
            let m = RecordControlModel.make(phase: phase, canResume: false)
            XCTAssertFalse(m.label.isEmpty, "\(phase)")
            XCTAssertFalse(m.systemImage.isEmpty, "\(phase)")
        }
    }

    // MARK: RecFormat.clock

    func testClockFormatsBelowAnHour() {
        XCTAssertEqual(RecFormat.clock(0), "0:00")
        XCTAssertEqual(RecFormat.clock(5), "0:05")
        XCTAssertEqual(RecFormat.clock(9.9), "0:09")   // truncates, not rounds
        XCTAssertEqual(RecFormat.clock(65), "1:05")
        XCTAssertEqual(RecFormat.clock(600), "10:00")
        XCTAssertEqual(RecFormat.clock(3599), "59:59")
    }

    func testClockFormatsHours() {
        XCTAssertEqual(RecFormat.clock(3600), "1:00:00")
        XCTAssertEqual(RecFormat.clock(3661), "1:01:01")
        XCTAssertEqual(RecFormat.clock(7325), "2:02:05")
    }

    func testClockClampsNegative() {
        XCTAssertEqual(RecFormat.clock(-42), "0:00")
    }

    // MARK: RecFormat.statusText

    func testStatusTextInterruptedVariesWithResume() {
        let withResume = RecFormat.statusText(phase: .interrupted, canResume: true)
        let without = RecFormat.statusText(phase: .interrupted, canResume: false)
        XCTAssertNotEqual(withResume, without)
        XCTAssertTrue(withResume.localizedCaseInsensitiveContains("resume"))
    }

    func testStatusTextNonEmptyForEveryPhase() {
        for phase in CaptureState.allCases {
            XCTAssertFalse(RecFormat.statusText(phase: phase, canResume: false).isEmpty, "\(phase)")
        }
    }

    // MARK: Row timestamp

    /// The ULID head is the fallback when a manifest is missing or corrupt, so it has to
    /// round-trip against the minter that wrote it.
    func testULIDTimestampRoundTripsAgainstTheMinter() {
        for offset in [0.0, 1_000_000.0, 1_800_000_000.0] {
            let original = Date(timeIntervalSince1970: offset)
            let id = CaptureCoordinator.makeULID(now: original)
            let decoded = ULID.timestamp(from: id)
            XCTAssertNotNil(decoded)
            // ULID timestamps are whole milliseconds.
            XCTAssertEqual(decoded!.timeIntervalSince1970, offset, accuracy: 0.001)
        }
    }

    func testULIDTimestampRejectsMalformedIDs() {
        XCTAssertNil(ULID.timestamp(from: "short"))
        XCTAssertNil(ULID.timestamp(from: "UUUUUUUUUU0000000000000000"))  // U not in Crockford
    }
}
