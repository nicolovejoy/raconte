import XCTest
@testable import Raconte

/// Issue #12 — the phase -> "keep the display awake" mapping. Pure, so it's tested
/// directly rather than through `UIApplication` (not injectable at this layer).
/// Enumerates every `CaptureState` case: a new phase added to the enum fails this
/// test until it's explicitly classified in `keepsDisplayAwake`.
final class CaptureStateDisplayAwakeTests: XCTestCase {

    func testAllCasesClassified() {
        let awake: Set<CaptureState> = [.recording, .resuming]
        for phase in CaptureState.allCases {
            XCTAssertEqual(phase.keepsDisplayAwake, awake.contains(phase),
                           "unexpected classification for \(phase)")
        }
    }

    func testRecordingKeepsAwake() {
        XCTAssertTrue(CaptureState.recording.keepsDisplayAwake)
    }

    func testResumingKeepsAwake() {
        XCTAssertTrue(CaptureState.resuming.keepsDisplayAwake)
    }

    func testInterruptedReleasesEvenThoughItFollowsRecording() {
        // Owner decision: interrupted may mean an incoming phone call — normal lock
        // behavior, not held awake, distinguishing it from resuming.
        XCTAssertFalse(CaptureState.interrupted.keepsDisplayAwake)
    }

    func testNonLiveCasesReleaseAwake() {
        for phase: CaptureState in [.idle, .preparing, .stopping, .captured, .finalizing, .complete] {
            XCTAssertFalse(phase.keepsDisplayAwake, "\(phase) must not hold the display awake")
        }
    }
}
