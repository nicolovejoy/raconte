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

    func testTranscriptFillsAvailableHeightWhileCapturing() {
        for phase in capturingPhases {
            XCTAssertTrue(layout(phase).transcriptFillsAvailableHeight,
                          "\(phase): the transcript is still capped during a capture")
        }
    }

    /// #118 §3: Ready is journal + backdate + the bar, nothing else. Ready and Recording
    /// differ ONLY in the middle band (empty vs transcript) — the flags that used to
    /// distinguish them (last entry, two voices, recovery banners, full backdate field)
    /// are gone, not pinned false.
    func testReadyIsTheBareLayout() {
        let ready = layout(.idle)
        XCTAssertEqual(ready.mode, .ready)
        XCTAssertFalse(ready.showsLiveTranscript, "nothing is being transcribed")
        XCTAssertFalse(ready.showsReceipt)
        XCTAssertFalse(ready.showsDiscardButton)
        XCTAssertFalse(ready.transcriptFillsAvailableHeight,
                       "no transcript, so nothing to give the height to")
    }

    // MARK: - The post-stop receipt (owner ruling 2026-08-15, option B)

    /// The defect the receipt exists to fix. A finished capture leaves the coordinator
    /// `.idle` — `finishCurrentCapture` spawns a fresh one — so the phase alone cannot
    /// tell "just finished a reading" from "just opened the app". That is exactly why the
    /// finished transcript ended up loose on the landing screen with nothing owning it:
    /// there was no state for it to belong to.
    func testReceiptIsItsOwnStateEvenThoughThePhaseIsIdle() {
        let receipt = CaptureLayoutModel.make(phase: .idle, hasReceipt: true)
        XCTAssertEqual(receipt.mode, .receipt)
        XCTAssertNotEqual(receipt, layout(.idle),
                          "a screen showing a receipt is indistinguishable from a plain "
                          + "idle screen — which is the bug")
    }

    /// While the receipt is up, nothing about arming the NEXT reading is on screen.
    func testReceiptOwnsTheMiddleBand() {
        let receipt = CaptureLayoutModel.make(phase: .idle, hasReceipt: true)
        XCTAssertTrue(receipt.showsReceipt)
    }

    /// The stranded-text bug, pinned directly: the live transcript band must never be on
    /// screen outside a capture, in either settled state.
    func testLiveTranscriptOnlyExistsDuringACapture() {
        for phase in capturingPhases {
            XCTAssertTrue(layout(phase).showsLiveTranscript,
                          "\(phase): no live transcript while capturing")
        }
        for phase in settledPhases {
            XCTAssertFalse(layout(phase).showsLiveTranscript,
                           "\(phase): the finished transcript is still on the landing "
                           + "screen — this is the owner's 'messed up' report")
            XCTAssertFalse(CaptureLayoutModel.make(phase: phase, hasReceipt: true)
                            .showsLiveTranscript,
                           "\(phase): the loose transcript band is drawn UNDER the receipt")
        }
    }

    /// A live capture outranks a leftover receipt in every capturing phase.
    ///
    /// If a stale receipt could survive into a recording it would cover the live
    /// transcript with the PREVIOUS entry's words — a worse version of the bug the receipt
    /// exists to fix, and one that would look like the transcriber had failed.
    func testACaptureAlwaysOutranksALeftoverReceipt() {
        for phase in capturingPhases {
            let withReceipt = CaptureLayoutModel.make(phase: phase, hasReceipt: true)
            XCTAssertEqual(withReceipt.mode, .capturing, "\(phase)")
            XCTAssertFalse(withReceipt.showsReceipt,
                           "\(phase): a stale receipt is covering a live recording")
            XCTAssertEqual(withReceipt, layout(phase),
                           "\(phase): a leftover receipt changes the recording layout")
        }
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
    ///
    /// `.resuming` is compared field-by-field, not with `==`: since Task 1 it deliberately
    /// hides Discard (a machine-busy phase, per `showsDiscardButton`'s doc), which is the
    /// one field this test is not about — everything that actually occupies screen space
    /// must still match `.recording`.
    func testLayoutDoesNotChangeAcrossAnInterruption() {
        XCTAssertEqual(layout(.interrupted), layout(.recording),
                       "layout changes when a call interrupts a reading")

        let resuming = layout(.resuming)
        let recording = layout(.recording)
        XCTAssertEqual(resuming.mode, recording.mode)
        XCTAssertEqual(resuming.showsLiveTranscript, recording.showsLiveTranscript)
        XCTAssertEqual(resuming.showsReceipt, recording.showsReceipt)
        XCTAssertEqual(resuming.transcriptFillsAvailableHeight,
                       recording.transcriptFillsAvailableHeight)
        XCTAssertFalse(resuming.showsDiscardButton,
                       "resuming is machine-busy — Discard must not race the resume")
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

    // MARK: Discard button (record-flow plan, Task 1)

    /// Discard exists to undo a mis-tap of the library's floating record button, so it is
    /// offered exactly while there is a capture the owner could still be stopping himself.
    func testDiscardIsOfferedWhileRecording() {
        XCTAssertTrue(CaptureLayoutModel.make(phase: .recording).showsDiscardButton)
    }

    /// An interrupted capture is still the owner's to abandon — the same reason
    /// `RecordControlModel` offers Done there.
    func testDiscardIsOfferedWhileInterrupted() {
        XCTAssertTrue(CaptureLayoutModel.make(phase: .interrupted).showsDiscardButton)
    }

    /// The machine-busy phases. The primary control is already disabled in all three; a
    /// Discard racing the start or the stop is a defect, not a feature.
    func testDiscardIsHiddenInMachineBusyPhases() {
        for phase in [CaptureState.preparing, .resuming, .stopping] {
            XCTAssertFalse(CaptureLayoutModel.make(phase: phase).showsDiscardButton,
                           "\(phase) must not offer Discard")
        }
    }

    /// Nothing in flight: the landing screen, the receipt, and the terminal phases.
    func testDiscardIsHiddenWhenNothingIsInFlight() {
        XCTAssertFalse(CaptureLayoutModel.make(phase: .idle).showsDiscardButton)
        XCTAssertFalse(CaptureLayoutModel.make(phase: .captured, hasReceipt: true).showsDiscardButton)
        XCTAssertFalse(CaptureLayoutModel.make(phase: .finalizing).showsDiscardButton)
        XCTAssertFalse(CaptureLayoutModel.make(phase: .complete).showsDiscardButton)
    }

    /// Every remaining flag is exercised by at least one phase in each direction — a flag
    /// that reads the same in every phase is the dead flag #74 complained about.
    func testNoRemainingFlagIsConstant() {
        let all = CaptureState.allCases.flatMap { phase in
            [CaptureLayoutModel.make(phase: phase, hasReceipt: false),
             CaptureLayoutModel.make(phase: phase, hasReceipt: true)]
        }
        XCTAssertTrue(all.contains { $0.showsLiveTranscript } && all.contains { !$0.showsLiveTranscript })
        XCTAssertTrue(all.contains { $0.showsReceipt } && all.contains { !$0.showsReceipt })
        XCTAssertTrue(all.contains { $0.showsDiscardButton } && all.contains { !$0.showsDiscardButton })
        XCTAssertTrue(all.contains { $0.transcriptFillsAvailableHeight }
                      && all.contains { !$0.transcriptFillsAvailableHeight })
    }
}
