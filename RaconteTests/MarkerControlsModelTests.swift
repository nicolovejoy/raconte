import XCTest
@testable import Raconte

/// T6 §14 step 5 — the pure phase+toggle → marker-control mapping. Exhaustive over the
/// phases that matter, so the "which controls exist when" rules are pinned in one place
/// rather than read out of a SwiftUI body.
final class MarkerControlsModelTests: XCTestCase {

    private func model(_ phase: CaptureState, multiVoice: Bool) -> MarkerControlsModel {
        MarkerControlsModel.make(phase: phase, multiVoice: multiVoice)
    }

    func testNothingShownBeforeRecording() {
        for multiVoice in [true, false] {
            for phase in [CaptureState.idle, .preparing] {
                let m = model(phase, multiVoice: multiVoice)
                XCTAssertFalse(m.showsVoiceControl,
                               "\(phase) multiVoice=\(multiVoice): voice control shown before recording")
                XCTAssertFalse(m.showsParagraphControl,
                               "\(phase) multiVoice=\(multiVoice): paragraph control shown before recording")
                XCTAssertFalse(m.isEnabled, "\(phase): enabled before recording")
            }
        }
    }

    func testVoiceAndParagraphShownWhileRecordingWithMultiVoiceOn() {
        let m = model(.recording, multiVoice: true)
        XCTAssertTrue(m.showsVoiceControl)
        XCTAssertTrue(m.showsParagraphControl)
        XCTAssertTrue(m.isEnabled)
    }

    /// Owner decision 7: paragraph markers are independent of the multi-voice toggle.
    func testParagraphShownWhileRecordingEvenWithMultiVoiceOff() {
        let m = model(.recording, multiVoice: false)
        XCTAssertTrue(m.showsParagraphControl, "paragraph control is not gated on multi-voice")
        XCTAssertTrue(m.isEnabled)
    }

    func testVoiceControlHiddenWhenMultiVoiceOff() {
        for phase in [CaptureState.recording, .interrupted, .resuming] {
            XCTAssertFalse(model(phase, multiVoice: false).showsVoiceControl,
                           "\(phase): voice control shown with multi-voice off")
            XCTAssertTrue(model(phase, multiVoice: true).showsVoiceControl,
                          "\(phase): voice control hidden with multi-voice on")
        }
    }

    /// Plan §0.3.9: shown-but-disabled through an interruption so the layout doesn't jump.
    func testControlsShownButDisabledWhileInterruptedAndResuming() {
        for phase in [CaptureState.interrupted, .resuming] {
            let on = model(phase, multiVoice: true)
            XCTAssertTrue(on.showsVoiceControl, "\(phase): voice control hidden")
            XCTAssertTrue(on.showsParagraphControl, "\(phase): paragraph control hidden")
            XCTAssertFalse(on.isEnabled, "\(phase): taps must not land outside .recording")

            let off = model(phase, multiVoice: false)
            XCTAssertTrue(off.showsParagraphControl, "\(phase): paragraph control hidden")
            XCTAssertFalse(off.isEnabled, "\(phase): taps must not land outside .recording")
        }
    }

    func testNothingShownAfterCapture() {
        for multiVoice in [true, false] {
            for phase in [CaptureState.stopping, .captured, .finalizing, .complete] {
                let m = model(phase, multiVoice: multiVoice)
                XCTAssertFalse(m.showsVoiceControl,
                               "\(phase) multiVoice=\(multiVoice): voice control shown after capture")
                XCTAssertFalse(m.showsParagraphControl,
                               "\(phase) multiVoice=\(multiVoice): paragraph control shown after capture")
                XCTAssertFalse(m.isEnabled, "\(phase): enabled after capture")
            }
        }
    }
}
