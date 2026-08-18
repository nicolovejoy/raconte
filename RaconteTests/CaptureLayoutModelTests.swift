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

    func testLastEntryIsHiddenWhileCapturing() {
        for phase in capturingPhases {
            XCTAssertFalse(layout(phase).showsLastEntry,
                           "\(phase): the last-entry row still occupies height during a capture")
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

    // MARK: - Approach 2, 2026-08-16 IA discussion
    //
    // Owner: "there are three sections on the iPhone screen... the fact that there's two
    // scrollable sections above [the bottom control bar] doesn't make any sense at all to
    // me... I would rather have none, especially during the recording." The two scroll
    // views were the setup band (squeezed into `setupHeightWhileCapturing` and forced to
    // scroll internally) and the transcript. Bounded content — the journal name, the
    // backdate — should never need a scroll region of its own; only the transcript is
    // genuinely unbounded. These two flags are how the setup band stops needing one.

    func testBackdateFieldIsCompactWhileCapturing() {
        for phase in capturingPhases {
            XCTAssertTrue(layout(phase).usesCompactBackdateField,
                          "\(phase): the full inline backdate field is still on screen — "
                          + "it is exactly the content that forced a second scroll view")
        }
    }

    func testRecoveryBannersAreHiddenWhileCapturing() {
        for phase in capturingPhases {
            XCTAssertFalse(layout(phase).showsRecoveryBanners,
                           "\(phase): a launch-recovery banner still occupies height during "
                           + "a capture")
        }
    }

    /// The owner's explicit constraint: idle must look exactly as it did. This fix is not
    /// licence to redesign the capture landing — that redesign is separately scoped and
    /// deliberately deferred until it can be discussed on a large screen.
    func testIdleShowsTheLandingLayout() {
        let idle = layout(.idle)
        XCTAssertEqual(idle.mode, .setup)
        XCTAssertTrue(idle.showsLastEntry, "idle lost the last-entry row")
        XCTAssertTrue(idle.showsMultiVoiceField, "idle lost the Two-voices toggle")
        XCTAssertFalse(idle.transcriptFillsAvailableHeight,
                       "idle must not give the transcript the whole screen")
        XCTAssertFalse(idle.usesCompactBackdateField,
                       "idle must keep the full inline backdate field — it is a browsing "
                       + "screen, where one honest scroll region is fine")
        XCTAssertTrue(idle.showsRecoveryBanners, "idle lost the launch-recovery banners")
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
    func testReceiptReplacesTheLandingControls() {
        let receipt = CaptureLayoutModel.make(phase: .idle, hasReceipt: true)
        XCTAssertTrue(receipt.showsReceipt)
        XCTAssertFalse(receipt.showsLastEntry,
                       "the receipt IS the last entry; showing the row too is a duplicate")
        XCTAssertFalse(receipt.showsMultiVoiceField)
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
