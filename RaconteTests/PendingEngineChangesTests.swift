import XCTest
@testable import Raconte

/// M4 T4 (review fix): the buffer that keeps a local change from vanishing when it
/// arrives before the engine has started.
///
/// `SyncCoordinator.launch()` runs from a `.task` and suspends twice — reading the
/// engine state, then the whole reconciliation scan — and the coordinator is an actor,
/// so a change hook (Tasks 5+) can land in either gap and reach `enqueueSaves` while
/// `CloudKitEngineControl` still has no `CKSyncEngine`. Dropping it there would be
/// invisible: nothing uploads, nothing logs, and the next launch's reconciliation covers
/// for it, so "the hooks were never wired up" looks exactly like working software.
///
/// The buffer lives in `CloudKitEngineControl`, which cannot be unit-tested without
/// CloudKit's servers — so the buffering itself is this separate pure value, and only
/// its two-line use is device-verifiable (Gate A).
final class PendingEngineChangesTests: XCTestCase {

    private let journalID = ULID.make()
    private let captureID = ULID.make()

    func testAFreshBufferIsEmpty() {
        let buffer = PendingEngineChanges()
        XCTAssertTrue(buffer.isEmpty)
        XCTAssertEqual(buffer.changes, [])
    }

    /// Order across the two kinds is the point of a single list: a save followed by a
    /// delete of the same record must not replay as a delete followed by a save, which
    /// is what two separate lists would produce.
    func testBufferedChangesReplayInArrivalOrderAcrossSavesAndDeletes() {
        var buffer = PendingEngineChanges()
        buffer.bufferSaves([.journal(id: journalID)])
        buffer.bufferDeletes([.entry(captureID: captureID)])
        buffer.bufferSaves([.audio(captureID: captureID)])

        XCTAssertEqual(buffer.drain(), [
            .save(.journal(id: journalID)),
            .delete(.entry(captureID: captureID)),
            .save(.audio(captureID: captureID)),
        ])
    }

    /// A batch keeps its own order too, and cardinality >= 2 so an implementation that
    /// buffered only the first or last name still fails.
    func testABatchOfNamesIsBufferedWholeAndInOrder() {
        var buffer = PendingEngineChanges()
        buffer.bufferSaves([.entry(captureID: captureID), .audio(captureID: captureID),
                            .liveLog(captureID: captureID)])

        XCTAssertEqual(buffer.drain(), [
            .save(.entry(captureID: captureID)),
            .save(.audio(captureID: captureID)),
            .save(.liveLog(captureID: captureID)),
        ])
    }

    /// Draining empties. Without this, `start()` replaying the buffer would enqueue
    /// every buffered change again on any later drain.
    func testDrainingEmptiesTheBufferSoNothingReplaysTwice() {
        var buffer = PendingEngineChanges()
        buffer.bufferSaves([.journal(id: journalID)])

        XCTAssertEqual(buffer.drain(), [.save(.journal(id: journalID))])
        XCTAssertTrue(buffer.isEmpty)
        XCTAssertEqual(buffer.drain(), [], "a second drain must replay nothing")
    }

    /// The no-op case `start()` relies on to stay quiet: an engine that started before
    /// any hook fired has nothing to replay and logs nothing.
    func testDrainingAnEmptyBufferYieldsNothing() {
        var buffer = PendingEngineChanges()
        XCTAssertEqual(buffer.drain(), [])
    }

    // MARK: bufferDeletes drops an already-buffered save for the same name (M4 T11 fix
    // round, review Important) — the pre-start mirror of `dropPendingSaves`'s own
    // post-start "the delete wins" guarantee.

    /// A save buffered for a record, then a delete for the SAME record, before the
    /// engine has even started: the save must not survive to replay. Without this, a
    /// local edit queuing a save moments before its capture was permanently deleted
    /// would replay to the real engine in arrival order — save then delete — once the
    /// engine finally starts, leaving the queued save reaching the server at all an
    /// undocumented assumption about `CKSyncEngine` internals rather than a guarantee
    /// this app makes itself.
    func testBufferingADeleteDropsAnAlreadyBufferedSaveForTheSameName() {
        var buffer = PendingEngineChanges()
        buffer.bufferSaves([.entry(captureID: captureID)])
        buffer.bufferDeletes([.entry(captureID: captureID)])

        XCTAssertEqual(buffer.drain(), [.delete(.entry(captureID: captureID))],
                       "the save must not survive to replay alongside (or ahead of) the delete")
    }

    /// A targeted removal, not a wipe: an unrelated buffered save for a DIFFERENT
    /// record must survive a delete for this one.
    func testBufferingADeleteLeavesUnrelatedBufferedSavesAlone() {
        var buffer = PendingEngineChanges()
        buffer.bufferSaves([.journal(id: journalID), .entry(captureID: captureID)])
        buffer.bufferDeletes([.entry(captureID: captureID)])

        XCTAssertEqual(buffer.drain(), [
            .save(.journal(id: journalID)),
            .delete(.entry(captureID: captureID)),
        ])
    }

    /// Mutation evidence (recorded, not just asserted): reverting `bufferDeletes` to
    /// its pre-fix body — a bare append with no `removeSaves` call — makes
    /// `testBufferingADeleteDropsAnAlreadyBufferedSaveForTheSameName` fail, since the
    /// buffered save would then survive to drain alongside the delete. Verified by
    /// hand during the fix round (see the task's fix report); not re-asserted here as
    /// a live mutation since this file already tests `bufferDeletes` and `removeSaves`
    /// as the two real production entry points.
}
