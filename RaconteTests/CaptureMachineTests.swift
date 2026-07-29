import XCTest
@testable import Raconte

final class CaptureMachineTests: XCTestCase {

    private let machine = CaptureMachine(resumeRetryBudget: 3, finalizeBudget: 3)

    // MARK: Helpers — build a state parked in a given phase.

    private func state(_ phase: CaptureState,
                       stateSeq: Int = 5,
                       captureID: String? = "01CAPTURE",
                       segmentIndex: Int = 0,
                       retryCount: Int = 0,
                       finalizeAttempts: Int = 0) -> MachineState {
        MachineState(phase: phase, stateSeq: stateSeq, captureID: captureID,
                     segmentIndex: segmentIndex, retryCount: retryCount,
                     finalizeAttempts: finalizeAttempts)
    }

    /// Index of the first `writeManifest` effect, or nil.
    private func manifestIndex(_ effects: [Effect]) -> Int? {
        effects.firstIndex { if case .writeManifest = $0 { return true } else { return false } }
    }

    private func manifest(_ effects: [Effect]) -> ManifestUpdate? {
        for e in effects { if case .writeManifest(let m) = e { return m } }
        return nil
    }

    // MARK: Row 1 — idle -> preparing.

    func testRow1_record() {
        let (next, effects) = machine.reduce(.idle, .record(captureID: "01ABC"))
        XCTAssertEqual(next.phase, .preparing)
        XCTAssertEqual(next.captureID, "01ABC")
        XCTAssertEqual(next.stateSeq, 1)
        XCTAssertEqual(effects, [
            .createCaptureDirectory(captureID: "01ABC"),
            .writeManifest(.init(state: .preparing, stateSeq: 1)),
            .requestPermissionAndConfigure,
        ])
    }

    // MARK: Row 2 — preparing -> recording.

    func testRow2_engineReady() {
        let (next, effects) = machine.reduce(state(.preparing), .engineReady)
        XCTAssertEqual(next.phase, .recording)
        XCTAssertEqual(next.segmentIndex, 0)
        XCTAssertEqual(effects, [
            .writeManifest(.init(state: .recording, stateSeq: 6)),
            .installTapAndOpenSegment(index: 0),
        ])
    }

    // MARK: Row 3 — preparing -> idle.

    func testRow3_prepareFailed() {
        let (next, effects) = machine.reduce(state(.preparing), .prepareFailed(.permissionDenied))
        XCTAssertEqual(next.phase, .idle)
        XCTAssertNil(next.captureID)
        XCTAssertEqual(effects, [
            .tearDownEngine,
            .surfaceError(.permissionDenied),
            .deleteCaptureDirectory,
        ])
        // Row 3 writes no manifest (the dir is deleted).
        XCTAssertNil(manifest(effects))
    }

    // MARK: Row 4 — recording -> recording (rotation).

    func testRow4_rotation() {
        let (next, effects) = machine.reduce(state(.recording, segmentIndex: 7), .rotationTick)
        XCTAssertEqual(next.phase, .recording)
        XCTAssertEqual(next.segmentIndex, 8)
        XCTAssertEqual(effects, [
            .closeLiveSegment(reason: .rotation),
            .writeManifest(.init(state: .recording, stateSeq: 6, segmentCount: 8)),
            .openNextSegment(index: 8),
        ])
        // Close (sidecar) precedes the manifest that claims the new count.
        XCTAssertLessThan(effects.firstIndex(of: .closeLiveSegment(reason: .rotation))!,
                          manifestIndex(effects)!)
    }

    // MARK: Rows 5/6/7 — recording -> interrupted.

    func testRow5_interruptionBegan_closesSegmentBeforeStateFlips() {
        let (next, effects) = machine.reduce(state(.recording, segmentIndex: 3), .interruptionBegan)
        XCTAssertEqual(next.phase, .interrupted)
        XCTAssertEqual(next.segmentIndex, 4)
        XCTAssertEqual(effects, [
            .stopEngine,
            .closeLiveSegment(reason: .interruption),
            .writeManifest(.init(state: .interrupted, stateSeq: 6, segmentCount: 4, appendInterruption: true)),
        ])
        // Effect ordering: the live segment closes BEFORE the manifest flips to interrupted.
        let closeIdx = effects.firstIndex(of: .closeLiveSegment(reason: .interruption))!
        XCTAssertLessThan(closeIdx, manifestIndex(effects)!)
    }

