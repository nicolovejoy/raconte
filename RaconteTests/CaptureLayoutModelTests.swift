import XCTest
@testable import Raconte

/// Issue #53. The record button, voice switch and paragraph button sat inside the page's
/// one scroll view, below a transcript that grows as you speak — so they slid down the
/// screen during a reading, and on a long entry the voice switch left the viewport
/// entirely. The owner's requirement, in his words: "need the controls to stay put."
///
/// This pins the visibility half of the fix. The frames-don't-move half cannot be
/// expressed here — it lives in `CaptureControlsUITests`, which measures the rendered
/// positions — and this file is deliberately not a substitute for it.
final class CaptureLayoutModelTests: XCTestCase {

    private func layout(_ phase: CaptureState) -> CaptureLayoutModel {
        CaptureLayoutModel.make(phase: phase)
    }

    /// The phases in which audio is being captured, or is about to be, or is being wound
    /// up — everything from arming the engine to the stop completing.
    private let capturingPhases: [CaptureState] =
        [.preparing, .recording, .interrupted, .resuming, .stopping]

    private let settledPhases: [CaptureState] =
        [.idle, .captured, .finalizing, .complete]

    func testRecentListIsHiddenWhileCapturing() {
        for phase in capturingPhases {
            XCTAssertFalse(layout(phase).showsRecentList,
                           "\(phase): the Recent list still occupies height during a capture")
        }
    }

    func testMultiVoiceFieldIsHiddenWhileCapturing() {
        for phase in capturingPhases {
            XCTAssertFalse(layout(phase).showsMultiVoiceField,
                           "\(phase): the Two-voices toggle still occupies height during a capture")
        }
    }

    func testTranscriptFillsAvailableHeightWhileCapturing() {
        for phase in capturingPhases {
            XCTAssertTrue(layout(phase).transcriptFillsAvailableHeight,
                          "\(phase): the transcript is still capped during a capture")
        }
    }

    /// The owner's explicit constraint: idle must look exactly as it did. This fix is not
    /// licence to redesign the capture landing — that redesign is separately scoped and
    /// deliberately deferred until it can be discussed on a large screen.
    func testIdleLayoutIsUnchanged() {
        let idle = layout(.idle)
        XCTAssertTrue(idle.showsRecentList, "idle lost the Recent list")
        XCTAssertTrue(idle.showsMultiVoiceField, "idle lost the Two-voices toggle")
        XCTAssertFalse(idle.transcriptFillsAvailableHeight,
                       "idle must not give the transcript the whole screen")
    }

    func testSettledPhasesRestoreTheSetupLayout() {
        for phase in settledPhases {
            XCTAssertEqual(layout(phase), layout(.idle),
                           "\(phase): should present the same layout as idle")
        }
    }

    /// An interruption (a phone call mid-reading) must not reflow the screen. Reflowing at
    /// exactly the moment the owner is trying to resume is the same class of defect as #53
    /// itself, and `MarkerControlsModel` already keeps the controls *shown* through these
    /// phases for this reason — the two models have to agree or the bar would still jump.
    func testLayoutDoesNotChangeAcrossAnInterruption() {
        XCTAssertEqual(layout(.interrupted), layout(.recording),
                       "layout changes when a call interrupts a reading")
        XCTAssertEqual(layout(.resuming), layout(.recording),
                       "layout changes while resuming after an interruption")
    }

    /// Every phase must be classified deliberately. `CaseIterable` means a newly added
    /// `CaptureState` shows up here rather than inheriting whatever the last `case` said.
    func testEveryCaptureStateIsClassified() {
        let classified = Set(capturingPhases + settledPhases)
        for phase in CaptureState.allCases {
            XCTAssertTrue(classified.contains(phase),
                          "\(phase) is not classified by these tests — decide whether a "
                          + "capture is under way in that phase")
        }
    }
}
