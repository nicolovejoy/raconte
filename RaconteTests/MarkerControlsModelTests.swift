import XCTest
@testable import Raconte

/// T6 §14 step 5 — the pure phase+toggle → marker-control mapping. Exhaustive over the
/// phases that matter, so the "which controls exist when" rules are pinned in one place
/// rather than read out of a SwiftUI body.
final class MarkerControlsModelTests: XCTestCase {

    private func model(_ phase: CaptureState, multiVoice: Bool) -> MarkerControlsModel {
        MarkerControlsModel.make(phase: phase, multiVoice: multiVoice)
    }

    /// Owner ruling, 2026-08-16 smoke: "when I select Two Voices, show the switcher button
    /// right away, don't wait for me to hit record. Just greyed out. Same with paragraph
    /// button, leave it up, but grey, when not recording."
    ///
    /// Supersedes the original rule, which showed nothing until `.recording`. The controls
    /// were the answer to "can this reading be marked at all", and that question is asked
    /// BEFORE the record button is pressed, not after — hiding them until recording made the
    /// Two-voices toggle's effect invisible at exactly the moment it is being decided.
    func testControlsAreShownButDisabledBeforeRecording() {
        for phase in [CaptureState.idle, .preparing] {
            let on = model(phase, multiVoice: true)
            XCTAssertTrue(on.showsVoiceControl,
                          "\(phase): Two voices is on, so the switcher must already be visible")
            XCTAssertTrue(on.showsParagraphControl, "\(phase): paragraph control hidden")
            XCTAssertFalse(on.isEnabled, "\(phase): a tap must not land before recording")

            let off = model(phase, multiVoice: false)
            XCTAssertTrue(off.showsParagraphControl,
                          "\(phase): the paragraph button stands regardless of Two voices")
            XCTAssertFalse(off.isEnabled, "\(phase): a tap must not land before recording")
        }
    }

    /// The visible-but-disabled rule must not quietly become visible-AND-tappable: a tap
    /// landing outside `.recording` has no frame to attach a marker to.
    func testTapsOnlyEverLandWhileRecording() {
        for phase in CaptureState.allCases {
            for multiVoice in [true, false] {
                XCTAssertEqual(model(phase, multiVoice: multiVoice).isEnabled,
                               phase == .recording,
                               "\(phase) multiVoice=\(multiVoice): enabled must track .recording exactly")
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

    /// Same ruling, carried through the tail phases: the buttons stand, greyed, rather than
    /// vanishing the instant Done is pressed. One shape in every phase is also the simplest
    /// way to keep the #53 promise that nothing in the control bar moves.
    func testControlsStayShownButDisabledAfterCapture() {
        for phase in [CaptureState.stopping, .captured, .finalizing, .complete] {
            let on = model(phase, multiVoice: true)
            XCTAssertTrue(on.showsVoiceControl, "\(phase): voice control vanished after capture")
            XCTAssertTrue(on.showsParagraphControl, "\(phase): paragraph control vanished")
            XCTAssertFalse(on.isEnabled, "\(phase): enabled after capture")

            XCTAssertTrue(model(phase, multiVoice: false).showsParagraphControl,
                          "\(phase): paragraph control vanished with Two voices off")
        }
    }

    /// The voice switch is the ONE control still gated on the toggle, in every phase — it is
    /// what the toggle means. The paragraph button never was (owner decision 7).
    func testVoiceControlIsGatedOnMultiVoiceInEveryPhase() {
        for phase in CaptureState.allCases {
            XCTAssertEqual(model(phase, multiVoice: true).showsVoiceControl, true,
                           "\(phase): voice control hidden with Two voices on")
            XCTAssertEqual(model(phase, multiVoice: false).showsVoiceControl, false,
                           "\(phase): voice control shown with Two voices off")
            XCTAssertTrue(model(phase, multiVoice: false).showsParagraphControl,
                          "\(phase): paragraph control must not be gated on Two voices")
        }
    }
}