    func testRow6_routeLost() {
        let (next, effects) = machine.reduce(state(.recording, segmentIndex: 3), .routeLost)
        XCTAssertEqual(next.phase, .interrupted)
        XCTAssertEqual(effects, [
            .stopEngine,
            .closeLiveSegment(reason: .interruption),
            .writeManifest(.init(state: .interrupted, stateSeq: 6, segmentCount: 4, appendInterruption: true)),
        ])
    }

    func testRow7_mediaServicesReset_discardsEngine() {
        let (next, effects) = machine.reduce(state(.recording, segmentIndex: 0), .mediaServicesReset)
        XCTAssertEqual(next.phase, .interrupted)
        XCTAssertEqual(effects, [
            .discardEngine,
            .closeLiveSegment(reason: .interruption),
            .writeManifest(.init(state: .interrupted, stateSeq: 6, segmentCount: 1, appendInterruption: true)),
        ])
    }

    // MARK: Row 8 — interrupted -> resuming.

    func testRow8_resume() {
        let (next, effects) = machine.reduce(state(.interrupted, retryCount: 1), .resume)
        XCTAssertEqual(next.phase, .resuming)
        XCTAssertEqual(next.retryCount, 1)
        XCTAssertEqual(effects, [
            .writeManifest(.init(state: .resuming, stateSeq: 6)),
            .rebuildSessionAndEngine,
        ])
    }

    // MARK: Row 9 — resuming -> recording.

    func testRow9_engineReady_opensNextSegmentAndResetsRetry() {
        let (next, effects) = machine.reduce(state(.resuming, segmentIndex: 4, retryCount: 2), .engineReady)
        XCTAssertEqual(next.phase, .recording)
        XCTAssertEqual(next.retryCount, 0, "successful resume resets the retry budget")
        XCTAssertEqual(effects, [
            .writeManifest(.init(state: .recording, stateSeq: 6)),
            .installTapAndOpenSegment(index: 4),
        ])
    }

    // MARK: Rows 10/11 — resuming reacquire fail (retry budget).

    func testRows10and11_retryBudget() {
        // Budget 3: fails 1..3 stay interrupted; fail 4 -> captured.
        var s = state(.resuming, retryCount: 0)
        for expected in 1...3 {
            let (next, effects) = machine.reduce(s, .reacquireFailed)
            XCTAssertEqual(next.phase, .interrupted, "fail #\(expected) stays interrupted")
            XCTAssertEqual(next.retryCount, expected)
            XCTAssertEqual(effects, [
                .writeManifest(.init(state: .interrupted, stateSeq: s.stateSeq + 1, retryCount: expected)),
                .scheduleResumeBackoff,
            ])
            // Re-enter resuming for the next attempt (carry retryCount forward).
            s = MachineState(phase: .resuming, stateSeq: next.stateSeq, captureID: next.captureID,
                             segmentIndex: next.segmentIndex, retryCount: next.retryCount,
                             finalizeAttempts: next.finalizeAttempts)
        }
        // Budget exhausted: N+1 -> captured.
        let (giveUp, effects) = machine.reduce(s, .reacquireFailed)
        XCTAssertEqual(giveUp.phase, .captured)
        XCTAssertEqual(effects, [.writeManifest(.init(state: .captured, stateSeq: s.stateSeq + 1))])
    }

    // MARK: Row 12 — recording -> stopping.

    func testRow12_done() {
        let (next, effects) = machine.reduce(state(.recording, segmentIndex: 2), .done)
        XCTAssertEqual(next.phase, .stopping)
        XCTAssertEqual(effects, [
            .writeManifest(.init(state: .stopping, stateSeq: 6)),
            .beginFlushWindow,
        ])
    }

    // MARK: Row 13 — stopping -> captured.

    func testRow13_tailDrained() {
        let (next, effects) = machine.reduce(state(.stopping, segmentIndex: 2), .tailDrained)
        XCTAssertEqual(next.phase, .captured)
        XCTAssertEqual(next.segmentIndex, 3)
        XCTAssertEqual(effects, [
            .closeLiveSegment(reason: .stop),
            .stopEngine,
            .releaseSession,
            .writeManifest(.init(state: .captured, stateSeq: 6, segmentCount: 3)),
        ])
        // Sidecar (close) precedes the final manifest.
        XCTAssertLessThan(effects.firstIndex(of: .closeLiveSegment(reason: .stop))!,
                          manifestIndex(effects)!)
    }

    // MARK: Row 14 — interrupted -> captured (Done), no new segment.

