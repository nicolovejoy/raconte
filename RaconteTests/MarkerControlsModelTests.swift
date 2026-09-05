import XCTest
@testable import Raconte

/// T6 §14 step 5, revised by #118 §4 — the pure phase → marker-control mapping. The
/// Two-voices toggle is gone: the voice switch is present in every recording, so the
/// only thing phase decides is whether a tap can land.
final class MarkerControlsModelTests: XCTestCase {

    private func model(_ phase: CaptureState) -> MarkerControlsModel {
        MarkerControlsModel.make(phase: phase)
    }

    /// #118 §4: the pre-record gate existed only to arm the live switch; nothing is lost
    /// by dropping it because `VoiceMarkingPlan.openerIfNeeded` synthesizes a frame-0
    /// opener for any entry lacking one. What the gate cost was live thumb-marking on a
    /// journal's first two-voice reading, which arriving-recording made unreachable.
    func testVoiceControlIsShownInEveryPhase() {
        for phase in CaptureState.allCases {
            XCTAssertTrue(model(phase).showsVoiceControl,
                          "\(phase): the voice switch must be present — there is no toggle to gate it")
        }
    }

    /// Owner decision 7: paragraphs are structure in a single-voice reading too.
    func testParagraphControlIsShownInEveryPhase() {
        for phase in CaptureState.allCases {
            XCTAssertTrue(model(phase).showsParagraphControl, "\(phase): paragraph control hidden")
        }
    }

    /// Visible-but-disabled must not quietly become visible-AND-tappable: a tap landing
    /// outside `.recording` has no frame to attach a marker to.
    func testTapsOnlyEverLandWhileRecording() {
        for phase in CaptureState.allCases {
            XCTAssertEqual(model(phase).isEnabled, phase == .recording,
                           "\(phase): enabled must track .recording exactly")
        }
    }

    /// Plan §0.3.9 / #53: one shape in every phase is what keeps the bar from moving.
    func testControlsHaveOneShapeInEveryPhase() {
        let reference = model(.recording)
        for phase in CaptureState.allCases {
            let m = model(phase)
            XCTAssertEqual(m.showsVoiceControl, reference.showsVoiceControl, "\(phase)")
            XCTAssertEqual(m.showsParagraphControl, reference.showsParagraphControl, "\(phase)")
        }
    }
}