    func testRow14_doneWhileInterrupted_noNewSegment() {
        let (next, effects) = machine.reduce(state(.interrupted, segmentIndex: 5), .done)
        XCTAssertEqual(next.phase, .captured)
        XCTAssertEqual(next.segmentIndex, 5, "segment index unchanged — nothing new closed")
        XCTAssertEqual(effects, [.writeManifest(.init(state: .captured, stateSeq: 6))])
        // No segment is closed on row 14 (already closed at row 5).
        XCTAssertFalse(effects.contains { if case .closeLiveSegment = $0 { return true } else { return false } })
    }

    // MARK: Row 15 — captured -> finalizing.

    func testRow15_finalizerPickup() {
        let (next, effects) = machine.reduce(state(.captured), .finalizerPickup)
        XCTAssertEqual(next.phase, .finalizing)
        XCTAssertEqual(effects, [
            .writeManifest(.init(state: .finalizing, stateSeq: 6)),
            .beginFinalize,
        ])
    }

    // MARK: Row 16 — finalizing -> complete.

    func testRow16_finalizeSucceeded_manifestBeforeDelete() {
        let (next, effects) = machine.reduce(state(.finalizing), .finalizeSucceeded)
        XCTAssertEqual(next.phase, .complete)
        XCTAssertEqual(effects, [
            .promoteFinalRecording,
            .writeManifest(.init(state: .complete, stateSeq: 6, markFinalVerified: true)),
            .deleteRawSegments,
        ])
        // Write-ahead: manifest `complete` is durable BEFORE raw segments are unlinked.
        XCTAssertLessThan(manifestIndex(effects)!,
                          effects.firstIndex(of: .deleteRawSegments)!)
    }

    // MARK: Rows 17/18 — finalize fail budget.

    func testRows17and18_finalizeBudget() {
        // Budget 3: fails 1..3 requeue (captured, attempts++); fail 4 -> needsAttention.
        var s = state(.finalizing, finalizeAttempts: 0)
        for expected in 1...3 {
            let (next, effects) = machine.reduce(s, .finalizeFailed)
            XCTAssertEqual(next.phase, .captured)
            XCTAssertEqual(next.finalizeAttempts, expected)
            XCTAssertEqual(effects, [
                .discardFinalPart,
                .writeManifest(.init(state: .captured, stateSeq: s.stateSeq + 1, finalizeAttempts: expected)),
            ])
            // Requeue: captured -> finalizing again, carrying finalizeAttempts.
            s = MachineState(phase: .finalizing, stateSeq: next.stateSeq, captureID: next.captureID,
                             segmentIndex: next.segmentIndex, retryCount: next.retryCount,
                             finalizeAttempts: next.finalizeAttempts)
        }
        let (flagged, effects) = machine.reduce(s, .finalizeFailed)
        XCTAssertEqual(flagged.phase, .captured)
        XCTAssertEqual(effects, [
            .discardFinalPart,
            .writeManifest(.init(state: .captured, stateSeq: s.stateSeq + 1, needsAttention: true)),
        ])
    }

    // MARK: Row 19 — disk full during recording/stopping.

    func testRow19_diskFullRecording_noDataClaiming() {
        let (next, effects) = machine.reduce(state(.recording, segmentIndex: 4), .diskFull)
        XCTAssertEqual(next.phase, .interrupted)
        XCTAssertEqual(next.segmentIndex, 4, "no segment closed — index unchanged")
        XCTAssertEqual(effects, [
            .stopEngine,
            .surfaceError(.diskFull),
            .writeManifest(.init(state: .interrupted, stateSeq: 6, lastError: .diskFull)),
        ])
        // No data-claiming: no segment close, and segmentCount is left untouched (nil).
        XCTAssertFalse(effects.contains { if case .closeLiveSegment = $0 { return true } else { return false } })
        XCTAssertNil(manifest(effects)?.segmentCount)
    }

    func testRow19_diskFullStopping() {
        let (next, effects) = machine.reduce(state(.stopping, segmentIndex: 1), .diskFull)
        XCTAssertEqual(next.phase, .interrupted)
        XCTAssertEqual(manifest(effects)?.lastError, .diskFull)
    }

    // MARK: Row 20 — app terminating (last-gasp), state unchanged.

    func testRow20_appTerminatingRecording_fsyncsLiveSegment() {
        let (next, effects) = machine.reduce(state(.recording, stateSeq: 9, segmentIndex: 2), .appTerminating)
        XCTAssertEqual(next.phase, .recording, "phase unchanged")
        XCTAssertEqual(next.stateSeq, 10, "stateSeq still bumps on the manifest touch")
        XCTAssertEqual(effects, [
            .fsyncLiveSegment,
            .writeManifest(.init(state: .recording, stateSeq: 10, touchOnly: true)),
        ])
    }

    func testRow20_appTerminatingCaptured_noLiveSegmentFsync() {
        let (next, effects) = machine.reduce(state(.captured, stateSeq: 9), .appTerminating)
        XCTAssertEqual(next.phase, .captured)
        XCTAssertEqual(effects, [
            .writeManifest(.init(state: .captured, stateSeq: 10, touchOnly: true)),
        ])
    }

    func testRow20_appTerminatingWhileIdle_isNoop() {
        let (next, effects) = machine.reduce(.idle, .appTerminating)
        XCTAssertEqual(next, .idle)
        XCTAssertTrue(effects.isEmpty)
    }

    // MARK: stateSeq monotonicity across a full lifecycle.

    func testStateSeqStrictlyIncreasesAcrossEveryTransition() {
        var s = MachineState.idle
        var lastSeq = s.stateSeq
        let script: [Event] = [
            .record(captureID: "01X"),   // 1 -> preparing
            .engineReady,                // 2 -> recording
            .rotationTick,               // 4 -> recording
            .interruptionBegan,          // 5 -> interrupted
            .resume,                     // 8 -> resuming
            .engineReady,                // 9 -> recording
            .done,                       // 12 -> stopping
            .tailDrained,                // 13 -> captured
            .finalizerPickup,            // 15 -> finalizing
            .finalizeSucceeded,          // 16 -> complete
        ]
        for event in script {
            let (next, effects) = machine.reduce(s, event)
            XCTAssertGreaterThan(next.stateSeq, lastSeq, "stateSeq must strictly increase on \(event)")
            // Every emitted manifest write carries the post-increment seq.
            if let m = manifest(effects) { XCTAssertEqual(m.stateSeq, next.stateSeq) }
            lastSeq = next.stateSeq
            s = next
        }
        XCTAssertEqual(s.phase, .complete)
    }

    func testStateSeqMonotonicWithRetriesAndInterruptions() {
        let m = CaptureMachine(resumeRetryBudget: 2, finalizeBudget: 2)
        var s = MachineState(phase: .resuming, stateSeq: 0, captureID: "01Y",
                             segmentIndex: 1, retryCount: 0, finalizeAttempts: 0)
        var lastSeq = s.stateSeq
        // Fail, resume, fail, resume, fail (exhaust budget 2) -> captured.
        let events: [Event] = [.reacquireFailed, .resume, .reacquireFailed, .resume, .reacquireFailed]
        for e in events {
            let (next, _) = m.reduce(s, e)
            XCTAssertGreaterThan(next.stateSeq, lastSeq)
            lastSeq = next.stateSeq
            s = next
        }
        XCTAssertEqual(s.phase, .captured)
    }

    // MARK: Illegal events are no-ops (stateSeq unmoved, no effects).

    func testIllegalEvent_rotationWhileIdle_isNoop() {
        let (next, effects) = machine.reduce(.idle, .rotationTick)
        XCTAssertEqual(next, .idle)
        XCTAssertEqual(next.stateSeq, 0)
        XCTAssertTrue(effects.isEmpty)
    }

    func testIllegalEvents_assortedNoops() {
        let cases: [(CaptureState, Event)] = [
            (.idle, .engineReady),
            (.idle, .done),
            (.recording, .record(captureID: "z")),
            (.recording, .engineReady),
            (.recording, .resume),
            (.recording, .tailDrained),
            (.recording, .finalizeSucceeded),
            (.preparing, .rotationTick),
            (.interrupted, .rotationTick),
            (.interrupted, .reacquireFailed),
            (.resuming, .done),
            (.stopping, .rotationTick),
            (.captured, .done),
            (.captured, .finalizeSucceeded),
            (.finalizing, .rotationTick),
            (.complete, .finalizerPickup),
            (.complete, .done),
        ]
        for (phase, event) in cases {
            let start = state(phase, stateSeq: 42)
            let (next, effects) = machine.reduce(start, event)
            XCTAssertEqual(next, start, "\(phase) + \(event) must be a no-op")
            XCTAssertTrue(effects.isEmpty, "\(phase) + \(event) must emit no effects")
        }
    }
}
